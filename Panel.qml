import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Claude Code session browser: every past conversation, newest first, resumed
// in a terminal on Enter.
//
// Standalone panel plugin, summoned with
// `omarchy-shell shell summon diegodiaz1256.claude-sessions`. Each summon re-reads
// the transcripts, so a session that ended a moment ago is already in the
// list.
//
// Claude's own `--resume` picker only lists the directory it starts in, which
// is the thing this panel exists to fix: sessions are gathered across every
// project and carry their folder with them, so resuming is one keystroke from
// anywhere rather than a cd followed by a second pick.
Item {
  id: root

  property var shell: null
  property var manifest: null
  // The shell only injects this when the property exists on the root
  // object, and only it can resolve a directory once __sourceDir is gone.
  property var pluginRegistry: null

  property bool opened: false
  property var localSessions: []
  property var remoteSessions: []
  property bool hasRemoteHosts: false
  // Which list is on screen. Local loads on every open since it is a plain
  // filesystem scan; remote is an SSH round trip per host, so it is fetched
  // lazily on first switch and then cached until Ctrl+R, rather than
  // dialing out on every open the way local re-reads every time.
  property string view: "local"
  property bool remoteFetched: false
  property string query: ""
  property int cursor: 0
  property bool loading: false
  property bool remoteLoading: false
  property string error: ""

  readonly property var sessions: root.view === "remote" ? root.remoteSessions : root.localSessions

  readonly property string fontFamily: Style.font.family

  // Omarchy strips __sourceDir (and __isFirstParty, __hostCapabilities) from
  // a third-party plugin's manifest before handing it to the plugin, so it
  // is only ever present for a first-party one. Third-party has to recover
  // the directory through pluginRegistry.entryPointUrl() instead, which
  // resolves against the shell's own unstripped copy of the manifest.
  // entryPointUrl only needs candidate.id, and id survives the stripping,
  // so the stripped manifest is fine to pass in.
  //
  // Silent failure otherwise: an empty sourceDir here previously resolved
  // listScript to "/bin/claude-sessions-list", which does not exist, so the
  // panel hung on "Reading sessions..." forever with nothing but a
  // "Process failed to start" line in the shell's own log to explain why.
  readonly property string sourceDir: {
    if (manifest && manifest.__sourceDir) return String(manifest.__sourceDir)
    if (pluginRegistry && manifest) {
      var url = String(pluginRegistry.entryPointUrl(manifest, "panel") || "")
      var path = url.replace(/^file:\/\//, "")
      var cut = path.lastIndexOf("/")
      if (cut > 0) return path.substring(0, cut)
    }
    return ""
  }

  readonly property string listScript: root.sourceDir + "/bin/claude-sessions-list-all"

  // Matching is per-word across title, the original typed message, and folder
  // together, so "omarchy menu" finds a session whose title has one word and
  // whose path has the other. The typed message is searched but not shown: the
  // displayed title is a generated phrase that may share none of the user's
  // own words, and searching for what you remember typing should still find it.
  readonly property var filtered: {
    var q = query.trim().toLowerCase()
    if (q === "") return sessions
    var terms = q.split(/\s+/)
    var out = []
    for (var i = 0; i < sessions.length; i++) {
      var s = sessions[i]
      var hay = (s.title + " " + (s.subtitle || "") + " " + s.cwd).toLowerCase()
      var all = true
      for (var t = 0; t < terms.length; t++) {
        if (hay.indexOf(terms[t]) === -1) { all = false; break }
      }
      if (all) out.push(s)
    }
    return out
  }

  function open(payloadJson) {
    root.query = ""
    search.text = ""
    root.cursor = 0
    root.error = ""
    root.opened = true
    root.view = "local"
    reloadLocal()
    // The window is instantiated hidden, so focus set before the surface is
    // mapped lands nowhere. Re-acquire once it exists.
    Qt.callLater(function() { if (root.opened) search.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    if (listProc.running) listProc.running = false
    if (remoteProc.running) remoteProc.running = false
  }

  function reloadLocal() {
    if (listProc.running) return
    // A bare "/bin/claude-sessions-list" (sourceDir empty) fails to launch
    // with only a line in the shell's own log, and the panel would hang on
    // "Reading sessions..." forever with nothing telling the user why.
    if (!root.sourceDir) {
      root.error = "Could not find this plugin's own folder"
      return
    }
    root.loading = true
    listProc.collected = ""
    listProc.command = [root.listScript, "--no-remote"]
    listProc.running = true
  }

  function reloadRemote() {
    if (remoteProc.running) return
    if (!root.sourceDir) {
      root.error = "Could not find this plugin's own folder"
      return
    }
    root.remoteLoading = true
    remoteProc.collected = ""
    // --no-remote here too: this process only wants the SSH hosts, and the
    // local scan the base command would also run is redundant work spent
    // waiting on the (already up to date) local list a second time.
    remoteProc.command = [root.listScript, "--remote-only"]
    remoteProc.running = true
  }

  // Tab switches between local and remote sessions. Remote is fetched only
  // the first time it is switched to, then cached until Ctrl+R -- an SSH
  // round trip per host on every keypress would make the toggle feel like
  // it hangs.
  function toggleView() {
    root.view = root.view === "local" ? "remote" : "local"
    root.query = ""
    search.text = ""
    root.cursor = 0
    root.error = ""
    if (root.view === "remote" && !root.remoteFetched) reloadRemote()
  }

  // Ctrl+R re-dials whichever list is currently on screen.
  function refresh() {
    root.error = ""
    if (root.view === "remote") {
      root.remoteFetched = false
      reloadRemote()
    } else {
      reloadLocal()
    }
  }

  // Keep the cursor on a row that exists: the list shrinks as the query gets
  // longer, and a stale index would highlight nothing and resume nothing.
  onFilteredChanged: if (cursor >= filtered.length) cursor = Math.max(0, filtered.length - 1)

  function move(delta) {
    var n = filtered.length
    if (n === 0) return
    // Wrap, so holding a direction cycles rather than dead-ends.
    cursor = ((cursor + delta) % n + n) % n
    list.positionViewAtIndex(cursor, ListView.Contain)
  }

  function resume(session) {
    if (!session) return
    // Resuming by session id rather than by cwd: ids are unique across
    // projects, so the right conversation is restored even when several
    // share a folder.
    //
    // A project folder can be gone -- deleted, or on a disk that is not
    // mounted -- and a bare `cd` into it fails while the `&&` chain still
    // exits 0, so the terminal would open and vanish with the reason on a
    // window nobody gets to read. Hold it open on the error instead.
    var quotedDir = Util.shellQuote(session.cwd)
    var cmd = "if ! cd " + quotedDir + " 2>/dev/null; then "
      + "echo \"This session's folder no longer exists:\"; "
      + "echo \"  \" " + quotedDir + "; echo; "
      + "read -rsn1 -p 'Press any key to close...'; exit 1; "
      + "fi; exec claude --resume " + Util.shellQuote(session.id)

    var command = session.host
      // -t forces a PTY: claude is an interactive TUI, and without one SSH
      // would hand it a pipe instead of a terminal. BatchMode keeps a host
      // that would otherwise prompt for a password from hanging the window
      // silently instead of the folder-missing message actually showing.
      ? ["ssh", "-t", "-o", "BatchMode=yes", session.host, "bash", "-lc", cmd]
      : ["bash", "-lc", cmd]

    Quickshell.execDetached(["omarchy-launch-tui",
      "--app-id=org.omarchy.claude-resume"].concat(command))
    root.close()
  }

  function relativeTime(mtime) {
    var mins = Math.max(0, Math.floor(Date.now() / 1000 - mtime) / 60)
    if (mins < 1) return "just now"
    if (mins < 60) return Math.floor(mins) + "m ago"
    var hours = mins / 60
    if (hours < 24) return Math.floor(hours) + "h ago"
    var days = Math.floor(hours / 24)
    if (days < 30) return days + "d ago"
    return Math.floor(days / 30) + "mo ago"
  }

  function shortPath(path) {
    var home = Quickshell.env("HOME")
    if (home && path.indexOf(home) === 0) return "~" + path.substring(home.length)
    return path
  }

  Process {
    id: listProc
    property string collected: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: listProc.collected = String(text || "")
    }
    onExited: function(exitCode) {
      root.loading = false
      if (!root.opened) return
      if (exitCode !== 0) {
        // 127 is the shell/exec "not found" code, which for this script means
        // its python3 interpreter is missing rather than anything being wrong
        // with the sessions. Say which, so the fix is obvious.
        root.error = exitCode === 127
          ? "This plugin needs python3, which is not installed"
          : "Could not read Claude sessions"
        return
      }
      try {
        var parsed = JSON.parse(listProc.collected || "{}")
        root.localSessions = parsed.sessions || []
        root.hasRemoteHosts = !!parsed.hasRemoteHosts
        root.cursor = 0
      } catch (e) {
        root.error = "Could not parse the session list"
      }
    }
  }

  // Fetches every configured remote host, triggered on first switch to the
  // remote view (see toggleView) rather than on every open, since each
  // host costs an SSH round trip.
  Process {
    id: remoteProc
    property string collected: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: remoteProc.collected = String(text || "")
    }
    onExited: function(exitCode) {
      root.remoteLoading = false
      root.remoteFetched = true
      if (!root.opened) return
      if (exitCode !== 0) {
        root.error = "Could not reach any remote host"
        return
      }
      try {
        var parsed = JSON.parse(remoteProc.collected || "{}")
        root.remoteSessions = parsed.sessions || []
        root.cursor = 0
      } catch (e) {
        root.error = "Could not parse the remote session list"
      }
    }
  }

  PanelWindow {
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-claude-sessions"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
      MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    id: panelWindow

    Item {
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()

      Rectangle {
        anchors.centerIn: parent
        // Absolute pixels, clamped to the screen. Sizing this in spacing
        // units or against an ancestor's width both produced a card far
        // smaller than intended, so the dimensions are stated outright and
        // only shrink when the output is genuinely too small to hold them.
        width: Math.min(panelWindow.width - 80, 820)
        // Follows the content so a short list is a short card, capped so a
        // long one scrolls instead of running off the screen.
        height: Math.min(panelWindow.height - 80, 760,
          content.implicitHeight + Style.spacing.lg * 2)
        radius: Style.cornerRadius
        color: Color.menu.background
        border.width: 1
        border.color: Color.menu.border

        // Swallow clicks so only the scrim outside dismisses.
        MouseArea { anchors.fill: parent; onClicked: {} }

        ColumnLayout {
          id: content
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.spacing.lg
          spacing: Style.spacing.md

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md

            // The Claude mark, shipped as an SVG: neither the Nerd Font nor
            // Omarchy's own icon font has a Claude glyph -- U+F06C4, which the
            // menu uses for its Claude row, is a generic sparkle. Rendered at
            // 2x and scaled down so it stays crisp on HiDPI, and tinted with
            // the themed menu text colour so it tracks the theme.
            Item {
              width: Style.font.icon
              height: Style.font.icon

              // Claude's own orange, so the mark reads as the brand rather
              // than as one more monochrome glyph. Drawn white and recoloured
              // through a sibling MultiEffect, the pattern the bar's tray
              // uses: `layer.effect` left it untinted and it rendered raw
              // black against the dark panel.
              Image {
                id: claudeMark
                anchors.fill: parent
                // Relative to this QML file, which is the plugin's own folder.
                // Building an absolute "file://" + __sourceDir path instead
                // resolved to file:///claude-mark.svg and silently failed.
                source: "claude-mark.svg"
                sourceSize.width: Style.font.icon * 2
                sourceSize.height: Style.font.icon * 2
                fillMode: Image.PreserveAspectFit
                visible: false
                layer.enabled: true
              }

              MultiEffect {
                anchors.fill: claudeMark
                source: claudeMark
                colorization: 1.0
                colorizationColor: "#d97757"
              }
            }

            Text {
              text: "Claude Sessions"
              color: Color.menu.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.weight: Font.DemiBold
            }

            Text {
              // Only shown once there is a choice to indicate: no configured
              // remote hosts means the toggle never does anything, and
              // announcing a mode that cannot change would just be noise.
              visible: root.hasRemoteHosts
              text: root.view === "remote" ? "Remote" : "Local"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.weight: Font.DemiBold
            }

            Item { Layout.fillWidth: true }

            Text {
              // The count follows the filter, so it doubles as feedback that
              // typing is narrowing the list.
              text: root.filtered.length + (root.filtered.length === 1 ? " session" : " sessions")
              color: Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          TextField {
            id: search
            Layout.fillWidth: true
            placeholderText: "Search Claude sessions"
            onTextChanged: {
              root.query = text
              root.cursor = 0
            }

            // Arrows and Enter belong to the list while typing continues in
            // the field, so the whole panel is driven without leaving it.
            Keys.onDownPressed: root.move(1)
            Keys.onUpPressed: root.move(-1)
            Keys.onEscapePressed: root.close()
            Keys.onReturnPressed: root.resume(root.filtered[root.cursor])
            Keys.onEnterPressed: root.resume(root.filtered[root.cursor])
            // Tab would otherwise move focus off the only focusable control
            // in this window; claimed here instead to flip local/remote.
            Keys.onTabPressed: function(event) {
              if (root.hasRemoteHosts) root.toggleView()
              event.accepted = true
            }
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
                root.refresh()
                event.accepted = true
              }
            }
          }

          // The list and the empty-state message share one stretching slot.
          // A hidden ColumnLayout child stops taking part in the layout, so
          // hiding the list outright let the column collapse and pulled the
          // search field into the middle of the card. The slot always fills
          // the remaining height; only its contents swap.
          Item {
            Layout.fillWidth: true
            // Tall enough for the rows, bounded so a long list scrolls inside
            // the card rather than growing it past the screen.
            Layout.preferredHeight: Math.min(list.contentHeight, 560)
            Layout.minimumHeight: root.filtered.length > 0 ? 0 : Style.font.body * 3

            Text {
              readonly property bool activeLoading: root.view === "remote" ? root.remoteLoading : root.loading

              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              visible: root.error !== "" || activeLoading
                || (root.filtered.length === 0 && !activeLoading)
              text: root.error !== "" ? root.error
                : activeLoading
                  ? (root.view === "remote" ? "Reading remote sessions…" : "Reading sessions…")
                : root.sessions.length === 0
                  ? (root.view === "remote" ? "No remote sessions yet" : "No Claude sessions yet")
                : "No session matches “" + root.query + "”"
              color: root.error !== "" ? Color.urgent : Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            ListView {
              id: list
              anchors.fill: parent
              visible: root.filtered.length > 0
              model: root.filtered
              clip: true
              spacing: Style.spacing.xxs
              currentIndex: root.cursor
              boundsBehavior: Flickable.StopAtBounds

              delegate: Rectangle {
                required property int index
                required property var modelData

                width: list.width
                height: rowLayout.implicitHeight + Style.spacing.md * 2
                radius: Style.cornerRadius
                color: index === root.cursor ? Color.menu.selectedBackground
                  : hover.hovered ? Style.hoverFill : "transparent"
                border.width: index === root.cursor ? Style.selectedBorderWidth : 0
                border.color: Color.menu.selectedBorder

                HoverHandler {
                  id: hover
                  onHoveredChanged: if (hovered) root.cursor = index
                }
                TapHandler { onTapped: root.resume(modelData) }

                // Title on its own line at full width, then one quiet meta line
                // holding folder and age. Three competing text sizes stacked
                // against a right-aligned timestamp read as clutter; a single
                // dimmed line under a clear title reads as one item.
                ColumnLayout {
                  id: rowLayout
                  anchors.fill: parent
                  anchors.margins: Style.spacing.md
                  spacing: Style.spacing.hairline

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.spacing.sm

                    // A running session gets a small live dot ahead of its
                    // title, so a session still open elsewhere is obvious
                    // without reading the whole row.
                    Rectangle {
                      visible: !!modelData.status
                      Layout.preferredWidth: 6
                      Layout.preferredHeight: 6
                      radius: 3
                      color: Color.accent
                      Layout.alignment: Qt.AlignVCenter
                    }

                    Text {
                      Layout.fillWidth: true
                      text: modelData.title
                      color: index === root.cursor ? Color.menu.selectedText : Color.menu.text
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.subtitle
                      font.weight: index === root.cursor ? Font.DemiBold : Font.Normal
                      elide: Text.ElideRight
                      maximumLineCount: 1
                    }
                  }

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.spacing.sm

                    Text {
                      // Two configured hosts can otherwise show the same
                      // path with nothing distinguishing which machine it
                      // is on.
                      text: (modelData.host ? modelData.host + ":" : "") + root.shortPath(modelData.cwd)
                      color: Color.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideMiddle
                      maximumLineCount: 1
                      // Give the path whatever the age does not need, so a long
                      // path elides instead of pushing the age off the row.
                      Layout.maximumWidth: rowLayout.width - age.implicitWidth
                        - dot.implicitWidth - Style.spacing.sm * 2
                    }

                    Text {
                      id: dot
                      text: "·"
                      color: Color.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                      id: age
                      // A live row shows its status plus the session's own
                      // self-reported name, so it can be matched against
                      // ListAgents/SendMessage output without guessing.
                      text: modelData.status
                        ? modelData.status + (modelData.liveName ? " · " + modelData.liveName : "")
                        : root.relativeTime(modelData.mtime)
                      color: modelData.status ? Color.accent : Color.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Item { Layout.fillWidth: true }
                  }
                }
              }
            }
          }

          Text {
            Layout.fillWidth: true
            visible: root.filtered.length > 0 || root.hasRemoteHosts
            text: root.filtered.length > 0
              ? "↑↓ select · ⏎ resume · esc close"
                + (root.hasRemoteHosts ? " · tab " + (root.view === "remote" ? "local" : "remote") + " · ^r refresh" : "")
              : "tab " + (root.view === "remote" ? "local" : "remote") + " · ^r refresh · esc close"
            color: Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignRight
          }
        }
      }
    }
  }
}

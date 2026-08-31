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

  property bool opened: false
  property var sessions: []
  property string query: ""
  property int cursor: 0
  property bool loading: false
  property string error: ""

  readonly property string fontFamily: Style.font.family
  readonly property string listScript: (manifest && manifest.__sourceDir ? manifest.__sourceDir : "")
    + "/bin/claude-sessions-list"

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
    reload()
    // The window is instantiated hidden, so focus set before the surface is
    // mapped lands nowhere. Re-acquire once it exists.
    Qt.callLater(function() { if (root.opened) search.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    if (listProc.running) listProc.running = false
  }

  function reload() {
    if (listProc.running) return
    root.loading = true
    listProc.collected = ""
    listProc.command = [root.listScript]
    listProc.running = true
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
    Quickshell.execDetached(["omarchy-launch-tui",
      "--app-id=org.omarchy.claude-resume", "bash", "-lc", cmd])
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
        root.sessions = parsed.sessions || []
        root.cursor = 0
      } catch (e) {
        root.error = "Could not parse the session list"
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
                // Relative to this QML file, which is the plugin's own folder;
                // the manifest's source dir is not exposed on panel instances.
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
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              visible: root.error !== "" || root.loading
                || (root.filtered.length === 0 && !root.loading)
              text: root.error !== "" ? root.error
                : root.loading ? "Reading sessions…"
                : root.sessions.length === 0 ? "No Claude sessions yet"
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

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.spacing.sm

                    Text {
                      text: root.shortPath(modelData.cwd)
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
                      text: root.relativeTime(modelData.mtime)
                      color: Color.muted
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
            visible: root.filtered.length > 0
            text: "↑↓ select · ⏎ resume · esc close"
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

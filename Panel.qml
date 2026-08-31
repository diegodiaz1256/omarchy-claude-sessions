import QtQuick
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
// `omarchy-shell shell summon zeroge.claude-sessions`. Each summon re-reads
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
    var cmd = "cd " + Util.shellQuote(session.cwd)
      + " && exec claude --resume " + Util.shellQuote(session.id)
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
        root.error = "Could not read Claude sessions"
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
      color: Qt.rgba(0, 0, 0, 0.55)
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
        width: Math.min(panelWindow.width - 80, 1100)
        height: Math.min(panelWindow.height - 80, 820)
        radius: Style.cornerRadius
        color: Color.background
        border.width: 1
        border.color: Style.normalBorderColor

        // Swallow clicks so only the scrim outside dismisses.
        MouseArea { anchors.fill: parent; onClicked: {} }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.spacing.xxl
          spacing: Style.spacing.lg

          TextField {
            id: search
            Layout.fillWidth: true
            placeholderText: "Search Claude sessions"
            text: root.query
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

          Text {
            Layout.fillWidth: true
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
            Layout.fillWidth: true
            Layout.fillHeight: true
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
              height: rowLayout.implicitHeight + Style.spacing.xl * 2
              radius: Style.cornerRadius
              color: index === root.cursor ? Style.selectedFill
                : hover.hovered ? Style.hoverFill : "transparent"

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
                anchors.margins: Style.spacing.xl
                spacing: Style.spacing.xs

                Text {
                  Layout.fillWidth: true
                  text: modelData.title
                  color: Color.foreground
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

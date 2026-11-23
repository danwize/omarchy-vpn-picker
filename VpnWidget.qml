import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget for omarchy-vpn-picker. Polls `bin/omarchy-vpn-picker status
// --json` from this plugin folder and shows a VPN glyph, dimmed while nothing
// is connected. Left-click opens the picker menu, right-click shows the
// status as a notification, middle-click refreshes.
BarWidget {
  id: root
  moduleName: "io.github.danwize.vpn-picker"

  readonly property string script: decodeURIComponent(
    Qt.resolvedUrl("bin/omarchy-vpn-picker").toString().replace(/^file:\/\//, ""))
  readonly property int refreshSec: Math.max(2, Number(setting("refreshIntervalSec", 10)) || 10)
  readonly property bool hideWhenDisconnected: setting("hideWhenDisconnected", false) === true

  property bool connected: false
  property string tooltip: "VPN: not connected"

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function applyStatus(text) {
    try {
      var s = JSON.parse(String(text || "").trim())
      root.connected = s.connected === true
      root.tooltip = String(s.tooltip || "")
    } catch (e) {
      root.connected = false
      root.tooltip = "VPN: status unavailable"
    }
  }

  visible: root.connected || !root.hideWhenDisconnected
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: [root.script, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // A connect or disconnect started from the menu settles a few seconds
  // later; check again soon instead of waiting for the next interval.
  Timer {
    id: settleTimer
    interval: 4000
    repeat: false
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(root.connected ? 0xF0582 : 0xF099E)
    opacity: root.connected ? 1.0 : 0.55
    slotSize: Style.bar.statusSlot
    tooltipText: root.tooltip

    onPressed: function(b) {
      if (b === Qt.MiddleButton) {
        root.refresh()
      } else if (b === Qt.RightButton) {
        Util.execArgv(["notify-send", "VPN Picker", root.tooltip])
      } else {
        Util.execArgv([root.script, "menu"])
        settleTimer.restart()
      }
    }
  }
}

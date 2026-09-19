// EGPU Buddy desktop app: native Qt6/QML window + system-tray icon around the local backend (egpu-buddy-server.py).
// Why QML: SteamOS ships KDE Plasma, so Qt6 + QtQuick Controls + Qt.labs.platform are always there, while WebKitGTK is not
// (the app used to fall back to a browser tab on SteamOS). Run by the launcher (which also selects the Fusion style and Qt's generic platform theme, see there)
// Test hook: `-- --shot /path.png` renders one frame after the first status, saves it and quits (used with the offscreen platform).
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt.labs.platform as Platform

ApplicationWindow {
    id: win
    width: 900; height: 640; minimumWidth: 640; minimumHeight: 520
    readonly property bool startHidden: Qt.application.arguments.indexOf("--tray") >= 0
    visible: !startHidden
    property int showSeq: -1                   // the launcher asks a running instance to show itself through the backend
    title: "EGPU Buddy"
    // own dark palette + the Fusion style (selected by the launcher): the same look on every desktop theme and distro
    palette { window: "#0b1016"; windowText: "#dfe8f0"; base: "#101720"; alternateBase: "#162030"; text: "#dfe8f0"
              button: "#1b2633"; buttonText: "#dfe8f0"; highlight: "#1a9fff"; highlightedText: "#ffffff"
              mid: "#3a4a5c"; dark: "#070a0e"; light: "#2a3848"; placeholderText: "#7f8fa0"; toolTipBase: "#162030"; toolTipText: "#dfe8f0" }
    readonly property string api: "http://127.0.0.1:8772"
    property var s: ({})                       // last /api/status
    property var g: (s.gpu || {})
    readonly property bool on: !!(s.present && s.driver_loaded && g.name)
    property bool sliderTouched: false
    property string msg: "Ready."
    property bool msgErr: false

    function num(v, d) { var x = parseFloat(v); return isNaN(x) ? "–" : x.toFixed(d || 0) }
    function call(method, path, body, cb) {
        var x = new XMLHttpRequest(); x.open(method, api + path)
        x.onreadystatechange = function() { if (x.readyState !== XMLHttpRequest.DONE) return
            var r = null; try { r = JSON.parse(x.responseText) } catch (e) {}
            cb(r, x.status) }
        if (body) { x.setRequestHeader("content-type", "application/json"); x.send(JSON.stringify(body)) } else x.send()
    }
    function refresh() {
        call("GET", "/api/status", null, function(r) {
            if (!r) { msg = "The EGPU Buddy backend is not answering (it starts with the app; reopen EGPU Buddy)."; msgErr = true; return }
            s = r
            if (showSeq >= 0 && (r.show_seq || 0) !== showSeq) { win.show(); win.raise(); win.requestActivate() }
            showSeq = r.show_seq || 0
            if (on && !sliderTouched) { pl.from = Math.max(100, Math.round(+g["power.min_limit"] || 100)); pl.to = Math.min(320, Math.round(+g["power.max_limit"] || 320)); pl.value = Math.round(+g["power.limit"] || pl.to) }
            var d = r.detach, gm = r.gm, l = r.last
            if (d && d.state && d.state !== "IDLE") { msgErr = /FAIL|DO_NOT|INCOMPLETE/.test(d.state); msg = d.state + ": " + (d.message || "") }
            else if (gm && gm.state && gm.state !== "ATTACHED") { msgErr = false; msg = gm.state + ": " + (gm.message || "") }
            else if (l && l.action) { msgErr = l.state === "failed"
                msg = l.state === "running" ? l.action + ": working…" : l.state === "ok" ? l.action + ": done." + (l.out ? "\n" + l.out : "") : l.action + " failed (rc " + l.rc + ")\n" + (l.out || "no output") }
            if (shot.length) shotTimer.start()
        })
    }
    function act(action, extra) {
        var b = { action: action }; for (var k in (extra || {})) b[k] = extra[k]
        call("POST", "/api/action", b, function(r) {
            if (!r) { msg = "Failed: no answer from the backend"; msgErr = true; return }
            msgErr = !r.ok; msg = r.ok ? (r.started ? "Started: " + r.started : (r.out || "Done.")) : "Failed: " + (r.error || r.out || "?")
            refresh() })
    }
    Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true; onTriggered: win.refresh() }

    // closing the window keeps the tray icon (and the backend) alive; Quit is in the tray menu
    onClosing: function(close) { if (tray.available && !win.shot.length) { close.accepted = false; win.hide() } }

    Platform.SystemTrayIcon {
        id: tray
        visible: !win.shot.length
        icon.source: Qt.resolvedUrl("egpu-buddy.png")
        tooltip: "EGPU Buddy — " + (win.s.present ? (win.g.name || "eGPU on the bus") : "no eGPU")
        onActivated: function(reason) { if (reason !== Platform.SystemTrayIcon.Context) { win.show(); win.raise(); win.requestActivate() } }
        menu: Platform.Menu {
            Platform.MenuItem { text: "Open EGPU Buddy"; onTriggered: { win.show(); win.raise(); win.requestActivate() } }
            Platform.MenuSeparator {}
            Platform.MenuItem { text: "Safe Detach…"; enabled: !!win.s.present; onTriggered: { win.show(); win.raise(); confirmDetach.open() } }
            Platform.MenuItem { text: "Re-attach"; enabled: !(win.s.present && win.s.driver_loaded); onTriggered: win.act("attach") }
            Platform.MenuSeparator {}
            Platform.MenuItem { text: "Quit"; onTriggered: Qt.quit() }
        }
    }

    Dialog {
        id: confirmDetach
        title: "Safe Detach"; modal: true; anchors.centerIn: parent; width: Math.min(win.width - 80, 520)
        standardButtons: Dialog.Ok | Dialog.Cancel
        Label { width: parent.width; wrapMode: Text.WordWrap
            text: "The session moves back to the handheld screen and the eGPU is removed from the bus. Do not unplug until the result says it is safe. Continue?" }
        onAccepted: win.act("safe-detach")
    }

    component Badge: Rectangle {
        property string text; property bool lit
        radius: 10; height: 22; width: lbl.implicitWidth + 18
        color: lit ? palette.highlight : "transparent"; border.color: lit ? palette.highlight : palette.mid
        Label { id: lbl; anchors.centerIn: parent; text: parent.text; font.pixelSize: 11; font.capitalization: Font.AllUppercase
                color: parent.lit ? palette.highlightedText : palette.windowText }
    }
    component Cell: Frame {
        property string value; property string unit; property string label
        Layout.fillWidth: true; Layout.preferredWidth: 1
        ColumnLayout { anchors.fill: parent; spacing: 2
            Label { Layout.alignment: Qt.AlignHCenter; text: value + (unit ? " " + unit : ""); font.pixelSize: 20; font.bold: true }
            Label { Layout.alignment: Qt.AlignHCenter; text: label; font.pixelSize: 11; opacity: 0.7; font.capitalization: Font.AllUppercase } }
    }

    ScrollView {
        id: view
        anchors.fill: parent; contentWidth: availableWidth
        background: Rectangle { color: palette.window }
        ColumnLayout {
            width: win.width - 32; x: 16; y: 12; spacing: 12
            RowLayout { Layout.fillWidth: true; spacing: 10
                Label { text: "EGPU Buddy"; font.pixelSize: 22; font.bold: true }
                Label { text: win.g.name || (win.s.present ? "NVIDIA GPU (driver not loaded)" : "not detected"); opacity: 0.75; Layout.fillWidth: true; elide: Text.ElideRight }
                Badge { text: win.s.present ? "On the bus" : "No eGPU"; lit: !!win.s.present }
                Badge { text: win.s.tunnel ? "Tunnel up" : "No tunnel"; lit: !!win.s.tunnel }
                Badge { text: win.s.driver_loaded ? "Driver loaded" : "Driver unloaded"; lit: !!win.s.driver_loaded }
                Badge { text: win.s.game_mode ? "Game Mode" : "Desktop"; lit: true }
            }
            GridLayout { Layout.fillWidth: true; columns: 4; columnSpacing: 8; rowSpacing: 8
                Cell { value: win.num(win.g["temperature.gpu"]); unit: "°C"; label: "GPU temp" }
                Cell { value: win.num(win.g["power.draw"]); unit: win.g["power.limit"] ? "/ " + win.num(win.g["power.limit"]) + " W" : "W"; label: "Power" }
                Cell { value: win.num(win.g["utilization.gpu"]); unit: "%"; label: "GPU util" }
                Cell { value: win.g["memory.used"] ? win.num(win.g["memory.used"] / 1024, 1) + " G" : "–"; label: "VRAM" }
                Cell { value: win.num(win.g["clocks.gr"]); unit: "MHz"; label: "GPU clock" }
                Cell { value: win.num(win.g["clocks.mem"]); unit: "MHz"; label: "Memory clock" }
                Cell { value: win.num(win.g["fan.speed"]); unit: "%"; label: "Fan" }
                Cell { value: win.g["pcie.link.gen.current"] ? "Gen" + win.g["pcie.link.gen.current"] + " x" + win.g["pcie.link.width.current"] : "–"; label: "PCIe link" }
            }
            Flow { Layout.fillWidth: true; spacing: 14
                Label { text: "Driver  <b>" + (win.g.driver_version || "—") + "</b>"; textFormat: Text.StyledText }
                Label { text: "Bus  <b>" + (win.s.bdf || "—") + "</b>"; textFormat: Text.StyledText }
                Label { text: "VRAM  <b>" + (win.g["memory.total"] ? win.num(win.g["memory.total"] / 1024) + " GB" : "—") + "</b>"; textFormat: Text.StyledText }
                Label { text: "Displays  <b>" + ((win.s.displays || []).map(function(d) { return d.name + (d.enabled ? "" : " (off)") }).join(", ") || "none") + "</b>"; textFormat: Text.StyledText }
                Label { text: "Handheld panel  <b>" + (win.s.panel_enabled == null ? "—" : win.s.panel_enabled ? "on" : "off") + "</b>"; textFormat: Text.StyledText }
            }
            Label { text: "Power"; font.bold: true; opacity: 0.7; font.capitalization: Font.AllUppercase; font.pixelSize: 11 }
            RowLayout { Layout.fillWidth: true; spacing: 10
                Label { text: "Power limit" }
                Slider { id: pl; Layout.fillWidth: true; from: 100; to: 320; stepSize: 5; value: 320; enabled: win.on; onMoved: win.sliderTouched = true }
                Label { text: win.on ? Math.round(pl.value) + " W" : "– W"; Layout.preferredWidth: 60; horizontalAlignment: Text.AlignRight }
                Button { text: "Apply"; enabled: win.on; opacity: enabled ? 1 : 0.4; onClicked: { win.act("power-limit", { watts: Math.round(pl.value) }); win.sliderTouched = false } }
            }
            Label { text: "Lifecycle"; font.bold: true; opacity: 0.7; font.capitalization: Font.AllUppercase; font.pixelSize: 11 }
            RowLayout { Layout.fillWidth: true; spacing: 10
                Button { text: "Safe Detach"; Layout.fillWidth: true; enabled: !!win.s.present; opacity: enabled ? 1 : 0.4; onClicked: confirmDetach.open() }
                Button { text: "Re-attach"; Layout.fillWidth: true; enabled: !(win.s.present && win.s.driver_loaded); opacity: enabled ? 1 : 0.4; onClicked: win.act("attach") }
                Button { text: "Reset clocks"; Layout.fillWidth: true; enabled: win.on; opacity: enabled ? 1 : 0.4; onClicked: win.act("reset-clocks") }
            }
            Frame { Layout.fillWidth: true
                Label { width: parent.width; wrapMode: Text.WordWrap; text: win.msg; color: win.msgErr ? "#e05555" : palette.windowText } }
            Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; opacity: 0.6; font.pixelSize: 11
                text: "Safe Detach moves the desktop back to the handheld and removes the card; only then unplug. Closing this window keeps EGPU Buddy in the system tray." }
        }
    }

    // ---- self-test: one frame to a PNG, then quit ----
    readonly property string shot: Qt.application.arguments.indexOf("--shot") >= 0 ? (Qt.application.arguments[Qt.application.arguments.indexOf("--shot") + 1] || "") : ""
    Timer { id: shotTimer; interval: 600; onTriggered: view.grabToImage(function(r) { console.log("shot saved: " + r.saveToFile(win.shot)); Qt.quit() }) }
}

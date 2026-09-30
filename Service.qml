import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root
    property var shell: null
    property var manifest: null
    property var status: ({ mode: "auto", tablet: false, attached: true, keyboardAvailable: false, favorites: [] })
    property bool keyboardVisible: false
    property bool homeOpen: false
    property string page: "home"
    property bool switcherOpen: false
    property string message: ""
    readonly property bool tablet: status.tablet === true
    readonly property var apps: shell ? shell.appLibrary : null
    property int appsRevision: 0

    function command(action, value) {
        if (backend.running) backend.write(JSON.stringify({action: action, value: value}) + "\n")
    }
    function openPage(value) { switcherOpen = false; page = value; homeOpen = true }
    function home(all) { openPage(all ? "apps" : "home") }
    function close() { homeOpen = false; switcherOpen = false }
    function openSwitcher() { command("hideKeyboard"); switcherOpen = true; homeOpen = false }
    function closeSwitcher() { switcherOpen = false }
    function launch(entry) {
        if (!entry || !apps) return
        // Wayland IM modules let Squeekboard receive text-input events.
        // gtk-launch handles desktop-entry quoting, actions and field codes.
        Quickshell.execDetached(["env", "GTK_IM_MODULE=wayland", "QT_IM_MODULE=wayland",
            "uwsm-app", "--", "gtk-launch", entry.id + ".desktop"])
        close()
    }
    function favorite(id) { command("favorite", id) }
    function run(argv) { Quickshell.execDetached(argv) }

    Process {
        id: keyboardWatch
        command: ["python3", "-B", decodeURIComponent(Qt.resolvedUrl("keyboard_watch.py").toString().replace(/^file:\/\//, ""))]
        running: true
        stdout: SplitParser {
            onRead: function(line) {
                try { root.keyboardVisible = JSON.parse(line).visible }
                catch (e) { console.warn("Invalid keyboard visibility signal") }
            }
        }
        onExited: { root.keyboardVisible = false; watchRestart.restart() }
    }
    Timer { id: watchRestart; interval: 4000; onTriggered: keyboardWatch.running = true }

    Process {
        id: backend
        command: ["python3", "-B", decodeURIComponent(Qt.resolvedUrl("tablet.py").toString().replace(/^file:\/\//, "")), "daemon"]
        stdinEnabled: true
        running: true
        stdout: SplitParser {
            onRead: function(line) {
                try {
                    const next = JSON.parse(line)
                    root.status = next
                    root.message = next.error || ""
                } catch (e) { console.warn("Omarchy Tablet: invalid backend response") }
            }
        }
        onExited: restart.restart()
    }
    Timer { id: restart; interval: 4000; onTriggered: backend.running = true }
    Connections {
        target: root.apps
        function onAppsChanged() { root.appsRevision++ }
    }
    IpcHandler {
        target: "tablet"
        function home(): void { root.home(false) }
        function apps(): void { root.home(true) }
        function close(): void { root.close() }
        function switcher(): void { if (root.switcherOpen) root.closeSwitcher(); else root.openSwitcher() }
        function settings(): void { root.openPage("settings") }
        function mode(value: string): void { root.command("mode", value) }
        function layout(value: string): void { root.command("layout", value) }
        function dictation(): void { root.command("dictation") }
        function hideKeyboard(): void { root.command("hideKeyboard") }
        function keyboardActivation(value: string): void { root.command("keyboardActivation", value) }
        function keyboardStyle(value: string): void { root.command("keyboardStyle", value) }
        function keyboard(): void { root.command("keyboard") }
        function autoRotate(value: string): void { root.command("autoRotate", value === "true" || value === "on" || value === "auto") }
        function rotationLock(value: string): void { root.command("rotationLock", value === "true" || value === "lock" || value === "locked" ? true : (value === "toggle" ? "toggle" : false)) }
        function orientation(value: string): void { root.command("orientation", Number(value)) }
        function build(): string { return Qt.resolvedUrl("tablet.py").toString() }
        function status(): string { return JSON.stringify(root.status) }
        function view(): string { return JSON.stringify({home: root.homeOpen, switcher: root.switcherOpen, page: root.page, keyboard: root.keyboardVisible}) }
    }
}

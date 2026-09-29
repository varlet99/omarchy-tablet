pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQml.Models
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons

Item {
    id: root
    property var shell: null
    property var manifest: null
    property var barConfig: ({})
    property var pluginRegistry: null
    property var barWidgetRegistry: null
    property var service: shell ? shell.serviceFor("surface.tablet") : null
    readonly property bool tablet: service ? service.tablet : false
    readonly property var internalScreen: Quickshell.screens.find(s => /^(eDP|DSI|LVDS)/.test(s.name)) || Quickshell.screens[0]
    property var entries: []
    property string entriesJson: ""

    function updateEntries() {
        const layout = barConfig.layout || {}
        const next = [].concat(layout.left || [], layout.center || [], layout.right || [])
        const json = JSON.stringify(next)
        if (json === entriesJson) return
        entriesJson = json
        entries = next
    }

    onBarConfigChanged: updateEntries()
    Component.onCompleted: updateEntries()
    readonly property var leftEntries: (barConfig.layout && barConfig.layout.left) || []
    readonly property var centerEntries: (barConfig.layout && barConfig.layout.center) || []
    readonly property var rightEntries: (barConfig.layout && barConfig.layout.right) || []
    readonly property var centerList: {
        const c = centerEntries
        const bk = String(barConfig.centerAnchor || "")
        const idx = c.findIndex(e => (typeof e === "string" ? e : e.id) === bk)
        return idx < 0 ? {before: c, anchor: null, after: []} : {before: c.slice(0, idx), anchor: c[idx], after: c.slice(idx + 1)}
    }
    property var hosts: []
    readonly property string position: "top"
    readonly property string fontFamily: Style.font.family
    readonly property bool barHidden: false
    readonly property int barSize: hosts.length ? hosts[0].panelHeight : Style.bar.sizeHorizontal
    function findPanelWidget(id) {
        const name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
        const ordered = hosts.slice().sort((a, b) => (b.screenName === name ? 1 : 0) - (a.screenName === name ? 1 : 0))
        for (const host of ordered) {
            const items = host.moduleWidgets(id)
            for (const item of items) if (item.open && item.close) return item
        }
        return null
    }
    function isBarWidgetOpen(id) { const w = findPanelWidget(id); return w ? w.opened === true : false }
    function summonBarWidget(id) { const w = findPanelWidget(id); if (!w) return false; w.open(); return true }
    function hideBarWidget(id) { const w = findPanelWidget(id); if (!w) return false; w.close(); return true }
    function toggleBarWidget(id) { const w = findPanelWidget(id); if (!w) return false; if (w.opened) w.close(); else w.open(); return true }
    function panelWidgetIdAt(region, index) {
        const layout = barConfig.layout || {}
        const candidates = (layout[region] || []).filter(e => findPanelWidget(typeof e === "string" ? e : e.id))
        const entry = candidates[Number(index) - 1]
        return entry ? (typeof entry === "string" ? entry : entry.id) : ""
    }
    IpcHandler {
        target: "tablet-bar"
        function geometry(): string {
            return JSON.stringify(root.hosts.map(h => ({screen: h.screenName, tablet: h.tabletMode, size: h.barSize, panelHeight: h.panelHeight,
                viewport: h.viewportWidth, content: h.contentWidth,
                slots: h.slots.map(s => ({id: s.moduleName, width: s.width, height: s.height, visible: s.visible, loaded: !!s.item}))})))
        }
    }
    // Native widgets keep their identity across mode changes. Only their
    // visual parent changes; popouts, IPC handlers and services are not rebuilt.
    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: bar
            required property var modelData
            screen: modelData
            readonly property bool tabletBar: root.tablet && screen === root.internalScreen
            readonly property int rowHeight: Math.max(48, native.barSize)
            readonly property int navHeight: rowHeight + Style.spacing.sm
            anchors { top: true; left: true; right: true }
            implicitHeight: navHeight
            exclusiveZone: implicitHeight
            color: root.barConfig.transparent ? "transparent" : Color.bar.background
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.namespace: "omarchy-tablet-bar"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            NativeHost {
                id: native
                property string screenName: bar.screen.name
                property int panelHeight: bar.implicitHeight
                property bool tabletMode: bar.tabletBar
                property real viewportWidth: systemArea.width
                property real contentWidth: systemArea.contentWidth
                shell: root.shell
                tablet: false
                animations: root.service ? root.service.status.animations !== false : true
                layoutConfig: root.barConfig.layout || ({})
                transparent: root.barConfig.transparent === true
                Component.onCompleted: root.hosts = root.hosts.concat([native])
                Component.onDestruction: root.hosts = root.hosts.filter(h => h !== native)
            }

            Item {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.sm
                anchors.rightMargin: Style.spacing.sm
                Row {
                    id: touchControls
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.xs
                    NavButton {
                        iconText: root.tablet ? "\uf10a" : "\uf108"
                        selected: root.tablet
                        Accessible.name: root.tablet ? "Tablet mode. Switch to desktop" : "Desktop mode. Switch to tablet"
                        onClicked: if (root.service) root.service.command("mode", "toggle")
                    }
                    NavButton {
                        visible: bar.tabletBar
                        iconText: "\uf00a"; Accessible.name: "Applications"
                        selected: root.service && root.service.homeOpen && root.service.page !== "settings"
                        onClicked: if (root.service) root.service.home(false)
                    }
                    NavButton {
                        visible: bar.tabletBar
                        iconText: "\uf2d0"; Accessible.name: "Windows"
                        selected: root.service && root.service.switcherOpen
                        onClicked: if (root.service) root.service.openSwitcher()
                    }
                    NavButton {
                        visible: bar.tabletBar
                        iconText: "\uf11c"; Accessible.name: "On-screen keyboard"
                        enabled: !!(root.service && root.service.status.keyboardAvailable)
                        onClicked: root.service.command("keyboard")
                    }
                    NavButton {
                        visible: bar.tabletBar
                        iconText: "\uf130"; Accessible.name: "Dictation"
                        enabled: !!(root.service && root.service.status.dictationAvailable)
                        onClicked: root.service.command("dictation")
                    }
                    NavButton {
                        visible: bar.tabletBar
                        iconText: "\uf013"; Accessible.name: "Settings"
                        selected: root.service && root.service.homeOpen && root.service.page === "settings"
                        onClicked: if (root.service) root.service.openPage("settings")
                    }
                    NavButton {
                        visible: bar.tabletBar
                        iconText: "\uf00d"; Accessible.name: "Close current application"
                        activeColor: Color.urgent
                        enabled: !!ToplevelManager.activeToplevel && !(root.service && (root.service.homeOpen || root.service.switcherOpen))
                        onClicked: { const top = ToplevelManager.activeToplevel; if (top) top.close() }
                    }
                }
                // Native widgets stay on the same line. On narrow displays the
                // system area scrolls horizontally; touch shortcuts stay pinned.
                Flickable {
                    id: systemArea
                    anchors.left: touchControls.right
                    anchors.leftMargin: Style.spacing.md
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: bar.rowHeight
                    clip: true
                    contentWidth: Math.max(width, nativeLeft.width + desktopAnchor.width + nativeRight.width + Style.spacing.md * 2)
                    contentHeight: height
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.HorizontalFlick
                    ScrollBar.horizontal: ScrollBar { policy: systemArea.contentWidth > systemArea.width ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff }
                    Row {
                        id: nativeLeft
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.spacing.sm
                        Row { id: desktopLeft; spacing: Style.spacing.sm }
                        Row { id: desktopBefore; spacing: Style.spacing.sm }
                    }
                    Item {
                        id: desktopAnchor
                        x: Math.max(nativeLeft.width + Style.spacing.md,
                            Math.min(bar.width / 2 - systemArea.x - width / 2,
                                systemArea.contentWidth - nativeRight.width - Style.spacing.md - width))
                        anchors.verticalCenter: parent.verticalCenter
                        width: childrenRect.width
                        height: bar.rowHeight
                    }
                    Row {
                        id: nativeRight
                        x: systemArea.contentWidth - width
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.spacing.sm
                        Row { id: desktopAfter; spacing: Style.spacing.sm }
                        Row { id: desktopRight; spacing: Style.spacing.sm }
                    }
                }
            }
            Component {
                id: widgetComponent
                NativeWidget {
                    registry: root.barWidgetRegistry
                    host: native
                    visible: !(bar.tabletBar && moduleName === "omarchy.workspaces")
                }
            }

            property var activeWidgets: ({})

            function getTargetParent(moduleName) {
                const anchorId = root.centerList.anchor ? (typeof root.centerList.anchor === "string" ? root.centerList.anchor : root.centerList.anchor.id) : ""
                const contains = list => list.some(e => (typeof e === "string" ? e : e.id) === moduleName)
                if (moduleName === anchorId) return desktopAnchor
                if (contains(root.leftEntries)) return desktopLeft
                if (contains(root.rightEntries)) return desktopRight
                return contains(root.centerList.before) ? desktopBefore : desktopAfter
            }

            function syncOrder() {
                const rows = [
                    { parent: desktopLeft, entries: root.leftEntries },
                    { parent: desktopBefore, entries: root.centerList.before },
                    { parent: desktopAfter, entries: root.centerList.after },
                    { parent: desktopRight, entries: root.rightEntries }
                ]
                for (let r = 0; r < rows.length; r++) {
                    const rowInfo = rows[r]
                    const rowParent = rowInfo.parent
                    const list = rowInfo.entries || []
                    let prev = null
                    for (let i = 0; i < list.length; i++) {
                        const id = typeof list[i] === "string" ? list[i] : (list[i] ? list[i].id : "")
                        const widget = activeWidgets[id]
                        if (widget && widget.parent === rowParent) {
                            if (prev && typeof widget.stackAfter === "function") {
                                widget.stackAfter(prev)
                            }
                            prev = widget
                        }
                    }
                }
            }

            function updateWidgets() {
                const currentEntries = root.entries || []
                const desired = {}
                for (let i = 0; i < currentEntries.length; i++) {
                    const entry = currentEntries[i]
                    const id = typeof entry === "string" ? entry : (entry ? entry.id : "")
                    if (!id) continue
                    desired[id] = entry
                }

                const nextWidgets = Object.assign({}, activeWidgets)
                for (const id in nextWidgets) {
                    if (!desired[id]) {
                        const w = nextWidgets[id]
                        if (w) w.destroy()
                        delete nextWidgets[id]
                    }
                }

                for (let i = 0; i < currentEntries.length; i++) {
                    const entry = currentEntries[i]
                    const id = typeof entry === "string" ? entry : (entry ? entry.id : "")
                    if (!id) continue

                    const targetParent = getTargetParent(id)
                    let widget = nextWidgets[id]
                    if (!widget) {
                        widget = widgetComponent.createObject(targetParent, {
                            entry: entry
                        })
                        if (widget) nextWidgets[id] = widget
                    } else {
                        widget.entry = entry
                        if (widget.parent !== targetParent) {
                            widget.parent = targetParent
                        }
                    }
                }

                activeWidgets = nextWidgets
                syncOrder()
            }

            Component.onCompleted: updateWidgets()
            Connections {
                target: root
                function onEntriesChanged() { bar.updateWidgets() }
                function onCenterListChanged() { bar.updateWidgets() }
                function onLeftEntriesChanged() { bar.updateWidgets() }
                function onRightEntriesChanged() { bar.updateWidgets() }
            }
            component NavButton: TouchButton {
                width: bar.rowHeight
                height: bar.rowHeight
                iconSize: Style.font.icon
                animations: native.animations
            }
        }
    }

    KeyboardControls { service: root.service; screen: root.internalScreen }

    // One transient surface for Home, apps, settings and the switcher.
    // No full-screen Bottom surface remains under maximized applications.
    PanelWindow {
        id: overlay
        screen: root.internalScreen
        visible: root.service ? root.service.homeOpen || root.service.switcherOpen : false
        anchors { top: true; bottom: true; left: true; right: true }
        exclusiveZone: 0
        color: Color.background
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "omarchy-tablet-home"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        Loader {
            anchors.fill: parent
            active: overlay.visible
            sourceComponent: root.service && root.service.switcherOpen ? switcherContent : homeContent
        }
        Component { id: homeContent; HomeContent { service: root.service } }
        Component { id: switcherContent; SwitcherOverlay { service: root.service } }
    }
    // A visible, narrow grip leaves the bottom corners of apps accessible.
    // Tap: Home. Swipe up / hold: windows. No keyboard required.
    PanelWindow {
        screen: root.internalScreen
        visible: root.tablet && root.service !== null && !root.service.keyboardVisible
        anchors { bottom: true }
        implicitWidth: Style.space(160)
        implicitHeight: Math.max(24, Style.space(20))
        exclusiveZone: 0
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "omarchy-tablet-gesture"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        Rectangle {
            anchors.centerIn: parent
            width: Style.space(72); height: Style.space(4)
            radius: height / 2
            color: Color.foreground
            opacity: gestureArea.pressed ? 1 : 0.55
        }
        MouseArea {
            id: gestureArea
            anchors.fill: parent
            property real startY: 0
            property bool handled: false
            onPressed: function(mouse) { startY = mouse.y; handled = false }
            onPositionChanged: function(mouse) {
                if (pressed && !handled && startY - mouse.y > Style.space(12)) {
                    handled = true
                    root.service.openSwitcher()
                }
            }
            onPressAndHold: { handled = true; root.service.openSwitcher() }
            onClicked: if (!handled) { if (root.service.homeOpen || root.service.switcherOpen) root.service.close(); else root.service.home(false) }
            Accessible.role: Accessible.Button
            Accessible.name: "Home. Hold or swipe up for windows."
        }
    }
}

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

    property var barDragSource: null
    property var barDragTarget: null
    property var barDragTargetGeometry: null
    property bool barDragAfter: false
    property var barDragWindow: null
    property var barDragScreen: null
    property url barDragImageUrl: ""
    property real barDragSceneX: 0
    property real barDragSceneY: 0
    property real barDragScreenX: 0
    property real barDragScreenY: 0
    property real barDragOffsetX: 0
    property real barDragOffsetY: 0

    function regionFor(moduleName) {
        const contains = list => (list || []).some(e => (typeof e === "string" ? e : e.id) === moduleName)
        if (contains(leftEntries)) return "left"
        if (contains(rightEntries)) return "right"
        return "center"
    }

    function clearBarDrag() {
        barDragSource = null
        barDragWindow = null
        barDragScreen = null
        barDragImageUrl = ""
        barDragTarget = null
        barDragTargetGeometry = null
        barDragAfter = false
        barDragSceneX = 0
        barDragSceneY = 0
        barDragScreenX = 0
        barDragScreenY = 0
        barDragOffsetX = 0
        barDragOffsetY = 0
    }

    function captureBarDragGhost(slot) {
        var it = slot && slot.item ? slot.item : slot
        barDragImageUrl = ""
        if (!it || typeof it.grabToImage !== "function") return

        var grabWidth = Math.max(1, Math.ceil(it.width || it.implicitWidth || slot.width || 1))
        var grabHeight = Math.max(1, Math.ceil(it.height || it.implicitHeight || slot.height || 1))
        it.grabToImage(function(result) {
            if (root.barDragSource !== slot || !result || !result.url) return
            root.barDragImageUrl = result.url
        }, Qt.size(grabWidth, grabHeight))
    }

    function startBarDrag(slot, pressedX, pressedY) {
        barDragSource = slot
        barDragWindow = (slot && slot.host && slot.host.barWindow) || (hosts.length ? hosts[0].barWindow : null)
        barDragScreen = barDragWindow ? barDragWindow.screen : null
        barDragOffsetX = pressedX
        barDragOffsetY = pressedY
        var scene = slot.mapToItem(null, pressedX, pressedY)
        barDragSceneX = scene.x
        barDragSceneY = scene.y
        barDragScreenX = scene.x
        barDragScreenY = scene.y
        captureBarDragGhost(slot)
    }

    function nearestDropTarget(candidates, point) {
        var rows = Array.isArray(candidates) ? candidates : []
        var axis = Number(point && point.x)
        if (!isFinite(axis)) return null

        var best = null
        var bestDistance = Infinity
        for (var i = 0; i < rows.length; i++) {
            var row = rows[i]
            if (!row) continue

            var start = Number(row.x)
            var size = Number(row.width)
            if (!isFinite(start) || !isFinite(size) || size <= 0) continue

            var beforeDistance = Math.abs(axis - start)
            var afterDistance = Math.abs(axis - (start + size))
            var after = afterDistance < beforeDistance
            var distance = after ? afterDistance : beforeDistance
            if (distance < bestDistance) {
                best = { candidate: row, after: after }
                bestDistance = distance
            }
        }
        return best
    }

    function dropMarkerRect(candidate, after) {
        if (!candidate) return null
        var thickness = Style.spacing.xs || 4
        return {
            x: candidate.x + (after ? candidate.width : 0) - thickness / 2,
            y: candidate.y,
            width: thickness,
            height: candidate.height
        }
    }

    function moduleDropAtScene(scenePoint, sourceSlot) {
        var targetWindow = (sourceSlot && sourceSlot.host && sourceSlot.host.barWindow) || barDragWindow
        if (!targetWindow) return null

        var barY = scenePoint.y
        try {
            if (targetWindow.contentItem) {
                var barPoint = targetWindow.contentItem.mapFromItem(null, scenePoint.x, scenePoint.y)
                barY = barPoint.y
            }
        } catch (e) {
            barY = scenePoint.y
        }
        if (barY < -60 || barY > targetWindow.height + 60) {
            return null
        }

        var sourceHost = sourceSlot.host
        var slots = sourceHost ? sourceHost.slots : []
        var candidates = []

        for (var i = 0; i < slots.length; i++) {
            var slot = slots[i]
            if (!slot || slot === sourceSlot || !slot.visible || slot.width <= 0 || slot.height <= 0) continue

            var slotPoint = { x: slot.x, y: slot.y }
            try {
                slotPoint = slot.mapToItem(null, 0, 0)
            } catch (e) {
                continue
            }

            candidates.push({
                slot: slot,
                x: slotPoint.x,
                y: slotPoint.y,
                width: slot.width,
                height: slot.height,
                region: slot.region,
                isPlaceholder: false
            })
        }

        var hasLeft = candidates.some(c => c.region === "left")
        var hasCenter = candidates.some(c => c.region === "center")
        var hasRight = candidates.some(c => c.region === "right")

        if (!hasLeft && sourceSlot.region !== "left") {
            candidates.push({
                region: "left",
                isPlaceholder: true,
                x: 0,
                y: 0,
                width: 60,
                height: targetWindow.height
            })
        }
        if (!hasCenter && sourceSlot.region !== "center") {
            candidates.push({
                region: "center",
                isPlaceholder: true,
                x: targetWindow.width / 2 - 30,
                y: 0,
                width: 60,
                height: targetWindow.height
            })
        }
        if (!hasRight && sourceSlot.region !== "right") {
            candidates.push({
                region: "right",
                isPlaceholder: true,
                x: targetWindow.width - 60,
                y: 0,
                width: 60,
                height: targetWindow.height
            })
        }

        return nearestDropTarget(candidates, scenePoint)
    }

    function updateBarDrag(scenePoint) {
        if (!barDragSource || !barDragWindow) return
        barDragSceneX = scenePoint.x
        barDragSceneY = scenePoint.y
        barDragScreenX = scenePoint.x
        barDragScreenY = scenePoint.y

        var drop = moduleDropAtScene(scenePoint, barDragSource)
        barDragTarget = drop ? drop.candidate : null
        barDragAfter = drop ? drop.after : false
        barDragTargetGeometry = drop ? dropMarkerRect(drop.candidate, drop.after) : null
    }

    function nextVisibleModuleName(region, afterName, sourceSlot) {
        const layout = root.barConfig.layout || {}
        const entries = layout[region] || []
        let found = false
        for (let i = 0; i < entries.length; i++) {
            const name = typeof entries[i] === "string" ? entries[i] : (entries[i] ? entries[i].id : "")
            if (!found) {
                if (name === afterName) found = true
                continue
            }
            if (name && name !== (sourceSlot ? sourceSlot.moduleName : "")) return name
        }
        return ""
    }

    function dropBarModuleAtTarget(sourceSlot, targetCandidate, afterTarget) {
        if (!sourceSlot || !targetCandidate) return false
        if (targetCandidate.isPlaceholder) {
            return dropBarModule(sourceSlot, targetCandidate.region, "")
        }
        const targetSlot = targetCandidate.slot
        if (!targetSlot) return false
        const toRegion = targetSlot.region
        const beforeName = afterTarget
            ? nextVisibleModuleName(toRegion, targetSlot.moduleName, sourceSlot)
            : targetSlot.moduleName
        return dropBarModule(sourceSlot, toRegion, beforeName)
    }

    function dropBarModule(sourceSlot, toRegion, beforeName) {
        if (!sourceSlot || !sourceSlot.region || !sourceSlot.moduleName || !toRegion) return false
        if (sourceSlot.region === toRegion && sourceSlot.moduleName === beforeName) return false
        if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return false

        var changed = false
        root.shell.mutateShellConfig(function(config) {
            changed = moveModuleInConfig(config, sourceSlot.region, sourceSlot.moduleName, toRegion, beforeName)
        })
        return changed
    }

    function moveModuleInConfig(config, fromRegion, fromName, toRegion, beforeName) {
        if (!config) return false
        if (!config.bar) config.bar = {}
        if (!config.bar.layout) config.bar.layout = {}
        if (!Array.isArray(config.bar.layout[fromRegion])) config.bar.layout[fromRegion] = []
        if (!Array.isArray(config.bar.layout[toRegion])) config.bar.layout[toRegion] = []

        var fromEntries = config.bar.layout[fromRegion]
        var toEntries = config.bar.layout[toRegion]

        function entryId(entry) {
            return typeof entry === "string" ? entry : (entry ? entry.id : "")
        }

        var fromIndex = -1
        for (var i = 0; i < fromEntries.length; i++) {
            if (entryId(fromEntries[i]) === fromName) { fromIndex = i; break }
        }
        if (fromIndex < 0) return false

        var toIndex = toEntries.length
        if (beforeName) {
            for (var j = 0; j < toEntries.length; j++) {
                if (entryId(toEntries[j]) === beforeName) { toIndex = j; break }
            }
        }

        if (fromRegion === toRegion && fromIndex === toIndex) return false

        var movedEntry = fromEntries[fromIndex]
        fromEntries.splice(fromIndex, 1)

        if (fromRegion === toRegion && fromIndex < toIndex) toIndex -= 1
        if (toIndex < 0) toIndex = 0
        if (toIndex > toEntries.length) toIndex = toEntries.length

        if (fromRegion === toRegion && fromIndex === toIndex) {
            fromEntries.splice(fromIndex, 0, movedEntry)
            return false
        }

        toEntries.splice(toIndex, 0, movedEntry)
        return true
    }

    function finishBarDrag(slot) {
        var targetCandidate = barDragTarget
        var afterTarget = barDragAfter
        clearBarDrag()
        if (targetCandidate) {
            dropBarModuleAtTarget(slot, targetCandidate, afterTarget)
        }
    }

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
                barWindow: bar
                barRoot: root
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
                    interactive: !root.barDragSource && (systemArea.contentWidth > systemArea.width)
                    contentWidth: Math.max(width, nativeLeft.width + centerGroup.width + nativeRight.width + Style.spacing.md * 2)
                    contentHeight: height
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.HorizontalFlick
                    ScrollBar.horizontal: ScrollBar { policy: systemArea.contentWidth > systemArea.width ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff }
                    Row {
                        id: nativeLeft
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.spacing.sm
                        Row { id: desktopLeft; spacing: Style.spacing.sm }
                    }
                    Row {
                        id: centerGroup
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.spacing.sm
                        x: {
                            const minX = nativeLeft.width + Style.spacing.md
                            const maxX = systemArea.contentWidth - nativeRight.width - Style.spacing.md - width
                            if (desktopAnchor.width > 0) {
                                const anchorOffset = desktopBefore.width + (desktopBefore.width > 0 ? spacing : 0) + desktopAnchor.width / 2
                                const targetX = (bar.width / 2 - systemArea.x) - anchorOffset
                                return Math.max(minX, Math.min(targetX, maxX))
                            }
                            return Math.max(minX, Math.min(bar.width / 2 - systemArea.x - width / 2, maxX))
                        }
                        Row { id: desktopBefore; spacing: Style.spacing.sm }
                        Item {
                            id: desktopAnchor
                            width: childrenRect.width
                            height: childrenRect.height
                        }
                        Row { id: desktopAfter; spacing: Style.spacing.sm }
                    }
                    Row {
                        id: nativeRight
                        x: systemArea.contentWidth - width
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.spacing.sm
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
                    const rowParent = rows[r].parent
                    const list = rows[r].entries || []
                    const items = []
                    for (let i = 0; i < list.length; i++) {
                        const id = typeof list[i] === "string" ? list[i] : (list[i] ? list[i].id : "")
                        const widget = activeWidgets[id]
                        if (widget && widget.parent === rowParent) {
                            items.push(widget)
                        }
                    }
                    if (items.length > 0) {
                        for (let i = 0; i < items.length; i++) {
                            items[i].parent = null
                        }
                        for (let i = 0; i < items.length; i++) {
                            items[i].parent = rowParent
                        }
                        if (typeof rowParent.forceLayout === "function") {
                            rowParent.forceLayout()
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

    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: dragGhostWindow
            required property var modelData
            screen: modelData
            readonly property bool screenMatches: root.barDragScreen === modelData ||
                (root.barDragScreen && modelData && root.barDragScreen.name && modelData.name && root.barDragScreen.name === modelData.name)
            readonly property bool active: root.barDragSource && root.barDragScreen && screenMatches
            readonly property var sourceItem: root.barDragSource ? (root.barDragSource.item || root.barDragSource) : null
            readonly property int ghostPadding: Style.space(1)
            readonly property int ghostWidth: sourceItem ? Math.max(1, Math.ceil(sourceItem.width)) : 1
            readonly property int ghostHeight: sourceItem ? Math.max(1, Math.ceil(sourceItem.height)) : 1

            visible: active && sourceItem !== null
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "omarchy-bar-drag-ghost"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            mask: Region {}

            Item {
                visible: dragGhostWindow.visible
                x: Math.round(root.barDragScreenX - root.barDragOffsetX - dragGhostWindow.ghostPadding)
                y: Math.round(root.barDragScreenY - root.barDragOffsetY - dragGhostWindow.ghostPadding)
                width: dragGhostWindow.ghostWidth + dragGhostWindow.ghostPadding * 2
                height: dragGhostWindow.ghostHeight + dragGhostWindow.ghostPadding * 2

                Rectangle {
                    anchors.fill: parent
                    color: root.barConfig.transparent ? "transparent" : Color.bar.background
                    border.color: Color.bar.text
                    border.width: 1
                    radius: Math.min(Style.cornerRadius, height / 2)
                    opacity: root.barConfig.transparent ? 0.45 : 0.94
                }

                Image {
                    anchors.fill: parent
                    anchors.margins: dragGhostWindow.ghostPadding
                    source: root.barDragImageUrl
                    fillMode: Image.Stretch
                    smooth: true
                    opacity: 0.85
                }
            }

            Rectangle {
                readonly property var targetRect: root.barDragTargetGeometry
                visible: dragGhostWindow.active && targetRect !== null
                x: targetRect ? Math.round(targetRect.x) : 0
                y: targetRect ? Math.round(targetRect.y) : 0
                width: targetRect ? targetRect.width : 0
                height: targetRect ? targetRect.height : 0
                color: Color.accent
                radius: Math.min(width, height) / 2
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

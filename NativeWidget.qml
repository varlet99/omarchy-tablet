import QtQuick
import Quickshell
import qs.Commons

Item {
    id: slot
    required property var entry
    required property var registry
    required property var host
    readonly property string moduleName: typeof entry === "string" ? entry : (entry ? entry.id : "")
    property var item: null
    property var activeComponent: null

    readonly property string region: host ? host.regionFor(moduleName) : "center"
    readonly property bool dragSource: host && host.barRoot ? host.barRoot.barDragSource === slot : false
    opacity: dragSource ? 0.35 : 1.0

    readonly property var registeredComponent: {
        const w = registry && registry.widgets ? registry.widgets : null
        return w && w[moduleName] ? w[moduleName].component : null
    }

    implicitWidth: item && item.visible ? Math.max(host.tablet ? 48 : 0, item.implicitWidth) : 0
    implicitHeight: host.barSize
    width: implicitWidth
    height: implicitHeight
    property bool ready: false

    Component.onCompleted: {
        ready = true
        host.registerSlot(slot)
        rebuild()
    }
    Component.onDestruction: {
        host.unregisterSlot(slot)
        if (item) {
            item.destroy()
            item = null
            activeComponent = null
        }
    }

    function rebuild() {
        if (!ready) return
        const comp = registeredComponent
        if (comp === activeComponent && item !== null) {
            inject()
            return
        }
        if (item) {
            item.destroy()
            item = null
            activeComponent = null
        }
        if (!comp) return
        item = comp.createObject(slot, {
            bar: host,
            moduleName: moduleName,
            settings: typeof entry === "string" ? {} : entry
        })
        if (item) {
            activeComponent = comp
            item.width = Qt.binding(() => slot.width)
            item.height = Qt.binding(() => slot.height)
            item.anchors.centerIn = slot
            inject()
        }
    }

    onRegisteredComponentChanged: rebuild()

    function inject() {
        if (!item) return
        if ("bar" in item) item.bar = host
        if ("moduleName" in item) item.moduleName = moduleName
        if ("settings" in item) item.settings = typeof entry === "string" ? {} : entry
    }
    onEntryChanged: inject()

    MouseArea {
        id: dragArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        enabled: slot.visible && slot.width > 0 && slot.height > 0
        propagateComposedEvents: true
        preventStealing: true
        z: 10
        cursorShape: slot.host && slot.host.moduleClickTargetAt && slot.host.moduleClickTargetAt(slot, mouseX, mouseY) ? Qt.PointingHandCursor : Qt.ArrowCursor

        property bool dragging: false
        property bool suppressClick: false
        property real pressedX: 0
        property real pressedY: 0
        readonly property real dragThreshold: Style.space(4)

        onPressed: function(mouse) {
            dragging = false
            suppressClick = false
            pressedX = mouse.x
            pressedY = mouse.y
            if (slot.host) slot.host.clearBarDrag()
        }

        onPositionChanged: function(mouse) {
            if (!dragArea.pressed && !(mouse.buttons & Qt.LeftButton)) return
            var distance = Math.abs(mouse.x - pressedX) + Math.abs(mouse.y - pressedY)
            if (distance >= dragThreshold) {
                if (!dragging) {
                    dragging = true
                    if (slot.host) slot.host.startBarDrag(slot, pressedX, pressedY)
                }
            }
            if (dragging) {
                var scenePoint = slot.mapToItem(null, mouse.x, mouse.y)
                if (slot.host) slot.host.updateBarDrag(scenePoint)
            }
        }

        onReleased: function(mouse) {
            var wasDragging = dragging
            dragging = false
            if (wasDragging) {
                suppressClick = true
                if (slot.host) slot.host.finishBarDrag(slot)
                mouse.accepted = true
            } else {
                mouse.accepted = false
            }
        }

        onCanceled: {
            dragging = false
            suppressClick = false
            if (slot.host) slot.host.clearBarDrag()
        }

        onClicked: function(mouse) {
            if (suppressClick) {
                suppressClick = false
                mouse.accepted = true
                return
            }
            if (!slot.host || !slot.host.pressModuleClickTarget || !slot.host.pressModuleClickTarget(slot, mouse.button, mouse.x, mouse.y)) {
                mouse.accepted = false
            }
        }
    }
}

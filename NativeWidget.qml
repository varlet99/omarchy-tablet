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
}

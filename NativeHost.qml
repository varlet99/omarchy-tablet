import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons

// The public bar contract used by Omarchy's original widget components.
Item {
    id: host
    property var shell: null
    property bool tablet: false
    property bool animations: true
    property var layoutConfig: ({})
    property color foreground: Color.bar.text
    property color barForeground: Color.bar.text
    property color background: Color.bar.background
    property color urgent: Color.bar.active
    property string fontFamily: Style.font.family
    property string position: "top"
    property bool vertical: false
    property int barSize: tablet ? Math.max(48, Style.space(40), Style.bar.sizeHorizontal) : Style.bar.sizeHorizontal
    property bool transparent: false
    property bool foregroundAnimationEnabled: animations
    property bool centerSectionRevealHeld: tablet
    property bool centerHoverRevealSuppressed: false
    property var activePopout: null
    property var clickTargets: []
    property var touchSizing: new Map()
    property var slots: []
    property string tooltipText: ""
    property var barRoot: null
    property var barWindow: null

    function regionFor(moduleName) {
        return barRoot ? barRoot.regionFor(moduleName) : "center"
    }

    function setCenterHoverRevealSuppressed(value) { centerHoverRevealSuppressed = value }
    function showTooltip(target, text) { tooltipText = text || "" }
    function hideTooltip(target) { tooltipText = "" }

    function registerClickTarget(target) {
        if (clickTargets.indexOf(target) >= 0) return
        clickTargets = clickTargets.concat([target])
        // Enlarge the original control, so native right clicks, wheel actions and
        // multi-button widgets keep receiving their own events.
        if ("fixedWidth" in target && target.fixedWidth > 0) {
            const sizing = touchWidth.createObject(host, {control: target,
                baseWidth: target.fixedWidth, baseScale: Style.spaceReal(1)})
            touchSizing.set(target, sizing)
        }
    }

    function unregisterClickTarget(target) {
        const sizing = touchSizing.get(target)
        if (sizing) {
            sizing.when = false  // restore the native binding before re-registering
            sizing.destroy()
            touchSizing.delete(target)
        }
        clickTargets = clickTargets.filter(t => t !== target)
    }

    Component {
        id: touchWidth
        Binding {
            required property var control
            required property real baseWidth
            required property real baseScale
            target: control
            property: "fixedWidth"
            value: control ? Math.max(48, "slotSize" in control ? control.slotSize : baseWidth * Style.spaceReal(1) / baseScale) : 48
            when: host.tablet
            restoreMode: Binding.RestoreBindingOrValue
        }
    }

    function registerSlot(slot) { slots = slots.concat([slot]) }
    function unregisterSlot(slot) { slots = slots.filter(s => s !== slot) }
    function moduleWidgets(id) { return slots.filter(s => s.moduleName === id && s.item).map(s => s.item) }
    function targetBelongsToWindow(target, window) { return target && target.QsWindow.window === window }

    function moduleTargetClickable(target) {
        return target
            && target.visible !== false
            && target.opacity !== 0
            && target.interactive !== false
            && target.pressable !== false
            && target.concealed !== true
            && typeof target.triggerPress === "function"
    }

    function moduleClickTargetAt(slot, localX, localY) {
        for (var i = clickTargets.length - 1; i >= 0; i--) {
            var target = clickTargets[i]
            if (!moduleTargetClickable(target)) continue

            var targetPoint = { x: localX, y: localY }
            try {
                targetPoint = slot.mapToItem(target, localX, localY)
            } catch (e) {
                continue
            }

            if (targetPoint.x >= 0 && targetPoint.x <= target.width &&
                targetPoint.y >= 0 && targetPoint.y <= target.height) {
                return target
            }
        }
        if (slot && moduleTargetClickable(slot.item)) return slot.item
        return null
    }

    function pressModuleClickTarget(slot, button, localX, localY) {
        var target = moduleClickTargetAt(slot, localX, localY)
        if (!target) return false
        target.triggerPress(button)
        return true
    }

    function startBarDrag(slot, pressedX, pressedY) {
        if (barRoot) barRoot.startBarDrag(slot, pressedX, pressedY)
    }

    function updateBarDrag(scenePoint) {
        if (barRoot) barRoot.updateBarDrag(scenePoint)
    }

    function finishBarDrag(slot) {
        if (barRoot) barRoot.finishBarDrag(slot)
    }

    function clearBarDrag() {
        if (barRoot) barRoot.clearBarDrag()
    }

    function requestPopout(owner) {
        if (activePopout && activePopout !== owner) {
            if (activePopout.closeForPopoutSwitch) activePopout.closeForPopoutSwitch()
            else if (activePopout.close) activePopout.close()
        }
        activePopout = owner
    }

    function releasePopout(owner) { if (activePopout === owner) activePopout = null }

    function switchPanelFrom(owner, direction) {
        const panels = slots.map(s => s.item).filter(i => i && i.open && i.close)
        const index = panels.indexOf(owner)
        if (index < 0 || panels.length < 2) return false
        panels[(index + panels.length + (direction < 0 ? -1 : 1)) % panels.length].open()
        return true
    }

    function run(command) { Quickshell.execDetached(["bash", "-c", command]) }
    ToolTip { visible: !host.tablet && host.tooltipText.length > 0; text: host.tooltipText; delay: 500 }
}

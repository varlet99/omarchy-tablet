pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// On-demand opaque tablet home, styled with Omarchy's live theme tokens.
Item {
    id: root
    property var service: null
    readonly property string page: service ? service.page : "home"
    property bool editing: false
    property string query: ""

    readonly property var entries: {
        if (!service || !service.apps) return []
        const revision = service.appsRevision
        const values = service.apps.sortedEntries(query).map(row => row.entry)
        if (page === "apps" || query.length) return values
        return (service.status.favorites || []).map(id => values.find(entry => entry.id === id)).filter(Boolean)
    }

    // Opaque themed surface: no wallpaper decoding or full-screen blending
    // during rotation. The native wallpaper remains untouched behind apps.
    Rectangle { anchors.fill: parent; color: Color.background }
    focus: true
    Keys.onEscapePressed: if (service) service.close()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.spacing.panelGap

        // ---- header: page title + primary actions ----
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(40, Style.space(40))
            Text {
                Layout.fillWidth: true
                text: root.page === "settings" ? "Settings"
                    : root.page === "windows" ? "Windows"
                    : root.page === "apps" ? "Applications"
                    : "Home"
                color: Color.menu.text
                font { family: Style.font.family; pixelSize: Style.font.display; weight: Font.Light }
                elide: Text.ElideRight
            }
            TouchButton {
                iconText: "\uf00d"
                foreground: Color.menu.text
                compact: false
                Accessible.name: "Close"
                onClicked: root.service.close()
            }
        }

        // ---- mode toggle + search (launcher views only) ----
        RowLayout {
            visible: root.page === "home" || root.page === "apps"
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(48, Style.space(40))
            spacing: Style.spacing.controlGap
            TextField {
                id: searchField
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(44, Style.space(40))
                foreground: Color.menu.text
                accent: Color.accent
                placeholderText: "Search applications"
                text: root.query
                onTextEdited: root.query = text
            }
            TouchButton { text: root.editing ? "Done" : "Edit"; selected: root.editing; foreground: Color.menu.text
                onClicked: { root.service.page = "apps"; root.editing = !root.editing } }
        }

        RowLayout {
            visible: root.page === "home" || root.page === "apps"
            Layout.fillWidth: true
            spacing: Style.spacing.controlGap
            Button {
                text: "Favorites"
                foreground: Color.menu.text
                accent: Color.accent
                selected: root.page === "home" && !root.query.length
                bordered: true
                onClicked: { root.query = ""; root.service.openPage("home") }
            }
            Button {
                text: "All apps"
                foreground: Color.menu.text
                accent: Color.accent
                selected: root.page === "apps"
                bordered: true
                onClicked: { root.query = ""; root.service.openPage("apps") }
            }
            Item { Layout.fillWidth: true }
            Text {
                visible: root.page === "home" && !root.query.length
                text: "Hold an app to edit favorites"
                color: Util.alpha(Color.menu.text, 0.6)
                font { family: Style.font.family; pixelSize: Style.font.caption }
                horizontalAlignment: Text.AlignRight
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
        }

        Text {
            visible: root.service && root.service.message.length > 0
            text: root.service ? root.service.message : ""
            color: Color.urgent
            font { family: Style.font.family; pixelSize: Style.font.body }
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        // ---- application grid: icons free of boxes ----
        GridView {
            id: grid
            visible: root.page === "home" || root.page === "apps"
            Layout.fillHeight: true
            Layout.fillWidth: true
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            cellWidth: width / Math.max(1, Math.floor(width / Style.space(112)))
            cellHeight: Math.min(Style.space(150), Math.round(cellWidth * 1.15))
            model: root.entries
            ScrollBar.vertical: ScrollBar {}
            delegate: Item {
                id: tile
                required property var modelData
                width: grid.cellWidth
                height: grid.cellHeight
                readonly property string appName: root.service ? root.service.apps.entryName(modelData) : ""
                readonly property bool favorite: root.service && (root.service.status.favorites || []).indexOf(modelData.id) !== -1
                readonly property int iconSlot: Math.min(Math.round(grid.cellWidth * 0.5), Style.space(64))
                readonly property int labelSpace: Math.max(Style.font.subtitle, Style.space(22)) + Style.space(12)

                MouseArea {
                    id: tileArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: { if (root.editing) root.service.favorite(modelData.id); else root.service.launch(modelData) }
                    onPressAndHold: { root.editing = true; root.service.favorite(modelData.id) }
                    cursorShape: Qt.PointingHandCursor
                }

                // Soft highlight only while hovered/pressed — no permanent box.
                Rectangle {
                    id: iconBack
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: -Math.round(tile.labelSpace / 2)
                    width: tile.iconSlot + Style.space(12)
                    height: width
                    radius: Style.cornerRadius * 2
                    color: tileArea.pressed ? Style.pressedFillFor(Color.menu.text, Color.accent)
                        : tileArea.containsMouse ? Style.hoverFillFor(Color.menu.text, Color.accent)
                        : "transparent"
                    Behavior on color { enabled: root.service && root.service.status.animations !== false; ColorAnimation { duration: 100 } }
                }

                // Icon directly above the name, forming one tight group.
                Column {
                    id: cellColumn
                    anchors.centerIn: parent
                    width: grid.cellWidth - Style.space(6)
                    spacing: Style.space(8)
                    Image {
                        id: appIcon
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: tile.iconSlot
                        height: tile.iconSlot
                        sourceSize.width: width * Screen.devicePixelRatio
                        sourceSize.height: height * Screen.devicePixelRatio
                        source: root.service.apps.iconSource(modelData.icon)
                        asynchronous: true
                        fillMode: Image.PreserveAspectFit
                        Text { anchors.centerIn: parent; visible: parent.status !== Image.Ready; text: "\uf00a"
                            color: Color.accent; font { family: Style.font.family; pixelSize: Style.font.iconLarge } }
                    }
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: tile.appName
                        color: Color.foreground
                        font { family: Style.font.family; pixelSize: Style.font.subtitle; weight: Font.DemiBold }
                        style: Text.Raised
                        styleColor: Util.alpha(Color.background, 0.5)
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }
                }
                TouchButton {
                    visible: root.editing
                    anchors { right: parent.right; top: parent.top }
                    iconText: tile.favorite ? "\uf005" : "\uf006"
                    compact: false
                    selected: tile.favorite
                    foreground: Color.accent
                    iconSize: Style.font.icon
                    Accessible.name: tile.favorite ? "Remove favorite" : "Add favorite"
                    onClicked: root.service.favorite(modelData.id)
                }
            }
            Text {
                anchors.centerIn: parent
                visible: grid.count === 0
                text: root.page === "apps" || root.query.length ? "No applications found." : "Choose favorites in All apps → Edit."
                color: Color.menu.text
                font { family: Style.font.family; pixelSize: Style.font.body }
                width: parent.width
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
            }
        }

        // ---- settings ----
        Flickable {
            visible: root.page === "settings"
            Layout.fillHeight: true
            Layout.fillWidth: true
            contentHeight: settingsColumn.implicitHeight
            clip: true
            ColumnLayout {
                id: settingsColumn
                width: parent.width
                spacing: Style.spacing.panelGap
                Text { text: "Mode"; color: Color.menu.text; font.pixelSize: Style.font.heading; font.family: Style.font.family }
                Flow {
                    Layout.fillWidth: true
                    spacing: Style.spacing.controlGap
                    Repeater {
                        model: [{label: "Automatic", mode: "auto"}, {label: "Tablet", mode: "tablet"}, {label: "Desktop", mode: "desktop"}]
                        Button { required property var modelData; text: modelData.label; foreground: Color.menu.text; accent: Color.accent; bordered: true;
                            selected: root.service && root.service.status.mode === modelData.mode; onClicked: root.service.command("mode", modelData.mode) }
                    }
                }
                Text {
                    text: root.service && root.service.status.attached ? "Physical keyboard attached. Auto uses tiling." : "Physical keyboard detached. Auto maximizes applications."
                    color: Color.menu.text; font.pixelSize: Style.font.body; font.family: Style.font.family
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                }
                Text {
                    Layout.fillWidth: true
                    text: "Tablet shows one application at a time and touch shortcuts. Desktop restores tiling. Both use a single top bar."
                    wrapMode: Text.WordWrap
                    color: Color.menu.text; font.pixelSize: Style.font.body; font.family: Style.font.family
                }
                Text { text: "Touch shortcuts"; color: Color.menu.text; font.pixelSize: Style.font.heading; font.family: Style.font.family }
                Flow {
                    Layout.fillWidth: true
                    spacing: Style.spacing.controlGap
                    TouchButton { text: "Keyboard"; iconText: "\uf11c"; onClicked: root.service.command("keyboard") }
                    TouchButton { text: "Windows"; iconText: "\uf2d0"; onClicked: root.service.openSwitcher() }
                    TouchButton { text: "Clipboard"; onClicked: { root.service.close(); root.service.run(["omarchy", "menu", "clipboard"]) } }
                    TouchButton { text: "Emoji"; onClicked: { root.service.close(); root.service.run(["omarchy", "menu", "emoji"]) } }
                    TouchButton { text: "Omarchy menu"; iconText: "\uf0c9"; onClicked: { root.service.close(); root.service.run(["omarchy", "menu"]) } }
                }
                Text {
                    Layout.fillWidth: true
                    text: "Bottom grip: tap for Home, swipe up or hold for windows.\nHold an application to edit favorites. On narrow screens, swipe the system widgets along the top bar."
                    wrapMode: Text.WordWrap
                    color: Color.menu.text; font.pixelSize: Style.font.body; font.family: Style.font.family
                }
                Text { text: "Screen rotation"; color: Color.menu.text; font.pixelSize: Style.font.heading; font.family: Style.font.family }
                Flow {
                    Layout.fillWidth: true
                    spacing: Style.spacing.controlGap
                    Repeater {
                        model: [{label: "Automatic", value: true}, {label: "Off", value: false}]
                        Button {
                            required property var modelData
                            text: modelData.label; foreground: Color.menu.text; accent: Color.accent; bordered: true
                            selected: root.service && (root.service.status.autoRotate === modelData.value || (root.service.status.autoRotate === undefined && modelData.value === true))
                            onClicked: root.service.command("autoRotate", modelData.value)
                        }
                    }
                    Repeater {
                        model: [{label: "Rotation locked", value: true}, {label: "Unlocked", value: false}]
                        Button {
                            required property var modelData
                            text: modelData.label; foreground: Color.menu.text; accent: Color.accent; bordered: true
                            selected: root.service && root.service.status.rotationLocked === modelData.value
                            enabled: root.service && root.service.status.autoRotate !== false
                            onClicked: root.service.command("rotationLock", modelData.value)
                        }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: root.service && root.service.status.sensorAvailable === false
                        ? "No accelerometer sensor detected on this device."
                        : (root.service && root.service.status.rotationLocked
                            ? "Rotation is locked. The screen will stay in the current orientation."
                            : (root.service && root.service.status.autoRotate !== false
                                ? "Automatic rotates the display when tilting your device."
                                : "Auto-rotation is turned off."))
                    color: Color.menu.text; font.pixelSize: Style.font.body; font.family: Style.font.family
                }
                Text { text: "Keyboard activation"; color: Color.menu.text; font.pixelSize: Style.font.heading; font.family: Style.font.family }
                Flow {
                    Layout.fillWidth: true
                    spacing: Style.spacing.controlGap
                    Repeater {
                        model: [{label: "Automatic", value: "auto"}, {label: "Button only", value: "manual"}]
                        Button {
                            required property var modelData
                            text: modelData.label; foreground: Color.menu.text; accent: Color.accent; bordered: true
                            selected: root.service && root.service.status.keyboardActivation === modelData.value
                            onClicked: root.service.command("keyboardActivation", modelData.value)
                        }
                    }
                }
                Text {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    text: "In Tablet mode, Automatic follows text fields: open when input is requested, hide when it ends. Button only keeps the keyboard closed until you open it."
                    color: Color.menu.text; font.pixelSize: Style.font.body; font.family: Style.font.family
                }
                Text { text: "Keyboard appearance"; color: Color.menu.text; font.pixelSize: Style.font.heading; font.family: Style.font.family }
                Flow {
                    Layout.fillWidth: true
                    spacing: Style.spacing.controlGap
                    Repeater {
                        model: [{label: "Omarchy", style: "omarchy"}, {label: "Rounded", style: "rounded"}, {label: "High contrast", style: "contrast"}]
                        Button {
                            required property var modelData
                            text: modelData.label; foreground: Color.menu.text; accent: Color.accent; bordered: true
                            selected: root.service && root.service.status.keyboardStyle === modelData.style
                            onClicked: root.service.command("keyboardStyle", modelData.style)
                        }
                    }
                }
                Text {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    text: "All three styles follow your Omarchy theme. Changes apply when the keyboard is hidden, then reopened."
                    color: Color.menu.text; font.pixelSize: Style.font.body; font.family: Style.font.family
                }
                Text { text: "Dictation command"; color: Color.menu.text; font.pixelSize: Style.font.heading; font.family: Style.font.family }
                TextField {
                    id: dictationField
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.max(44, Style.space(40))
                    foreground: Color.menu.text
                    accent: Color.accent
                    text: root.service ? root.service.status.dictationCommandText || "" : ""
                    placeholderText: "murmure --transcription"
                }
                Button { text: "Save command"; foreground: Color.menu.text; accent: Color.accent; bordered: true;
                    onClicked: root.service.command("dictationCommand", dictationField.text) }
                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: "Tap the microphone in the top bar to toggle dictation into the focused field.\nAutomatic follows compatible text fields in Tablet mode. The keyboard button remains available in either mode.\nF9 and your keyboard language remain independent of these settings."
                    color: Color.menu.text; font.pixelSize: Style.font.body; font.family: Style.font.family
                }
            }
        }
    }
}

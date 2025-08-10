import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents

Item {
    id: root

    ColumnLayout {
        spacing: 10
        anchors.fill: parent
        anchors.margins: 10

        PlasmaComponents.Label {
            text: i18n("URL to retrieve IP address")
            Layout.fillWidth: true
        }

        PlasmaComponents.TextField {
            id: urlInput
            text: plasmoid.configuration.url ?? ""
            placeholderText: "https://example.com"
            Layout.fillWidth: true
            onEditingFinished: plasmoid.configuration.url = text
        }

        PlasmaComponents.Label {
            text: i18n("Update Interval (minutes, 0 = only at startup):")
            Layout.fillWidth: true
        }

        PlasmaComponents.SpinBox {
            id: intervalInput
            from: 0; to: 60; stepSize: 1
            value: plasmoid.configuration.updateInterval ?? 0
            Layout.fillWidth: true
            onValueChanged: plasmoid.configuration.updateInterval = value
        }

        PlasmaComponents.Button {
            text: i18n("Save")
            icon.name: "dialog-ok"
            Layout.alignment: Qt.AlignRight
            onClicked: {
                plasmoid.configuration.url = urlInput.text
                plasmoid.configuration.updateInterval = intervalInput.value
            }
        }
    }
}

import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.plasma.components 3.0 as PlasmaComponents

Item {
    id: root
    width: 300
    height: 150

    signal urlChanged()

    ColumnLayout {
        spacing: 10
        anchors.fill: parent
        anchors.margins: 10

        PlasmaComponents.Label {
            text: i18n("URL to retrive IP address")
            Layout.fillWidth: true
        }

        PlasmaComponents.TextField {
            id: urlInput
            text: plasmoid.configuration.url || ""
            placeholderText: i18n("https://example.com")
            Layout.fillWidth: true
        }

        // Timer Interval Input
        PlasmaComponents.Label {
            text: i18n("Update Interval (minutes, 0 = only at startup):")
            Layout.fillWidth: true
        }

        PlasmaComponents.SpinBox {
            id: intervalInput
            value: plasmoid.configuration.updateInterval !== undefined ? plasmoid.configuration.updateInterval : 0
            from: 0
            to: 60
            stepSize: 1
            Layout.fillWidth: true
        }

        PlasmaComponents.Button {
            text: i18n("Save")
            icon.name: "dialog-ok"
            Layout.alignment: Qt.AlignRight

            onClicked: {
                plasmoid.configuration.url = urlInput.text;
                plasmoid.configuration.updateInterval = intervalInput.value;
                root.urlChanged();
            }
        }
    }
}

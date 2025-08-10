import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.plasma.plasmoid


PlasmoidItem {
    id: mainWidget
    preferredRepresentation: compactRepresentation

    compactRepresentation:  Item {
            id: main
            implicitWidth: 120
            implicitHeight: 32
            clip: true
            Layout.fillWidth: true
            Layout.preferredWidth: Math.max(120, ipLabel.implicitWidth + 16)
            Layout.maximumWidth: 1e9

            PlasmaComponents.Label {
                id: ipLabel
                text: "Loading IP..."
                font.pixelSize: 18
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                //color: Kirigami.Theme.textColor
                //elide: Text.ElideRight
                anchors.centerIn: parent
            }

            MouseArea {
                anchors.fill: main;
                onClicked: {
                    ipLabel.text = "Refreshing…"
                    getIP();
                }
            }
           
            // Timer to refresh IP based on updateInterval
            Timer {
                id: refreshTimer
                interval: (plasmoid.configuration.updateInterval !== undefined ? plasmoid.configuration.updateInterval : 0) * 60000
                running: (plasmoid.configuration.updateInterval > 0)
                repeat: true
                onTriggered: {
                    console.log("Auto-refreshing IP...");
                    getIP();
                }
            }
            
            // Watch for URL changes and refresh automatically
            Connections {
                target: plasmoid.configuration
                function onUpdateIntervalChanged() {
                    console.log("Configuration changed, reloading IP...");
                    getIP();
                    console.log("Update interval changed to:", plasmoid.configuration.updateInterval, "minutes");
                    refreshTimer.interval = plasmoid.configuration.updateInterval > 0 ? plasmoid.configuration.updateInterval * 60000 : 0;
                    refreshTimer.running = plasmoid.configuration.updateInterval > 0;
                }
            }

            function getIP() {

                if (!plasmoid.configuration.url || plasmoid.configuration.url === "") {
                    ipLabel.text = "No URL set";
                    return;
                }

                var xhr = new XMLHttpRequest();
                xhr.onreadystatechange = function() {
                    if (xhr.readyState == XMLHttpRequest.DONE) {
                        if (xhr.status == 200) {
                            //ipLabel.text = xhr.responseText.trim(); // Set the IP address
                            var match = xhr.responseText.match(/\b(?:\d{1,3}\.){3}\d{1,3}\b/);
                            if (match) {
                                ipLabel.text = match[0]; // Guardar la IP encontrada
                            } else {
                                ipLabel.text = "No IP found in response";
                            }
                        } else {
                            ipLabel.text = "Failed to get IP";
                        }
                    }
                }
                xhr.open("GET", plasmoid.configuration.url, true); // Using a public API to get IP address
                xhr.send(); 
            }

            Component.onCompleted: {
                getIP(); // Fetch the IP when the widget starts
            }
    }

    fullRepresentation: Item {
        implicitWidth: 220
        implicitHeight: 80
        PlasmaComponents.Label { anchors.centerIn: parent; text: "FULL"; color: Kirigami.Theme.textColor }
    }
}



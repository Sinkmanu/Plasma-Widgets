import QtQuick 2.15
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 2.0 as PlasmaComponents
import org.kde.plasma.plasmoid 2.0
import QtQuick.Layouts 1.0
import QtQuick.Controls 1.4



Item {
    id: mainWidget
    Plasmoid.preferredRepresentation: Plasmoid.compactRepresentation


        Plasmoid.compactRepresentation:  Item {
            id: main
            Layout.minimumWidth: ipLabel.implicitWidth
            Layout.minimumHeight: ipLabel.implicitHeight
            
            PlasmaComponents.Label {
                id: ipLabel
                text: "Loading IP..."
                font.pixelSize: 18
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                anchors.centerIn: parent
            }

            MouseArea {
                anchors.fill: main;
                onClicked: {
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
}
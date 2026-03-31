import org.kde.plasma.configuration 2.0

ConfigModel {
    ConfigCategory {
        name: i18n("Connection")
        icon: "network-connect"
        source: "config/ConfigConnection.qml"
    }
    ConfigCategory {
        name: i18n("Display")
        icon: "preferences-desktop-display"
        source: "config/ConfigDisplay.qml"
    }
}

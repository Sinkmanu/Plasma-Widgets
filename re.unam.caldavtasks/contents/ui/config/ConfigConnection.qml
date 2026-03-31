import QtQuick 2.15
import QtQuick.Controls 2.15 as QQC2
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.20 as Kirigami

Kirigami.FormLayout {
    id: configPage

    property alias cfg_caldavUrl: caldavUrlField.text
    property alias cfg_username: usernameField.text
    property alias cfg_password: passwordField.text
    property alias cfg_refreshInterval: refreshSpinBox.value

    QQC2.TextField {
        id: caldavUrlField
        Kirigami.FormData.label: i18n("CalDAV URL:")
        placeholderText: "https://nextcloud.example.org/remote.php/dav"
        Layout.fillWidth: true
    }

    QQC2.Label {
        text: i18n("Base DAV URL only — do not include /calendars/... Use: https://yournextcloud/remote.php/dav")
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        opacity: 0.6
        font.italic: true
    }

    QQC2.TextField {
        id: usernameField
        Kirigami.FormData.label: i18n("Username:")
        placeholderText: i18n("Your Nextcloud username")
        Layout.fillWidth: true
    }

    QQC2.TextField {
        id: passwordField
        Kirigami.FormData.label: i18n("Password / App Token:")
        placeholderText: i18n("App password or token")
        echoMode: TextInput.Password
        Layout.fillWidth: true
    }

    QQC2.SpinBox {
        id: refreshSpinBox
        Kirigami.FormData.label: i18n("Refresh interval (minutes):")
        from: 1
        to: 120
        value: 5
    }

    QQC2.Label {
        text: i18n("Tip: Use an App Password from Nextcloud → Settings → Security for better security.")
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        opacity: 0.7
        font.italic: true
    }
}

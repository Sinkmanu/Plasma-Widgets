import QtQuick 2.15
import QtQuick.Controls 2.15 as QQC2
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.plasmoid 2.0

Kirigami.FormLayout {
    id: configPage

    property alias cfg_showCompleted: showCompletedCheck.checked
    property string cfg_calendarFilter: ""

    // ── Internal discovery state ──
    property var discoveredCalendars: []
    property bool discovering: false
    property string discoverError: ""

    function doDiscover() {
        var baseUrl = (Plasmoid.configuration.caldavUrl || "").replace(/\/$/, "");
        var user = Plasmoid.configuration.username || "";
        var pass = Plasmoid.configuration.password || "";

        if (!baseUrl || !user || !pass) {
            discoverError = i18n("Configure the connection (URL, username, password) first.");
            return;
        }

        discovering = true;
        discoverError = "";
        discoveredCalendars = [];

        var calMatch = baseUrl.match(/^(.*\/calendars\/[^\/]+)/i);
        var calendarsUrl = calMatch
            ? calMatch[1] + "/"
            : baseUrl + "/calendars/" + encodeURIComponent(user) + "/";

        var xhr = new XMLHttpRequest();
        xhr.open("PROPFIND", calendarsUrl, true);
        xhr.setRequestHeader("Authorization", "Basic " + Qt.btoa(user + ":" + pass));
        xhr.setRequestHeader("Content-Type", "application/xml; charset=utf-8");
        xhr.setRequestHeader("Depth", "1");

        var body =
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<d:propfind xmlns:d="DAV:" xmlns:cs="urn:ietf:params:xml:ns:caldav">' +
            '<d:prop><d:resourcetype/><d:displayname/>' +
            '<cs:supported-calendar-component-set/></d:prop>' +
            '</d:propfind>';

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            discovering = false;

            if (xhr.status < 200 || xhr.status >= 300) {
                discoverError = i18n("Error %1: %2\nURL: %3", xhr.status, xhr.statusText, calendarsUrl);
                return;
            }

            var xml = xhr.responseText;
            var found = [];
            var responses = xml.split(/<[^:>]+:response[\s>]/i);
            for (var i = 1; i < responses.length; i++) {
                var block = responses[i];
                if (!/:calendar[\s\/]/i.test(block)) continue;
                if (!/:comp[^>]+name\s*=\s*["']?VTODO["']?/i.test(block)) continue;
                var nm = block.match(/<[^:>]+:displayname[^>]*>([^<]*)<\/[^:>]+:displayname>/i);
                var name = (nm && nm[1].trim()) ? nm[1].trim() : "";
                if (name) found.push(name);
            }

            if (found.length === 0) {
                discoverError = i18n("No calendars with VTODO support found.");
            } else {
                discoveredCalendars = found;
            }
        };

        xhr.send(body);
    }

    // Returns true if the given calendar name is enabled in the current filter
    function isEnabled(name) {
        var f = cfg_calendarFilter.trim();
        if (f === "") return true; // empty = all enabled
        var parts = f.split(",");
        for (var i = 0; i < parts.length; i++) {
            if (parts[i].trim() === name) return true;
        }
        return false;
    }

    // Toggle a calendar in/out of the filter
    function toggleCalendar(name, enabled) {
        var current = [];
        var f = cfg_calendarFilter.trim();
        if (f !== "") {
            var parts = f.split(",");
            for (var i = 0; i < parts.length; i++) {
                var t = parts[i].trim();
                if (t !== "") current.push(t);
            }
        } else {
            // Was "all" — start with all discovered checked except the one being unchecked
            for (var j = 0; j < discoveredCalendars.length; j++) {
                if (discoveredCalendars[j] !== name) current.push(discoveredCalendars[j]);
            }
            cfg_calendarFilter = current.join(", ");
            return;
        }

        var idx = current.indexOf(name);
        if (enabled && idx < 0) current.push(name);
        if (!enabled && idx >= 0) current.splice(idx, 1);

        // If all discovered calendars are checked, store empty (= all)
        if (current.length === discoveredCalendars.length) {
            cfg_calendarFilter = "";
        } else {
            cfg_calendarFilter = current.join(", ");
        }
    }

    // ── UI ──

    QQC2.CheckBox {
        id: showCompletedCheck
        Kirigami.FormData.label: i18n("Show completed tasks:")
        text: i18n("Include completed tasks in the list")
    }

    Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Calendar Filter") }

    RowLayout {
        Kirigami.FormData.label: i18n(" ")
        QQC2.Button {
            text: discovering ? i18n("Discovering…") : i18n("Discover Calendars")
            icon.name: "view-refresh"
            enabled: !discovering
            onClicked: doDiscover()
        }
    }

    // Error label
    QQC2.Label {
        visible: discoverError !== ""
        text: discoverError
        color: Kirigami.Theme.negativeTextColor
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        Kirigami.FormData.label: i18n(" ")
    }

    // Hint when not yet discovered
    QQC2.Label {
        visible: discoveredCalendars.length === 0 && discoverError === "" && !discovering
        text: i18n("Click 'Discover Calendars' to load your calendars from the server.")
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        opacity: 0.7
        font.italic: true
        Kirigami.FormData.label: i18n(" ")
    }

    // Checkboxes — one per discovered calendar
    Repeater {
        model: discoveredCalendars.length
        QQC2.CheckBox {
            Kirigami.FormData.label: index === 0 ? i18n("Calendars:") : " "
            text: discoveredCalendars[index]
            checked: isEnabled(discoveredCalendars[index])
            onToggled: toggleCalendar(discoveredCalendars[index], checked)
        }
    }

    // Manual override text field (advanced / fallback)
    QQC2.TextField {
        id: calendarFilterField
        Kirigami.FormData.label: i18n("Manual filter:")
        placeholderText: i18n("Tasks, Personal (empty = all VTODO lists)")
        Layout.fillWidth: true
        text: cfg_calendarFilter
        onEditingFinished: cfg_calendarFilter = text
    }

    QQC2.Label {
        text: i18n("Comma-separated VTODO list names. Empty = show all. Updated automatically by the checkboxes above.")
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        opacity: 0.6
        font.italic: true
    }
}


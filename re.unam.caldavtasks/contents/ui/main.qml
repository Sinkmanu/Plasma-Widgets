import QtQuick 2.15
import QtQuick.Controls 2.15 as QQC2
import QtQuick.Layouts 1.15
import org.kde.plasma.plasmoid 2.0
import org.kde.kirigami 2.20 as Kirigami

PlasmoidItem {
    id: root

    // ── Config bindings ──
    readonly property string caldavUrl: Plasmoid.configuration.caldavUrl
    readonly property string username: Plasmoid.configuration.username
    readonly property string password: Plasmoid.configuration.password
    readonly property int refreshInterval: Plasmoid.configuration.refreshInterval
    readonly property bool showCompleted: Plasmoid.configuration.showCompleted
    readonly property string calendarFilter: Plasmoid.configuration.calendarFilter
    readonly property string widgetTitle: Plasmoid.configuration.widgetTitle
    readonly property int fontSize: Plasmoid.configuration.fontSize
    readonly property string fontFamily: Plasmoid.configuration.fontFamily

    // ── State ──
    property var taskList: []
    property bool loading: false
    property string errorMessage: ""
    property int pendingCount: 0
    property string createCalendarUrl: ""  // URL of first active calendar, used for new tasks
    property bool savingTask: false
    property var editingTask: null
    property string filterText: ""
    property date editDueDate: new Date()
    property int editDueHour: 9
    property int editDueMinute: 0
    property bool editDueHasTime: false

    readonly property var filteredTaskList: {
        if (filterText.trim() === "") return taskList;
        var q = filterText.trim().toLowerCase();
        var result = [];
        for (var i = 0; i < taskList.length; i++) {
            var t = taskList[i];
            if ((t.summary && t.summary.toLowerCase().indexOf(q) >= 0) ||
                (t.description && t.description.toLowerCase().indexOf(q) >= 0) ||
                (t.calendar && t.calendar.toLowerCase().indexOf(q) >= 0)) {
                result.push(t);
            }
        }
        return result;
    }

    switchWidth: Kirigami.Units.gridUnit * 12
    switchHeight: Kirigami.Units.gridUnit * 16

    Plasmoid.icon: "view-task"

    toolTipMainText: widgetTitle
    toolTipSubText: pendingCount > 0
        ? i18np("%1 pending task", "%1 pending tasks", pendingCount)
        : i18n("No pending tasks")

    // ── CalDAV helpers ──

    // Build Basic auth header
    function authHeader() {
        return "Basic " + Qt.btoa(username + ":" + password);
    }

    // PROPFIND to discover calendars that support VTODO
    function discoverCalendars() {
        console.log("[CalDAVTasks] discoverCalendars() — url='" + caldavUrl + "' user='" + username + "' passSet=" + (password !== "") + " filter='" + calendarFilter + "'");
        if (!caldavUrl || !username || !password) {
            errorMessage = i18n("Please configure connection settings.");
            loading = false;
            console.log("[CalDAVTasks] Aborted: missing config.");
            return;
        }

        loading = true;
        errorMessage = "";
        taskList = [];

        var baseUrl = caldavUrl.replace(/\/$/, "");
        // Normalise: if the user pasted a full calendar URL, trim to /calendars/username/
        var calendarsUrl;
        var calMatch = baseUrl.match(/^(.*\/calendars\/[^\/]+)/i);
        if (calMatch) {
            calendarsUrl = calMatch[1] + "/";
        } else {
            calendarsUrl = baseUrl + "/calendars/" + encodeURIComponent(username) + "/";
        }

        console.log("[CalDAVTasks] PROPFIND to: " + calendarsUrl);

        var xhr = new XMLHttpRequest();
        xhr.open("PROPFIND", calendarsUrl, true);
        xhr.setRequestHeader("Authorization", authHeader());
        xhr.setRequestHeader("Content-Type", "application/xml; charset=utf-8");
        xhr.setRequestHeader("Depth", "1");
        xhr.timeout = 20000;

        var propfindBody =
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<d:propfind xmlns:d="DAV:" xmlns:cs="urn:ietf:params:xml:ns:caldav" xmlns:x1="http://apple.com/ns/ical/">' +
            '  <d:prop>' +
            '    <d:resourcetype/>' +
            '    <d:displayname/>' +
            '    <cs:supported-calendar-component-set/>' +
            '  </d:prop>' +
            '</d:propfind>';

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;

            console.log("[CalDAVTasks] PROPFIND status: " + xhr.status + " " + xhr.statusText);

            if (xhr.status === 0) {
                // status 0 = network error (unreachable host, SSL failure, etc.)
                errorMessage = i18n("Network error — could not reach server.\nCheck your CalDAV URL and network.\nURL: %1", calendarsUrl);
                loading = false;
                return;
            }

            if (xhr.status < 200 || xhr.status >= 300) {
                errorMessage = i18n("PROPFIND failed: %1 %2\nURL: %3", xhr.status, xhr.statusText, calendarsUrl);
                loading = false;
                return;
            }

            var calendars = parseCalendarsResponse(xhr.responseText);
            if (calendars.length === 0) {
                errorMessage = i18n("No calendars with VTODO support found.");
                loading = false;
                return;
            }

            // Apply calendar filter
            var filterList = [];
            if (calendarFilter.trim() !== "") {
                var parts = calendarFilter.split(",");
                for (var i = 0; i < parts.length; i++) {
                    filterList.push(parts[i].trim().toLowerCase());
                }
            }

            var filtered = [];
            for (var j = 0; j < calendars.length; j++) {
                // Match against display name OR against the URL path slug (e.g. "todo")
                var slug = calendars[j].href.replace(/\/$/, "").split("/").pop().toLowerCase();
                console.log("[CalDAVTasks] Calendar found: name='" + calendars[j].name + "' slug='" + slug + "' href='" + calendars[j].href + "'");
                if (filterList.length === 0
                        || filterList.indexOf(calendars[j].name.toLowerCase()) >= 0
                        || filterList.indexOf(slug) >= 0) {
                    filtered.push(calendars[j]);
                }
            }
            console.log("[CalDAVTasks] Calendars after filter (" + (calendarFilter || "<all>") + "): " + filtered.length + " / " + calendars.length);

            if (filtered.length === 0) {
                var available = [];
                for (var k = 0; k < calendars.length; k++) {
                    available.push(calendars[k].name);
                }
                errorMessage = i18n("No calendars matched filter '%1'.\nFound: %2", calendarFilter, available.join(", "));
                loading = false;
                return;
            }

            // Store the first calendar's absolute URL for task creation
            var firstHref = filtered[0].href;
            if (firstHref.indexOf("http") === 0) {
                createCalendarUrl = firstHref;
            } else {
                var originParts = baseUrl.match(/^(https?:\/\/[^\/]+)/i);
                createCalendarUrl = originParts ? originParts[1] + firstHref : baseUrl + firstHref;
            }
            if (createCalendarUrl.slice(-1) !== "/") createCalendarUrl += "/";
            console.log("[CalDAVTasks] createCalendarUrl: " + createCalendarUrl);

            // Fetch tasks from each calendar
            fetchAllTasks(filtered, 0, []);
        };

        xhr.ontimeout = function() {
            console.log("[CalDAVTasks] PROPFIND timed out: " + calendarsUrl);
            errorMessage = i18n("Connection timed out.\nCheck your CalDAV URL and network.\nURL: %1", calendarsUrl);
            loading = false;
        };

        xhr.onerror = function() {
            console.log("[CalDAVTasks] PROPFIND onerror: " + calendarsUrl);
            errorMessage = i18n("Network error — could not reach server.\nCheck your CalDAV URL and network.\nURL: %1", calendarsUrl);
            loading = false;
        };

        xhr.send(propfindBody);
    }

    // Parse PROPFIND multistatus to extract calendar hrefs that support VTODO
    function parseCalendarsResponse(xml) {
        var calendars = [];

        // Log raw response for debugging (visible in plasmawindowed terminal)
        console.log("[CalDAVTasks] PROPFIND response:\n" + xml);

        // Split on any namespace-prefixed <response> tag (DAV: namespace, any prefix)
        var responses = xml.split(/<[^:>]+:response[\s>]/i);

        for (var i = 1; i < responses.length; i++) {
            var block = responses[i];

            // Extract href (any namespace prefix)
            var hrefMatch = block.match(/<[^:>]+:href[^>]*>([^<]+)<\/[^:>]+:href>/i);
            if (!hrefMatch) continue;
            var href = hrefMatch[1].trim();

            // Check it's a calendar collection (any namespace prefix)
            var isCalendar = /:calendar[\s\/]/i.test(block);
            if (!isCalendar) continue;

            // Check it supports VTODO — any prefix, with or without quotes
            var supportsVtodo = /:comp[^>]+name\s*=\s*["']?VTODO["']?/i.test(block);
            if (!supportsVtodo) continue;

            // Extract display name (any namespace prefix)
            var nameMatch = block.match(/<[^:>]+:displayname[^>]*>([^<]*)<\/[^:>]+:displayname>/i);
            var displayName = (nameMatch && nameMatch[1].trim()) ? nameMatch[1].trim() : href;

            calendars.push({ href: href, name: displayName });
        }

        console.log("[CalDAVTasks] Found calendars with VTODO: " + calendars.length);

        return calendars;
    }

    // Normalize iCal-like date values to YYYYMMDD for stable lexical sorting
    function dateSortKey(value) {
        if (!value) return "";
        var compact = (value + "").replace(/[^0-9]/g, "");
        if (compact.length < 8) return "";
        return compact.substring(0, 8);
    }

    // Fetch tasks from each calendar using PROPFIND with inline calendar-data.
    function fetchAllTasks(calendars, index, accumulated) {
        if (index >= calendars.length) {
            console.log("[CalDAVTasks] All calendars fetched. Total tasks: " + accumulated.length);
            accumulated.sort(function(a, b) {
                // Completed always sink to the bottom
                if (a.completed !== b.completed) return a.completed ? 1 : -1;
                // Within each group: tasks with due date first, earliest due date first
                var da = dateSortKey(a.due);
                var db = dateSortKey(b.due);
                if (da !== db) {
                    if (!da) return 1;
                    if (!db) return -1;
                    return da.localeCompare(db);
                }
                // Fallback for identical/missing due dates: newest CREATED/DTSTAMP first
                var ca = dateSortKey(a.created);
                var cb = dateSortKey(b.created);
                if (ca !== cb) {
                    if (!ca) return 1;
                    if (!cb) return -1;
                    return cb.localeCompare(ca);
                }
                return (a.summary || "").localeCompare(b.summary || "");
            });

            taskList = accumulated;
            pendingCount = 0;
            for (var c = 0; c < accumulated.length; c++) {
                if (!accumulated[c].completed) pendingCount++;
            }
            loading = false;
            return;
        }

        var cal = calendars[index];
        var baseUrl = caldavUrl.replace(/\/$/, "");

        var calUrl;
        if (cal.href.indexOf("http") === 0) {
            calUrl = cal.href;
        } else {
            var urlParts = baseUrl.match(/^(https?:\/\/[^\/]+)/i);
            calUrl = urlParts ? urlParts[1] + cal.href : baseUrl + cal.href;
        }

        console.log("[CalDAVTasks] PROPFIND (calendar-data) listing: " + calUrl);

        var xhr = new XMLHttpRequest();
        xhr.open("PROPFIND", calUrl, true);
        xhr.setRequestHeader("Authorization", authHeader());
        xhr.setRequestHeader("Content-Type", "application/xml; charset=utf-8");
        xhr.setRequestHeader("Depth", "1");
        xhr.timeout = 20000;

        var body =
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">' +
            '<d:prop><d:getetag/><c:calendar-data/></d:prop>' +
            '</d:propfind>';

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            console.log("[CalDAVTasks] PROPFIND status: " + xhr.status + " for '" + cal.name + "'");

            if (xhr.status >= 200 && xhr.status < 300) {
                var count = parseTasksFromMultistatus(xhr.responseText, cal, baseUrl, accumulated);
                console.log("[CalDAVTasks] Inline tasks in '" + cal.name + "': " + count);
                fetchAllTasks(calendars, index + 1, accumulated);
            } else {
                console.log("[CalDAVTasks] PROPFIND failed " + xhr.status + " for " + calUrl);
                fetchAllTasks(calendars, index + 1, accumulated);
            }
        };

        xhr.ontimeout = function() {
            console.log("[CalDAVTasks] PROPFIND timed out: " + calUrl);
            fetchAllTasks(calendars, index + 1, accumulated);
        };

        xhr.onerror = function() {
            console.log("[CalDAVTasks] PROPFIND onerror: " + calUrl);
            fetchAllTasks(calendars, index + 1, accumulated);
        };

        xhr.send(body);
    }

    // Parse inline calendar-data from a DAV multistatus response.
    function parseTasksFromMultistatus(xml, cal, baseUrl, accumulated) {
        var count = 0;
        var originMatch = baseUrl.match(/^(https?:\/\/[^\/]+)/i);
        var origin = originMatch ? originMatch[1] : "";

        var responses = xml.split(/<[^:>]+:response[\s>]/i);
        for (var i = 1; i < responses.length; i++) {
            var block = responses[i];

            var hrefMatch = block.match(/<[^:>]+:href[^>]*>([^<]+)<\/[^:>]+:href>/i);
            if (!hrefMatch) continue;
            var href = hrefMatch[1].trim();
            if (href.indexOf("http") !== 0) href = origin + href;

            var dataMatch = block.match(/<[^:>]+:calendar-data[^>]*>([\s\S]*?)<\/[^:>]+:calendar-data>/i);
            if (!dataMatch) continue;

            var ical = dataMatch[1]
                .replace(/<!\[CDATA\[/g, "")
                .replace(/\]\]>/g, "")
                .trim();

            if (addTaskFromIcal(ical, href, cal, accumulated)) {
                count++;
            }
        }

        return count;
    }

    function addTaskFromIcal(ical, href, cal, accumulated) {
        if (!/BEGIN:VTODO/i.test(ical)) return false;

        var summary = icalField(ical, "SUMMARY") || i18n("(no title)");
        var status = icalField(ical, "STATUS") || "";
        var priority = parseInt(icalField(ical, "PRIORITY") || "0", 10);
        var due = icalField(ical, "DUE") || "";
        var uid = icalField(ical, "UID") || "";
        var percent = parseInt(icalField(ical, "PERCENT-COMPLETE") || "0", 10);
        var description = icalField(ical, "DESCRIPTION") || "";
        var categories = icalField(ical, "CATEGORIES") || "";
        var created = icalField(ical, "CREATED") || icalField(ical, "DTSTAMP") || "";
        var isCompleted = (status.toUpperCase() === "COMPLETED" || percent === 100);

        console.log("[CalDAVTasks]   task: '" + summary + "' completed=" + isCompleted + " priority=" + priority + " created=" + created);

        if (showCompleted || !isCompleted) {
            accumulated.push({
                uid: uid,
                summary: summary,
                status: status,
                priority: priority,
                due: due,
                completed: isCompleted,
                percent: percent,
                description: description,
                categories: categories,
                created: created,
                calendar: cal.name,
                href: href,
                calUrl: cal.href,
                ical: ical
            });
        }

        return true;
    }

    // Extract a field value from iCal text
    function icalField(ical, fieldName) {
        // Handle folded lines (RFC 5545: continuation lines start with space/tab)
        var unfolded = ical.replace(/\r?\n[ \t]/g, "");
        var re = new RegExp("^" + fieldName + "(?:;[^:]*)?:(.*)$", "mi");
        var m = unfolded.match(re);
        return m ? m[1].trim() : "";
    }

    // Convert iCal DUE value to editor text (YYYY-MM-DD or YYYY-MM-DD HH:MM)
    function dueToEditorValue(due) {
        if (!due || due.length < 8) return "";
        var y = due.substring(0, 4);
        var m = due.substring(4, 6);
        var d = due.substring(6, 8);
        var text = y + "-" + m + "-" + d;
        if (due.indexOf("T") >= 0 && due.length >= 13) {
            var hh = due.substring(9, 11);
            var mm = due.substring(11, 13);
            text += " " + hh + ":" + mm;
        }
        return text;
    }

    // Parse iCal DUE value for date-time picker state
    function dueToPickerState(due) {
        var now = new Date();
        var state = {
            date: new Date(now.getFullYear(), now.getMonth(), now.getDate()),
            hour: now.getHours(),
            minute: now.getMinutes(),
            hasTime: false
        };
        if (!due || due.length < 8) return state;

        var y = parseInt(due.substring(0, 4), 10);
        var m = parseInt(due.substring(4, 6), 10) - 1;
        var d = parseInt(due.substring(6, 8), 10);
        state.date = new Date(y, m, d);

        if (due.indexOf("T") >= 0 && due.length >= 13) {
            state.hasTime = true;
            state.hour = parseInt(due.substring(9, 11), 10);
            state.minute = parseInt(due.substring(11, 13), 10);
        }
        return state;
    }

    // Build iCal DUE line from editor text
    function buildDueIcalLine(newDue) {
        var v = newDue.trim();
        if (!v) return "";
        var m = v.match(/^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2}))?$/);
        if (!m) return "";
        var datePart = m[1] + m[2] + m[3];
        if (m[4] !== undefined && m[5] !== undefined) {
            return "DUE:" + datePart + "T" + m[4] + m[5] + "00";
        }
        return "DUE;VALUE=DATE:" + datePart;
    }

    // Toggle task completion via PROPPATCH
    function toggleTaskComplete(task) {
        var baseUrl = caldavUrl.replace(/\/$/, "");
        var taskUrl;
        if (task.href.indexOf("http") === 0) {
            taskUrl = task.href;
        } else {
            var urlParts = baseUrl.match(/^(https?:\/\/[^\/]+)/i);
            taskUrl = urlParts ? urlParts[1] + task.href : baseUrl + task.href;
        }

        // Modify the iCal: toggle STATUS and PERCENT-COMPLETE
        var newIcal = task.ical;
        var unfolded = newIcal.replace(/\r?\n[ \t]/g, "");

        if (task.completed) {
            // Mark as needs-action
            unfolded = unfolded.replace(/^STATUS:.*$/mi, "STATUS:NEEDS-ACTION");
            unfolded = unfolded.replace(/^PERCENT-COMPLETE:.*$/mi, "PERCENT-COMPLETE:0");
            unfolded = unfolded.replace(/^COMPLETED:.*$\r?\n?/mi, "");
        } else {
            // Mark as completed
            var now = new Date();
            var ts = now.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");

            if (/^STATUS:/mi.test(unfolded)) {
                unfolded = unfolded.replace(/^STATUS:.*$/mi, "STATUS:COMPLETED");
            } else {
                unfolded = unfolded.replace(/^(END:VTODO)/mi, "STATUS:COMPLETED\n$1");
            }

            if (/^PERCENT-COMPLETE:/mi.test(unfolded)) {
                unfolded = unfolded.replace(/^PERCENT-COMPLETE:.*$/mi, "PERCENT-COMPLETE:100");
            } else {
                unfolded = unfolded.replace(/^(END:VTODO)/mi, "PERCENT-COMPLETE:100\n$1");
            }

            if (!/^COMPLETED:/mi.test(unfolded)) {
                unfolded = unfolded.replace(/^(END:VTODO)/mi, "COMPLETED:" + ts + "\n$1");
            }
        }

        // Update DTSTAMP and LAST-MODIFIED per RFC 5545
        var modTs = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
        if (/^DTSTAMP:/mi.test(unfolded)) {
            unfolded = unfolded.replace(/^DTSTAMP:.*$/mi, "DTSTAMP:" + modTs);
        } else {
            unfolded = unfolded.replace(/^(END:VTODO)/mi, "DTSTAMP:" + modTs + "\n$1");
        }
        if (/^LAST-MODIFIED:/mi.test(unfolded)) {
            unfolded = unfolded.replace(/^LAST-MODIFIED:.*$/mi, "LAST-MODIFIED:" + modTs);
        } else {
            unfolded = unfolded.replace(/^(END:VTODO)/mi, "LAST-MODIFIED:" + modTs + "\n$1");
        }

        console.log("[CalDAVTasks] toggleTaskComplete: '" + task.summary + "' completed=" + task.completed + " -> " + !task.completed + " url=" + taskUrl);

        var xhr = new XMLHttpRequest();
        xhr.open("PUT", taskUrl, true);
        xhr.setRequestHeader("Authorization", authHeader());
        xhr.setRequestHeader("Content-Type", "text/calendar; charset=utf-8");
        xhr.setRequestHeader("If-Match", "*");

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            console.log("[CalDAVTasks] PUT status: " + xhr.status + " for '" + task.summary + "'");
            // Refresh regardless of result
            discoverCalendars();
        };

        xhr.send(unfolded);
    }

    // Generate a RFC 4122 v4 UUID
    function generateUid() {
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
            var r = Math.random() * 16 | 0;
            return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
        });
    }

    // Create a new VTODO on the server via PUT
    function createTask(summary) {
        summary = summary.trim();
        if (!summary || !createCalendarUrl) return;

        var uid = generateUid();
        var now = new Date();
        var stamp = now.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
        var ical =
            "BEGIN:VCALENDAR\r\n" +
            "VERSION:2.0\r\n" +
            "PRODID:-//re.unam.CalDAVTasks//EN\r\n" +
            "BEGIN:VTODO\r\n" +
            "DTSTAMP:" + stamp + "\r\n" +
            "CREATED:" + stamp + "\r\n" +
            "UID:" + uid + "\r\n" +
            "SUMMARY:" + summary + "\r\n" +
            "STATUS:NEEDS-ACTION\r\n" +
            "PERCENT-COMPLETE:0\r\n" +
            "END:VTODO\r\n" +
            "END:VCALENDAR\r\n";

        var url = createCalendarUrl + uid + ".ics";
        console.log("[CalDAVTasks] createTask: '" + summary + "' -> " + url);

        savingTask = true;
        var xhr = new XMLHttpRequest();
        xhr.open("PUT", url, true);
        xhr.setRequestHeader("Authorization", authHeader());
        xhr.setRequestHeader("Content-Type", "text/calendar; charset=utf-8");
        xhr.setRequestHeader("If-None-Match", "*");  // fail if UID already exists
        xhr.timeout = 15000;

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            savingTask = false;
            console.log("[CalDAVTasks] createTask PUT status: " + xhr.status);
            if (xhr.status >= 200 && xhr.status < 300) {
                discoverCalendars();
            } else {
                errorMessage = i18n("Failed to create task: %1 %2", xhr.status, xhr.statusText);
            }
        };
        xhr.ontimeout = function() {
            savingTask = false;
            errorMessage = i18n("Timed out while creating task.");
        };
        xhr.onerror = function() {
            savingTask = false;
            errorMessage = i18n("Network error while creating task.");
        };
        xhr.send(ical);
    }

    // Update an existing VTODO on the server via PUT
    function updateTask(task, newSummary, newDescription, newDue, newPriority) {
        newSummary = newSummary.trim();
        if (!newSummary) return;

        var taskUrl;
        if (task.href.indexOf("http") === 0) {
            taskUrl = task.href;
        } else {
            var baseUrl = caldavUrl.replace(/\/$/, "");
            var urlParts = baseUrl.match(/^(https?:\/\/[^\/]+)/i);
            taskUrl = urlParts ? urlParts[1] + task.href : baseUrl + task.href;
        }

        var unfolded = task.ical.replace(/\r?\n[ \t]/g, "");

        // Update SUMMARY
        if (/^SUMMARY:/mi.test(unfolded)) {
            unfolded = unfolded.replace(/^SUMMARY:.*$/mi, "SUMMARY:" + newSummary);
        } else {
            unfolded = unfolded.replace(/^(END:VTODO)/mi, "SUMMARY:" + newSummary + "\n$1");
        }

        // Update DESCRIPTION
        var newDesc = newDescription.trim();
        if (newDesc) {
            var descVal = newDesc.replace(/\n/g, "\\n");
            if (/^DESCRIPTION:/mi.test(unfolded)) {
                unfolded = unfolded.replace(/^DESCRIPTION:.*$/mi, "DESCRIPTION:" + descVal);
            } else {
                unfolded = unfolded.replace(/^(END:VTODO)/mi, "DESCRIPTION:" + descVal + "\n$1");
            }
        } else {
            unfolded = unfolded.replace(/^DESCRIPTION:.*$\r?\n?/mi, "");
        }

        // Update DUE
        var newDueTrimmed = newDue.trim();
        if (newDueTrimmed) {
            var dueLine = buildDueIcalLine(newDueTrimmed);
            if (!dueLine) {
                dueLine = "DUE;VALUE=DATE:" + newDueTrimmed.replace(/-/g, "");
            }
            if (/^DUE[^:]*:/mi.test(unfolded)) {
                unfolded = unfolded.replace(/^DUE[^:]*:.*$/mi, dueLine);
            } else {
                unfolded = unfolded.replace(/^(END:VTODO)/mi, dueLine + "\n$1");
            }
        } else {
            unfolded = unfolded.replace(/^DUE[^:]*:.*$\r?\n?/mi, "");
        }

        // Update PRIORITY
        if (newPriority > 0) {
            if (/^PRIORITY:/mi.test(unfolded)) {
                unfolded = unfolded.replace(/^PRIORITY:.*$/mi, "PRIORITY:" + newPriority);
            } else {
                unfolded = unfolded.replace(/^(END:VTODO)/mi, "PRIORITY:" + newPriority + "\n$1");
            }
        } else {
            unfolded = unfolded.replace(/^PRIORITY:.*$\r?\n?/mi, "");
        }

        // Update DTSTAMP and LAST-MODIFIED
        var modTs = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
        if (/^DTSTAMP:/mi.test(unfolded)) {
            unfolded = unfolded.replace(/^DTSTAMP:.*$/mi, "DTSTAMP:" + modTs);
        } else {
            unfolded = unfolded.replace(/^(END:VTODO)/mi, "DTSTAMP:" + modTs + "\n$1");
        }
        if (/^LAST-MODIFIED:/mi.test(unfolded)) {
            unfolded = unfolded.replace(/^LAST-MODIFIED:.*$/mi, "LAST-MODIFIED:" + modTs);
        } else {
            unfolded = unfolded.replace(/^(END:VTODO)/mi, "LAST-MODIFIED:" + modTs + "\n$1");
        }

        console.log("[CalDAVTasks] updateTask: '" + task.summary + "' -> '" + newSummary + "' url=" + taskUrl);

        savingTask = true;
        var xhr = new XMLHttpRequest();
        xhr.open("PUT", taskUrl, true);
        xhr.setRequestHeader("Authorization", authHeader());
        xhr.setRequestHeader("Content-Type", "text/calendar; charset=utf-8");
        xhr.setRequestHeader("If-Match", "*");
        xhr.timeout = 15000;

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            savingTask = false;
            root.editingTask = null;
            console.log("[CalDAVTasks] updateTask PUT status: " + xhr.status);
            if (xhr.status >= 200 && xhr.status < 300) {
                discoverCalendars();
            } else {
                errorMessage = i18n("Failed to update task: %1 %2", xhr.status, xhr.statusText);
            }
        };
        xhr.ontimeout = function() {
            savingTask = false;
            errorMessage = i18n("Timed out while updating task.");
        };
        xhr.onerror = function() {
            savingTask = false;
            errorMessage = i18n("Network error while updating task.");
        };

        xhr.send(unfolded);
    }

    // Format due date for display
    function formatDue(due) {
        if (!due) return "";
        // Parse iCal date format: YYYYMMDD or YYYYMMDDTHHmmssZ
        var y = due.substring(0, 4);
        var m = due.substring(4, 6);
        var d = due.substring(6, 8);

        var today = new Date();
        var todayStr = Qt.formatDate(today, "yyyy-MM-dd");
        var dueStr = y + "-" + m + "-" + d;

        var dueDate = new Date(parseInt(y), parseInt(m) - 1, parseInt(d));
        var diffMs = dueDate.getTime() - new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime();
        var diffDays = Math.round(diffMs / 86400000);

        if (diffDays < 0) return i18n("overdue %1d", Math.abs(diffDays));
        if (diffDays === 0) return i18n("today");
        if (diffDays === 1) return i18n("tomorrow");
        var base = d + "/" + m + "/" + y;
        if (due.indexOf("T") >= 0 && due.length >= 13) {
            base += " " + due.substring(9, 11) + ":" + due.substring(11, 13);
        }
        return base;
    }

    // Priority label
    function priorityLabel(p) {
        if (p >= 1 && p <= 4) return "!!";
        if (p === 5) return "!";
        return "";
    }

    function priorityColor(p) {
        if (p >= 1 && p <= 4) return Kirigami.Theme.negativeTextColor;
        if (p === 5) return Kirigami.Theme.neutralTextColor;
        return "transparent";
    }

    // ── Auto-refresh timer ──
    Timer {
        id: refreshTimer
        interval: refreshInterval * 60 * 1000
        running: caldavUrl !== "" && username !== "" && password !== ""
        repeat: true
        onTriggered: discoverCalendars()
    }

    Component.onCompleted: {
        console.log("[CalDAVTasks] Component ready. url='" + caldavUrl + "' user='" + username + "' passSet=" + (password !== "") + " filter='" + calendarFilter + "' refreshInterval=" + refreshInterval);
        if (caldavUrl && username && password) {
            discoverCalendars();
        } else {
            console.log("[CalDAVTasks] Not starting: missing config.");
        }
    }

    // Re-fetch when config changes
    onCaldavUrlChanged: if (caldavUrl && username && password) discoverCalendars()
    onUsernameChanged: if (caldavUrl && username && password) discoverCalendars()
    onPasswordChanged: if (caldavUrl && username && password) discoverCalendars()
    onShowCompletedChanged: if (caldavUrl && username && password) discoverCalendars()
    onCalendarFilterChanged: if (caldavUrl && username && password) discoverCalendars()

    // ── Compact representation (panel icon) ──
    compactRepresentation: MouseArea {
        acceptedButtons: Qt.LeftButton
        onClicked: root.expanded = !root.expanded

        Kirigami.Icon {
            anchors.fill: parent
            source: "view-task"
            active: parent.containsMouse

            QQC2.Label {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: -2
                visible: pendingCount > 0
                text: pendingCount
                font.pixelSize: parent.height * 0.4
                font.bold: true
                color: Kirigami.Theme.highlightColor
                style: Text.Outline
                styleColor: Kirigami.Theme.backgroundColor
            }
        }
    }

    // ── Full representation (expanded popup) ──
    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.preferredWidth: Kirigami.Units.gridUnit * 24
        // No fixed preferredHeight: let implicitHeight (sum of children) drive the popup size
        spacing: 0

        // Header
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                source: "view-task"
                implicitWidth: Kirigami.Units.iconSizes.medium
                implicitHeight: Kirigami.Units.iconSizes.medium
            }

            Kirigami.Heading {
                id: titleHeading
                text: widgetTitle
                level: 3
                Layout.fillWidth: true
                visible: !titleField.visible

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.IBeamCursor
                    onClicked: {
                        titleField.text = widgetTitle;
                        titleField.visible = true;
                        titleField.forceActiveFocus();
                        titleField.selectAll();
                    }
                }
            }

            QQC2.TextField {
                id: titleField
                Layout.fillWidth: true
                visible: false
                font: titleHeading.font

                function commitTitle() {
                    var t = text.trim();
                    if (t) Plasmoid.configuration.widgetTitle = t;
                    visible = false;
                }

                Keys.onReturnPressed: commitTitle()
                Keys.onEnterPressed: commitTitle()
                Keys.onEscapePressed: visible = false
                onActiveFocusChanged: if (!activeFocus && visible) commitTitle()
            }

            QQC2.Label {
                text: pendingCount > 0 ? i18np("%1 pending task", "%1 pending tasks", pendingCount) : ""
                opacity: 0.7
                font.italic: true
            }

            QQC2.ToolButton {
                icon.name: "view-refresh"
                onClicked: discoverCalendars()
                enabled: !loading
                QQC2.ToolTip.text: i18n("Refresh tasks")
                QQC2.ToolTip.visible: hovered
            }
        }

        Kirigami.Separator {
            Layout.fillWidth: true
        }

        // Loading indicator
        QQC2.BusyIndicator {
            Layout.alignment: Qt.AlignHCenter
            visible: loading
            running: loading
        }

        // Error message
        QQC2.Label {
            visible: errorMessage !== ""
            text: errorMessage
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.largeSpacing
            horizontalAlignment: Text.AlignHCenter
        }

        // Not configured message
        QQC2.Label {
            visible: !caldavUrl && !loading
            text: i18n("Right-click → Configure to set up your CalDAV Tasks connection.")
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.largeSpacing
            horizontalAlignment: Text.AlignHCenter
            opacity: 0.7
        }

        // Empty state
        QQC2.Label {
            visible: !loading && errorMessage === "" && caldavUrl !== "" && taskList.length === 0
            text: i18n("No tasks found.")
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.largeSpacing
            horizontalAlignment: Text.AlignHCenter
            opacity: 0.7
        }

        // Task list
        QQC2.ScrollView {
            Layout.fillWidth: true
            // Grow with actual rendered content; cap at 30 gu to avoid going off-screen
            Layout.preferredHeight: Math.min(
                taskListView.contentHeight > 0 ? taskListView.contentHeight : Kirigami.Units.gridUnit * 3,
                Kirigami.Units.gridUnit * 30
            )
            visible: filteredTaskList.length > 0 && !loading && editingTask === null

            ListView {
                id: taskListView
                model: filteredTaskList.length
                spacing: 1
                clip: true

                delegate: Rectangle {
                    id: taskDelegate
                    width: taskListView.width
                    height: taskContent.implicitHeight + Kirigami.Units.smallSpacing * 2
                    color: index % 2 === 0 ? "transparent" : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.03)

                    readonly property var task: filteredTaskList[index]
                    property bool editingTitle: false

                    RowLayout {
                        id: taskContent
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.smallSpacing

                        QQC2.CheckBox {
                            checked: task.completed
                            onToggled: toggleTaskComplete(task)
                            Layout.alignment: Qt.AlignTop
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                // Priority indicator
                                QQC2.Label {
                                    visible: priorityLabel(task.priority) !== ""
                                    text: priorityLabel(task.priority)
                                    color: priorityColor(task.priority)
                                    font.bold: true
                                    font.pixelSize: root.fontSize > 0 ? root.fontSize : Kirigami.Theme.defaultFont.pixelSize
                                    font.family: root.fontFamily !== "" ? root.fontFamily : Kirigami.Theme.defaultFont.family
                                }

                                QQC2.Label {
                                    text: task.summary
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    font.strikeout: task.completed
                                    font.pixelSize: root.fontSize > 0 ? root.fontSize : Kirigami.Theme.defaultFont.pixelSize
                                    font.family: root.fontFamily !== "" ? root.fontFamily : Kirigami.Theme.defaultFont.family
                                    opacity: task.completed ? 0.5 : 1.0
                                    visible: !taskDelegate.editingTitle
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.IBeamCursor
                                        onClicked: {
                                            summaryEdit.text = task.summary;
                                            taskDelegate.editingTitle = true;
                                            summaryEdit.forceActiveFocus();
                                            summaryEdit.selectAll();
                                        }
                                    }
                                }

                                QQC2.Label {
                                    visible: !taskDelegate.editingTitle && task.calendar !== ""
                                    text: task.calendar
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                    color: Kirigami.Theme.disabledTextColor
                                    elide: Text.ElideRight
                                    Layout.maximumWidth: Kirigami.Units.gridUnit * 6
                                }

                                QQC2.TextField {
                                    id: summaryEdit
                                    Layout.fillWidth: true
                                    visible: taskDelegate.editingTitle
                                    font.strikeout: task.completed

                                    function commit() {
                                        var newSummary = text.trim();
                                        if (newSummary && newSummary !== task.summary) {
                                            var due = dueToEditorValue(task.due);
                                            updateTask(task, newSummary, task.description, due, task.priority);
                                        }
                                        taskDelegate.editingTitle = false;
                                    }

                                    Keys.onReturnPressed: commit()
                                    Keys.onEnterPressed: commit()
                                    Keys.onEscapePressed: taskDelegate.editingTitle = false
                                    onActiveFocusChanged: if (!activeFocus && visible) commit()
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.largeSpacing
                                visible: task.due !== ""

                                // Due date
                                QQC2.Label {
                                    visible: task.due !== ""
                                    text: formatDue(task.due)
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                    color: {
                                        var due = task.due;
                                        if (!due) return Kirigami.Theme.disabledTextColor;
                                        var y = parseInt(due.substring(0, 4));
                                        var m = parseInt(due.substring(4, 6)) - 1;
                                        var d = parseInt(due.substring(6, 8));
                                        var dueDate = new Date(y, m, d);
                                        var today = new Date();
                                        today.setHours(0, 0, 0, 0);
                                        if (dueDate < today) return Kirigami.Theme.negativeTextColor;
                                        if (dueDate.getTime() === today.getTime()) return Kirigami.Theme.neutralTextColor;
                                        return Kirigami.Theme.disabledTextColor;
                                    }
                                }


                            }
                        }

                        QQC2.ToolButton {
                            icon.name: "document-edit"
                            flat: true
                            opacity: taskMouseArea.containsMouse ? 1.0 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 100 } }
                            onClicked: {
                                var t = task;
                                root.editingTask = t;
                                editSummaryField.text = t.summary;
                                editDescField.text = t.description.replace(/\\n/g, "\n");
                                editDueField.text = dueToEditorValue(t.due);
                                var dueState = dueToPickerState(t.due);
                                root.editDueDate = dueState.date;
                                root.editDueHour = dueState.hour;
                                root.editDueMinute = dueState.minute;
                                root.editDueHasTime = dueState.hasTime;
                                editPriorityCombo.currentIndex = (t.priority >= 1 && t.priority <= 4) ? 2
                                    : t.priority === 5 ? 1 : 0;
                            }
                            QQC2.ToolTip.text: i18n("Edit task")
                            QQC2.ToolTip.visible: hovered
                        }
                    }

                    // Hover highlight
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        propagateComposedEvents: true
                        onEntered: taskDelegate.color = Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g, Kirigami.Theme.highlightColor.b, 0.1)
                        onExited: taskDelegate.color = index % 2 === 0 ? "transparent" : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.03)
                        // Pass clicks through so CheckBox works
                        onClicked: mouse.accepted = false
                        onPressed: mouse.accepted = false
                        onReleased: mouse.accepted = false
                    }

                    QQC2.ToolTip.visible: taskMouseArea.containsMouse && task.description !== ""
                    QQC2.ToolTip.text: task.description
                    QQC2.ToolTip.delay: 800

                    MouseArea {
                        id: taskMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                    }
                }
            }
        }

        // Edit task form
        ColumnLayout {
            visible: editingTask !== null
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Heading {
                level: 4
                text: i18n("Edit Task")
                Layout.fillWidth: true
            }

            QQC2.Label { text: i18n("Title") }
            QQC2.TextField {
                id: editSummaryField
                Layout.fillWidth: true
                Keys.onReturnPressed: {
                    var p = editPriorityCombo.currentIndex === 2 ? 1
                           : editPriorityCombo.currentIndex === 1 ? 5 : 0;
                    updateTask(editingTask, text, editDescField.text, editDueField.text, p);
                }
            }

            QQC2.Label { text: i18n("Description") }
            QQC2.TextArea {
                id: editDescField
                Layout.fillWidth: true
                implicitHeight: Kirigami.Units.gridUnit * 4
                wrapMode: TextEdit.Wrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                ColumnLayout {
                    spacing: 2
                    QQC2.Label { text: i18n("Due date") }
                    RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        QQC2.TextField {
                            id: editDueField
                            readOnly: true
                            placeholderText: i18n("Select date and time")
                            implicitWidth: Kirigami.Units.gridUnit * 12
                        }

                        QQC2.ToolButton {
                            icon.name: "office-calendar"
                            onClicked: duePickerPopup.open()
                            QQC2.ToolTip.text: i18n("Pick due date")
                            QQC2.ToolTip.visible: hovered
                        }

                        QQC2.ToolButton {
                            icon.name: "edit-clear"
                            visible: editDueField.text !== ""
                            onClicked: {
                                editDueField.text = "";
                                root.editDueHasTime = false;
                            }
                            QQC2.ToolTip.text: i18n("Clear due date")
                            QQC2.ToolTip.visible: hovered
                        }
                    }
                }

                ColumnLayout {
                    spacing: 2
                    QQC2.Label { text: i18n("Priority") }
                    QQC2.ComboBox {
                        id: editPriorityCombo
                        model: [i18n("None"), i18n("Medium"), i18n("High")]
                    }
                }
            }

            QQC2.Popup {
                id: duePickerPopup
                x: Math.max(0, (parent.width - width) / 2)
                y: Math.max(0, (parent.height - height) / 2)
                modal: true
                focus: true
                closePolicy: QQC2.Popup.CloseOnEscape | QQC2.Popup.CloseOnPressOutside
                padding: Kirigami.Units.smallSpacing

                property date selectedDate: root.editDueDate
                property int shownMonth: root.editDueDate.getMonth()
                property int shownYear: root.editDueDate.getFullYear()
                property var weekdayHeaders: [i18n("Mon"), i18n("Tue"), i18n("Wed"), i18n("Thu"), i18n("Fri"), i18n("Sat"), i18n("Sun")]
                property var calendarCells: []

                function sameDate(a, b) {
                    return a.getFullYear() === b.getFullYear()
                        && a.getMonth() === b.getMonth()
                        && a.getDate() === b.getDate();
                }

                function refreshCalendarCells() {
                    var first = new Date(shownYear, shownMonth, 1);
                    var firstWeekDay = (first.getDay() + 6) % 7; // Monday-first grid
                    var start = new Date(shownYear, shownMonth, 1 - firstWeekDay);
                    var cells = [];
                    for (var i = 0; i < 42; i++) {
                        var d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i);
                        cells.push({
                            year: d.getFullYear(),
                            month: d.getMonth(),
                            day: d.getDate(),
                            inMonth: d.getMonth() === shownMonth
                        });
                    }
                    calendarCells = cells;
                }

                function syncEditorField() {
                    var y = selectedDate.getFullYear();
                    var m = ("0" + (selectedDate.getMonth() + 1)).slice(-2);
                    var d = ("0" + selectedDate.getDate()).slice(-2);
                    var value = y + "-" + m + "-" + d;
                    if (root.editDueHasTime) {
                        var hh = ("0" + root.editDueHour).slice(-2);
                        var mm = ("0" + root.editDueMinute).slice(-2);
                        value += " " + hh + ":" + mm;
                    }
                    editDueField.text = value;
                }

                onOpened: {
                    selectedDate = root.editDueDate;
                    shownMonth = root.editDueDate.getMonth();
                    shownYear = root.editDueDate.getFullYear();
                    refreshCalendarCells();
                }

                onShownMonthChanged: refreshCalendarCells()
                onShownYearChanged: refreshCalendarCells()

                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true

                        QQC2.ToolButton {
                            icon.name: "go-previous"
                            onClicked: {
                                duePickerPopup.shownMonth -= 1;
                                if (duePickerPopup.shownMonth < 0) {
                                    duePickerPopup.shownMonth = 11;
                                    duePickerPopup.shownYear -= 1;
                                }
                            }
                        }

                        QQC2.Label {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: Qt.formatDate(new Date(duePickerPopup.shownYear, duePickerPopup.shownMonth, 1), "MMMM yyyy")
                            font.bold: true
                        }

                        QQC2.ToolButton {
                            icon.name: "go-next"
                            onClicked: {
                                duePickerPopup.shownMonth += 1;
                                if (duePickerPopup.shownMonth > 11) {
                                    duePickerPopup.shownMonth = 0;
                                    duePickerPopup.shownYear += 1;
                                }
                            }
                        }
                    }

                    GridLayout {
                        columns: 7
                        Layout.fillWidth: true
                        columnSpacing: Kirigami.Units.smallSpacing
                        rowSpacing: Kirigami.Units.smallSpacing

                        Repeater {
                            model: duePickerPopup.weekdayHeaders
                            delegate: QQC2.Label {
                                text: modelData
                                horizontalAlignment: Text.AlignHCenter
                                Layout.fillWidth: true
                                opacity: 0.8
                                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            }
                        }

                        Repeater {
                            model: duePickerPopup.calendarCells
                            delegate: QQC2.ItemDelegate {
                                readonly property bool isSelected: duePickerPopup.selectedDate
                                    && duePickerPopup.selectedDate.getFullYear() === modelData.year
                                    && duePickerPopup.selectedDate.getMonth() === modelData.month
                                    && duePickerPopup.selectedDate.getDate() === modelData.day
                                readonly property bool isToday: duePickerPopup.sameDate(new Date(), new Date(modelData.year, modelData.month, modelData.day))

                                implicitWidth: Kirigami.Units.gridUnit * 1.9
                                implicitHeight: Kirigami.Units.gridUnit * 1.7
                                opacity: modelData.inMonth ? 1.0 : 0.45

                                onClicked: {
                                    duePickerPopup.selectedDate = new Date(modelData.year, modelData.month, modelData.day);
                                    if (!modelData.inMonth) {
                                        duePickerPopup.shownMonth = modelData.month;
                                        duePickerPopup.shownYear = modelData.year;
                                    }
                                }

                                background: Rectangle {
                                    radius: Kirigami.Units.smallSpacing
                                    color: isSelected
                                        ? Kirigami.Theme.highlightColor
                                        : (isToday
                                            ? Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g, Kirigami.Theme.highlightColor.b, 0.15)
                                            : "transparent")
                                    border.width: isToday && !isSelected ? 1 : 0
                                    border.color: Kirigami.Theme.highlightColor
                                }

                                contentItem: QQC2.Label {
                                    text: modelData.day
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                    color: isSelected ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                                }
                            }
                        }
                    }

                    RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        QQC2.CheckBox {
                            text: i18n("Include time")
                            checked: root.editDueHasTime
                            onToggled: root.editDueHasTime = checked
                        }

                        QQC2.SpinBox {
                            enabled: root.editDueHasTime
                            from: 0
                            to: 23
                            value: root.editDueHour
                            onValueModified: root.editDueHour = value
                            textFromValue: function(value) { return ("0" + value).slice(-2); }
                            valueFromText: function(text) { return parseInt(text, 10); }
                        }

                        QQC2.Label {
                            text: ":"
                            enabled: root.editDueHasTime
                        }

                        QQC2.SpinBox {
                            enabled: root.editDueHasTime
                            from: 0
                            to: 59
                            value: root.editDueMinute
                            onValueModified: root.editDueMinute = value
                            textFromValue: function(value) { return ("0" + value).slice(-2); }
                            valueFromText: function(text) { return parseInt(text, 10); }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true

                        QQC2.Button {
                            text: i18n("Today")
                            onClicked: {
                                var now = new Date();
                                duePickerPopup.selectedDate = new Date(now.getFullYear(), now.getMonth(), now.getDate());
                                duePickerPopup.shownMonth = duePickerPopup.selectedDate.getMonth();
                                duePickerPopup.shownYear = duePickerPopup.selectedDate.getFullYear();
                            }
                        }

                        Item { Layout.fillWidth: true }

                        QQC2.Button {
                            text: i18n("Apply")
                            highlighted: true
                            onClicked: {
                                root.editDueDate = duePickerPopup.selectedDate;
                                duePickerPopup.syncEditorField();
                                duePickerPopup.close();
                            }
                        }
                    }
                }
            }

            Item { Layout.fillHeight: true }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                QQC2.Button {
                    text: i18n("Cancel")
                    onClicked: root.editingTask = null
                }

                Item { Layout.fillWidth: true }

                QQC2.Button {
                    text: i18n("Save")
                    highlighted: true
                    enabled: editSummaryField.text.trim() !== "" && !savingTask
                    onClicked: {
                        var p = editPriorityCombo.currentIndex === 2 ? 1
                               : editPriorityCombo.currentIndex === 1 ? 5 : 0;
                        updateTask(editingTask, editSummaryField.text,
                                   editDescField.text, editDueField.text, p);
                    }
                }
            }
        }

        // Add task bar
        Kirigami.Separator { Layout.fillWidth: true }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.bottomMargin: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            visible: caldavUrl !== "" && createCalendarUrl !== "" && editingTask === null

            QQC2.TextField {
                id: newTaskField
                Layout.fillWidth: true
                placeholderText: i18n("New task…")
                enabled: !savingTask && !loading
                Keys.onReturnPressed: {
                    createTask(text);
                    text = "";
                }
                Keys.onEnterPressed: {
                    createTask(text);
                    text = "";
                }
            }

            QQC2.TextField {
                id: filterField
                implicitWidth: Kirigami.Units.gridUnit * 8
                placeholderText: i18n("Filter…")
                onTextChanged: root.filterText = text
                Keys.onEscapePressed: { text = ""; root.filterText = ""; }

                // Clear button
                QQC2.ToolButton {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: filterField.text !== ""
                    icon.name: "edit-clear"
                    flat: true
                    implicitWidth: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing
                    implicitHeight: implicitWidth
                    onClicked: { filterField.text = ""; root.filterText = ""; }
                }
            }

            QQC2.ToolButton {
                icon.name: savingTask ? "process-working" : "list-add"
                enabled: newTaskField.text.trim() !== "" && !savingTask && !loading
                onClicked: {
                    createTask(newTaskField.text);
                    newTaskField.text = "";
                }
                QQC2.ToolTip.text: i18n("Add task")
                QQC2.ToolTip.visible: hovered
            }
        }

        // Footer
        Kirigami.Separator {
            Layout.fillWidth: true
        }

        QQC2.Label {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            text: {
                if (!loading && taskList.length > 0) {
                    var cals = [];
                    for (var i = 0; i < taskList.length; i++) {
                        if (cals.indexOf(taskList[i].calendar) < 0) cals.push(taskList[i].calendar);
                    }
                    return i18np("From %2 (%1 task)", "From %2 (%1 tasks)", taskList.length, cals.join(", "));
                }
                return "";
            }
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            color: Kirigami.Theme.disabledTextColor
            horizontalAlignment: Text.AlignRight
            visible: text !== ""
        }
    }
}

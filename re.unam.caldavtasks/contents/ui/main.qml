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

    // ── State ──
    property var taskList: []
    property bool loading: false
    property string errorMessage: ""
    property int pendingCount: 0
    property string createCalendarUrl: ""  // URL of first active calendar, used for new tasks
    property bool savingTask: false
    property var editingTask: null

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

    // Step 1: for each calendar, PROPFIND Depth:1 to list .ics resources
    function fetchAllTasks(calendars, index, accumulated) {
        if (index >= calendars.length) {
            console.log("[CalDAVTasks] All calendars fetched. Total tasks: " + accumulated.length);
            accumulated.sort(function(a, b) {
                // Completed always sink to the bottom
                if (a.completed !== b.completed) return a.completed ? 1 : -1;
                // Within each group: newest first (CREATED desc — strings are YYYYMMDD... so lexicographic desc works)
                var ca = a.created || "";
                var cb = b.created || "";
                if (ca !== cb) return cb.localeCompare(ca);
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

        console.log("[CalDAVTasks] PROPFIND listing: " + calUrl);

        var xhr = new XMLHttpRequest();
        xhr.open("PROPFIND", calUrl, true);
        xhr.setRequestHeader("Authorization", authHeader());
        xhr.setRequestHeader("Content-Type", "application/xml; charset=utf-8");
        xhr.setRequestHeader("Depth", "1");
        xhr.timeout = 20000;

        var body =
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<d:propfind xmlns:d="DAV:">' +
            '<d:prop><d:getetag/><d:getcontenttype/></d:prop>' +
            '</d:propfind>';

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            console.log("[CalDAVTasks] PROPFIND list status: " + xhr.status + " for '" + cal.name + "'");
            if (xhr.status >= 200 && xhr.status < 300) {
                var icsHrefs = parseIcsHrefs(xhr.responseText, baseUrl);
                console.log("[CalDAVTasks] .ics resources in '" + cal.name + "': " + icsHrefs.length);
                fetchIcsFiles(icsHrefs, 0, cal, accumulated, calendars, index);
            } else {
                console.log("[CalDAVTasks] PROPFIND list failed " + xhr.status + " for " + calUrl);
                fetchAllTasks(calendars, index + 1, accumulated);
            }
        };

        xhr.ontimeout = function() {
            console.log("[CalDAVTasks] PROPFIND list timed out: " + calUrl);
            fetchAllTasks(calendars, index + 1, accumulated);
        };

        xhr.onerror = function() {
            console.log("[CalDAVTasks] PROPFIND list onerror: " + calUrl);
            fetchAllTasks(calendars, index + 1, accumulated);
        };

        xhr.send(body);
    }

    // Extract absolute .ics URLs from a PROPFIND Depth:1 multistatus response
    function parseIcsHrefs(xml, baseUrl) {
        var hrefs = [];
        var originMatch = baseUrl.match(/^(https?:\/\/[^\/]+)/i);
        var origin = originMatch ? originMatch[1] : "";

        var responses = xml.split(/<[^:>]+:response[\s>]/i);
        for (var i = 1; i < responses.length; i++) {
            var block = responses[i];
            var hrefMatch = block.match(/<[^:>]+:href[^>]*>([^<]+)<\/[^:>]+:href>/i);
            if (!hrefMatch) continue;
            var href = hrefMatch[1].trim();
            if (href.slice(-4).toLowerCase() !== ".ics") continue;
            if (href.indexOf("http") !== 0) href = origin + href;
            hrefs.push(href);
        }
        return hrefs;
    }

    // Step 2: GET each .ics file and parse the VTODO inside
    function fetchIcsFiles(hrefs, idx, cal, accumulated, calendars, calIndex) {
        if (idx >= hrefs.length) {
            fetchAllTasks(calendars, calIndex + 1, accumulated);
            return;
        }

        var icsUrl = hrefs[idx];
        var xhr = new XMLHttpRequest();
        xhr.open("GET", icsUrl, true);
        xhr.setRequestHeader("Authorization", authHeader());
        xhr.timeout = 15000;

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status >= 200 && xhr.status < 300) {
                var ical = xhr.responseText;
                if (/BEGIN:VTODO/i.test(ical)) {
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
                            href: icsUrl,
                            calUrl: cal.href,
                            ical: ical
                        });
                    }
                }
            } else {
                console.log("[CalDAVTasks] GET failed " + xhr.status + " for " + icsUrl);
            }
            fetchIcsFiles(hrefs, idx + 1, cal, accumulated, calendars, calIndex);
        };

        xhr.ontimeout = function() {
            console.log("[CalDAVTasks] GET timed out: " + icsUrl);
            fetchIcsFiles(hrefs, idx + 1, cal, accumulated, calendars, calIndex);
        };

        xhr.onerror = function() {
            console.log("[CalDAVTasks] GET onerror: " + icsUrl);
            fetchIcsFiles(hrefs, idx + 1, cal, accumulated, calendars, calIndex);
        };

        xhr.send(null);
    }

    // Extract a field value from iCal text
    function icalField(ical, fieldName) {
        // Handle folded lines (RFC 5545: continuation lines start with space/tab)
        var unfolded = ical.replace(/\r?\n[ \t]/g, "");
        var re = new RegExp("^" + fieldName + "(?:;[^:]*)?:(.*)$", "mi");
        var m = unfolded.match(re);
        return m ? m[1].trim() : "";
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
            var dueVal = newDueTrimmed.replace(/-/g, "");
            if (/^DUE[^:]*:/mi.test(unfolded)) {
                unfolded = unfolded.replace(/^DUE[^:]*:.*$/mi, "DUE;VALUE=DATE:" + dueVal);
            } else {
                unfolded = unfolded.replace(/^(END:VTODO)/mi, "DUE;VALUE=DATE:" + dueVal + "\n$1");
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
        return d + "/" + m + "/" + y;
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
        Layout.minimumHeight: Kirigami.Units.gridUnit * 20
        Layout.preferredWidth: Kirigami.Units.gridUnit * 22
        Layout.preferredHeight: Kirigami.Units.gridUnit * 28
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
            Layout.fillHeight: true
            visible: taskList.length > 0 && !loading && editingTask === null

            ListView {
                id: taskListView
                model: taskList.length
                spacing: 1
                clip: true

                delegate: Rectangle {
                    id: taskDelegate
                    width: taskListView.width
                    height: taskContent.implicitHeight + Kirigami.Units.smallSpacing * 2
                    color: index % 2 === 0 ? "transparent" : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.03)

                    readonly property var task: taskList[index]

                    RowLayout {
                        id: taskContent
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.smallSpacing

                        QQC2.CheckBox {
                            checked: task.completed
                            onToggled: toggleTaskComplete(task)
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
                                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                                }

                                QQC2.Label {
                                    text: task.summary
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    font.strikeout: task.completed
                                    opacity: task.completed ? 0.5 : 1.0
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.largeSpacing
                                visible: task.due !== "" || task.calendar !== ""

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

                                // Calendar name
                                QQC2.Label {
                                    text: task.calendar
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                    color: Kirigami.Theme.disabledTextColor
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    horizontalAlignment: Text.AlignRight
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
                                editDueField.text = t.due.length >= 8
                                    ? t.due.substring(0, 4) + "-" + t.due.substring(4, 6) + "-" + t.due.substring(6, 8)
                                    : "";
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
                    QQC2.TextField {
                        id: editDueField
                        placeholderText: "YYYY-MM-DD"
                        implicitWidth: Kirigami.Units.gridUnit * 8
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

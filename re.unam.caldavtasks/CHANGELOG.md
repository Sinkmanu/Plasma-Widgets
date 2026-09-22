# Changelog

## [1.5.0] - 2026-09-22

### Added
- **Radicale support**: the widget previously assumed Nextcloud's URL layout (`/calendars/<user>/<calendar>/`) and silently broke against servers with a different structure, such as Radicale (`/<user>/<calendar-id>/`), as reported on GitHub. Discovery, task fetching, and task editing now work against both.

### Changed
- Calendar discovery now follows the CalDAV `current-user-principal` and `calendar-home-set` properties, supporting servers whose calendar collections do not use Nextcloud's `/calendars/<user>/` path, including Radicale. The former Nextcloud path remains as a fallback for legacy server configurations.

### Fixed
- All DAV response parsing (`current-user-principal`, `calendar-home-set`, calendar listing, and task fetching) now accepts XML with or without a namespace prefix on tags. Radicale emits unprefixed elements (`xmlns="DAV:"` declared once on the root, e.g. `<href>` instead of `<d:href>`), which the previous prefix-only regexes never matched — causing discovery to silently fall back to the Nextcloud-style path and fail with 404 against Radicale.
- Task fetching now falls back to individual `GET` requests per resource when a plain `PROPFIND` returns resources but no `calendar-data` for any of them. Radicale strictly follows RFC 4791 and answers `calendar-data` requested via plain PROPFIND with 404 on that property (unlike Nextcloud's more lenient PROPFIND handling), so tasks created and stored correctly never showed up in the widget. A `REPORT calendar-query` would be the spec-correct fix, but QML's `XMLHttpRequest` doesn't reliably support the REPORT verb (this was also the original blocker with Nextcloud that led to the PROPFIND-based inline approach in 1.3.0), so the fallback goes back to per-item GET instead — same as the pre-1.3.0 behavior, but only for servers that need it. The single-PROPFIND path is left untouched as the primary attempt for servers that support inline calendar-data.
- Completing/editing a task now sends the resource's real `ETag` in the `If-Match` header instead of the `*` wildcard. Radicale returns 412 Precondition Failed for `If-Match: *` on an update (Nextcloud accepts it), so toggling completion or editing a task silently failed against Radicale. The ETag was already being requested via `d:getetag` but discarded; it's now captured and stored per task, with no extra requests needed.
- Sending the real `ETag` above caused a regression against Nextcloud, which then rejected the update with 412 instead. Both `toggleTaskComplete` and `updateTask` now retry the PUT once without `If-Match` if the server responds 412, so a mismatched/stale ETag on any server never permanently blocks an edit.

## [1.4.0] - 2026-08-26

### Added
- **Subtasks**: hovering a task now reveals a "+" button next to the edit pencil to add a subtask inline. Subtasks are linked to their parent via the standard iCalendar `RELATED-TO` property (RFC 5545), are created in the same calendar as their parent, and are displayed indented under it with a small marker. Servers/clients that don't understand `RELATED-TO` (most CalDAV servers just store it) will simply show them as regular flat tasks, so nothing breaks for unsupported setups.

## [1.3.0] - 2026-07-21

### Added
- **Due date picker with time in task edit panel**: editing a task now opens a small calendar popup to select due date, with optional time (HH:mm). The field can be cleared, and saves either date-only or date-time DUE values.

### Changed
- **Task fetch pipeline refactor**: removed per-task `.ics` GET requests. Task data is now requested inline via `PROPFIND Depth:1` with `cal:calendar-data`, reducing refresh traffic from `1 + N_calendars + N_tasks` requests to `1 + N_calendars` requests.

## [1.2.2] - 2026-06-01

### Fixed
- Tasks are now sorted consistently by due date (earliest first). Tasks without a due date are placed after dated tasks; ties fall back to newest creation timestamp and then title.

## [1.2.1] - 2026-05-18

### Added
- **Full task editing panel**: hovering over a task reveals a pencil button that opens a dedicated edit form to change the title, description, due date (YYYY-MM-DD), and priority (None / Medium / High).
- **Widget title inline editing**: clicking the heading in the popup header opens an in-place text field to rename the widget title; saved to configuration on Enter or focus loss.
- **Task description tooltip**: hovering over a task for 800 ms shows its `DESCRIPTION` field in a tooltip.
- **Pending task badge on panel icon**: the compact representation now overlays a small badge with the number of incomplete tasks.
- **Appearance settings**: new "Appearance" section in the Display configuration page with a font-size spinner (0 = system default) and a font-family text field applied to task summaries and priority labels.
- **Calendar auto-discovery in settings**: "Discover Calendars" button in the Display configuration page performs a live PROPFIND against the server and presents the found VTODO calendars as individual checkboxes, replacing the need to type names manually.

### Fixed
- `updateTask` now correctly updates `DTSTAMP` and `LAST-MODIFIED` on every PUT, satisfying RFC 5545 requirements.
- Toggling task completion also updates `DTSTAMP` and `LAST-MODIFIED` fields.

## [1.2.0] - 2026-04-24

### Added
- **Popup size adapts to content**: the popup width and height now grow dynamically based on the number of tasks, instead of using fixed dimensions. Minimum and maximum bounds are clamped to avoid overflowing the screen.
- **Live task filter**: a "Filter…" text field next to the new-task input lets you filter the task list in real time by summary, description, or calendar name. Press Escape or click × to clear.
- **Inline title editing**: clicking directly on a task's title text opens an in-place text field to rename it. Press Enter to save, Escape to cancel, or click away to confirm.
- **Calendar name moved inline**: the calendar/list name is now displayed on the same line as the task title (small, muted label) instead of on a separate row, keeping the layout compact and the checkbox aligned with the text.

## [1.1.0] - 2026-03-31

### Added
- Initial public release with CalDAV VTODO support, task creation, completion toggle, and priority/due-date display.

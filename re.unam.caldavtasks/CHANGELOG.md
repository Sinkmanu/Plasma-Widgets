# Changelog

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

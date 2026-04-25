# Changelog

## [1.2.0] - 2026-04-24

### Added
- **Popup size adapts to content**: the popup width and height now grow dynamically based on the number of tasks, instead of using fixed dimensions. Minimum and maximum bounds are clamped to avoid overflowing the screen.
- **Live task filter**: a "Filter…" text field next to the new-task input lets you filter the task list in real time by summary, description, or calendar name. Press Escape or click × to clear.
- **Inline title editing**: clicking directly on a task's title text opens an in-place text field to rename it. Press Enter to save, Escape to cancel, or click away to confirm.
- **Calendar name moved inline**: the calendar/list name is now displayed on the same line as the task title (small, muted label) instead of on a separate row, keeping the layout compact and the checkbox aligned with the text.

## [1.1.0] - 2026-03-31

### Added
- Initial public release with CalDAV VTODO support, task creation, completion toggle, and priority/due-date display.

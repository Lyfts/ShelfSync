# Changelog

## 0.2.6
- Fix reading progress sync sometimes failing to start (or getting stuck) when opening a book, which previously required closing and reopening the book to recover.

## 0.2.5
- Automatically mark a book as "read" on StoryGraph once progress reaches 100%, independent of KOReader's own end-of-book settings.

## 0.2.4
- Fix "Update by edition pages" not sticking/showing as selected when the linked StoryGraph edition has no page count — now falls back to percentage-based tracking with a note explaining why, instead of silently reverting the selection.
- Fix About dialog showing an outdated repo link.
- General code cleanup: removed dead code, unused requires, and unused functions.

## 0.2.3
- Fix "Update by progress" and "Update by edition pages" auto-sync options never triggering an update (only "Update periodically" worked before).

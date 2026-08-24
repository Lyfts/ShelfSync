# Changelog

## 0.2.8
- Fix progress sync sometimes going quiet for the rest of a reading session: if the book's read status couldn't be determined right after opening it (e.g. a stale session cookie briefly serving a logged-out page), the plugin now retries instead of assuming sync was successfully established.

## 0.2.7
- Fix a crash at the end of some books when "Update by edition pages" is enabled, caused by a page mapping calculation returning an incomplete value once the reader passed the last page covered by the book's page map.
- Show a clear message instead of doing nothing when manually updating progress (e.g. via gesture) can't go through — for example when the book has already been marked "read" on StoryGraph.

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

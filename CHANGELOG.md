# Changelog

## 0.3.3
- Fix reading progress/status not being detected at all for some books: KOReader's bundled HTML parser was silently failing on the current StoryGraph page markup, making a book's real "Currently Reading" status and progress unreadable to the plugin even though it was correctly set on the website. This could also make a freshly-linked book appear to never have been marked as Currently Reading, triggering an incorrect "not marked as reading" warning right after linking.

## 0.3.2
- Add an optional "Sync immediately when opening a book" setting (off by default) that tries to push progress right when a book opens instead of waiting for the first page turn or tracking interval, while still respecting the usual "don't go backwards past StoryGraph's progress" guard.
- Fixed a dormant bug where the "no baseline yet this session" leading-edge sync never actually triggered on the first page turn.
- Give a book's status fetch a couple of retries before treating it as having no status, so a one-off parse hiccup on a normal "Currently Reading" book can't trigger the "not marked as reading" warning by mistake.

## 0.3.1
- Fix the "not marked as Currently Reading" warning from 0.3.0 never actually appearing for a book with no status on StoryGraph (e.g. removed from your shelves) — a retry safeguard from 0.2.8 was unintentionally blocking the exact code path the warning depends on.

## 0.3.0
- Warn when a book's progress can't sync because its status on StoryGraph isn't "Currently Reading" (e.g. it was changed to Paused/DNF/etc. directly on the site while still being read in KOReader) — previously this failed silently. The warning offers a one-tap way to mark the book as Currently Reading again.

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

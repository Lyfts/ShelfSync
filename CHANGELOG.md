# Changelog

## 1.1.2
##### Plugin
- Fixed Goodreads automatic and manual book linking silently finding no matches while logged in.
- Fixed Goodreads syncing the wrong reading percentage when tracking by percentage rather than edition pages. Goodreads now sends the percentage directly instead of converting it to a page number first.
- Fixed the reader freezing with no way to cancel while manually linking a book (or re-searching from within that dialog), for all three services.

##### Scripts
- Fixed the cookie-fetching script crashing (and writing nothing) when adding a service to a `shelfsync_config.lua` that didn't already have a section for it, e.g. filling in Goodreads cookies into a config that so far only had StoryGraph set up.
- The cookie-fetching script's `--browser auto` mode now keeps whichever browser's copy of a cookie has the furthest-out expiry when the same cookie is found in more than one browser, instead of an arbitrary one.

## 1.1.1
##### Scripts
- Add cross-platform scripts (`fetch-cookies.sh`/`fetch-cookies.bat`, packaged in their own release zip) that grab your StoryGraph/Goodreads session cookies straight from a locally logged-in browser and write them into `shelfsync_config.lua`, as an alternative to copying them out of devtools by hand — see the README's Installation section.

## 1.1.0
- Add Goodreads sync support alongside StoryGraph and Hardcover, using the same session-cookie based approach as StoryGraph since Goodreads has no official API for this either — see the README for setup instructions. Goodreads has a couple of inherent limitations compared to the other two services: its website doesn't expose a way to read back your current page position, so "Jump to linked book position" isn't available and background sync always pushes progress forward instead of detecting when local progress is behind; Paused/Did Not Finish statuses can be set but aren't reliably read back either.
- When multiple services are linked for the same book, prefer Hardcover's page count for progress tracking over StoryGraph's or Goodreads', since it's the most precise (edition-level, first-party); Goodreads' is scraped and not always available, so it's now used only as a last resort.
- Automatically link by ISBN/Title is now enabled by default for all services (previously off).

## 1.0.3
- Add a "Paused" status option to the Hardcover menu, matching StoryGraph's, now that Hardcover supports it too.

## 1.0.2
- The StoryGraph and Hardcover menus are now combined into a single **ShelfSync** menu, with **StoryGraph** and **Hardcover** as sub-menus and shared plugin-wide settings (previously tucked under the StoryGraph menu's Settings) moved to a new **Common settings** sub-menu.
- Progress tracking settings, "Enable wifi on demand", "Confirm changes to book read status", "Compatibility mode", "Include location info in regular notes", and "Verbose logging" are now combined across StoryGraph and Hardcover instead of being configured separately for each — they've moved to **ShelfSync > Common settings** and apply to both services. Linking and account settings remain per-service. Existing values aren't migrated; each of these settings falls back to its default until re-set once under Common settings.
- Renamed "Jump to StoryGraph/Hardcover position" to "Jump to linked book position" in both menus for consistency.
- The top-level ShelfSync menu now has its own **About** entry with ShelfSync branding, replacing the separate About entry that used to live under each service's own sub-menu.
- Fixed the ShelfSync menu item showing up under the Documents tab instead of Tools > More tools.
- Fixed newly linked books not being automatically marked "Currently Reading" on Hardcover the way they already were on StoryGraph — linking a book with no existing status on your Hardcover shelves now adds it as Currently Reading right away, instead of silently staying unmarked (and unsynced) until a much later retry happened to catch it.
- Fixed a crash when manually linking a Hardcover book whose edition has a publisher set, caused by the publisher field being passed through as a raw object instead of its name.
- Fixed a race between the StoryGraph and Hardcover engines when a book was opened with wifi off: whichever engine's automatic wifi restore kicked off first could cause the other engine's sync to silently die instead of proceeding once the connection came up.
- Retry once on a failed network subprocess (seen on some devices as requests silently not completing) before giving up, for both StoryGraph and Hardcover.

## 1.0.1
- StoryGraph and Hardcover now share a single `shelfsync_config.lua` file (replacing the separate `storygraph_config.lua`/`hardcover_config.lua`), with independent, optional sections per service — see the README. Existing installs are migrated automatically.

## 1.0.0
- Renamed the project to ShelfSync (from storygraph.koplugin) now that it syncs to both StoryGraph and Hardcover — the plugin folder, internal require paths, and update-check/repo URLs all moved accordingly. No functional changes; existing settings and linked books are unaffected.

## 0.4.0
- Add Hardcover sync support alongside StoryGraph, so both services can be linked and tracked independently from the same install instead of needing two near-identical plugins. See the README for setup instructions.
- The StoryGraph and Hardcover sync logic now share a common engine internally; behavior and settings for each service remain independent, but "Plugin Updates" settings (mandatory update checks) are shared plugin-wide and only shown under the StoryGraph menu.

## 0.3.5
- The auto-mark-as-Currently-Reading write (added in 0.3.4) now retries a couple of times if it fails, instead of giving up permanently after a single transient failure.
- Expand the "Verbose logging" diagnostics (added in 0.3.4) to cover several more places that were previously silent on failure: the actual progress-update write, automatic wifi enabling, sync retry/reschedule points, the status-mismatch warning's fire/skip decision, and the autolink matching flow.

## 0.3.4
- An already-linked book with no status on StoryGraph now also gets automatically marked as "Currently Reading" (after a couple of retries in case it's just a momentary hiccup), instead of only ever being caught by the status-mismatch warning.
- Add a "Verbose logging" setting (off by default) for extra diagnostic detail when troubleshooting sync issues, instead of it always being on.

## 0.3.3.2
- Fix a newly linked book sometimes never actually getting marked as "Currently Reading" on StoryGraph, with no indication anything had gone wrong — the book stayed linked locally, but progress silently never synced until the status-mismatch warning eventually caught it. That auto-add step now surfaces a clear warning if it fails, instead of failing silently.

## 0.3.3
- Fix reading progress/status not being detected for some books when the page's HTML happened to be structured in a way KOReader's bundled HTML parser failed to read correctly, even though the status was set correctly on the website.

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

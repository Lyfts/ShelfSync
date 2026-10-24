# ShelfSync for KOReader

[![Latest release](https://img.shields.io/github/v/release/Lyfts/ShelfSync?style=for-the-badge&color=orange)](https://github.com/Lyfts/ShelfSync/releases/latest) [![Total downloads](https://img.shields.io/github/downloads/Lyfts/ShelfSync/total?style=for-the-badge&color=blue)](https://github.com/Lyfts/ShelfSync/releases) [![Platform](https://img.shields.io/badge/Platform-KOReader-success?style=for-the-badge&logo=koreader)](https://github.com/koreader/koreader) [![License](https://img.shields.io/github/license/Lyfts/ShelfSync?style=for-the-badge)](LICENSE)

A KOReader plugin to synchronize your reading progress, notes, and status to [The StoryGraph](https://thestorygraph.com), [Hardcover](https://hardcover.app), [Goodreads](https://goodreads.com), [Fable](https://fable.co), [Pagebound](https://pagebound.co), and/or [LibraryThing](https://www.librarything.com). All services can be linked and tracked independently, side by side, from the same install.

> [!CAUTION]
> **Disclaimer**: StoryGraph, Goodreads, and LibraryThing sync use unofficial APIs based on session cookies. Hardcover, Fable, and Pagebound sync use their services' official APIs; Pagebound uses the same API as its website. Any integration may break if a service changes its website or API.

> [!NOTE]
> **Goodreads limitations**: Goodreads' website doesn't expose a way to read back your current page position, only your shelf (status), so "Jump to linked book position" isn't available and background sync can't detect when your local progress is behind what's on Goodreads — it always pushes forward. Paused/Did Not Finish statuses can be set but aren't reliably read back either. Posting reviews/ratings isn't supported yet.

> [!NOTE]
> **LibraryThing limitations**: LibraryThing doesn't track reading progress, so nothing is sent while you read. ShelfSync syncs the book's status instead: Currently reading and To read are LibraryThing collections, and a book is Read once its latest reading date has a finished date. Re-reading a book adds new reading dates, keeping the earlier ones. Finishing a book in KOReader sets the finished date and moves it from Currently reading to the collection chosen under **LibraryThing > Read books go to** (Your library by default; any of your collections, including your own, e.g. Read but unowned for borrowed books). A book in that collection also counts as Read, unless it's Your library. There's no Paused or Did Not Finish, and no notes. librarything.com is behind Cloudflare, which can answer requests with a browser check that ShelfSync can't complete; when that happens, syncing fails until Cloudflare lets it through again.

## Installation

1. Download the latest release and extract it to your KOReader `plugins/` folder.
2. Set up authentication for whichever service(s) you want to use — all are optional and independent.

Rename `shelfsync_config.example.lua` to `shelfsync_config.lua`. Its `storygraph`, `hardcover`, and `goodreads` sections are optional; leave unused sections blank or omit the file. Sign in to StoryGraph and LibraryThing from KOReader with your account credentials. Fable and Pagebound can also be set up there.

> [!TIP]
> The StoryGraph, Goodreads, and LibraryThing cookies below can be grabbed automatically instead of copying them out of devtools by hand:
>
> 1. Log in to StoryGraph, Goodreads, and/or LibraryThing in a browser on this PC — the script only reads cookies that already exist, it can't log in for you.
> 2. Download `shelfsync-fetch-cookies.zip` from the [latest release](/releases/latest), extract it, and run `fetch-cookies.sh` (macOS/Linux) or `fetch-cookies.bat` (Windows). Needs Python 3; it'll use [uv](https://docs.astral.sh/uv/) if you have it to grab `browser_cookie3` automatically, otherwise `pip install browser_cookie3==0.20.1` first.
> 3. It writes the cookies straight into `shelfsync_config.lua` — nothing is sent anywhere else. Use `--help` for options like `--browser firefox`.
>
> Hardcover supports OAuth device-code sign-in from the KOReader menu. Its API token can still be configured as a fallback (see below).

### Authentication overview

| Provider | Authentication |
| --- | --- |
| [StoryGraph](#storygraph-authentication) | Email and password in KOReader; browser cookies can be imported if login is blocked |
| [Hardcover](#hardcover-authentication) | OAuth device sign-in, with an API token as a fallback |
| [Goodreads](#goodreads-authentication) | Browser session cookie, or the optional self-hosted cookie refresher |
| [Fable](#fable-authentication) | Email and password in KOReader |
| [Pagebound](#pagebound-authentication) | Email and password in KOReader |
| [LibraryThing](#librarything-authentication) | Username/password sign-in, or browser session cookies |

### StoryGraph authentication
Open **ShelfSync > Providers > StoryGraph > Account (Cookies & Tokens) > Log in** and enter your StoryGraph email and password. The plugin saves the session and remember-me cookies returned by StoryGraph; it does not store your password. Log in again if your session expires.

If Cloudflare blocks login on your device, import browser cookies using the helper above or these manual steps:

1. Log in to [thestorygraph.com](https://thestorygraph.com) in your browser.
2. Open your browser's Developer Tools (F12) -> Application/Storage -> Cookies.
3. Copy the value of the `_storygraph_session` cookie and paste it into the `session_cookie` field of the `storygraph` section in `shelfsync_config.lua`.
4. Copy the value of the `remember_user_token` cookie and paste it into the `remember_user_token` field of the `storygraph` section in `shelfsync_config.lua`.

### Hardcover authentication
Open **ShelfSync > Providers > Hardcover > Account (OAuth / API Token) > Sign in with Hardcover (OAuth)** and follow the device-code instructions. When signed in, ShelfSync uses OAuth; it refreshes the session automatically and falls back to an API token only when OAuth is signed out or its session is rejected.

API-token authentication remains available as a fallback:
1. Go to [hardcover.app/account/api](https://hardcover.app/account/api) in your browser and copy your API token.
2. Paste it into the `token` field of the `hardcover` section in `shelfsync_config.lua`, or open **Hardcover > Account (OAuth / API Token) > Hardcover API Token fallback** in KOReader.

### Goodreads authentication
Goodreads accounts are linked through Amazon, so a valid session is a bundle of cookies rather than one or two named values, and it can go stale periodically from an AWS WAF bot-challenge on Goodreads' side.

[`goodreads-cookie-refresher`](https://github.com/Lyfts/goodreads-cookie-refresher) is an optional self-hosted Docker setup that handles both of those for you: it keeps a real logged-in browser session alive on your network and hands the plugin fresh cookies automatically, covering initial setup (leave the cookie field below blank) as well as every future refresh, so you never have to do the manual steps below at all.

Without that setup, grab a cookie by hand instead. Rather than copying each one individually from the cookie storage view, grab the browser's pre-assembled `Cookie` request header instead — it's the exact same cookies, already joined into the one string this plugin needs.
1. Log in to [goodreads.com](https://goodreads.com) in your browser.
2. Open Developer Tools (F12) -> Network tab, then reload the page.
3. Click any request to `www.goodreads.com`, open its **Headers** panel, and find the `Cookie` row under **Request Headers** (not Storage/Application -> Cookies, and not `Set-Cookie` under Response Headers — this is a specific request's outgoing header). If it isn't shown, look for a "raw headers" toggle.
4. Right-click it -> Copy Value, and paste the whole thing into the `cookie` field of the `goodreads` section in `shelfsync_config.lua`.
   - Alternatively, you can paste it directly into the **Goodreads** menu's **Settings > Account (Cookie)** field from within KOReader instead of editing the config file.

Without the Docker refresher, this cookie will go stale again periodically — when that happens, syncing pauses until you repeat the steps above.

### Fable authentication
Unlike the other services, Fable has a real login API, so the plugin logs in directly with your Fable email and password rather than a cookie/token you have to fetch by hand.

1. In KOReader, open **Fable** menu -> **Account** -> **Log in**, and enter your Fable email and password.
2. ShelfSync caches your password on the device so it can silently sign in again if the refresh token stops working. The password is encrypted at rest when `libcrypto` is available; otherwise, it is stored in plaintext. Your access/refresh tokens refresh automatically, and **Log out** clears the cached password and tokens.

> [!TIP]
> If you signed up to Fable with **Google or Apple**, there's no password to log in with here. Convert the account to a regular email/password account first: in the Fable app, go to **Account settings** and set/add a password for your account. Once that's done, log in above using that email and password like any other account.

### Pagebound authentication
Open **ShelfSync > Providers > Pagebound > Account > Log in** and enter your Pagebound email and password. The plugin signs in through Firebase, exchanges that session for a Pagebound API token, and refreshes the token automatically. It caches your password on the device, encrypted at rest where available, so it can recover if the refresh token stops working. Use **Log out** to clear the credentials cached by ShelfSync.

> [!TIP]
> If you usually sign in to Pagebound with **Google or Apple**, reset the password for the email address on your account through Pagebound. You can then log in with that email and password; ShelfSync uses this regular email/password account.

### LibraryThing authentication
To connect, open **ShelfSync > Providers > LibraryThing > Account > Sign in with LibraryThing** and enter your username and password. ShelfSync saves your session and password so it can sign you back in if the session expires. It encrypts the saved password when your device supports it; otherwise, it is stored unencrypted. **Log out** clears both.

The sign-in method is unofficial and may change. Your password is sent in the sign-in web address over HTTPS, and that address may be recorded in logs.

If you prefer not to enter your password in ShelfSync, use browser cookies instead:

1. Sign in to [librarything.com](https://www.librarything.com) in a browser on your computer.
2. Run the cookie helper above with `--service librarything` (`fetch-cookies.sh --service librarything` or `fetch-cookies.bat --service librarything`). It writes only those three cookies into the `librarything` section of `shelfsync_config.lua`; copy that file into the plugin's folder on your e-reader. This avoids typing them on an e-reader keyboard.
   - Or copy them by hand: Developer Tools (F12) -> Application/Storage -> Cookies -> `www.librarything.com`, then enter `cookie_userid=...; cookie_usernum=...; cookie_userchecksum=...` under **ShelfSync > Providers > LibraryThing > Account > Session cookies**, or into the `cookie` field of the `librarything` section in `shelfsync_config.lua`.
3. Use **Account > Test connection** to check that it works. **Log out** clears the session from ShelfSync.

Linking a book that isn't in your LibraryThing library adds it to **Your library** and **Currently reading**, using the edition LibraryThing picks for the work.

A book that no LibraryThing member has added yet has no work on LibraryThing to link to. When **Link book** finds none, it searches a book source instead, as LibraryThing's **Add books** page does, and picking an edition adds it to your library, which creates the work. Choose the source under **LibraryThing > Books not on LibraryThing**: Amazon.com by default, or e.g. the **Vlaamse Centrale Catalogus** for Dutch-language books. Linking on its own (by ISBN or title) never adds a book from a source.

## Usage

Everything lives under a single **ShelfSync** menu in **Tools > More tools** when a document is active, with a **Providers** sub-menu containing **StoryGraph**, **Hardcover**, **Goodreads**, **Fable**, **Pagebound**, and **LibraryThing**. They work independently and can be used together.

### Updating Progress & Notes
Each menu provides a unified **"Update progress: [XX]%"** item. This opens a powerful dialog where you can:
- **Set Progress**: Tap the progress button to open a native picker showing both your **KOReader** and remote synced percentages.
- **Add a Note**: Write your thoughts in the note field. Pagebound posts it to the book's forum, where other users may see it; the post title includes the selected percentage and page position.
- **Location Context**: By default, notes sent via the highlight menu automatically include your current **Chapter, Page, and Percentage**. You can enable this for regular notes in the settings.

### Linking a Book
Before updates can be sent, a document needs to be linked to a book on each service you want to sync to.
- Use **"Link book"** to search by metadata or ISBN. The plugin automatically tries to link the correct edition (e.g. by matching ISBN) — "Change edition" and the other settings below are mostly for changing which specific edition ends up linked, when you want something other than what was auto-selected.
- Use **"Change edition"** to switch to a different edition (StoryGraph) or select a specific edition (Hardcover). Goodreads, Fable, Pagebound, and LibraryThing have no edition-switching concept, so they have no "Change edition" item — linking picks whichever book the search returns.
- Audio editions are filtered out of the search results (StoryGraph, Hardcover).
- If a book is not currently tracked, the plugin will set its status to Currently Reading.
- On StoryGraph, if another edition of the book is set as 'Currently Reading' or 'Want to Read' then the plugin will automatically link to that edition, but not change the status. You can use "Change edition" to link to a different edition if needed.

### Reviews
With a book open, choose **ShelfSync > Review** to open the review composer. Add a rating, review text, or both, then choose which providers should receive it. Enabled providers where you are signed in and the book is linked are selected by default; unavailable providers show why they cannot receive the review. If submission fails for a provider, the draft stays available so you can retry it.

Ratings range from 0 to 5 in quarter-star steps. Hardcover, LibraryThing, and Pagebound round down to half stars; StoryGraph, Fable, and Goodreads preserve quarter-star ratings. When ShelfSync detects that you finished a book, it offers to open the composer if at least one provider is eligible.

### Automatically Track Progress
When enabled (per service), the plugin will periodically sync your progress:
- Updates are sent when paging, no more than once per minute (configurable).
- When reaching the end of the document, the book is automatically marked as "Read"/"Finished".
- If progress can't be sent for lack of a network (e.g. Wi-Fi is off), the book's latest progress is kept for up to 4 weeks and sent once the network is back, even after the book is closed. A finished status set by KOReader (e.g. by its end-of-book action) that can't be sent, for lack of a network or because the service rejects it, is also kept and retried the same way. If Goodreads accepts it, but the date it was finished can't be set, the date is tried up to 3 times while online, at least an hour apart, before it's given up on. A status chosen in ShelfSync's menus isn't kept for later. Progress isn't sent if the service has the book further along, or not as Currently Reading. Goodreads and Fable don't expose your progress to check against, so there it's only sent within a day, to avoid overwriting newer progress from another device.
- Progress can be synced automatically based on time duration, percentage read or pages read (based on edition page count).
- Hardcover only stores progress as a page number; if a tracking mode produces a percentage instead (e.g. no page count is known for the linked edition), it's converted to a page number automatically before syncing.

### Update Progress with a Gesture
KOReader's gesture manager includes a **ShelfSync: Update progress for all linked books** action in the **General** category. Assign it to any gesture to immediately push the open book's current progress to every provider it is linked to, without waiting for the configured time, percentage, or page interval. Gesture-triggered updates show the provider being synced and whether the update succeeded or failed; automatic interval updates remain silent. Provider authentication, enablement, and per-book tracking settings still apply.

## Settings

Each service has its own **Settings** submenu for linking and account options:
- **Automatically link by provider identifier/ISBN/Title**: Attempt to find matching books automatically when opening a new document, in that priority order — a provider identifier embedded in the book's metadata first, then ISBN, then title+author. Each method can be toggled independently, and all are enabled by default; disable any of them here if you'd rather link books manually. Identifier-based linking is supported for Goodreads (`goodreads:` tag), Hardcover (`hardcover:`/`hardcover-slug:`/`hardcover-edition:` tags), StoryGraph (`storygraph:`/`storygraph-edition:` tags), and LibraryThing (`librarything:` tag with a work id). Fable and Pagebound currently don't expose matching identifier schemes.
- **Never link automatically**: File types (e.g. `cbz, cbr` for manga and comics) that are never linked automatically, by any of the methods above. They can still be linked by hand with "Link book".
- **Account**: Cookies/tokens/login for that service.

Everything else — progress tracking settings, "Enable wifi on demand", "Confirm changes to book read status", "Include location info in regular notes", "Verbose logging", and the **"Plugin Updates"** settings (see below) — is shared between all services and lives under **ShelfSync > Settings**, since it applies to the whole plugin rather than one service:
- **Include location info in regular notes**: Automatically append Chapter, Page, and % info to your regular notes.
- **Enable wifi on demand**: Briefly enable wifi for background syncs to preserve battery life.
- **Confirm changes to book read status**: Prompt for confirmation before changing or removing a book's status from a service's **Update status** menu (e.g., Want to Read -> Read). Enabled by default; turn it off to apply status changes with a single tap.

## Versioning & Mandatory Updates

To prevent data corruption and ensure compatibility with the providers' APIs, the plugin includes a remote versioning system. This applies to the plugin as a whole (StoryGraph, Hardcover, Goodreads, Fable, Pagebound, and LibraryThing sync).

- **Automatic Checks**: The plugin periodically checks for mandatory updates via GitHub. If the StoryGraph API changes in a way that breaks older versions, the plugin will automatically disable sync to prevent errors.
- **Blocking**: When a mandatory update is required, the plugin menus will be greyed out.
- **Configurable Frequency**: Use the **"Version check frequency"** slider to choose how often the plugin checks for updates (from 1 to 30 days). Default is 1 day.
- **Manual Override**: You can enable **"Ignore version blocks"** to bypass mandatory update requirements. Use this with caution as older versions may break sync if the StoryGraph API changes.
- **Silent Mode**: Disable **"Show version alert dialog"** if you prefer the plugin to silently stop working when an update is required, rather than showing a notification.

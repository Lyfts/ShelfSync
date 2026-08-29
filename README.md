# ShelfSync for KOReader

A KOReader plugin to synchronize your reading progress, notes, and status to [The StoryGraph](https://thestorygraph.com), [Hardcover](https://hardcover.app), [Goodreads](https://goodreads.com), and/or [Fable](https://fable.co). All services can be linked and tracked independently, side by side, from the same install.

> [!CAUTION]
> **Disclaimer**: StoryGraph and Goodreads sync both use unofficial APIs based on session cookies. Because of this, they are inherently brittle and may break if either service updates their website or cookie structure. If sync stops working, please ensure you are using the latest version of the plugin and try re-fetching your session cookie(s). Hardcover and Fable sync use their services' official APIs and do not have this issue.

> [!NOTE]
> **Goodreads limitations**: Goodreads' website doesn't expose a way to read back your current page position, only your shelf (status), so "Jump to linked book position" isn't available and background sync can't detect when your local progress is behind what's on Goodreads — it always pushes forward. Paused/Did Not Finish statuses can be set but aren't reliably read back either. Posting reviews/ratings isn't supported yet.

## Installation

1. Download the latest release and extract it to your KOReader `plugins/` folder.
2. Set up authentication for whichever service(s) you want to use — all are optional and independent.

StoryGraph, Hardcover, and Goodreads share a single config file: rename `shelfsync_config.example.lua` to `shelfsync_config.lua`, then fill in whichever section(s) below you want — the `storygraph`, `hardcover`, and `goodreads` sections are all optional and independent, and leaving one blank (or the whole file missing) doesn't affect the others. Fable has no config file section — it's set up entirely from within KOReader (see below).
- *Note: If you are upgrading from an older version, the plugin will automatically merge an existing `storygraph_config.lua` and/or `hardcover_config.lua` into `shelfsync_config.lua`.*

> [!TIP]
> The StoryGraph and Goodreads cookies below can be grabbed automatically instead of copying them out of devtools by hand:
>
> 1. Log in to StoryGraph and/or Goodreads in a browser on this PC — the script only reads cookies that already exist, it can't log in for you.
> 2. Download `shelfsync-fetch-cookies.zip` from the [latest release](/releases/latest), extract it, and run `fetch-cookies.sh` (macOS/Linux) or `fetch-cookies.bat` (Windows). Needs Python 3; it'll use [uv](https://docs.astral.sh/uv/) if you have it to grab `browser_cookie3` automatically, otherwise `pip install browser_cookie3` first.
> 3. It writes the cookies straight into `shelfsync_config.lua` — nothing is sent anywhere else. Use `--help` for options like `--browser firefox`.
>
> Hardcover isn't cookie-based, so its token still needs to be pasted in by hand (see below).

### StoryGraph authentication
1. Log in to [thestorygraph.com](https://thestorygraph.com) in your browser.
2. Open your browser's Developer Tools (F12) -> Application/Storage -> Cookies.
3. Copy the value of the `_storygraph_session` cookie and paste it into the `session_cookie` field of the `storygraph` section in `shelfsync_config.lua`.
4. Copy the value of the `remember_user_token` cookie and paste it into the `remember_user_token` field of the `storygraph` section in `shelfsync_config.lua`.

### Hardcover authentication
1. Go to [hardcover.app/account/api](https://hardcover.app/account/api) in your browser and copy your API token.
2. Paste it into the `token` field of the `hardcover` section in `shelfsync_config.lua`.
   - Alternatively, you can paste the token directly into the **Hardcover** menu's **Settings > Account (API Token)** field from within KOReader instead of editing the config file.

### Goodreads authentication
Goodreads accounts are linked through Amazon, so a valid session is a bundle of cookies rather than one or two named values, and it can go stale periodically from an AWS WAF bot-challenge on Goodreads' side.

[`goodreads-cookie-refresher`](https://github.com/Lyfts/goodreads-cookie-refresher) is an optional self-hosted Docker setup that handles both of those for you: it keeps a real logged-in browser session alive on your network and hands the plugin fresh cookies automatically, covering initial setup (leave the cookie field below blank) as well as every future refresh, so you never have to do the manual steps below at all.

Without that setup, grab a cookie by hand instead. Rather than copying each one individually from the cookie storage view, grab the browser's pre-assembled `Cookie` request header instead — it's the exact same cookies, already joined into the one string this plugin needs.
1. Log in to [goodreads.com](https://goodreads.com) in your browser.
2. Open Developer Tools (F12) -> Network tab, then reload the page.
3. Click any request to `www.goodreads.com`, open its **Headers** panel, and find the `Cookie` row under **Request Headers** (not Storage/Application -> Cookies, and not `Set-Cookie` under Response Headers — this is a specific request's outgoing header). If it isn't shown, look for a "raw headers" toggle.
4. Right-click it -> Copy Value, and paste the whole thing into the `cookie` field of the `goodreads` section in `shelfsync_config.lua`.
   - Alternatively, you can paste it directly into the **Goodreads** menu's **Settings > Account (Cookie)** field from within KOReader instead of editing the config file.

This cookie will go stale again periodically unless you set up the Docker refresher above — when that happens, syncing pauses until you repeat the steps above.

### Fable authentication
Unlike the other services, Fable has a real login API, so the plugin logs in directly with your Fable email and password rather than a cookie/token you have to fetch by hand.

1. In KOReader, open **Fable** menu -> **Account** -> **Log in**, and enter your Fable email and password.
2. Your password itself is never stored — only the access/refresh token pair Fable's own login returns, the same thing its official app keeps. That pair refreshes itself automatically from then on; if it's ever revoked (e.g. after changing your password), just log in again the same way.

> [!TIP]
> If you signed up to Fable with **Google or Apple**, there's no password to log in with here. Convert the account to a regular email/password account first: in the Fable app, go to **Account settings** and set/add a password for your account. Once that's done, log in above using that email and password like any other account.

## Usage

Everything lives under a single **ShelfSync** menu in **Tools > More tools** when a document is active, with a **Providers** sub-menu containing **StoryGraph**, **Hardcover**, **Goodreads**, and **Fable**. They work the same way and can be used together or independently.

### Updating Progress & Notes
Each menu provides a unified **"Update progress: [XX]%"** item. This opens a powerful dialog where you can:
- **Set Progress**: Tap the progress button to open a native picker showing both your **KOReader** and remote synced percentages.
- **Add a Note**: Write your thoughts directly in the note field.
- **Location Context**: By default, notes sent via the highlight menu automatically include your current **Chapter, Page, and Percentage**. You can enable this for regular notes in the settings.

### Linking a Book
Before updates can be sent, a document needs to be linked to a book on each service you want to sync to.
- Use **"Link book"** to search by metadata or ISBN. The plugin automatically tries to link the correct edition (e.g. by matching ISBN) — "Change edition" and the other settings below are mostly for changing which specific edition ends up linked, when you want something other than what was auto-selected.
- Use **"Change edition"** to switch to a different edition (StoryGraph) or select a specific edition (Hardcover). Goodreads and Fable have no edition-switching concept, so they have no "Change edition" item — linking picks whichever edition the search returns.
- Audio editions are filtered out of the search results (StoryGraph, Hardcover).
- If a book is not currently tracked, the plugin will set its status to Currently Reading.
- On StoryGraph, if another edition of the book is set as 'Currently Reading' or 'Want to Read' then the plugin will automatically link to that edition, but not change the status. You can use "Change edition" to link to a different edition if needed.

### Automatically Track Progress
When enabled (per service), the plugin will periodically sync your progress:
- Updates are sent when paging, no more than once per minute (configurable).
- When reaching the end of the document, the book is automatically marked as "Read"/"Finished".
- Progress can be synced automatically based on time duration, percentage read or pages read (based on edition page count).
- Hardcover only stores progress as a page number; if a tracking mode produces a percentage instead (e.g. no page count is known for the linked edition), it's converted to a page number automatically before syncing.

## Settings

Each service has its own **Settings** submenu for linking and account options:
- **Automatically link by provider identifier/ISBN/Title**: Attempt to find matching books automatically when opening a new document, in that priority order — a provider identifier embedded in the book's metadata first, then ISBN, then title+author. Each method can be toggled independently, and all are enabled by default; disable any of them here if you'd rather link books manually. Identifier-based linking is supported for Goodreads (`goodreads:` tag), Hardcover (`hardcover:`/`hardcover-slug:`/`hardcover-edition:` tags), and StoryGraph (`storygraph:`/`storygraph-edition:` tags); Fable currently doesn't expose a matching identifier scheme, so that method has no effect there yet.
- **Account**: Cookies/tokens/login for that service.

Everything else — progress tracking settings, "Enable wifi on demand", "Confirm changes to book read status", "Include location info in regular notes", "Verbose logging", and the **"Plugin Updates"** settings (see below) — is shared between all services and lives under **ShelfSync > Settings**, since it applies to the whole plugin rather than one service:
- **Include location info in regular notes**: Automatically append Chapter, Page, and % info to your regular notes.
- **Enable wifi on demand**: Briefly enable wifi for background syncs to preserve battery life.
- **Confirm changes to book read status**: Prompt for confirmation before changing a book's status (e.g., Want to Read -> Read).

## Versioning & Mandatory Updates

To prevent data corruption and ensure compatibility with StoryGraph's and Goodreads' unofficial APIs, the plugin includes a remote versioning system. This applies to the plugin as a whole (StoryGraph, Hardcover, Goodreads, and Fable sync).

- **Automatic Checks**: The plugin periodically checks for mandatory updates via GitHub. If the StoryGraph API changes in a way that breaks older versions, the plugin will automatically disable sync to prevent errors.
- **Blocking**: When a mandatory update is required, the plugin menus will be greyed out.
- **Configurable Frequency**: Use the **"Version check frequency"** slider to choose how often the plugin checks for updates (from 1 to 20 days). Default is 1 day.
- **Manual Override**: You can enable **"Ignore version blocks"** to bypass mandatory update requirements. Use this with caution as older versions may break sync if the StoryGraph API changes.
- **Silent Mode**: Disable **"Show version alert dialog"** if you prefer the plugin to silently stop working when an update is required, rather than showing a notification.

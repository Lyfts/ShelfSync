# ShelfSync for KOReader

[![Latest release](https://img.shields.io/github/v/release/Lyfts/ShelfSync?style=for-the-badge&color=orange)](https://github.com/Lyfts/ShelfSync/releases/latest) [![Total downloads](https://img.shields.io/github/downloads/Lyfts/ShelfSync/total?style=for-the-badge&color=blue)](https://github.com/Lyfts/ShelfSync/releases) [![Platform](https://img.shields.io/badge/Platform-KOReader-success?style=for-the-badge&logo=koreader)](https://github.com/koreader/koreader) [![License](https://img.shields.io/github/license/Lyfts/ShelfSync?style=for-the-badge)](LICENSE)

A KOReader plugin to synchronize your reading progress, notes, and status to [The StoryGraph](https://thestorygraph.com), [Hardcover](https://hardcover.app), [Goodreads](https://goodreads.com), [Fable](https://fable.co), and/or [Pagebound](https://pagebound.co). All services can be linked and tracked independently, side by side, from the same install.

> [!CAUTION]
> **Disclaimer**: StoryGraph and Goodreads sync use unofficial APIs based on session cookies. Hardcover, Fable, and Pagebound sync use their services' official APIs; Pagebound uses the same API as its website. Any integration may break if a service changes its website or API.

> [!NOTE]
> **Goodreads limitations**: Goodreads' website doesn't expose a way to read back your current page position, only your shelf (status), so "Jump to linked book position" isn't available and background sync can't detect when your local progress is behind what's on Goodreads — it always pushes forward. Paused/Did Not Finish statuses can be set but aren't reliably read back either. Posting reviews/ratings isn't supported yet.

## Installation

1. Download the latest release and extract it to your KOReader `plugins/` folder.
2. Set up authentication for whichever service(s) you want to use — all are optional and independent.

Rename `shelfsync_config.example.lua` to `shelfsync_config.lua`. Its `storygraph`, `hardcover`, and `goodreads` sections are optional; leave unused sections blank or omit the file. Set up Fable and Pagebound in KOReader. On upgrade, existing `storygraph_config.lua` and `hardcover_config.lua` files are merged automatically.

> [!TIP]
> The StoryGraph and Goodreads cookies below can be grabbed automatically instead of copying them out of devtools by hand:
>
> 1. Log in to StoryGraph and/or Goodreads in a browser on this PC — the script only reads cookies that already exist, it can't log in for you.
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

### StoryGraph authentication
Open **ShelfSync > Accounts > StoryGraph > Log in** and enter your StoryGraph email and password. The plugin saves the session and remember-me cookies returned by StoryGraph; it does not store your password. Log in again if your session expires.

If Cloudflare blocks login on your device, import browser cookies using the helper above or these manual steps:

1. Log in to [thestorygraph.com](https://thestorygraph.com) in your browser.
2. Open your browser's Developer Tools (F12) -> Application/Storage -> Cookies.
3. Copy the value of the `_storygraph_session` cookie and paste it into the `session_cookie` field of the `storygraph` section in `shelfsync_config.lua`.
4. Copy the value of the `remember_user_token` cookie and paste it into the `remember_user_token` field of the `storygraph` section in `shelfsync_config.lua`.

### Hardcover authentication
Open **ShelfSync > Accounts > Hardcover > Sign in with Hardcover (OAuth)** and follow the device-code instructions. When signed in, ShelfSync uses OAuth; it refreshes the session automatically and falls back to an API token only when OAuth is signed out or its session is rejected.

API-token authentication remains available as a fallback:
1. Go to [hardcover.app/account/api](https://hardcover.app/account/api) in your browser and copy your API token.
2. Paste it into the `token` field of the `hardcover` section in `shelfsync_config.lua`, or open **ShelfSync > Accounts > Hardcover > Hardcover API Token fallback** in KOReader.

### Goodreads authentication
Goodreads accounts are linked through Amazon, so a valid session is a bundle of cookies rather than one or two named values, and it can go stale periodically from an AWS WAF bot-challenge on Goodreads' side.

[`goodreads-cookie-refresher`](https://github.com/Lyfts/goodreads-cookie-refresher) is an optional self-hosted Docker setup that handles both of those for you: it keeps a real logged-in browser session alive on your network and hands the plugin fresh cookies automatically, covering initial setup (leave the cookie field below blank) as well as every future refresh, so you never have to do the manual steps below at all.

For multiple Goodreads accounts on separate KOReader installs, configure the refresher with one account ID per login. Keep the default refresher URL on one device; on another, append its account path, such as `/accounts/girlfriend`, to **Cookie Auto-Refresh URL**.

Without that setup, grab a cookie by hand instead. Rather than copying each one individually from the cookie storage view, grab the browser's pre-assembled `Cookie` request header instead — it's the exact same cookies, already joined into the one string this plugin needs.
1. Log in to [goodreads.com](https://goodreads.com) in your browser.
2. Open Developer Tools (F12) -> Network tab, then reload the page.
3. Click any request to `www.goodreads.com`, open its **Headers** panel, and find the `Cookie` row under **Request Headers** (not Storage/Application -> Cookies, and not `Set-Cookie` under Response Headers — this is a specific request's outgoing header). If it isn't shown, look for a "raw headers" toggle.
4. Right-click it -> Copy Value, and paste the whole thing into the `cookie` field of the `goodreads` section in `shelfsync_config.lua`.
   - Alternatively, you can paste it into **ShelfSync > Accounts > Goodreads** from within KOReader instead of editing the config file.

Without the Docker refresher, this cookie will go stale again periodically — when that happens, syncing pauses until you repeat the steps above.

### Fable authentication
Unlike the other services, Fable has a real login API, so the plugin logs in directly with your Fable email and password rather than a cookie/token you have to fetch by hand.

1. In KOReader, open **ShelfSync > Accounts > Fable > Log in**, and enter your Fable email and password.
2. ShelfSync caches your password on the device so it can silently sign in again if the refresh token stops working. The password is encrypted at rest when `libcrypto` is available; otherwise, it is stored in plaintext. Your access/refresh tokens refresh automatically, and **Log out** clears the cached password and tokens.

> [!TIP]
> If you signed up to Fable with **Google or Apple**, there's no password to log in with here. Convert the account to a regular email/password account first: in the Fable app, go to **Account settings** and set/add a password for your account. Once that's done, log in above using that email and password like any other account.

### Pagebound authentication
Open **ShelfSync > Accounts > Pagebound > Log in** and enter your Pagebound email and password. The plugin signs in through Firebase, exchanges that session for a Pagebound API token, and refreshes the token automatically. It caches your password on the device, encrypted at rest where available, so it can recover if the refresh token stops working. Use **Log out** to clear the credentials cached by ShelfSync.

> [!TIP]
> If you usually sign in to Pagebound with **Google or Apple**, reset the password for the email address on your account through Pagebound. You can then log in with that email and password; ShelfSync uses this regular email/password account.

## Usage

Everything lives under a single **ShelfSync** menu in **Tools > More tools**. **Provider settings** groups provider enablement, book linking, automatic tracking, manual status/progress updates, and provider-specific options. **Accounts** contains separate **StoryGraph**, **Hardcover**, **Goodreads**, **Fable**, and **Pagebound** submenus. Providers work independently and can be used together.

### Updating Progress & Notes
Open **ShelfSync > Provider settings > Update status > [provider]** for that service's status and manual progress actions. Available actions depend on the provider and current book status; for example, Pagebound can post a note to the linked book's forum. Notes can include the current **Chapter, Page, and Percentage**; regular-note location context is configurable in **ShelfSync > Settings**.

### Linking a Book
Before updates can be sent, a document needs to be linked to a book on each service you want to sync to. Open **ShelfSync > Provider settings > Link or relink book**, then use the tabs at the bottom of the search screen to switch between StoryGraph, Hardcover, Goodreads, Fable, and Pagebound. The plugin automatically tries to link the correct edition (e.g. by matching ISBN); hold the unlink button to remove a provider's saved link. Provider-specific edition actions are under that provider's **options** submenu.
- Use **"Change edition"** under **StoryGraph options** or **Hardcover options** to switch to a different edition (StoryGraph) or select a specific edition (Hardcover). Goodreads, Fable, and Pagebound have no edition-switching concept, so linking picks whichever book the search returns.
- Audio editions are filtered out of the search results (StoryGraph, Hardcover).
- If a book is not currently tracked, the plugin will set its status to Currently Reading.
- On StoryGraph, if another edition of the book is set as 'Currently Reading' or 'Want to Read' then the plugin will automatically link to that edition, but not change the status. You can use "Change edition" to link to a different edition if needed.

### Reviews
With a book open, choose **ShelfSync > Review** to open the review composer. Add a rating, review text, or both, then choose which providers should receive it. Enabled providers where you are signed in and the book is linked are selected by default; unavailable providers show why they cannot receive the review. If submission fails for a provider, the draft stays available so you can retry it.

Ratings range from 0 to 5 in quarter-star steps. Goodreads rounds down to whole stars; Hardcover and Pagebound round down to half stars; StoryGraph and Fable preserve quarter-star ratings. When ShelfSync detects that you finished a book, it offers to open the composer if at least one provider is eligible.

### Automatically Track Progress
Enable tracking for each linked service under **ShelfSync > Provider settings > Automatically track progress** to sync progress periodically:
- Updates are sent when paging, no more than once per minute (configurable).
- When reaching the end of the document, the book is automatically marked as "Read"/"Finished".
- Progress can be synced automatically based on time duration, percentage read or pages read (based on edition page count).
- Hardcover only stores progress as a page number; if a tracking mode produces a percentage instead (e.g. no page count is known for the linked edition), it's converted to a page number automatically before syncing.

### Update Progress with a Gesture
KOReader's gesture manager includes a **ShelfSync: Update progress for all linked books** action in the **General** category. Assign it to any gesture to immediately push the open book's current progress to every provider it is linked to, without waiting for the configured time, percentage, or page interval. Gesture-triggered updates show the provider being synced and whether the update succeeded or failed; automatic interval updates remain silent. Provider authentication, enablement, and per-book tracking settings still apply.

## Settings

Provider and account controls are grouped separately:

- Provider enablement, linking, automatic tracking, and service-specific book actions are under **ShelfSync > Provider settings**.
- Cookies, tokens, login, and sign-out are under **ShelfSync > Accounts > [provider]**.

Shared settings live under **ShelfSync > Settings**, since they apply to the whole plugin rather than one service:

- **Auto Book Link**: Attempt to find matching books automatically when opening a new document, in the order provider identifier, ISBN, then title and author. Each method can be toggled independently, and all are enabled by default. Identifier-based linking is supported for Goodreads (`goodreads:` tag), Hardcover (`hardcover:`/`hardcover-slug:`/`hardcover-edition:` tags), and StoryGraph (`storygraph:`/`storygraph-edition:` tags). Fable and Pagebound currently don't expose matching identifier schemes.
- **Progress tracking settings**: Configure shared triggers based on time, percentage, or page changes.
- **Include location info in regular notes**: Automatically append Chapter, Page, and % info to your regular notes.
- **Enable wifi on demand**: Briefly enable wifi for background syncs to preserve battery life.
- **Confirm changes to book read status**: Prompt for confirmation before changing or removing a book's status from a service's **Update status** menu (e.g., Want to Read -> Read). Enabled by default; turn it off to apply status changes with a single tap.
- **Verbose logging**: Log additional detail for troubleshooting.
- **Plugin Updates**: Configure version checks and mandatory-update behavior (see below).

## Versioning & Mandatory Updates

To prevent data corruption and ensure compatibility with the providers' APIs, the plugin includes a remote versioning system. This applies to the plugin as a whole (StoryGraph, Hardcover, Goodreads, Fable, and Pagebound sync).

- **Automatic Checks**: The plugin periodically checks for mandatory updates via GitHub. If the StoryGraph API changes in a way that breaks older versions, the plugin will automatically disable sync to prevent errors.
- **Blocking**: When a mandatory update is required, the plugin menus will be greyed out.
- **Configurable Frequency**: Use the **"Version check frequency"** slider to choose how often the plugin checks for updates (from 1 to 30 days). Default is 1 day.
- **Manual Override**: You can enable **"Ignore version blocks"** to bypass mandatory update requirements. Use this with caution as older versions may break sync if the StoryGraph API changes.
- **Silent Mode**: Disable **"Show version alert dialog"** if you prefer the plugin to silently stop working when an update is required, rather than showing a notification.

# ShelfSync for KOReader

A KOReader plugin to synchronize your reading progress, notes, and status to [The StoryGraph](https://thestorygraph.com) and/or [Hardcover](https://hardcover.app). Both services can be linked and tracked independently, side by side, from the same install.

> [!NOTE]
> This project combines the features of [storygraph.koplugin](https://github.com/burneracc0112/storygraph.koplugin) and [hardcoverapp.koplugin](https://github.com/Billiam/hardcoverapp.koplugin) into a single plugin, largely vibe coded, with changes made mostly for personal use. It isn't intended to be upstreamed, but may still be useful to others.

> [!CAUTION]
> **Disclaimer**: StoryGraph sync uses an unofficial API based on session cookies. Because of this, it is inherently brittle and may break if StoryGraph updates their website or cookie structure. If sync stops working, please ensure you are using the latest version of the plugin and try re-fetching your session tokens. Hardcover sync uses Hardcover's official API and does not have this issue.

## Installation

1. Download the latest release and extract it to your KOReader `plugins/` folder.
2. Set up authentication for whichever service(s) you want to use — both are optional and independent.

Both services share a single config file: rename `shelfsync_config.example.lua` to `shelfsync_config.lua`, then fill in whichever section(s) below you want — the `storygraph` and `hardcover` sections are both optional and independent, and leaving one blank (or the whole file missing) doesn't affect the other.
- *Note: If you are upgrading from an older version, the plugin will automatically merge an existing `storygraph_config.lua` and/or `hardcover_config.lua` into `shelfsync_config.lua`.*

### StoryGraph authentication
1. Log in to [thestorygraph.com](https://thestorygraph.com) in your browser.
2. Open your browser's Developer Tools (F12) -> Application/Storage -> Cookies.
3. Copy the value of the `_story_graph_session` cookie and paste it into the `session_cookie` field of the `storygraph` section in `shelfsync_config.lua`.
4. Copy the value of the `remember_user_token` cookie and paste it into the `remember_user_token` field of the `storygraph` section in `shelfsync_config.lua`.

### Hardcover authentication
1. Go to [hardcover.app/account/api](https://hardcover.app/account/api) in your browser and copy your API token.
2. Paste it into the `token` field of the `hardcover` section in `shelfsync_config.lua`.
   - Alternatively, you can paste the token directly into the **Hardcover** menu's **Settings > Account (API Token)** field from within KOReader instead of editing the config file.

## Usage

Everything lives under a single **ShelfSync** menu in the **Bookmark** top menu when a document is active, with **StoryGraph** and **Hardcover** as sub-menus. They work the same way and can be used together or independently.

### Updating Progress & Notes
Each menu provides a unified **"Update progress: [XX]%"** item. This opens a powerful dialog where you can:
- **Set Progress**: Tap the progress button to open a native picker showing both your **KOReader** and remote synced percentages.
- **Add a Note**: Write your thoughts directly in the note field.
- **Location Context**: By default, notes sent via the highlight menu automatically include your current **Chapter, Page, and Percentage**. You can enable this for regular notes in the settings.

### Linking a Book
Before updates can be sent, a document needs to be linked to a book on each service you want to sync to.
- Use **"Link book"** to search by metadata or ISBN.
- Use **"Change edition"** to switch to a different edition (StoryGraph) or select a specific edition (Hardcover).
- Audio editions are filtered out of the search results.
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
- **Automatically link by ISBN/Title** (Hardcover also offers matching by its own identifiers): Attempt to find matching books automatically when opening a new document.
- **Account**: Cookies/tokens for that service.

Everything else — progress tracking settings, "Enable wifi on demand", "Confirm changes to book read status", "Compatibility mode", "Include location info in regular notes", "Verbose logging", and the **"Plugin Updates"** settings (see below) — is shared between both services and lives under **ShelfSync > Common settings**, since it applies to the whole plugin rather than one service:
- **Include location info in regular notes**: Automatically append Chapter, Page, and % info to your regular notes.
- **Enable wifi on demand**: Briefly enable wifi for background syncs to preserve battery life.
- **Confirm changes to book read status**: Prompt for confirmation before changing a book's status (e.g., Want to Read -> Read).

## Versioning & Mandatory Updates

To prevent data corruption and ensure compatibility with StoryGraph's unofficial API, the plugin includes a remote versioning system. This applies to the plugin as a whole (both StoryGraph and Hardcover sync).

- **Automatic Checks**: The plugin periodically checks for mandatory updates via GitHub. If the StoryGraph API changes in a way that breaks older versions, the plugin will automatically disable sync to prevent errors.
- **Blocking**: When a mandatory update is required, the plugin menus will be greyed out.
- **Configurable Frequency**: Use the **"Version check frequency"** slider to choose how often the plugin checks for updates (from 1 to 20 days). Default is 1 day.
- **Manual Override**: You can enable **"Ignore version blocks"** to bypass mandatory update requirements. Use this with caution as older versions may break sync if the StoryGraph API changes.
- **Silent Mode**: Disable **"Show version alert dialog"** if you prefer the plugin to silently stop working when an update is required, rather than showing a notification.

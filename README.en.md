# Yuliang · 余量

A compact macOS companion for AI quota and usage. Version 0.17.1 (build 24) offers a 344 × 160pt standard card, a genuinely smaller 280 × 112pt compact card, and a 160 × 160pt Duo frame. Duo's ring and character are larger within the same frame. Select Codex or Claude subscription quota. Daily and lifetime Codex Token statistics have independent display switches; missing Claude statistics are not inferred. The menu-bar card follows the compact setting and shares quota and interaction state with the desktop. Interface language can follow the system or use Simplified Chinese, English, or Japanese; light and dark appearance remain independently selectable.

Seven characters are supported: Star Sugar Dragon Girl, Orange Glow, Blue Whale, Star Kitty, Cloud Sprite, Nailong, and Sword Cat. The v0.17.1 public App and source include all seven characters' artwork and actions; the plugin ZIP contains no artwork and uses the local App's resources. Star Sugar is the default. A newer verified quota decrease triggers one biscuit. Twelve common interactions remain available alongside a signature action, local messages, and visual responses for each character. Mochi Cat, Butter Bunny, Mint Fox, and Sesame Bear no longer appear in the picker; old preferences can still migrate. Play never changes quota or Token statistics. Artwork sources and conditions remain in [ASSETS.md](ASSETS.md); inclusion does not imply official authorization or collaboration.

Compact mode reduces the actual window, type, rail, and Token rows together. The refined rail retains decoration through soft highlights, a few character-themed symbols, and pearl-like dots instead of dense mechanical ticks. Hover responses and taps accompany the character at the real quota endpoint; tapping never adjusts quota. Optional autonomous companionship reacts after a quiet interval of about 30 seconds (26–34 seconds), with character-specific local messages. Disable it under **Settings → Display → Autonomous companionship**. Quota collection still targets one read every 60 seconds.

An encouragement appears while idle. A newer accepted quota briefly shows its update time for about 2.4 seconds; interaction messages last about 5.5 seconds. Errors and actionable states take priority. Standard and Duo cards use 22pt continuous corners; compact uses 20pt. Light cards add a 94% white layer over the native material so dark wallpaper does not make them gray; menu cards, settings, and the character picker use white light surfaces. Dark mode retains native material and semantic colors. Mode resizing takes about 0.36 seconds, with short transitions for appearance, characters, language, display options, and settings pages. Reduce Motion removes these movements. Right-click opens a settings panel that stays open for consecutive changes. This is a standalone native window, not a WidgetKit system widget.

[中文](README.md) · [Downloads](https://github.com/lin52001/yuliang/releases/tag/v0.17.1) · [What's new](RELEASE-v0.17.1.md) · [Changelog](CHANGELOG.md) · [Interaction references](PROGRESS-INTERACTION-REFERENCES.md) · [System appearance research](apple/MACOS-WIDGET-APPEARANCE.md) · [Codex plugin](docs/YULIANG-PLUGIN.md)

**Separate licenses:** code is MIT. Character artwork, character designs, and official product marks retain their source-specific conditions; the code license does not cover third-party images or marks. See [ASSETS.md](ASSETS.md).

## Codex local plugin beta

[Download plugin ZIP](downloads/Yuliang-Plugin-v0.1.0-beta.2.zip) · [SHA256](downloads/Yuliang-Plugin-v0.1.0-beta.2.sha256)

Plugin `0.1.0-beta.2` exposes quota and Token queries, refresh requests, the native card, character interactions and selection, and layout, appearance, and language settings. Its minimum App version remains Yuliang `0.17.0` build `23`; this release pairs it with App `0.17.1` build `24`. Node.js 20+ and a plugin-capable Codex client are also required. It shares the existing approximately 60-second collector and bundles neither the App nor character artwork. Characters still appear in Yuliang’s native window. See the [plugin guide](docs/YULIANG-PLUGIN.md) for installation, remote marketplace updates, and data scope. Beta.2 first connects to an already running App, then attempts startup only when needed. It fixes launch errors being reported as a missing App. An existing compatible App does not need reinstalling for this plugin fix; update the App only to get the new visuals. A failed automatic launch does not prove that the App is absent.

## Synthetic previews (v0.17.1)

These native v0.17.1 acceptance previews use synthetic quota and Token data, not real account records. Standard, compact, Duo, and persistent settings come from the same tested version, showing the decorated rail and larger Duo ring and character. All previews use Star Sugar Dragon Girl. Native cache images do not fully capture screen material or monochrome compositing and do not prove real Claude quota collection. Artwork attribution and conditions remain in [ASSETS.md](ASSETS.md).

| Light | Dark |
| --- | --- |
| ![Synthetic preview of the light desktop card](docs/assets/widget.png) | ![Synthetic preview of the dark desktop card](docs/assets/widget-dark.png) |

| Compact light · 280 × 112pt | Compact dark · 280 × 112pt |
| --- | --- |
| ![Synthetic compact light card](docs/assets/compact.png) | ![Synthetic compact dark card](docs/assets/compact-dark.png) |

| Duo light | Duo dark |
| --- | --- |
| ![Synthetic light Duo ring preview](docs/assets/duo.png) | ![Synthetic dark Duo ring preview](docs/assets/duo-dark.png) |

The separate settings panel stays open for consecutive changes. Close it when finished.

| Settings light | Settings dark |
| --- | --- |
| ![Synthetic light settings panel](docs/assets/settings.png) | ![Synthetic dark settings panel](docs/assets/settings-dark.png) |

## Install

Requires macOS 14 or later. The Codex source needs an installed, signed-in official Codex CLI. The Claude source needs official sign-in inside Yuliang's connection window. No Apple Developer account is required. Enter Claude passwords and verification codes only on the official site; Yuliang does not ask you to paste cookies or API keys.

1. Open [Releases](https://github.com/lin52001/yuliang/releases/tag/v0.17.1). Download [Yuliang-v0.17.1-macOS-arm64.zip](https://github.com/lin52001/yuliang/releases/download/v0.17.1/Yuliang-v0.17.1-macOS-arm64.zip) for Apple Silicon or [Yuliang-v0.17.1-macOS-x86_64.zip](https://github.com/lin52001/yuliang/releases/download/v0.17.1/Yuliang-v0.17.1-macOS-x86_64.zip) for Intel, if that asset is available. Check **Apple menu → About This Mac** if unsure.
2. Extract the archive and move `余量.app` to `~/Applications` or `/Applications`.
3. Open the app. The default Codex source starts reading automatically. Claude requires connecting and enabling collection as described below. The app has no Dock icon.

Downloads currently have an ad-hoc signature, not a Developer ID distribution signature or Apple notarization. If macOS blocks the first launch, verify that the file came from this repository and matches the Release's `SHA256SUMS`. Try opening it, then use **System Settings → Privacy & Security → Open Anyway**, and confirm **Open**. Managed devices may restrict this. See [Apple's instructions](https://support.apple.com/102445). Do not disable Gatekeeper or remove quarantine attributes.

Already using Codex? Do not reinstall it if Yuliang can read your account. Claude-only use does not require the Codex CLI. If Homebrew is already installed, OpenAI documents this CLI installation method:

```sh
brew install --cask codex
codex login
```

Sign in with the ChatGPT account whose subscription quota you want to monitor. Yuliang reuses the CLI's login; if the CLI and desktop app use different accounts, the CLI account applies. API-key billing is a different quota scope. For other installation methods, use the [official Codex CLI guide](https://developers.openai.com/codex/cli/). Never share credentials or authentication files in an issue.

### Build locally

Requires Node.js 20+, Git, and Apple Command Line Tools. No npm runtime dependencies or full Xcode installation are needed. Check `xcode-select -p` and `xcrun swiftc --version`; run `xcode-select --install` only if the tools are missing.

```sh
git clone https://github.com/lin52001/yuliang.git
cd yuliang
npm run build:mac
npm run install:mac
open "$HOME/Applications/余量.app"
```

The build produces `releases/余量.app` for the current machine's architecture and signs it ad hoc. The installer copies it to `~/Applications`, checks bundle identity and signature integrity, and attempts rollback if replacement fails. It does not quit or restart an existing process; quit the old version before opening the update. Local signing is not Developer ID certification or notarization.

## Use

- Click **余 N%** in the menu bar to open the popover. Choose **设置 → 额度来源** to select Codex or Claude; each source keeps its own quota and read status.
- Right-click or Control-click the desktop card to open the persistent settings panel. Right-clicking the character still opens its action panel. Desktop header buttons for locking, hiding, and settings are removed; the menu-bar popover retains settings and a desktop-restore entry.
- The desktop card is freely movable by default: drag its header or non-interactive areas. Buttons and the character retain their click actions. Choose **锁定位置** in settings to fix or release its position. Position and lock preference are saved locally.
- Set always-on-top or desktop-level placement separately in the settings menu. Always-on-top and position locking are independent.
- Choose **收起桌面卡片** in settings to hide only the desktop widget. Background collection continues; show it again or explicitly move it back to the current screen from the popover. This menu action can reposition a locked card.
- Choose all seven characters through the standard card’s character button or **Settings → Choose a companion**, including Nailong and Sword Cat with their artwork and actions. Compact mode uses the context settings. The selection is stored locally and shared with the menu-bar card.
- Under **Settings → Widget style**, use the standard card (344 × 160pt), compact card (280 × 112pt), or Duo ring (160 × 160pt). Compact changes the actual card and menu-bar window dimensions, reduces Token rows, and hides bottom shortcuts; it does not resize Duo. Standard and Duo corners are 22pt; compact corners are 20pt. Resizing and crossfades preserve the upper-left anchor and keep the card on screen. Settings stay open. Progress fill, percentage, and character position share one real quota value.
- Duo uses a 20-point monochrome menu-bar ring. Click it to open the complete card; hide the desktop widget to use the menu-bar entry alone.
- Codex daily and lifetime Token usage are both shown by default. Toggle **日 Token 用量** and **累计 Token 用量** independently under **显示内容** in settings. The card uses one row; Duo uses two narrow rows whose content collapses independently without resizing the outer frame. Hover or open details for the server's daily date and full numbers. These switches control display only. Claude does not borrow Codex statistics or infer Token counts from quota.
- Choose **Settings → Language** for System, 简体中文, English, or 日本語. Text, dates, and numbers update immediately while settings stay open. This local preference does not rewrite quota records or change the official website’s language.
- Under **外观**, choose system/light/dark appearance independently from **自动 · 后台淡为单色**, **始终全彩**, or **始终单色**. Automatic uses the frontmost application as an approximation: Finder or Yuliang in front means full color; other apps in front mean monochrome. A Finder file window also counts as full color. The desktop surface uses `underWindowBackground` with `behindWindow` blending. It cannot automatically read the system's exact Clear/Tinted selection; app color options do not synchronize bidirectionally with system widget settings or promise pixel-identical output. Preferences are saved locally.
- Click the character for a response from its own action mix. Right-click, use the standard card’s bottom sparkle button, or choose **Settings → Interactions** for twelve common actions plus the current character’s signature: dragon sugar, warm glow, bubble leap, star orbit, floating cloud, belly bounce, or sword guard. Tapping the rail also triggers interaction. Play never changes quota, Token statistics, timestamps, or long-term satiety.
- Autonomous companionship plays a short action after a quiet interval of about 30 seconds (26–34 seconds) and a local caring message. Toggle **自主陪伴** under **设置 → 显示内容** to disable it. Manual actions and verified quota consumption take priority, followed by a short quiet period. Consumption arriving every minute does not keep restarting the full companionship delay. Hidden widgets, sleep, settings operations, and Reduce Motion suppress autonomous actions without queuing them for later. It reads no chats and makes no model requests.
- The footer normally shows encouragement. A successfully accepted newer quota observation shows its update time for about 2.4 seconds; hover or open details for the full time. Manual interactions show matching encouragement for about 5.5 seconds and take priority over the refresh flash. Expired refresh flashes are not replayed afterward. Failed reads, sign-in requirements, unknown or stale values, and resets awaiting confirmation take priority. Interactions, character changes, and display switches keep the outer frame fixed.
- Choose **Settings → 立即刷新** to read immediately; the details window also offers refresh. Open **用量与额度详情** in settings for independent endpoint status and success times, quota windows, statistical scope, and pause/resume controls. Persistent hints and picker instructions are folded away.
- Quit Yuliang from its menu to stop collection. Sleep pauses requests; waking resumes them.

Motion respects the macOS Reduce Motion setting. Visual responses have no audio and do not simulate quota consumption between real observations.

Locking, unlocking, changing the window level, and hiding the card do not change the target of starting a quota read every 60 seconds. Locking prevents dragging; explicitly choosing the menu action to move the card to the current screen still repositions it.

The four themes use ChatGPT dragon-girl, Claude orange-haired senior-student, DeepSeek blue-whale-girl, and Gemini star-cat-girl directions, with new six-frame artwork made for the quota bar. The artwork is an AI-assisted adaptation of the designs documented by the community [llm-pet](https://github.com/savanna0425/llm-pet) project, redrawn into six frames for this quota card. The original attribution and artwork conditions remain in place. They are unofficial appearances, not official model-company characters. Character themes do not change the data provider: choosing the Claude or DeepSeek theme does not connect that service. Choose Codex or Claude separately under **额度来源**; Claude also requires its own connection step. See [ASSETS.md](ASSETS.md) for attribution and artwork rights.

## Connect Claude quota

1. Select **设置 → 额度来源 → Claude**, then choose **连接 Claude 官网**.
2. Sign in on the official page inside the app's connection window. Google and similar official sign-in methods open a separate sign-in window. After completing that flow, return to the connection window and click **前往额度页** to open **Settings → Usage** (`https://claude.ai/settings/usage`). Enter passwords and verification codes only on the official page or its official sign-in window.
3. Once the sign-in window has finished and the Usage page displays your quota, click **开始 60 秒刷新**. The connection window and quota details provide **暂停自动读取** and **立即刷新**. Closing the connection window keeps an enabled collector running; quitting Yuliang stops it. Sixty seconds is a target interval, affected by network errors, sleep, rate limits, and upstream delays.

Only visible percentages, quota windows, and reset text are parsed. Missing windows, reset times, or Token statistics remain unknown; nothing is inferred from your plan, quota percentage, or Codex data. Failed reads retain the last successful value and time. Yuliang does not import browser credentials, export session cookies, or read conversations.

The embedded connection window and its sign-in windows use a session separate from your external browser. **打开官网** opens the official page in your external browser for checking, but does not sign the embedded window in. Claude or its sign-in provider may restrict embedded-browser sign-in, and site structure or language changes can break parsing. The connection entry is available, and the official sign-in return flow has been verified. Redirects to a plan page do not produce quota samples; enable collection once the account can display Usage quota. Parsing and refresh sampling have been checked with isolated synthetic pages, with end-to-end acceptance on an account that displays quota still pending. This is not a promise of support for every account, plan, or region.

## What the numbers mean

For Codex, Yuliang reads subscription quota through `account/rateLimits/read` from the official local `codex app-server`. It does not create conversations or run model tasks. Claude uses the visible official Usage page described above. The rail shows the selected source's quota separately from Token usage; it does not convert quota percentages into Token counts, API credits, or ordinary ChatGPT conversation limits.

The target request-start interval is 60 seconds. Slow requests, network errors, rate limits, sleep, and upstream delays can extend the interval. A biscuit plays once after a saved, newer observation confirms a decrease in the same window and known reset cycle. Initial loads, duplicates, unknown values, window switches, and resets do not count as consumption. Opening the popover does not replay an event.

Unknown stays unknown. Failed reads keep the last successful value and time. Reaching a reset timestamp does not invent a full balance; the next valid observation must confirm it.

## Token usage

For Codex only, the separate read-only `account/usage/read` endpoint supplies Token statistics. Claude statistics are not inferred when its quota page does not provide them:

- **Daily · MM/DD** shows the latest statistical day and its count returned by the server. The server does not specify its timezone, so this is not local “today”; the date can differ from your Mac's current date.
- **Lifetime** shows the server's `lifetimeTokens` directly. It does not correspond to a subscription-quota window, remaining usable Tokens, or a monetary balance.

The card uses compact numbers; hover or open details for full values. Quota and Token endpoints have independent status and success timestamps. Missing, unsupported, or failed statistics do not become zero or borrow the other endpoint's success time. Both share the 60-second target collection cycle, and upstream statistics may be delayed. Token changes do not trigger or replay the quota-consumption biscuit event.

## Plugin connection troubleshooting

If Yuliang is running but an earlier plugin reports `app_unavailable`, follow the [plugin guide](docs/YULIANG-PLUGIN.md) to upgrade the remote marketplace before installing plugin `0.1.0-beta.2`, then restart Codex and open a new chat. Local path marketplaces do not need that remote upgrade step. This release offers App v0.17.1 build 24, while plugin compatibility still starts at v0.17.0 build 23. Beta.2 first waits for the existing App, then attempts startup if needed, and continues waiting for the same request even if startup fails. It distinguishes launch failure from a connection with no response. You can manually open the existing App and retry; an automatic launch error does not mean you must reinstall it. The plugin does not download or install background software.

## Privacy

Yuliang does not directly read Codex authentication files, passwords, cookies, API keys, or conversation content. The official CLI manages authentication and its requests to OpenAI. Only allowlisted quota and account-usage summary fields are retained; thread records, identity fields, and unknown fields are discarded. Claude's sign-in session is managed by local WebKit website data; Yuliang reads visible quota information and neither imports external browser credentials nor exports session cookies. Usage Tokens are not authentication tokens. Yuliang runs no analytics or cloud-sync service.

Quota and character preferences are stored at:

```text
~/Library/Application Support/YuliangStandalone/quota.json
```

Codex Token statistics and their read status are managed by the current process and fetched again after restarting; they are not written to the quota archive above. Plugin queries create short-lived, owner-only local response files and return the summary to the current Codex chat; completed calls clean up their response files. Window placement, position lock, widget style, both Token display switches, autonomous companionship, language, appearance, and other display preferences are stored through macOS preferences. No real account records or credentials are included in the repository or release archives.

If Token statistics are unsupported or missing, values remain unknown and quota keeps its independent result. A failed Token read retains its previous in-memory value and original success time. A restart clears that in-memory value until the next successful read. The daily server date is not converted into your local calendar day.

If Codex cannot be found, check its installation location. Common supported paths include `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, `~/.local/bin/codex`, `~/.npm-global/bin/codex`, and known official app bundles. Custom npm/nvm paths may not be detected. If login fails, run `codex login` and retry from the details window; do not copy authentication files.

This release is a standalone Mac card and menu-bar app, not a WidgetKit system widget. iPhone support, cloud sync, and embedding inside the native Codex interface are not included. The Codex plugin supplies tools and a skill; characters remain in the native Yuliang card. See the [plugin guide](docs/YULIANG-PLUGIN.md).

To uninstall, quit the app and remove `余量.app`. Optionally remove the `YuliangStandalone` data directory above; this permanently deletes your local records and character choice. It does not remove Codex login state.

## Develop

```sh
npm run check
npm test
npm run check:codex
npm run check:mac-ui
npm run build:mac
npm run release:mac
```

Tests use synthetic observations and temporary storage. UI checks briefly open only their own AppKit surfaces and require a logged-in graphical macOS session. Release packaging produces an architecture-specific zip and `SHA256SUMS`; it does not perform Apple distribution signing or notarization.

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and [CHANGELOG.md](CHANGELOG.md).

## License

Code uses the [MIT License](LICENSE). Character designs, generated or adapted artwork, and product marks have separate conditions documented in [ASSETS.md](ASSETS.md). The code license does not grant rights to third-party characters or marks. Legacy private-prototype character atlases are not included; migration identifiers do not grant distribution rights.

Yuliang is an independent community project, not an official OpenAI or character-brand product. Third-party marks belong to their respective owners; the MIT License does not grant rights to those marks or characters.

Official references: [Codex CLI](https://developers.openai.com/codex/cli/), [Authentication](https://developers.openai.com/codex/auth/), [App Server](https://developers.openai.com/codex/app-server), [Apple app security](https://support.apple.com/102445).

<img src="assets/AppIcon.png" width="96" align="left" alt="TokenTide icon">

# TokenTide

A tiny always-on-top macOS widget that shows how much of your Claude plan is left.

[![Downloads](https://img.shields.io/github/downloads/ychu824/TokenTide/total?color=D97757&label=downloads)](https://github.com/ychu824/TokenTide/releases)
[![Latest release](https://img.shields.io/github/v/release/ychu824/TokenTide?color=D97757)](https://github.com/ychu824/TokenTide/releases/latest)
[![Stars](https://img.shields.io/github/stars/ychu824/TokenTide?color=D97757)](https://github.com/ychu824/TokenTide/stargazers)

<p align="center"><img src="docs/demo.gif" width="420" alt="TokenTide: a ring gauge that expands into a usage panel on hover"></p>

**At rest** it's a small clay-tinted circle with two rings:

- the outer ring is the 5-hour window
- the inner ring is the 7-day window
- the number in the center is the outer ring's % left

On plans without a 5-hour limit (such as Ultra), it shows a single ring for the 7-day window.

**Hover** over it and it morphs into the full panel. Move the pointer away and it shrinks back.

## Install

**Download (recommended):** grab the latest [`TokenTide-vX.Y.Z.zip`](https://github.com/ychu824/TokenTide/releases/latest) (currently **v0.1.6**) from Releases, unzip it, and move `TokenTide.app` to `/Applications`. It's signed with a Developer ID and notarized by Apple, so it opens with a double-click.

**Or build from source:** needs Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/ychu824/TokenTide.git && cd TokenTide
./build.sh && open TokenTide.app
```

You need **macOS 13+** and [Claude Code](https://claude.com/claude-code), signed in at least once, because TokenTide reuses its login.

To start it automatically, right-click the widget and choose **Launch at Login**.

## Security & privacy

TokenTide reads the OAuth token Claude Code keeps in your Keychain, so it's built to be easy to trust:

- **Only talks to `api.anthropic.com`** for your usage: HTTPS only, ephemeral session, redirects refused. There's no analytics or telemetry. The only other host is GitHub, which the updater checks for new releases (see below).
- **The token stays in memory.** It's never logged, shown or written to disk, and TokenTide never refreshes or modifies it.
- **Reads the token the same way Claude Code does,** so there are no extra prompts, and it adds no new access path.
- **Stores almost nothing:** the widget position and the last limit percentages and reset times. It never stores the raw API response.
- **One file to audit.** The entire app is `TokenTide.swift`.
- **Signed and notarized.** Every release is signed with a Developer ID and notarized by Apple, and ships with a `SHA256SUMS.txt`.

Details and threat model: [SECURITY.md](SECURITY.md).

## What it shows

- **Plan**: Pro / Max 5x / Max 20x / Team / Enterprise
- **Limits**: 5-hour and 7-day windows, each with % left and a reset countdown, turning red at 20% or less. Per-model weekly limits such as **7d Fable** (Max and Ultra can spend up to half the week on Fable) appear quietly in the panel only once more than 50% used. They never take over the ring.
- **Model mix**: share of Claude Code tokens by Opus / Sonnet / Fable / Haiku, for the current 5-hour window and for today
- **Tokens**: Claude Code tokens in the current 5-hour window and today

The widget floats above every window, on every Space and over full-screen apps. It has no Dock icon and no menu bar item. Drag it anywhere and it remembers the spot. It always expands toward the middle of the screen. Right-click it for **Refresh**, **Launch at Login** and **Quit**.

**Size:** right-click → **Size** → Small, Medium, Large or Extra Large, for big or far-away displays.

## Updates

Release builds update themselves. Every 6 hours TokenTide asks GitHub for the latest release. If there's a newer one, it downloads it and installs it only if the new app:

- passes `codesign --verify --deep --strict`,
- is signed by the same Developer ID team as the running app, and
- passes Gatekeeper, i.e. is notarized by Apple.

It then swaps itself in place and relaunches. Your position, size and settings are kept.

- **Turn it off:** right-click → **Install Updates Automatically**. With it off, the panel shows an **Install** link when an update is available.
- **Check now:** right-click → **Check for Updates…**
- Keep the app in `/Applications`. macOS runs apps opened straight from Downloads from a read-only location, which can't be updated.
- Builds you make yourself with `./build.sh` (version `0.0.0-dev`) never update themselves.
- Auto-update starts with v0.1.4. If you're on an older version, download v0.1.4 once by hand.

## How it works

| What | Source | Refresh |
|---|---|---|
| Limit % and reset times | Claude Code's status line (optional, see below), otherwise `GET api.anthropic.com/api/oauth/usage` with Claude Code's OAuth token | live via status line; otherwise every 10 min while Claude Code is active, 30 min when idle, and when you hover over data older than 15 min |
| Plan name | `subscriptionType` / `rateLimitTier` in the Keychain entry, with `/api/oauth/profile` as a fallback | once |
| Tokens and model mix | Claude Code's session logs, `~/.claude/projects/**/*.jsonl` | every 5 s, and when you hover |

- **Limits are account-wide.** claude.ai, the desktop app and Claude Code all draw on the same limits.
- **Tokens and model mix cover Claude Code only.** claude.ai chats aren't logged locally.
- **Token counting.** Tokens are input + output + cache writes. Cache reads are excluded.
- **Token share is not limit share.** Opus and Fable tokens weigh more against your limits than Sonnet tokens.
- **Log reading is incremental.** TokenTide keeps a byte offset per file and parses only new lines, so a scan takes milliseconds.
- **Rate limits.** Anthropic throttles the usage endpoint hard, and the limit is shared with Claude Code's own `/usage`. TokenTide asks rarely, backs off on a 429 (10 → 20 → 40 → 60 min, remembered across relaunches), and keeps showing the last numbers with their age in the footer. It only shows an error if the data is more than an hour old.

### Live numbers with no polling (recommended)

Right-click the widget and choose **Use Claude Code Status Line**. Claude Code passes your 5h/7d usage to its status-line command on every update. TokenTide installs a tiny script (`~/.claude/tokentide/statusline.sh`) that saves just that `rate_limits` object for the widget, then runs your existing status line unchanged. With this on, TokenTide hits the usage endpoint only every 30 min, to pick up the plan and per-model windows.

- This edits `statusLine` in `~/.claude/settings.json`. A backup is saved next to it as `settings.json.tokentide-backup`, and choosing the menu item again restores your original setting.
- If you had no status line, the script prints a short `5h 23% · 7d 41% used`.
- The numbers update while Claude Code is in use. When it's idle, TokenTide falls back to occasional polling.

## Caveats

- `/api/oauth/usage` and `/api/oauth/profile` are **undocumented** endpoints and may change without notice.

## Contributing

Issues and PRs are welcome. To cut a release, see [docs/RELEASING.md](docs/RELEASING.md).

## License

[MIT](LICENSE)

---

TokenTide is an unofficial community tool. It is not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic, PBC.

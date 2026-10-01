# Agent Apps

An Omarchy bar widget for AI desktop apps and the agent CLIs mise manages. It
shows the installed and the newest version of each one and, when you press
Update, installs the newest version in a terminal.

The plugin installs only through mechanisms whose install knowledge someone
else maintains: Omarchy's own recipe, the vendor's own Arch package, or mise.
An app that none of these covers is still listed, as an indicator-only row. It
never installs anything on its own.

![Agent Apps panel](preview.png)

## Install

```sh
omarchy plugin add https://github.com/vladkarok/omarchy-agent-apps --enable
```

Remove it with `omarchy plugin remove io.github.vladkarok.agent-apps`.

## Prerequisites

- `base-devel` (makepkg) and `git`
- `jq`, `curl`, `python` 3.11 or newer, `libarchive` (`bsdtar`): what
  omarchy-pkgs' `bin/sync-upstream` needs
- sudo rights for `pacman -U`
- `mise`, optional, for the agent CLIs

Update on an omarchy row checks these first and, when something is missing,
prints the `sudo pacman -S --needed ...` line that installs it and stops. The
panel says "Missing: makepkg, jq" on those rows.

## What Update runs

Update opens a floating terminal and runs `bin/agent-apps-install <pkg>`.
Which of three mechanisms it uses depends on the row's source badge.

**omarchy.** The apps behind Omarchy's Install > AI menu come from the
[omarchy] pacman repo, built from the recipes in
[omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs). That repo
notices a vendor release within hours, but the update waits for a reviewed
pull request, so the repo can lag the vendor by days. Update runs the same
recipe update on your machine: it resets a clone of omarchy-pkgs to
`origin/master`, runs omarchy-pkgs' `bin/sync-upstream <pkg>`, prints the
recipe diff (normally `pkgver` and checksums), checks that the recipe builds
the expected package at a version newer than the installed one, builds it with
`makepkg` and installs it with `sudo pacman -U`. This runs packaging code you
did not write, so read the diff before you type your sudo password.

**vendor.** The vendor publishes a ready Arch package. `apps.json` gives its
URL with `{version}` in it and a feed for the newest version. Update refuses
unless the feed's version is newer than the installed one, prints the URL,
downloads the file with curl to `~/.cache/agent-apps/packages`, checks its
name and version with `pacman -Qp`, installs it with `sudo pacman -U` and
confirms the result with `pacman -Q`. curl fetches the file because pacman
checks a URL given to `-U` against `RemoteFileSigLevel`, which defaults to
`SigLevel = Required`, and vendors do not sign these packages. A local file
falls under `LocalFileSigLevel = Optional`. When the app is installed under
another name, pacman asks to replace that package; answer `y`.

**mise.** Update runs `MISE_MINIMUM_RELEASE_AGE=0 mise up <tool>` and reports
whether the active version now matches `mise latest <tool>`.

**indicator.** No Update button. These rows show the installed and newest
version and the status "No supported install path". Nobody packages these apps
in a way the plugin could install without keeping its own recipe for them, and
a recipe of ours would need fixing every time the vendor changes something.
Update them the way you installed them.

### Ask agent

A row with a newer version but no Update button (an indicator row, a recipe
without an upstream watch, or a row whose last check failed after it had seen
a newer version) has **Ask agent** and a copy button instead. Ask agent opens
your default coding agent (`omarchy default agent <name>`) in a terminal with
a prompt to update that app: what is installed, what the vendor published and
where, which install routes to prefer, to show the plan before any sudo
command and to leave `/usr/share/omarchy` and `~/.config` alone. With no
default agent set it copies the prompt instead and the row says so. The copy
button (`c`) only copies it. `bin/agent-apps-prompt <pkg>` prints the same
prompt from the last check's results.

### Omarchy builds and the repo

A locally built package says `Packager: Unknown Packager` in `pacman -Qi`.
pacman replaces it with the repo package only when the repo's full version
(`epoch:pkgver-pkgrel`) is higher. For a local build of `2.9940.0-1`:

| [omarchy] repo has | `pacman -Syu` |
|---|---|
| `2.9939.4-1` | keeps the local build |
| `2.9940.0-1` | keeps the local build (same version, same recipe) |
| `2.9940.0-2` | installs the repo package |
| `2.9941.0-1` | installs the repo package |

`sudo pacman -S <pkg>` puts the repo package back at any time.

A recipe without an upstream watch (hermes-desktop, and grok-bot on master, which sets
`"sync": false`) cannot be moved this way. Those rows show the version from the
vendor feed in `apps.json` and no Update button. T3 Code's recipe hook
downloads both release AppImages to hash them, so the check asks its GitHub
releases instead and the hook only runs on Update.

### ZCode

Z.ai publishes an Arch package at
`https://cdn-zcode.z.ai/zcode/electron/releases/{version}/linux-x64/ZCode-{version}-linux-x64.pkg.tar.zst`
(and `linux-arm64/...-linux-arm64...`). Checked with 3.14.4 on 2026-10-01:

- `pacman -Qp` reads `zcode 3.14.4-7912`. The pkgrel is Z.ai's build number.
- It is built with fpm. No provides, conflicts or replaces; packager
  `ZCode <dev@zcode.z.ai>`; no description; license `unknown`; no signature.
  Dependencies are all in the Arch repos.
- Files go to `/opt/ZCode` and `/usr/share`. The install script links
  `/usr/bin/zcode` to `/opt/ZCode/zcode`, so no package owns that link.
- `/opt/ZCode/resources/package-type` contains `pacman`. The AUR's
  `z-code-bin` repackages the Debian package, and there the file says `deb`.
  With `pacman`, ZCode's own updater should handle later updates itself.
- The AUR's `z-code-bin` declares `provides=zcode` and `conflicts=zcode`, so
  `pacman -U` asks to remove `z-code-bin` the first time. Update leaves out
  `--noconfirm` for that run so you can answer.

The newest version comes from Z.ai's update manifest.

## What it shows

The bar icon turns the urgent colour when an app can be updated. Left click
opens the panel, middle or right click checks now. When a check fails for an
app, the tooltip says so and that row shows the error; the icon colour stays
normal.

The panel lists every catalog app that is installed (found with `pacman -Q`,
or `mise ls` for mise tools) with a source badge, the installed version, the
newest version when it is newer, a status line, and an Update button when the
plugin can install it. Desktop apps come first, mise tools after them. The
footer shows the omarchy-pkgs commit used and when the last check ran.

Keys: `j`/`k` or arrows select a row, `Enter` updates it (or asks the agent
on a row without Update), `c` copies the agent prompt, `r` checks now, `s`
opens the settings, `Esc` closes. IPC: `qs ipc call
io.github.vladkarok.agent-apps open` (also `close`, `toggle`, `refresh`,
`status`, `settings`).

| Package | App | Source |
|---|---|---|
| `claude-desktop` | Claude Desktop | omarchy |
| `openai-codex-desktop` | Codex (also found as AUR `chatgpt-desktop`) | omarchy |
| `t3code-bin` | T3 Code | omarchy |
| `hermes-desktop` | Hermes | omarchy, no Update yet |
| `grok-bot` | Grok | omarchy |
| `lmstudio-bin` | LM Studio | omarchy |
| `openclaw` | OpenClaw | omarchy |
| `perplexity` | Perplexity | omarchy |
| `voxtype-bin` | Dictation (voxtype) | omarchy |
| `zcode` | ZCode (also found as AUR `z-code-bin`) | vendor |
| `antigravity` | Antigravity (or `antigravity-appimage`) | indicator, version from AUR |
| `antigravity-ide` | Antigravity IDE | indicator, version from AUR |
| `kimi-bin` | Kimi | indicator, version from Moonshot's update feed |
| `trae-bin` | Trae | indicator, version from AUR |

mise tools, shown when mise has them installed and active: Claude Code,
Codex CLI, Gemini CLI, Jules, Antigravity CLI, Qwen Code, Kimi CLI, Crush,
OpenCode, Amp, herdr, Grok CLI. Each entry lists the names a mise config may
use for it (`claude` or `npm:@anthropic-ai/claude-code`, for example). A tool
that mise's registry does not know is skipped.

Antigravity and Antigravity IDE are separate products with separate version
lines (2.18 and 2.5 at the time of writing), so they are separate rows. Google
publishes neither with a "latest" pointer, and Trae's update API mixes two
version schemes, so those rows ask the AUR.

## How it works

`bin/agent-apps-check` writes
`~/.local/state/omarchy/plugins/io.github.vladkarok.agent-apps/status.json`.
The widget runs it on a timer and watches that file, so a run from a terminal
updates the panel too. The file is rewritten after every app: rows not checked
yet keep their last result marked `"checking": true` and say "Checking…" in
the panel. `bin/agent-apps-install --dry-run <pkg>` prints what
Update would run and stops before building, downloading or installing.
`<pkg>` may also be an installed package name (`z-code-bin`) or a mise tool
name (`claude`).

For omarchy rows the check runs `bin/sync-upstream <pkg>` in the clone at
`~/.cache/agent-apps/omarchy-pkgs`, which rewrites the recipe only when the
vendor has something newer, reads the resulting version, and restores the
recipe. Recipe policies apply as they do in the repo: a `min_release_age` hold
(openclaw, voxtype) keeps a fresh release back. Sources, build files and
packages go to `~/.cache/agent-apps/{sources,build,packages}`, so the clone
stays clean and downloads are reused.

For mise rows the check reads `mise ls --json` once and asks `mise latest
<tool>`, so your mise settings (`prerelease`, release age) decide what counts
as newest.

## Settings

Settings live in the panel behind the gear in its header (or press `s`):
show mise tools, bar icon only when updates exist, notify on new releases
(each version is announced once, tracked in `notified.json` next to
`status.json`), and the check interval. The scripted equivalent is
`omarchy bar set io.github.vladkarok.agent-apps <key> <value>` with the keys
`showMise`, `barIconOnlyWithUpdates`, `notify` and `refreshIntervalSec`
(seconds).

## Adding or changing apps

`~/.config/omarchy/agent-apps/apps.json` is merged over the shipped
`apps.json` by `pkg`: an entry with a new `pkg` adds an app, an entry with an
existing `pkg` overrides the fields it sets, and `"disabled": true` hides one.

```json
[
  { "pkg": "lmstudio-bin", "disabled": true },
  {
    "pkg": "my-app",
    "label": "My App",
    "source": "vendor-pkg",
    "vendorPkg": { "x86_64": "https://example.com/{version}/my-app-{version}-x86_64.pkg.tar.zst" },
    "feed": { "type": "github-release", "repo": "owner/my-app" }
  }
]
```

Fields:

- `pkg`: the omarchy-pkgs recipe name, or the package name the vendor's
  package installs as for `vendor-pkg`. For mise entries any unique id
  (the shipped ones use `mise:<name>`).
- `source`: `omarchy`, `vendor-pkg`, `mise` or `indicator`.
- `installed` (optional): package names to look for with `pacman -Q`, default
  `[pkg]`.
- `tool` (mise only): the mise tool name, or a list of names; the first one
  mise has active is used.
- `vendorPkg` (vendor-pkg only): package URL per architecture (`uname -m`
  as key), with `{version}` replaced by the feed's version.
- `checkWith: "feed"` (optional, omarchy only): check with `feed` instead of
  running the recipe sync.
- `recipeRef` (optional, omarchy only): an omarchy-pkgs ref whose recipe is
  laid over origin/master before checking and building, for a package whose
  upstream watch is still in an unmerged PR (Grok Bot uses
  `refs/pull/725/head`). The panel row says so, and the install diff is shown
  against master, so the PR's changes are visible too. Drop the field once
  the PR merges.
- `feed`: where the newest version comes from for `vendor-pkg` and
  `indicator` apps, and the fallback for `omarchy` apps whose recipe cannot
  sync:
  - `apt-index` with `url` and `package`: a Debian `Packages` file, newest
    stanza for that exact package name.
  - `zcode-manifest` or `latest-yml` with `url`: YAML with `version:` on its
    own line (electron-updater's `latest.yml`).
  - `github-release` with `repo`: the tag behind `/releases/latest`, leading
    `v` stripped. No API calls, so no rate limit.
  - `aur-rpc` with `name`: the AUR's version of that package, pkgrel
    stripped.
  - `command` with `command`: any shell command that prints the version.
- `icon` and `iconLight` (optional): SVG marks for dark and light themes,
  relative to the plugin folder or absolute.

All versions are compared with `vercmp`.

## Attribution

`assets/claude.svg`, `assets/codex.svg` and `assets/codex-light.svg` are copied
from Omarchy's first-party Agents plugin
(`/usr/share/omarchy/shell/plugins/agents/assets/`), MIT licensed. The marks
belong to their owners. The ZCode and T3 Code marks are plain letter shapes
drawn for this plugin.

## License

MIT

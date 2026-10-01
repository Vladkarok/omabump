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

Tested on Omarchy r2083 and r6691.

When something is missing, omarchy rows have no Update button and say
"Missing: makepkg, jq; sudo pacman -S --needed base-devel jq".

## Security model

| Step | What runs | As whom |
|---|---|---|
| Background check (timer, Refresh) | curl and git fetch of feeds and the omarchy-pkgs clone; the fetched recipe is read as text | you, nothing fetched executes |
| Update on an omarchy row | omarchy-pkgs' `bin/sync-upstream`, the recipe's upstream hook, makepkg and the PKGBUILD | you; sudo for build dependencies |
| Install of any built or vendor package | the package's install script and pacman hooks | root |
| Update on a vendor row | the vendor's unsigned package and its install script | root |
| Update on a mise row | the mise backend that installs the tool | you |
| Ask agent | whatever your default agent decides to run | the permissions `omarchy-agent` gives it |

The background check never executes fetched code. It reads each app's
newest version from a feed in `apps.json` (an apt index, a GitHub release
redirect, a JSON or HTML page) and reads the omarchy-pkgs recipe with
`git show`. `bin/sync-upstream` runs only after you press Update.

The vendor package is unsigned. The plugin downloads it over HTTPS and
installs the local file, which pacman accepts under `LocalFileSigLevel`
(Optional by default). `pacman -Qp` checks the file's name and version, which
is metadata, not proof of where the file came from. You trust the vendor's
server, as you would with its .deb.

Every download is HTTPS only, redirects included, with connect and total
time limits. git fetches, `bin/sync-upstream` and mise calls run under
`timeout -k`, so a stalled network call cannot hold a lock forever.

Detection covers pacman packages (by exact name) and tools mise has active.
An app installed some other way, as an AppImage or with npm, is not listed.

## What Update runs

Update opens a floating terminal and runs `bin/agent-apps-install <pkg>`.
Which of three mechanisms it uses depends on the row's source badge.

**omarchy.** The apps behind Omarchy's Install > AI menu come from the
[omarchy] pacman repo, built from the recipes in
[omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs). That repo
notices a vendor release within hours, but the update waits for a reviewed
pull request, so the repo can lag the vendor by days. Update runs the same
recipe update on your machine. It resets a clone of omarchy-pkgs to
`origin/master`, runs omarchy-pkgs' `bin/sync-upstream <pkg>`, prints the
recipe diff (normally `pkgver` and checksums), checks that the recipe builds
the expected package at a full version newer than the installed one, builds
it with `makepkg` and installs it with `sudo pacman -U`. The sync tool and the
recipe's hook already ran by the time the diff shows, so read the diff as a
record of what changed, and stop at the sudo prompt if it looks wrong.

**vendor.** The vendor publishes a ready Arch package. `apps.json` gives its
URL with `{version}` in it and a feed for the newest version. Update refuses
unless the feed's version is newer than the installed one, downloads the file
to `~/.cache/agent-apps/packages`, checks its name with `pacman -Qp`, and
compares its full `epoch:pkgver-pkgrel` with the installed package's, read
again at that moment. Only then does it run `sudo pacman -U` and confirm the
result with `pacman -Q`. curl fetches the file because pacman checks a URL
given to `-U` against `RemoteFileSigLevel`, which defaults to
`SigLevel = Required`, and vendors do not sign these packages.

**mise.** Update runs `mise up <tool>` in `$HOME`. The check asked
`mise outdated` what that command can reach, so the configured request (an
exact pin or a range) and mise's release-age cooldown apply to both. A tool
pinned below the newest release shows "Pinned to 0.96.1, 0.97.1 exists" and
no Update button. Change the request with `mise use` to move it.

**indicator.** No Update button. These rows show the installed and newest
version and the status "No supported install path". Nobody packages these apps
in a way the plugin could install without keeping its own recipe for them, and
a recipe of ours would need fixing every time the vendor changes something.
Update them the way you installed them.

### Switch

Codex may be installed as the AUR's `chatgpt-desktop` and ZCode as
`z-code-bin`. When the canonical package (`openai-codex-desktop`, `zcode`)
has the same or a newer version, the row says "Installed as chatgpt-desktop,
switch to openai-codex-desktop" and has a Switch button (`w`). It runs
`agent-apps-install --switch <pkg>`, which allows an equal full version where
Update needs a newer one. Before pacman runs it checks that one of the two
packages declares a conflict with the other (otherwise pacman would keep
both), prints the new package's install script and the old one's, and names
the app's config directory (`~/.config/Codex`, `~/.config/ZCode`). pacman then
asks to remove the old package. pacman does not touch `$HOME`; whether the new
package picks up the old settings is up to the app, and the plugin does not
promise it.

### Ask agent

A row with a newer version but no Update button (an indicator row, a recipe
without an upstream watch, or a row whose route failed) has **Ask agent** and
a copy button instead. Ask agent opens your default agent
(`omarchy default agent <name>`) in a terminal with a prompt that asks for a
plan first: what is installed, what the vendor published and where, to use
the Omarchy recipe or the vendor's Arch package, to wait for your approval
before changing anything, and to leave `/usr/share/omarchy` and `~/.config`
alone. The agent runs with whatever permissions `omarchy-agent` grants it,
which for some agents means running commands without asking, so the row says
"Opens your default agent; it may change the system". With no default agent
set it copies the prompt instead. The copy button (`c`) only copies it.
`bin/agent-apps-prompt <pkg>` prints the same prompt from the last check's
results.

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

A recipe without an upstream watch (hermes-desktop, and grok-bot on master,
which sets `"sync": false`) cannot be moved by `bin/sync-upstream`. Those rows
show the vendor's version and no Update button. Grok uses the recipe from
omarchy-pkgs PR #725, pinned to one commit (see `recipeCommit` below).

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
  Whether ZCode's own updater then calls pacman or rewrites `/opt/ZCode`
directly is not verified.
- The AUR's `z-code-bin` declares `provides=zcode` and `conflicts=zcode`, so
  `pacman -U` asks to remove `z-code-bin` the first time. Update and Switch
  leave out `--noconfirm` for that run so you can answer.

The newest version comes from Z.ai's update manifest for this machine's
architecture.

## What it shows

The bar icon turns the urgent colour when an app can be updated. Left click
opens the panel, middle or right click checks now. The tooltip and the panel
header say one of: all current, N updates, check failed (the checker or the
omarchy-pkgs fetch failed, or a row's feed or route did), and last known (rows
that keep an earlier run's version because this run could not get one). A
failed check never reads as up to date.

The panel lists every catalog app that is installed (found with `pacman -Q`,
or `mise ls` for mise tools) with a source badge, the installed version, the
newest version when it is newer, a status line, and an Update or Switch
button when the plugin can do it. Desktop apps come first, mise tools after
them. The footer shows the omarchy-pkgs commit used and when the last check
ran.

Keys: `j`/`k` or arrows select a row, `Enter` updates it (or asks the agent
on a row without Update), `w` switches the package, `c` copies the agent
prompt, `r` checks now, `s` opens the settings, `Esc` closes. IPC: `qs ipc call
io.github.vladkarok.agent-apps open` (also `close`, `toggle`, `refresh`,
`status`, `settings`).

| Package | App | Source |
|---|---|---|
| `claude-desktop` | Claude Desktop | omarchy |
| `openai-codex-desktop` | Codex (also found as AUR `chatgpt-desktop`) | omarchy |
| `t3code-bin` | T3 Code | omarchy |
| `hermes-desktop` | Hermes | omarchy, no Update yet |
| `grok-bot` | Grok | omarchy, recipe pinned from PR #725 |
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
the panel. `startedAt` records when the run began; a "checking" mark older
than 10 minutes counts as a dead run and Refresh comes back.

For omarchy rows the check fetches the clone at
`~/.cache/agent-apps/omarchy-pkgs` (data only, no checkout) and reads the
recipe with `git show`. A row is installable when the recipe exists on master
(or at the pinned commit), has an upstream watch or hook, and the build tools
are present. The newest version comes from the feed and is compared with the
installed version less epoch and pkgrel; the installer compares full
versions. Recipe policies such as openclaw's 24 h `min_release_age` are not
in the feed, so a fresh release can show up a day before Update will build
it; until then the installer stops with "not newer than the installed".

`bin/agent-apps-install --prepare <pkg>` fetches, syncs and prepares the
recipe, and stops before makepkg builds. That runs `bin/sync-upstream` and
the recipe's hook, and makepkg reads the PKGBUILD. On the vendor path it
downloads and checks the package and stops before `pacman -U`. Add
`--switch` to prepare a switch. `<pkg>` may also be an installed package name
(`z-code-bin`) or a mise tool name (`claude`). Sources, build files and
packages go to `~/.cache/agent-apps/{sources,build,packages}`, so the clone
stays clean and downloads are reused.

For mise rows the check runs `mise ls --json`, `mise outdated --json` and
`mise outdated --bump --json` once each in `$HOME`. mise versions are shown
as mise prints them, and mise decides what is newer.

## Settings

Settings live in the panel behind the gear in its header (or press `s`):
show mise tools, bar icon only when updates exist, notify on new releases
(each version is announced once, saved to `notified.json` next to
`status.json` right after the notification goes out), and the check interval. The scripted equivalent is
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
- `vendorPkg` (vendor-pkg only): HTTPS package URL per architecture
  (`uname -m` as key), with `{version}` replaced by the feed's version.
- `recipeCommit` (optional, omarchy only): a 40-hex omarchy-pkgs commit
  whose exact recipe tree replaces master's before building, for a package
  whose upstream watch is still in an unmerged PR. `recipeFetch` names a ref
  to fetch when the server does not hand out the bare commit (Grok uses
  `refs/pull/725/head`), and `recipeNote` is the text the row shows. If the
  commit cannot be fetched or lacks the recipe, the row is not installable
  and shows the error; the plugin never falls back to master. Once master's
  recipe has a watch, the pin is ignored and the row says "Pinned recipe no
  longer needed", so the entry can go. Both commits are recorded in
  `status.json`.
- `configDir` (optional): where the app keeps its settings, printed before a
  package switch.
- `feed`: where the newest version comes from. Every non-mise app needs one.
  `url` may be a string or an object keyed by `uname -m`, and must be HTTPS.
  - `apt-index` with `url` and `package`: a Debian `Packages` file, newest
    stanza for that exact package name.
  - `zcode-manifest` or `latest-yml` with `url`: YAML with `version:` on its
    own line (electron-updater's `latest.yml`).
  - `github-release` with `repo`: the tag behind `/releases/latest`, leading
    `v` stripped. No API calls, so no rate limit.
  - `json` with `url` and `path`: a jq path into a JSON document
    (`.version`).
  - `regex` with `url` and `pattern`: a Python regex with one capture group,
    tried on the page and on the page with `\"` read as `"` (JSON inside a
    script tag).
  - `aur-rpc` with `name`: the AUR's version of that package, pkgrel
    stripped.
  - `command` with `command`: a shell command that prints the version. It
    runs during the check, so only use it in your own `apps.json`.
- `icon` and `iconLight` (optional): SVG marks for dark and light themes,
  relative to the plugin folder or absolute.

pacman versions are compared with `vercmp`; mise versions are left to mise.

## Attribution

`assets/claude.svg`, `assets/codex.svg` and `assets/codex-light.svg` are copied
from Omarchy's first-party Agents plugin
(`/usr/share/omarchy/shell/plugins/agents/assets/`), MIT licensed. The marks
belong to their owners. The ZCode and T3 Code marks are plain letter shapes
drawn for this plugin.

## License

MIT

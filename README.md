# Omabump

Agent desktop apps and CLIs at the version the vendor shipped, ahead of the Omarchy repo.

![Omabump panel](preview.png)

An Omarchy bar widget. It lists the agent desktop apps and agent CLIs installed on this machine, the installed and the newest version of each, and installs the newest version in a terminal when you press Update. It never installs anything on its own. The project was previously called Agent Apps.

The apps behind Omarchy's Install > AI menu come from the [omarchy] pacman repo, built from the recipes in [omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs). That repo notices a vendor release within hours (hourly for most of these apps, every six hours for the rest), and its bot's version bumps merge on their own once CI passes, so the repo usually follows within hours, a day later for a recipe that holds new releases. Omabump covers those hours, and a bump whose CI fails and waits for a person.

How it works inside, from the check's schedule to the security model, is in [docs/internals.md](docs/internals.md).

## Prerequisites

- `base-devel` (makepkg, sudo) and `git`
- `jq`, `curl`, `python` 3.11 or newer, `libarchive` (`bsdtar`): what omarchy-pkgs' `bin/sync-upstream` needs
- sudo rights for `pacman -U`
- `mise`, optional, for the agent CLIs
- `7zip`, optional, to read the version of an app installed as its self-updating AppImage (T3 Code); without it that row shows "version unknown"

When something is missing, omarchy rows have no Update button and say what to install, for example "Missing: makepkg, jq; sudo pacman -S --needed base-devel jq".

## Install

```sh
omarchy plugin add https://github.com/vladkarok/omabump.git --enable
```

`omarchy plugin add` asks for confirmation; from a script pass `--yes`.

The widget lands in the bar's right section. Move it with `omarchy bar move io.github.vladkarok.omabump --section center --index 0` (sections: left, center, right).

## What Update does to your machine

Nothing changes until you press Update (or Switch) on a row. Update opens a floating terminal and runs `bin/omabump-install <pkg>`, and the row's route decides what that does ([each route in detail](docs/internals.md#update-routes)):

- **omarchy**: runs `bin/sync-upstream` and the recipe's hook from the omarchy-pkgs commit this release pins ([why a pin](docs/internals.md#pinned-snapshots)), prints the recipe diff, builds the package with makepkg and installs it with `sudo pacman -U`.
- **vendor**: downloads the vendor's own Arch package over HTTPS, checks it against the checksum the vendor publishes, and installs it with `sudo pacman -U`.
- **mise**: `mise install <tool>@<version>`, with `MISE_MINIMUM_RELEASE_AGE=0` as Omarchy's own agent wrappers run it, so a `minimum_release_age` you set does not hold a release back. No sudo, and your mise config is not touched; when a lockfile keeps the old version, Update then runs `mise up <tool>`, which rewrites the lockfile.
- **Switch** (`w`, on a row installed under another package name, such as Codex as the AUR's `chatgpt-desktop` or ZCode as `z-code-bin`): `bin/omabump-install --switch <pkg>` installs the canonical package in place of the installed one, and pacman asks before it removes the old package ([details](docs/internals.md#switch)).
- **Omabump's own row**: a git fast-forward of the plugin's clone to the release tag, after you answer y (see [Updating Omabump](#updating-omabump)).
- **indicator** rows, and apps that update themselves, have no Update; the row says how the app updates.

Everything but the install runs as you. sudo is used for one thing: installing a package you asked for, in that visible terminal. Omabump copies the verified package into the root-owned `/var/cache/omabump` (`sudo install`), runs `sudo pacman -U` on that copy, where pacman asks before it installs, and removes the copy (`sudo rm`, or `sudo -n rm` when the run is stopped before pacman starts; the next Update of that app removes a copy a run stopped during pacman left). After a vendor install it also runs `sudo rm` on `/usr/bin/<pkg>` when that is a link no package owns to a file of the installed package ([why](docs/internals.md#vendor)): while the vendor build of ZCode is installed, `zcode` is not on PATH, so start it from the app launcher or run `/opt/ZCode/zcode`. makepkg also calls `sudo pacman -S --asdeps` when a recipe's build dependencies are missing, and pacman asks before it installs them. What runs as root is pacman, the package's install script and pacman's hooks. Omabump never changes sudo configuration and never installs from the background check, which runs as you and executes nothing it downloads.

Omabump itself writes to `~/.cache/omabump`, `~/.local/state/omarchy/plugins/io.github.vladkarok.omabump`, `/var/cache/omabump` (the staged package, through sudo), the plugin's own clone in `~/.config/omarchy/plugins/io.github.vladkarok.omabump` (its own Update, whose rollback runs `git reset --hard` and `git clean -fd` there, so untracked files in it go) and, when you change a setting, Omarchy's `~/.config/omarchy/shell.json`. Beyond that, pacman installs packages, `mise install` (and `mise outdated`) may write under `~/.local/share/mise`, `mise up` rewrites a lockfile as above, and `bin/sync-upstream`, its hooks and your own `command` feeds can write wherever your user can. What runs at each step, and what each guarantee covers, is in the [security model](docs/internals.md#security-model).

A local build says `Packager: Unknown Packager` in `pacman -Qi`. pacman replaces it with the repo package once the repo's full version is higher, and `sudo pacman -S <pkg>` puts the repo package back at any time. Switching Omarchy's channel (`omarchy channel set`) runs `pacman -Syyuu --noconfirm`, which also puts the repo's older version back, without asking.

## Using it

The bar icon turns the urgent colour when an app can be updated. Left click opens the panel, middle or right click checks now. The tooltip and the panel header say one of: all current, N updates, check failed, last known (rows that keep an earlier run's version because this run could not get one), "N newer, no Update here" (newer releases on rows without an Update button), or "All checked current, N unchecked" (rows whose newest version is not known: CLI tools whose update check was skipped, see [How CLI tools are found](docs/internals.md#how-cli-tools-are-found); a self-updating app's pre-release or unknown version; a version the local refresh found that no check has read yet), plus "(+N muted/skipped)" when quiet rows have updates. A failed or skipped check never reads as up to date; the one exception is a row you muted (see [Mute](#mute)). A check that stopped part way, killed or interrupted, says so in every bar, whoever started it.

A check runs once per interval (an hour by default), and a failed one is tried once more about 5 minutes after it started. Between checks the panel rereads the installed versions, offline, so an app updated by `omarchy update` stops offering its Update. [How both are scheduled](docs/internals.md#checks-and-the-local-refresh).

The panel has three sections: Desktop apps, CLI tools and Plugin (Omabump itself, only while it has an update or its check failed, see [Updating Omabump](#updating-omabump)). Apps are found with `pacman -Q` (exact package names) and CLIs with `mise ls`. A row shows the installed version, or `installed → newest` when there is an update. A second line appears only for an exception: a pin, a hold and until when, another package name, a failed check, no install route. On the row under the cursor its buttons take the version's place, and the version leads the second line. The row's tooltip says where the version came from and what Update runs, or why there is no Update. A row with a newer version but no Update button has no action, and `Enter` on it does nothing; its note and tooltip say why, and how the app updates.

### Keys

Arrows or `j` and `k` select a row, `Enter` updates it, `w` switches the package, `m` mutes or unmutes the row, `K` (Shift+k) skips or unskips its newest version (with CapsLock on, `j` and `k` still move the cursor), `r` checks now, `s` opens the settings, `Esc` closes. The selected row always scrolls into view. The panel opens on the first row with something to do. As the rows change (a check, or the refresh on open), the cursor goes to whichever row has something to do first until you move it or act on a row; after that it stays on that app. A pointer at rest over the rows does not move it.

From a script: `omarchy-shell io.github.vladkarok.omabump status|open|close|toggle|refresh|settings` ([what each answers](docs/internals.md#ipc)).

### Settings

The gear in the panel header (or `s`) opens the settings: check interval (an hour by default, kept between five minutes and a day), show mise tools, bar icon only when updates exist (it also shows while a check fails), notify on new releases. Each new version is announced once.

![Omabump settings](docs/settings.png)

The scripted equivalent:

```sh
omarchy bar set io.github.vladkarok.omabump <key> <value> --json
```

with the keys `refreshIntervalSec` (seconds), `showMise`, `barIconOnlyWithUpdates` and `notify`. Without `--json` the value is stored as a string; `"true"` and `"false"` are read as booleans.

### Mute

Mute (`m`, or the 󰖁 button on the row under the cursor) keeps a row in the list, dimmed with the same glyph after its name, and takes it out of every signal: no badge, no update count, no urgent icon, no reason to show the bar icon when it is hidden until an update, no notification. A muted row's failed check shows only on the row itself ("Check failed: ...") and in the tooltip and IPC status ("check failed for N muted apps"), not in the header or the bar; an omarchy-pkgs or mise failure that only muted rows share does not fail the check. Its update stays visible and Update and Enter still work. Mute again to undo, or Clear in the settings. The list is the widget setting `mutedApps`, an array of row ids (`pkg`), set with `omarchy bar set io.github.vladkarok.omabump mutedApps '["mise:grok-cli"]' --json`. [How mute and skip are applied](docs/internals.md#mute-and-skip-in-detail).

### Skip a version

On a row with an update, Skip (`K`, Shift+k since `k` moves the cursor, or the 󰒭 button) silences that one version the same way: the row shows `installed → newest skipped`, dimmed, and Update still works. When a newer version than the skipped one appears, or that version or a later one is installed, the skip no longer applies, and the row counts and notifies again (once) for a newer release. Skip again to undo. The setting is `skippedVersions`, an object of row id to version: `omarchy bar set io.github.vladkarok.omabump skippedVersions '{"grok-bot": "0.66.0"}' --json`.

Omarchy's settings schema has no array or object type, so `mutedApps` and `skippedVersions` appear only in the panel's own settings (one line, with Clear), not in the bar's widget settings.

## Supported apps

| Package | App | Route |
|---|---|---|
| `claude-desktop` | Claude Desktop | omarchy |
| `openai-codex-desktop` | Codex (also found as AUR `chatgpt-desktop`) | omarchy |
| `t3code-bin` | T3 Code | omarchy as the `t3code-bin` package; once Omarchy's migration 1792345511 replaces it with T3 Code's self-updating app, the row shows that app's version and no Update (it updates itself) |
| `hermes-desktop` | Hermes | omarchy, no Update until the recipe has an upstream watch |
| `grok-bot` | Grok | omarchy |
| `lmstudio-bin` | LM Studio | omarchy |
| `openclaw` | OpenClaw | omarchy as the `openclaw` package, no Update (it is the seed of OpenClaw's own copy); once Omarchy's migration 1792334754 sets that copy up in `~/.openclaw`, the row shows its version and no Update (it updates itself) |
| `perplexity` | Perplexity | omarchy |
| `zcode` | ZCode (also found as AUR `z-code-bin`) | vendor |
| `antigravity` | Antigravity (or `antigravity-appimage`) | indicator, version from the AUR; `omarchy update` updates it |
| `antigravity-ide` | Antigravity IDE | indicator, version from the AUR; `omarchy update` updates it |
| `kimi-bin` | Kimi | indicator, version from Moonshot's update feed |
| `trae-bin` | Trae | indicator, version from the AUR; `omarchy update` updates it |

mise tools, listed when mise has them installed and active: Claude Code, Codex CLI, Crush, OpenCode, Grok CLI, Copilot CLI, Cursor CLI, Pi, Oh My Pi, Ori, Antigravity CLI, Amp, Qwen Code, Kilo, Kiro CLI, Devin CLI, DeepSeek Harness, MiniMax Code, Command Code, Freebuff, Muse Code, Kimi CLI, Gemini CLI, Jules and herdr ([how they are found](docs/internals.md#how-cli-tools-are-found)). An agent Omarchy adds later needs an entry: until a release has it, add one to your own `apps.json`.

## Adding an app

`~/.config/omarchy/omabump/apps.json` is merged over the shipped `apps.json` by `pkg`: a new `pkg` adds an app, an existing one overrides the fields it sets, and `"disabled": true` hides one.

```json
[
  { "pkg": "lmstudio-bin", "disabled": true },
  {
    "pkg": "my-app",
    "label": "My App",
    "source": "vendor-pkg",
    "vendorPkg": { "x86_64": "https://example.com/{version}/my-app-{version}-x86_64.pkg.tar.zst" },
    "checksum": { "url": "https://example.com/{version}/SHA256SUMS", "algo": "sha256" },
    "feed": { "type": "github-release", "repo": "owner/my-app" }
  }
]
```

Every field, and every kind of feed, is in the [apps.json reference](docs/internals.md#appsjson-fields).

## Updating Omabump

`omarchy update` updates Omarchy and your packages, not plugins. So Omabump checks its own GitHub release too, and shows a Plugin section with an Omabump row while a newer release exists or that check failed. Its Update prints the release's commits and a diffstat, asks `Update Omabump to <version>? [y/N]`, and on `y` fast-forwards the plugin's clone to the release tag, validates the plugin and reloads the shell's plugins. If that fails, the clone goes back to the installed commit and the old version stays. `omarchy restart shell` then loads the new panel code. Mute and skip work on this row too (`self:omabump`). [What it checks first, and the rollback](docs/internals.md#omabump-itself).

`omarchy plugin update io.github.vladkarok.omabump`, run by hand, still follows the repository's HEAD, which can be ahead of the release. A plugin directory that is a symlink or has no `.git` (a developer checkout) shows "Local checkout, update it with git" and no Update button.

## Remove

```sh
omarchy plugin remove io.github.vladkarok.omabump
```

That leaves the cache (the omarchy-pkgs clone, downloaded recipe sources, any failed build) and the state directory (the last check, which versions were announced). Remove them with:

```sh
rm -rf ~/.cache/omabump
rm -rf ~/.local/state/omarchy/plugins/io.github.vladkarok.omabump
rm -rf ~/.config/omarchy/omabump   # only if you created overrides
sudo rm -rf /var/cache/omabump     # only if a staged package failed its check or a stopped run left one
```

Packages Omabump installed stay installed; pacman manages them like any other.

## Internals

[docs/internals.md](docs/internals.md) has the rest: how checks and the local refresh are scheduled, exit codes, status.json, how CLI tools are found, each Update route in detail, the pinned omarchy-pkgs snapshot and its weekly watch, the security model, the hosts and GitHub API calls Omabump makes, every apps.json field, and how to run the tests.

## Tested on

Omarchy 4.0.0 r6692 (host and a lab VM), Quickshell 0.3.1, x86_64.

## License

MIT, see [LICENSE](LICENSE).

`assets/claude.svg`, `assets/codex.svg` and `assets/codex-light.svg` are copied from Omarchy's first-party Agents plugin, MIT licensed. The marks belong to their owners. The ZCode and T3 Code marks are plain letter shapes drawn for this plugin.

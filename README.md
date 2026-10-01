# Agent Apps

An Omarchy bar widget for the AI desktop apps. It shows the installed and the
newest version of each one, and on request builds the newest version locally.

The apps behind Omarchy's Install > AI menu come from the [omarchy] pacman
repo, built from the recipes in [omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs).
That repo notices a vendor release within hours, but the update waits for a
reviewed pull request, so the repo can lag the vendor by days. This plugin runs
the same recipe update on your machine, at the moment you press Update, so you
get the vendor's release built from Omarchy's own recipe until the repo catches
up. It never installs anything on its own.

![Agent Apps panel](preview.png)

## Install

```sh
omarchy plugin add https://github.com/vladkarok/omarchy-agent-apps --enable
```

Remove it with `omarchy plugin remove io.github.vladkarok.agent-apps`.

## Prerequisites

- `base-devel` (makepkg) and `git`
- `pacman-contrib` (`updpkgsums`, used for AUR apps)
- `jq`, `curl`, `python` 3.11 or newer, `libarchive` (`bsdtar`): what
  omarchy-pkgs' `bin/sync-upstream` needs
- sudo rights for `pacman -U`
- `mise`, optional, for apps you run through mise

## What Update runs

Update opens a floating terminal and runs `bin/agent-apps-install <pkg>`. It
executes packaging code you did not write on your machine: Omarchy's recipe
from omarchy-pkgs, or the AUR recipe for an app Omarchy does not package.
Before building, it prints the recipe diff, so you see exactly what changed in
Omarchy's recipe (normally `pkgver` and checksums). Read it before you type
your sudo password.

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

## What it shows

The bar icon turns the urgent colour when an app can be updated. Left click
opens the panel, middle or right click checks now. When a check fails for an
app, the tooltip says so and that row shows the error; the icon colour stays
normal.

The panel lists every catalog app that is installed (found with `pacman -Q`,
or `mise` for mise tools), with a source badge, the installed version, the
newest version when it is newer, a status line, and an Update button when the
plugin can build it. The footer shows the omarchy-pkgs commit used and when
the last check ran.

Keys: `j`/`k` or arrows select a row, `Enter` updates it, `r` checks now,
`Esc` closes.

| Package | App | Source |
|---|---|---|
| `claude-desktop` | Claude Desktop | omarchy |
| `openai-codex-desktop` | Codex (also found as AUR `chatgpt-desktop`) | omarchy |
| `t3code-bin` | T3 Code | omarchy |
| `hermes-desktop` | Hermes | omarchy, no Update yet |
| `grok-bot` | Grok | omarchy, no Update yet |
| `lmstudio-bin` | LM Studio | omarchy |
| `openclaw` | OpenClaw | omarchy |
| `perplexity` | Perplexity | omarchy |
| `voxtype-bin` | Dictation (voxtype) | omarchy |
| `z-code-bin` | ZCode | aur |

## How it works

### Omarchy-packaged apps

The plugin keeps a clone of omarchy-pkgs in
`~/.cache/agent-apps/omarchy-pkgs` and resets it to `origin/master` before
each use. The check runs `bin/sync-upstream <pkg>` there, which rewrites the
recipe only when the vendor has something newer, reads the resulting version,
and restores the recipe. Recipe policies apply as they do in the repo: a
`min_release_age` hold (openclaw, voxtype) keeps a fresh release back.

Update does the same sync, shows the diff, checks that the recipe builds the
expected package at a version newer than the installed one, builds it with
`makepkg` and installs it with `sudo pacman -U`. Sources, build files and
packages go to `~/.cache/agent-apps/{sources,build,packages}`, so the clone
stays clean and downloads are reused.

A recipe without an upstream watch (hermes-desktop, and grok-bot, which sets
`"sync": false`) cannot be moved this way. Those rows show the version from the
vendor feed in `apps.json` and no Update button. T3 Code's recipe hook
downloads both release AppImages to hash them, so the check asks its GitHub
releases instead and the hook only runs on Update.

### Other apps

- `aur`: Update clones the AUR package into `~/.cache/agent-apps/aur/`, sets
  `pkgver` to the feed's version, refreshes checksums with `updpkgsums`, shows
  the diff and builds it the same way.
- `mise`: Update runs `MISE_MINIMUM_RELEASE_AGE=0 mise up <tool>` and reports
  whether the active version now matches the feed.

`bin/agent-apps-check` writes
`~/.local/state/omarchy/plugins/io.github.vladkarok.agent-apps/status.json`.
The widget runs it on a timer and watches that file, so a run from a terminal
updates the panel too. `bin/agent-apps-install --dry-run <pkg>` does
everything up to the build and stops.

## Settings

- `refreshIntervalSec`: how often to check, default 900.
- `notify`: send a desktop notification when a newer version shows up,
  default on. Each version is announced once; announced versions are kept in
  `notified.json` next to `status.json`.

## Adding or changing apps

`~/.config/omarchy/agent-apps/apps.json` is merged over the shipped
`apps.json` by `pkg`: an entry with a new `pkg` adds an app, an entry with an
existing `pkg` overrides the fields it sets, and `"disabled": true` hides one.

```json
[
  { "pkg": "lmstudio-bin", "disabled": true },
  {
    "pkg": "my-app-bin",
    "label": "My App",
    "source": "aur",
    "feed": { "type": "github-release", "repo": "owner/my-app" }
  }
]
```

Fields:

- `pkg`: the omarchy-pkgs recipe name, or the AUR package for `aur`.
- `source`: `omarchy` or `aur`.
- `installed` (optional): package names to look for with `pacman -Q`, default
  `[pkg]`.
- `aur` (optional): the AUR package to build when it differs from `pkg`.
- `mise` (optional): a mise tool name. When mise has it, that copy is the one
  reported and Update runs `mise up`.
- `checkWith: "feed"` (optional, omarchy only): check with `feed` instead of
  running the recipe sync.
- `recipeRef` (optional, omarchy only): an omarchy-pkgs ref whose recipe is
  laid over origin/master before checking and building, for a package whose
  upstream watch is still in an unmerged PR (Grok Bot uses
  `refs/pull/725/head`). The panel row says so, and the install diff is shown
  against master, so the PR's changes are visible too. Drop the field once
  the PR merges.
- `feed`: where the newest version comes from for `aur` and `mise` apps, and
  the fallback for `omarchy` apps whose recipe cannot sync:
  - `apt-index` with `url` and `package`: a Debian `Packages` file, newest
    stanza for that exact package name.
  - `zcode-manifest` with `url`: YAML with `version:` on its own line.
  - `github-release` with `repo`: the tag behind `/releases/latest`, leading
    `v` stripped. No API calls, so no rate limit.
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

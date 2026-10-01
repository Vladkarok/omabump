# Agent Apps

An Omarchy bar widget that shows the installed and the newest vendor version
of the desktop apps for AI coding agents, and updates one when you ask.

The vendors publish Linux builds as .deb files or GitHub release assets. The
Arch repackaging (AUR, the [omarchy] repo) follows hours to days later. This
plugin reads the vendor feeds directly. It never installs anything on its own.

![Agent Apps panel](preview.png)

## Install

```sh
omarchy plugin add https://github.com/vladkarok/omarchy-agent-apps --enable
```

Remove it with `omarchy plugin remove io.github.vladkarok.agent-apps`.

## What it shows

The bar icon turns the urgent colour when any app has a newer vendor version.
Left click opens the panel, middle or right click checks now.

The panel lists every tracked app that is installed: its mark, the installed
version, the vendor version when it is newer, and an Update button. Apps that
are not installed are skipped and show up once they are.

Keys: `j`/`k` or arrows select a row, `Enter` updates it, `r` checks now,
`Esc` closes.

| Package | App | Feed |
|---|---|---|
| `claude-desktop` | Claude Desktop | Anthropic apt index |
| `chatgpt-desktop` | Codex (ChatGPT app) | OpenAI apt index |
| `z-code-bin` | ZCode | ZCode's own updater manifest, stable channel |
| `t3code-bin` | T3 Code | GitHub releases of `pingdotgg/t3code` |

## Settings

- `refreshIntervalSec`: how often to check, default 900.
- `notify`: send a desktop notification when a vendor publishes a version
  newer than the installed one, default on. Each new version is announced
  once.

## How it works

`bin/agent-apps-check` reads the app table, asks each feed for its newest
version, compares it with `pacman -Q` using `vercmp`, and writes
`~/.local/state/omarchy/plugins/io.github.vladkarok.agent-apps/status.json`.
The widget runs it on a timer and watches that file, so running the script
from a terminal updates the panel too.

Update opens a floating Omarchy terminal running `bin/agent-apps-install <pkg>`.
It clones the AUR package into `~/.cache/agent-apps/`, sets `pkgver` to the
vendor version, refreshes checksums with `updpkgsums`, builds with `makepkg`,
and installs with `sudo pacman -U`. When the AUR package has a different name
from the installed one (`herdr-bin` replacing `herdr`), pacman asks about the
conflict in that terminal. Restart the app afterwards.

## Adding an app

Copy `apps.json` to `~/.config/omarchy/agent-apps/apps.json` and edit it. When
that file exists it replaces the shipped table. Each entry:

```json
{
  "pkg": "my-app-bin",
  "label": "My App",
  "feed": { "type": "github-release", "repo": "owner/my-app" },
  "aur": "my-app-bin",
  "icon": "/home/me/.local/share/icons/my-app.svg"
}
```

- `mise`: optional mise tool name. When mise has it installed, the installed
  version comes from mise and Update runs `mise up <tool>`; `pkg`/`aur` are
  then only a fallback for machines without the mise install.
- `pkg`: the installed package name. `aur` is the AUR package to build when it
  differs.
- `feed.type`:
  - `apt-index` with `url`: a Debian `Packages` file, highest `Version:` wins.
  - `zcode-manifest` with `url`: YAML with `version:` on the first line.
  - `github-release` with `repo`: the tag behind `/releases/latest`, leading
    `v` stripped. No API calls, so no rate limit.
  - `command` with `command`: any shell command that prints the version.
- `icon` and `iconLight` (optional): SVG marks for dark and light themes. A
  relative path is relative to the plugin folder. Without one the row shows a
  terminal glyph.

The install step works for AUR packages whose PKGBUILD only needs `pkgver`
changed to fetch a new release, which is the case for the repackaged
.deb/AppImage/binary packages above.

## Attribution

`assets/claude.svg`, `assets/codex.svg` and `assets/codex-light.svg` are copied
from Omarchy's first-party Agents plugin
(`/usr/share/omarchy/shell/plugins/agents/assets/`), MIT licensed. The marks
belong to their owners. The ZCode and T3 Code marks are plain letter shapes
drawn for this plugin.

## License

MIT

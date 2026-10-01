# Changelog

## 0.1.0 (unreleased)

First release, formerly Agent Apps.

- Bar widget and panel for installed agent desktop apps and the agent CLIs mise manages: installed and newest version, update count, notifications once per new version, settings and keyboard control inside the panel.
- Background check (`bin/omabump-check`) that reads each app's newest version from the vendor's own feed (apt index, GitHub release redirect, JSON, update manifest, AUR RPC) and never executes fetched code.
- Three Update routes, run in a visible terminal by `bin/omabump-install`:
  - omarchy: Omarchy's own recipe from omarchy-pkgs, synced to the vendor's
    release with omarchy-pkgs' `bin/sync-upstream`, built with makepkg and
    installed with `sudo pacman -U`. The recipe comes from a pinned 40-hex
    omarchy-pkgs commit (`pins.json`) checked out detached; following master
    is an explicit user opt-in.
  - vendor: the vendor's Arch package, verified against the sha512 in the
    vendor's update manifest before `pacman -U`.
  - mise: `mise up <tool>`, under the same request and cooldown the check
    used.
- Switch from an AUR package name (`chatgpt-desktop`, `z-code-bin`) to the canonical package, with both install scripts printed first.
- Ask agent for rows without an install route: a plan-first prompt for the default agent, or copied to the clipboard.
- User overrides in `~/.config/omarchy/omabump/apps.json` and `pins.json`.
- `--prepare` dry run, uncompressed local builds, and cache cleanup after a successful install.

Hardening before release:

- `command` feeds run only from the user's `~/.config/omarchy/omabump/apps.json`; one in the shipped `apps.json` is refused, and the tests assert the shipped file has none.
- Text written to `status.json` and notifications has control characters removed and `<`/`>` replaced. The scripts run under `LC_ALL=C.UTF-8` (`C` without it).
- The check holds the omarchy-pkgs clone lock only while it fetches; an install in progress no longer blocks it, and the check still reports the clone as busy when an install holds the lock at fetch time.
- A feed listing the vendor package both by name and by exact url no longer yields two digests and a failed checksum.
- `tests/run.sh` (plain bash, no network) and a CI workflow running `bash -n`, `jq`, shellcheck and the tests.
- pacman always asks before it installs: neither `pacman -U` passes `--noconfirm`. The verified package is copied into the root-owned `/var/cache/omabump`, checked again there and installed from that copy, so it cannot be swapped between verification and install. `--prepare` prints these steps and calls no sudo.
- `bin/sync-upstream` and its hooks run with an HTTPS-only `.curlrc` (`CURL_HOME`), `TMPDIR` under the cache and without the release-age bypass variables; makepkg runs with a generated config whose `DLAGENTS` allow only HTTPS, with time and size limits.
- `mise outdated` is asked about the listed, installed tools only; `MISE_HIDE_UPDATE_WARNING=1` for every mise call.
- Limits: feeds are capped at 8 MB and the vendor package at 4 GB, apt indexes count at most 500 matching stanzas and validate each version before `vercmp`, versions must start with a letter or digit, hold no `..` and stay within 64 characters (`full_version_ok` for pacman versions), and the shell runs the check under `timeout -k 10 600`.
- Package, installed, mise tool and git ref names from `apps.json` and `pins.json` are validated; bad entries are dropped with a message, and refs reach `git fetch` after `--`.
- git runs without hooks, fsmonitor, automatic gc or maintenance and with the `https` protocol only. The omarchy-pkgs clone fetches the pinned commit by SHA into an empty repo and is made again when its origin differs. Children (git, mise, sync-upstream, makepkg, sudo, command feeds) do not inherit the lock fds.
- Install scripts and the recipe diff shown before pacman have terminal escapes neutralised; the diff is printed without colour.
- The panel clamps the interval to 60 s to 1 day, throttles IPC `refresh` to once a minute, and loads icons only from the plugin directory.
- `&` in status text is replaced for notify-send markup, and large JSON reaches jq through `--slurpfile` instead of the command line.
- The README states each guarantee exactly: what the background check runs (mise backends, your own command feeds), where HTTPS-only applies, that a checksum proves integrity and not vendor authenticity, and where Omabump and the tools it runs write.

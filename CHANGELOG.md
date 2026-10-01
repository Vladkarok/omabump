# Changelog

## 0.1.0 (unreleased)

First release, formerly Agent Apps.

- Bar widget and panel for installed agent desktop apps and the agent CLIs
  mise manages: installed and newest version, update count, notifications
  once per new version, settings and keyboard control inside the panel.
- Background check (`bin/omabump-check`) that reads each app's newest
  version from the vendor's own feed (apt index, GitHub release redirect,
  JSON, update manifest, AUR RPC) and never executes fetched code.
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
- Switch from an AUR package name (`chatgpt-desktop`, `z-code-bin`) to the
  canonical package, with both install scripts printed first.
- Ask agent for rows without an install route: a plan-first prompt for the
  default agent, or copied to the clipboard.
- User overrides in `~/.config/omarchy/omabump/apps.json` and `pins.json`.
- `--prepare` dry run, uncompressed local builds, and cache cleanup after a
  successful install.

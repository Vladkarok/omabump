# Changelog

## 0.1.3 (2026-10-10)

- The panel reads the shell palette as `Commons.Color`. qt6-declarative 6.12 ships a QtQuick `Color` type that shadows the Omarchy shell's palette singleton, so the panel background and the accent resolved to undefined and the shell log said "Unable to assign [undefined] to QColor". Same fix as Omarchy's own plugins (basecamp/omarchy#14553).

## 0.1.2 (2026-10-08)

Worth knowing before you update:

- The default check interval is one hour (was 15 minutes). A setting you chose stays.
- Agent CLIs: mise runs with `MISE_MINIMUM_RELEASE_AGE=0` in the check and in Update, as Omarchy's own wrappers and `omarchy update` do, so a new release shows and installs at once instead of after mise's cooldown.
- Skip is Shift+K only; with CapsLock on, `j` and `k` move the cursor.
- `bin/omabump-check` exits 75 when it ran no check: without `--wait` when another check holds the lock (it used to exit 0), with `--wait` when its wait passes 11 minutes. One line on stderr says so.
- status.json has `"schemaVersion": 1`, and a row's `note` no longer carries "Installed as X, switch to Y": that comes from `installedName`, `switchable`, `updateAvailable` and `installable`. An older file is read as before until the next check rewrites it.

A failed check never reads as current:

- A `mise outdated` that failed without an error message (killed by its timeout) aborted the whole check, and an Update of a mise row stopped without a word. It is now a failed check for the mise rows only.
- A failing `mise ls` (a broken mise config) emptied the CLI section and the summary said "All current". The last known CLI rows stay, marked as failed, and the panel says why.
- Offline or rate limited, `mise outdated` exits 0 and leaves the tool out, so the row read as current. mise's warning now makes it a failed check that keeps the last known version, and a pending CLI update keeps counting.
- A check that stops part way (killed, Ctrl-C, closed terminal) writes `runError` into status.json, and every bar reads it as failed, not only the one that started it. A TERM to the check's process group, as the shell's `timeout` sends it, stops a running git, mise or feed command at once, and rows are never left "checking".
- "Hide icon until an update" no longer hides a failed check. A muted row's failed check stays on its row and in the tooltip, and no longer makes the header or bar read as failed.
- A malformed `pins.json` is a pin error on the omarchy rows instead of stopping every check and install. A recipe file the blob-less clone cannot download is a check error, not "no recipe". An odd entry in mise's answer is a row error, not a crash.

Versions:

- apt indexes: a version with a Debian revision or epoch (`2.0-1`, `1:2.0`) was skipped, so an older one could read as newest, and only the first (oldest) 500 matching stanzas counted; now revisions and epochs compare and the last 500 count. A hyphenated pre-release (`2.0.0-beta1`) is still not taken for the release.
- openclaw and voxtype hold new releases for 24 h in omarchy-pkgs (`min_release_age`), and Update failed with "nothing to do" until then. Such a row says from when Update works, and notifies then.
- A pinned mise row shows the real newest release, not mise's rewritten request.
- Feeds: a regex that matched nothing, a JSON path with several values, an empty body or several JSON documents are plain errors, not the version "None", two versions run together or a bash arithmetic error. CRLF update manifests work.

Refresh and the panel:

- A check you ask for while one runs is no longer dropped: a check that starts after your request answers it. A Refresh that waited over 11 minutes behind another check says "Check not run". The widget waits for a running check only before its 10-minute deadline, and a run that merely found the lock taken no longer clears an error.
- A shell reload or a second monitor no longer starts a check when one ran within the interval, and on two monitors a Show mise tools change or a Refresh during a check runs one check after it, not one per bar.
- Turning Show mise tools on or off while another check runs gets a check after it. Notify and Show mise tools apply to checks started from a terminal or by the installer too.
- Settings stored as strings (`omarchy bar set ... notify false` without `--json`) read as booleans everywhere; the toggles and the checker used to disagree. The interval picker keeps following the setting.
- A skip ends once that version or a later one is installed, and the settings list only skips that still apply. The panel applies mutes and skips by the checker's rules. Clear removes only what it lists. The header shows "(+N muted/skipped)" like the tooltip.
- A row with no Update says so, and why, in its tooltip. The selected row scrolls into view. IPC open, toggle and settings open the panel on the focused monitor. Ask agent starts the agent through `omarchy-agent-prompt`. Dimmed text is dimmer than normal text on light themes too.
- Rows are built only while the panel shows, and a status write that changes no row rebuilds nothing.

Agent discovery:

- Wrappers are read line by line, not as one byte-exact template, and an `@version` (also one holding a colon) is dropped from the key.
- The "wrapper not recognised" warning appears only for a file that runs mise but cannot be read. Discovery reads such a file as shell: another installer's launcher, your own script, `mise` in an `echo` string, a comment or a here-document's body, and a disabled row stay silent, while mise after `&&`, `env`, `sudo -E`, `nice`, `timeout` or a runner given by path counts.
- A deeply nested menu, or a menu with no agent entries (Omarchy renamed its ids), is reported instead of crashing or silently listing none. A long line of flags no longer stalls discovery.
- Omabump's disabled mise backends include yours (`MISE_DISABLE_BACKENDS`, `disable_backends`). Update asks mise only about its own tool.
- AUR rows installed from the AUR say "Updates with omarchy update (AUR)" and offer no Ask agent: `omarchy update` runs `yay -Sua`.

Update:

- The staged copy in `/var/cache/omabump` is read by you and written by root from a file checked to be regular, so a swapped-in symlink or device cannot make root copy a file you cannot read or an endless stream. On the omarchy route it is checked against the sha256 of the package makepkg built.
- makepkg no longer installs missing build dependencies with `--noconfirm`: pacman asks for those too.
- Answering n at pacman's prompt says so, removes the staged copy and keeps the verified package for a retry. A hook failing after the install is reported as done with a warning.
- A run stopped before pacman starts removes its staged copy. A run stopped while pacman runs leaves the copy to pacman, records it and prints the `sudo rm` to run; the next Update of that app removes recorded copies first, and nothing is staged while pacman's lock file exists.
- The refresh after an Update waits for a running check instead of being skipped, so the panel no longer offers the update just installed.
- Switch, and Update replacing a package installed under another name, read the declared conflict from the recipe before building. `pacman -Qi` runs with `COLUMNS` unset, so a wrapped Provides or Conflicts line no longer hides a name.
- A self update that fails or is stopped part way rolls back fully, waits for git first, cannot be cut short by a second Ctrl-C or a closed terminal, and says whether the rollback worked. Afterwards it asks you to restart the shell, since a plugin reload can keep the old panel code.
- A `url.*.insteadOf` rule for github.com in your git config made every check re-create the omarchy-pkgs clone, and the omarchy route never worked. The clone ignores your and the system's git config, except `http.*` (proxy, CA bundle).
- After a successful omarchy install, the sources that recipe downloaded are removed; the old name-prefix guess could remove another recipe's files. Checks remove day-old scratch files a killed Update or an older release left.
- Names in `apps.json` ending in a newline are dropped (jq's `$` matched before it).

Development:

- The widget's logic moved into `Model.js`, tested with node; `vercmp` is checked against a table taken from `/usr/bin/vercmp`. tests/run.sh runs every suite (723 tests, whole checks and installs against fake tools) and reports every failure. CI installs node, pins shellcheck, has job timeouts, and a release tag must match `manifest.json` and have a CHANGELOG entry.
- README: install and usage come first, the security model states exactly what each guarantee covers, own icons go in `assets/user/` (ignored by git, so they do not block self-update), and an Omarchy channel switch is noted to put repo versions back.

## 0.1.1 (2026-10-02)

- Agent CLIs are discovered instead of listed by hand. Omarchy's migration 1790863209 moved Grok CLI from `npm:@xai-official/grok` to mise's first-party `grok`, and the row disappeared because its key was not in `apps.json`; Copilot CLI, Cursor CLI, Pi, Oh My Pi and Ori were never there. `bin/omabump-discover` now reads Omarchy's agent menu (stock and your extension) and each agent's `omarchy-mise-install` wrapper, as text, and takes the mise key from the wrapper. Known agents keep their shipped name and icon (new `command` field), new ones get a row with the menu's label, disabled rows stay hidden.
- `mise outdated` is asked only about the key each row resolved to, and only on mise's own backends (`mise ls --backend`); a tool on asdf, vfox or another plugin backend shows "Update check skipped" and has no Update.
- A failed `mise outdated --bump` call is a check failure; it used to be ignored, and the row could read as current.
- The app table is built once per run, so the check, the mise queries and the installer see the same rows.
- The panel footer and the bar tooltip say when agent discovery failed, when the discovered agents could not be merged, and when a wrapper script exists but no longer matches Omarchy's template. A missing wrapper, a symlink or a binary in its place stays silent.
- Disabling `mise:<command>` or the shipped row with that `command` hides the agent everywhere: `mise:grok` and `mise:grok-cli` both hide Grok CLI.
- A failed merge of the discovered agents keeps the shipped and user rows. Discovered agents and the mise inventory reach jq as files, so a large one no longer empties the table or the mise selection, and a failed selection is a check failure.
- Table entries need one of the sources `omarchy`, `vendor-pkg`, `mise` or `indicator`.
- Discovery hardening: menus open without blocking and must be regular files owned by you or root, menu ids match whole, labels lose control and format characters and stop at 64 characters, at most 64 agents. Python helpers run with `-I`. The installer prints labels through the terminal filter.
- Every mise call runs with `MISE_DISABLE_BACKENDS` set to asdf, vfox and every installed plugin by name (a vfox backend plugin is disabled by its own name), so no plugin script runs during a check or an update. The checked backends are aqua, github, gitlab, forgejo, npm, http, ubi, pipx and cargo, listed in one `mise ls` call.
- CLI tools whose update check was skipped count as unchecked: the summary says "All checked current, N unchecked" instead of "All current", muted or not.
- Mute a row (`m`): it stays in the list, dimmed, with no badge, count or notification until unmuted; Update still works. Stored in the widget setting `mutedApps`.
- Skip a version (`K`): that version stops counting and notifying; a newer one lights the row up again and is announced once. Stored in `skippedVersions`. pacman and feed versions compare with `vercmp`, mise and Omabump's own versions as exact strings, for skips and for notifications alike.
- The checker reads `mutedApps` and `skippedVersions` from `shell.json` itself, so a check from a terminal or after an Update honours them too.
- Omabump checks its own GitHub release, since `omarchy update` does not update plugins. A newer one, or a failed check, shows in a PLUGIN section. Update fetches the release tag into the plugin's clone, prints its log and diffstat, asks, then checks the clone did not change while it waited, fast-forwards to the tagged commit and validates it, rolling back to the previous commit on failure. A symlinked or non-git checkout says "Local checkout, update it with git".

## 0.1.0 (2026-10-01)

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

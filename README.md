# Omabump

Agent desktop apps and CLIs at the version the vendor shipped, ahead of the Omarchy repo.

![Omabump panel](preview.png)

An Omarchy bar widget. It lists the agent desktop apps and agent CLIs installed on this machine, the installed and the newest version of each, and installs the newest version in a terminal when you press Update. It never installs anything on its own. The project was previously called Agent Apps.

## Prerequisites

- `base-devel` (makepkg, sudo) and `git`
- `jq`, `curl`, `python` 3.11 or newer, `libarchive` (`bsdtar`): what omarchy-pkgs' `bin/sync-upstream` needs
- sudo rights for `pacman -U`
- `mise`, optional, for the agent CLIs

When something is missing, omarchy rows have no Update button and say what to install, for example "Missing: makepkg, jq; sudo pacman -S --needed base-devel jq".

## Install

```sh
omarchy plugin add https://github.com/vladkarok/omabump.git --enable
```

`omarchy plugin add` asks for confirmation; from a script pass `--yes`.

The widget lands in the bar's right section. Move it with `omarchy bar move io.github.vladkarok.omabump --section center --index 0` (sections: left, center, right).

## Using it

The bar icon turns the urgent colour when an app can be updated. Left click opens the panel, middle or right click checks now. The tooltip and the panel header say one of: all current, N updates, check failed, last known (rows that keep an earlier run's version because this run could not get one), or "All checked current, N unchecked" (CLI tools whose update check was skipped, see How CLI tools are found), plus "(+N muted/skipped)" when quiet rows have updates. A failed or skipped check never reads as up to date; the one exception is a row you muted (see Mute). A check that stopped part way, killed or interrupted, says so in every bar, whoever started it.

A check you ask for (click, `r`, IPC `refresh`) is never lost: while one runs, yours runs after it. The timer's own check skips while any check runs.

The panel has three sections: Desktop apps, CLI tools and Plugin (Omabump itself, only while it has an update or its check failed, see Updating Omabump). Apps are found with `pacman -Q` (exact package names) and CLIs with `mise ls`. A row shows the installed version, or `installed → newest` when there is an update. A second line appears only for an exception: a pin, a recipe from an open omarchy-pkgs PR, another package name, a failed check, no install route. The row's tooltip says where the version came from and what Update runs, or why there is no Update.

### Keys

Arrows or `j` and `k` select a row, `Enter` updates it (or asks the agent on a row without Update), `w` switches the package, `c` copies the agent prompt, `m` mutes or unmutes the row, `K` skips or unskips its newest version, `r` checks now, `s` opens the settings, `Esc` closes.

IPC: `omarchy-shell io.github.vladkarok.omabump status|open|close|toggle|refresh|settings`. `status` counts what the bar counts, including unchecked rows, and adds "(+N muted/skipped)" when quiet rows have updates, with "check failed for N muted apps" inside it when muted rows failed. `refresh` answers `throttled` and starts nothing while this bar's own Refresh check runs or within a minute after its last check ended; during another bar's or a terminal's check it waits for that one and then checks. The check interval is kept between 60 seconds and a day.

### Settings

The gear in the panel header (or `s`) opens the settings: check interval (an hour by default), show mise tools, bar icon only when updates exist (it also shows while a check fails), notify on new releases. Each new version is announced once.

![Omabump settings](docs/settings.png)

The scripted equivalent:

```sh
omarchy bar set io.github.vladkarok.omabump <key> <value> --json
```

with the keys `refreshIntervalSec` (seconds), `showMise`, `barIconOnlyWithUpdates` and `notify`. Without `--json` the value is stored as a string; `"true"` and `"false"` are read as booleans.

### Mute

Mute (`m`, or the 󰖁 button on the row under the cursor) keeps a row in the list, dimmed with the same glyph after its name, and takes it out of every signal: no badge, no update count, no urgent icon, no reason to show the bar icon when it is hidden until an update, no notification. A muted row's failed check shows only on the row itself ("Check failed: ...") and in the tooltip and IPC status ("check failed for N muted apps"), not in the header or the bar; an omarchy-pkgs or mise failure that only muted rows share does not fail the check. Its update stays visible and Update and Enter still work. Mute again to undo, or Clear in the settings, which list the muted rows the last check showed (a mute for a row hidden by Show mise tools is kept, not listed). The list is the widget setting `mutedApps`, an array of row ids (`pkg`), set with `omarchy bar set io.github.vladkarok.omabump mutedApps '["mise:grok-cli"]' --json`.

### Skip a version

On a row with an update, Skip (`K`, Shift+k since `k` moves the cursor, or the 󰒭 button) silences that one version the same way: the row shows `installed → newest skipped`, dimmed, and Update still works. When a newer version than the skipped one appears, or that version or a later one is installed, the skip no longer applies: the row counts and notifies again (once) for a newer release, the settings stop listing the skip, and it is dropped the next time the panel writes a setting. A skip on a row the last check could not judge (failed, stale, still checking, unchecked or not listed) is kept. pacman and feed versions are compared with `vercmp`, so a feed that rolls back below the skipped version stays skipped; mise and Omabump's own versions must match exactly, so `1.0.0` after a skipped `1.0.0-beta.1` is new. Skip again to undo. The setting is `skippedVersions`, an object of row id to version: `omarchy bar set io.github.vladkarok.omabump skippedVersions '{"grok-bot": "0.66.0"}' --json`.

Omarchy's settings schema has no array or object type, so `mutedApps` and `skippedVersions` appear only in the panel's own settings (one line, with Clear), not in the bar's widget settings.

Mute, skip, Notify and Show mise tools apply to every check, whoever starts it: the shell's timer, `bin/omabump-check` in a terminal, or the refresh after an Update. The checker reads them itself from the widget's entry in `~/.config/omarchy/shell.json` (in `bar.layout` or the top-level `plugins` list), up to 1 MiB of file and 200 entries each; an id or version it does not accept is ignored with a line in the shell log. `--no-notify` and `--no-mise` still win.

## Supported apps

| Package | App | Route |
|---|---|---|
| `claude-desktop` | Claude Desktop | omarchy |
| `openai-codex-desktop` | Codex (also found as AUR `chatgpt-desktop`) | omarchy |
| `t3code-bin` | T3 Code | omarchy |
| `hermes-desktop` | Hermes | omarchy, no Update until the recipe has an upstream watch |
| `grok-bot` | Grok | omarchy, recipe from omarchy-pkgs PR #725 |
| `lmstudio-bin` | LM Studio | omarchy |
| `openclaw` | OpenClaw | omarchy |
| `perplexity` | Perplexity | omarchy |
| `voxtype-bin` | Dictation (voxtype) | omarchy |
| `zcode` | ZCode (also found as AUR `z-code-bin`) | vendor |
| `antigravity` | Antigravity (or `antigravity-appimage`) | indicator, version from the AUR; `omarchy update` updates it |
| `antigravity-ide` | Antigravity IDE | indicator, version from the AUR; `omarchy update` updates it |
| `kimi-bin` | Kimi | indicator, version from Moonshot's update feed |
| `trae-bin` | Trae | indicator, version from the AUR; `omarchy update` updates it |

mise tools, listed when mise has them installed and active: every coding agent Omarchy offers (Claude Code, Codex CLI, Crush, OpenCode, Grok CLI, Copilot CLI, Cursor CLI, Pi, Oh My Pi, Ori, Antigravity CLI, Muse Code and whatever Omarchy adds later, see How CLI tools are found), plus Gemini CLI, Jules, Qwen Code, Kimi CLI, Amp and herdr.

### How CLI tools are found

Omarchy lists its coding agents in its menu, as the entries `setup.default.agent.<command>` of `/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc` and of your `~/.config/omarchy/extensions/omarchy-menu.jsonc`, and installs each one on first use through `omarchy-mise-install`, which writes `~/.local/bin/<command>`:

```sh
#!/bin/bash
export MISE_MINIMUM_RELEASE_AGE=0
mise use -g --quiet "<package>" || exit 1
exec mise x "<package>" -- "<bin>" "$@"
```

Every check, `bin/omabump-discover` reads both as text. A menu may be a symlink, but what it opens must be a regular file owned by you or root, at most 4 MiB; it is opened without blocking, so a FIFO cannot stall the check. Of a menu entry it uses the command and the label, never `action`, `when` or `checked`; a label loses control and format characters (bidi overrides, zero-width) and stops at 64 characters, and at most 64 agents are listed. A wrapper counts only when it is a regular file you own (not a symlink), at most 4 KiB, UTF-8, and its quoted package and binary names hold no `$`, backtick, `\`, `"`, `!` or control character; it is opened, never run or sourced. It is read line by line: the bash shebang, exactly one `mise use -g [flags] "<package>"` line (optionally `|| exit 1`; only flags without a value, such as `--quiet`, `--yes`, `--force`, `--pin`), then exactly one `exec mise x "<package>" -- "<bin>" "$@"` line (or `mise exec`) with the same package; `export NAME=VALUE` lines, comments and blank lines may sit between them. The package, without a trailing `[options]` suffix (`http:muse[url=...]` is `http:muse`) or `@version` (`npm:@scope/name@1.2.3` is `npm:@scope/name`), is the key `mise ls` reports. Without such a wrapper the command itself is the key, used only when mise has exactly that tool installed and active. So when Omarchy moves an agent to another mise package, the row follows it, as long as Omarchy keeps its menu ids and a wrapper of that shape. A file there that runs mise but is not a wrapper Omabump can read is not trusted: the row falls back to the command name and the panel footer shows "Agent discovery: wrapper ~/.local/bin/<command> not recognised: <reason>", so a changed template is visible instead of a row quietly going missing. A file that does not run mise (another installer's launcher, your own script), a missing file, a symlink or a binary stays silent, and so does any command whose row you disabled. A menu nested too deeply to read, or a stock menu with no `setup.default.agent.<command>` entry at all (Omarchy renamed its ids), is a discovery error in the footer.

A discovered agent joins the shipped row whose `command` is its command or whose `tool` list holds its key, which keeps the shipped name and icon; otherwise it gets a row `mise:<command>` with the menu's label. Disabling either name in your `apps.json` hides the agent for good: `{"pkg": "mise:grok", "disabled": true}` and `{"pkg": "mise:grok-cli", "disabled": true}` both hide Grok CLI, the shipped row included. When the menu cannot be read, or the discovered agents cannot be merged, the panel footer says why ("Agent discovery: ...") and the shipped rows still show.

Every mise call Omabump makes, in the check and in Update, runs with `MISE_DISABLE_BACKENDS` set to `asdf`, `vfox` and the name of every plugin in mise's plugins directory (a vfox backend plugin is disabled by its own name), plus the backends you disabled yourself (your `MISE_DISABLE_BACKENDS` and mise's `disable_backends` setting, read once per run with `mise settings get`), so no plugin script runs while mise resolves your config; `mise ls` still lists such a tool. `mise outdated` is asked only about the key each row resolved to, and only when one `mise ls --backend` call puts it on a backend agent CLIs ship on: aqua, github, gitlab, forgejo, npm, http, ubi, pipx, cargo. A tool on any other backend (asdf, vfox, another plugin, or mise's core, go and gem) shows its installed version and "Update check skipped", has no Update button and counts as unchecked in the summary. When `mise ls` fails (a broken mise config), or `mise outdated` cannot fetch a tool's versions (offline, rate limited; mise still exits 0 then), the rows keep the last known version and the check reads as failed.

## How Update works

Update opens a floating terminal and runs `bin/omabump-install <pkg>`. The row's route decides what happens.

**omarchy.** The apps behind Omarchy's Install > AI menu come from the [omarchy] pacman repo, built from the recipes in [omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs). That repo notices a vendor release within hours, but the update waits for a reviewed pull request, so the repo can lag the vendor by days. Update checks out the pinned omarchy-pkgs commit (see Pinned snapshots) detached in `~/.cache/omabump/omarchy-pkgs`, runs its `bin/sync-upstream <pkg>`, prints the recipe diff (normally `pkgver` and checksums), checks that the recipe builds the expected package at a full version newer than the installed one, builds it with `makepkg` and installs it with `sudo pacman -U`. The sync tool and the recipe's hook have run by the time the diff shows, so read the diff as a record. pacman asks before it installs; that prompt is the point where you can still stop.

A recipe may hold new releases for a while (`min_release_age`; openclaw and voxtype: 24 h), and `bin/sync-upstream` does not move it to a younger release. Such a row shows the update, without an Update button or a notification, and says from when Update works. A feed gives no release date, so the wait counts from the first check that saw the version.

A local build says `Packager: Unknown Packager` in `pacman -Qi`. pacman replaces it with the repo package once the repo's full version is higher, and `sudo pacman -S <pkg>` puts the repo package back at any time. Switching Omarchy's channel (`omarchy channel set`) runs `pacman -Syyuu --noconfirm`, which also puts the repo's older version back, without asking.

**vendor.** The vendor publishes a ready Arch package (ZCode does). `apps.json` gives its URL and a feed for the newest version. Update refuses unless the feed's version is newer than the installed one, downloads the file over HTTPS, and verifies it against the sha512 the vendor lists for that exact file in its update manifest. It refuses if the manifest has no checksum for the file, and deletes a file that does not match. Then `pacman -Qp` checks the package name and full version, the installed version is read again, and only then is the file staged and installed with `sudo pacman -U`, after pacman asks. pacman does not fetch the URL itself because it would check a remote file against `SigLevel = Required`, and the vendor does not sign the package.

**mise.** Update runs `mise up <tool>` in `$HOME`, with asdf and vfox disabled. The check asked `mise outdated` what that command can reach, so the configured request applies to both. Both run with `MISE_MINIMUM_RELEASE_AGE=0`, as Omarchy's own agent wrappers and `omarchy update` do, so an agent CLI's new release shows and installs at once. A tool pinned below the newest release shows "Pinned to 0.96, 0.97.1 exists" (the newest release itself, not mise's rewritten request) and no Update button. Omabump passes `mise outdated` only the key each row resolved to, on the allowed backends, never every tool in your mise config, and Update asks only about its own tool (see How CLI tools are found).

**Omabump itself.** See Updating Omabump: a fast-forward to the release tag after you read the log and answer y.

**indicator.** No Update button. These rows show the installed and newest version. Update them the way you installed them: an AUR row installed from the AUR says "Updates with omarchy update (AUR)", since `omarchy update` runs `yay -Sua`, and has no Ask agent.

**Switch.** Codex may be installed as the AUR's `chatgpt-desktop` and ZCode as `z-code-bin`. When the canonical package has the same or a newer version, the row offers Switch (`w`), which runs `omabump-install --switch <pkg>`. It checks that one package declares a conflict with the other, prints both packages' install scripts and the app's config directory, and lets pacman ask before removing the old package. On omarchy rows the conflict is read from the recipe (`makepkg --printsrcinfo`, this machine's architecture included) before makepkg builds, so a switch that would be refused costs no build, and it is checked again on the built package. The same holds for Update when it replaces a package installed under another name.

**Ask agent.** A row with a newer version but no Update button has Ask agent (`Enter`) and Copy prompt (`c`). Ask agent opens your default agent (`omarchy default agent <name>`) with a prompt that asks for a plan and your approval before changing anything. `omarchy-agent` starts most agents without their own approval prompts (Claude Code in auto mode, Codex with `--approve-for-me`, Antigravity with `--dangerously-skip-permissions`), so that approval step is a request to the agent, not a gate. With no default agent set it copies the prompt instead.

`bin/omabump-install --prepare <pkg>` goes as far as it can without installing: on omarchy rows it syncs the recipe and stops before makepkg builds; on vendor rows it downloads and verifies the package and stops before `pacman -U`.

## Updating Omabump

`omarchy update` updates Omarchy and your packages, not plugins. So Omabump checks its own GitHub release too: the panel shows a PLUGIN section with an Omabump row while a newer release exists or that check failed, and hides it while Omabump is current. Update installs the release the row names, in a terminal: in the plugin's own clone it checks that `origin` is `https://github.com/vladkarok/omabump` and that there are no local changes, fetches the tag `v<version>` and nothing else, and requires the tagged commit to be a fast-forward of the installed one. It prints that commit, the commits since the installed one and a diffstat, then asks `Update Omabump to <version>? [y/N]`. On `y` it fast-forwards to the tagged commit, validates the plugin with `omarchy-plugin-validate` and reloads the shell's plugins. If the fast-forward fails part way, the validation fails, or the run is stopped (Ctrl-C, closing the terminal) before the validation passes, it waits for the running git step, resets the clone to the installed commit, removes what the merge created, and says whether that worked (if not, it prints the `git reset --hard` to run); `omarchy restart shell` then loads the new panel code. `omabump-install --prepare self:omabump` stops before the question. `omarchy plugin update io.github.vladkarok.omabump`, run by hand, still follows the repository's HEAD, which can be ahead of the release. A plugin directory that is a symlink or has no `.git` (a developer checkout) shows "Local checkout, update it with git" and no Update button. Mute and skip work on this row too (`self:omabump`).

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

Fields:

- `pkg`: the omarchy-pkgs recipe name, or the package name the vendor's package installs as. Any unique id for mise entries (`mise:<name>`).
- `source`: `omarchy`, `vendor-pkg`, `mise` or `indicator`; an entry with any other source (`self` is Omabump's own row) is dropped.
- `installed` (optional): package names to look for with `pacman -Q`, default `[pkg]`.
- `tool` (mise only): the mise tool name, or a list of names; the first one mise has active is used. Setting it in your file replaces the list, and discovery then leaves it alone.
- `command` (mise only, optional): the command Omarchy's agent menu uses for the tool (`grok`, `agy`, `omp`), so a discovered agent joins this row. Disabling the row disables the command: no discovered row comes back for it.
- `vendorPkg` (vendor-pkg): HTTPS package URL per architecture (`uname -m`), with `{version}` replaced by the feed's version.
- `checksum` (vendor-pkg, required for Update): `"feed"` reads the base64 `sha512` listed next to the file's `url` in the feed document (electron-updater's `latest.yml` format, as ZCode's manifest uses), or `{"url": ..., "algo": "sha256"|"sha512"}` reads a `sha256sum`-style list.
- `recipeCommit` (optional, omarchy): a 40-hex omarchy-pkgs commit whose recipe tree replaces the pinned one, for a package whose upstream watch is still in an unmerged PR. `recipeFetch` names a ref to fetch it from and `recipeNote` is the text the row shows. Once the pinned commit's own recipe has a watch, it is ignored.
- `configDir` (optional): where the app keeps its settings, printed before a switch.
- `feed`: where the newest version comes from. `url` may be a string or an object keyed by `uname -m`, and must be HTTPS.
  - `apt-index` with `url` and `package`: a Debian `Packages` file.
  - `zcode-manifest` or `latest-yml` with `url`: YAML with `version:`.
  - `github-release` with `repo`: the tag behind `/releases/latest`.
  - `json` with `url` and `path`: a jq path into a JSON document.
  - `regex` with `url` and `pattern`: a Python regex with one capture group.
  - `aur-rpc` with `name`: the AUR's version, pkgrel stripped.
  - `command` with `command`: a local shell command that prints the version.
    It runs during the background check, so it is accepted only when your
    own `~/.config/omarchy/omabump/apps.json` sets the entry's `feed`; a
    command feed from the shipped `apps.json` is refused.
- `icon` and `iconLight` (optional): SVG marks for dark and light themes, as paths relative to the plugin directory. Absolute paths, URLs and `..` are ignored. Put your own marks in `assets/user/`, which git ignores, so they never count as local changes that would stop Updating Omabump.

pacman versions are compared with `vercmp`; mise versions are left to mise.

## Pinned snapshots

`pins.json` holds the omarchy-pkgs commit every check and Update starts from:

```json
{ "omarchyPkgs": { "commit": "2c1d7c03466e500f3e21c27f75924662729a7163", "date": "2026-10-01T06:54:25-07:00", "ref": "refs/heads/master" } }
```

Update executes code from that repository (`bin/sync-upstream` and each recipe's upstream hook), so it runs only code from a commit reviewed for the release, never a moving branch. The marketplace baseline checks for exactly this. Bumping the pin is a plugin release: resolve the new commit with `git ls-remote https://github.com/omacom/omarchy-pkgs.git refs/heads/master`, read the diff of `bin/` and the recipes, update `pins.json`, and release.

Grok's recipe comes from omarchy-pkgs PR #725, pinned in `apps.json` as `recipeCommit` `c6576fa7f51966cc6f9d6fed574adec123741a16`. When a pin bump brings a master recipe with an upstream watch, the row says "Pinned recipe no longer needed" and the entry can go.

To track master instead, at your own risk, create `~/.config/omarchy/omabump/pins.json`:

```json
{ "omarchyPkgs": { "follow": "master" } }
```

The bar tooltip and the panel footer then say "omarchy-pkgs: following master (unpinned)". The same file can also set `"commit"` to another 40-hex commit. A file whose values have the wrong type is a pin error on the omarchy rows, never a stopped check.

## Security model

| Step | What runs | As whom |
|---|---|---|
| Background check (timer, Refresh) | curl of the feeds below; the pinned omarchy-pkgs commit, fetched with git; recipes read as text with `git show`; Omarchy's menu and agent wrappers read as text; your `shell.json` read for the widget's settings; `mise ls` and `mise outdated` for the listed tools on the allowed backends, asdf and vfox disabled; your own `command` feeds | you |
| Update, omarchy row | `bin/sync-upstream` and the recipe's upstream hook from the pinned commit, then makepkg and the PKGBUILD | you; sudo for missing build dependencies |
| Update, vendor row | download, digest check against the vendor's published list, `pacman -Qp` | you |
| Install of any built or vendor package | `sudo install` into `/var/cache/omabump`, `pacman -U` on that copy, the package's install script, pacman hooks | root |
| Update, mise row | `mise up` and the tool's backend, asdf and vfox disabled | you |
| Update, Omabump row | git fetch of the release tag into the plugin's clone, after you answer y a fast-forward to it, `omarchy-plugin-validate`, then the shell loads the new plugin code | you |
| Ask agent | whatever your default agent decides to run | the permissions `omarchy-agent` gives it |

What each guarantee covers, exactly:

- **No fetched code in the background check.** Feeds and recipes are parsed as text; nothing Omabump downloads is executed. mise runs with asdf and vfox disabled, so their plugin scripts do not run (another plugin backend mise may add later is not covered by that setting; `mise outdated` is still asked only about tools on the allowed backends). A `command` feed in your own `apps.json` is your code, and it runs. The shipped table has no command feeds. The whole check runs under `timeout -k 10 600`.
- **HTTPS only.** Omabump's own downloads allow only HTTPS, redirects included, with connect, total-time and size limits (8 MB for a feed, 4 GB for a package). Code from omarchy-pkgs that Update runs is held to the same rule from outside: `bin/sync-upstream` and its hooks run with `CURL_HOME` pointing at a generated `.curlrc` (`proto = "=https"`, `proto-redir = "=https"`, time and size limits), and makepkg runs with a generated `--config` that sources your makepkg configuration and replaces `DLAGENTS` with an HTTPS-only curl (`http`, `ftp`, `scp` and `rsync` sources fail). Not covered: a hook that bypasses curl, git calls inside `bin/sync-upstream` (git does not read `.curlrc`), a PKGBUILD that sets its own `DLAGENTS`, and VCS sources (`git+https://...`), which makepkg fetches with git. None of the shipped apps' recipes does any of these at the pinned commit. `bin/sync-upstream` gets `TMPDIR` under `~/.cache/omabump/scratch` and runs without the maintainer-only `BYPASS_MIN_RELEASE_AGE`.
- **Checksums are integrity, not authenticity.** The vendor package's digest comes from the vendor's own unsigned manifest or list over HTTPS. It catches a corrupted or swapped download on the way (transport, CDN), not a compromised vendor. The omarchy route likewise takes its hashes from the vendor's unsigned index through `bin/sync-upstream`; voxtype is the exception, its recipe checks a signed `.asc`.
- **pacman asks before it installs.** Both installs run plain `sudo pacman -U`, so pacman shows the package and asks "Proceed with installation?". sudo may not ask for a password at all (a cached credential, or makepkg's own `sudo pacman -S` a moment earlier), so the pacman prompt is the point where you can still stop. Answering n prints "pacman did not install <pkg> <version> (you answered no, or it failed above)", and the verified package stays in `~/.cache/omabump/packages` for a retry. When pacman exits with an error after installing (a failed hook or install script), the install counts as done, with a warning to read pacman's output. makepkg installs missing build dependencies with `sudo pacman -S --asdeps`, and pacman asks for those too.
- **What is printed before pacman is inert.** Install scripts and the recipe diff go through a filter that shows ESC as `^[` and drops other control characters, so they cannot drive the terminal.
- **git and limits.** git, for the omarchy-pkgs clone and Omabump's own update alike, runs with hooks, fsmonitor, automatic gc and maintenance off and only the `https` protocol allowed. For the omarchy-pkgs clone, Omabump's own, your and the system's git config do not apply, so a `url.*.insteadOf` rule cannot point it elsewhere; only their `http.*` settings (proxy, CA bundle) are passed on, and proxy environment variables apply too. git fetches, `bin/sync-upstream` and mise calls run under `timeout -k`. Names from `apps.json` and `pins.json` (packages, mise tools, git refs) are checked before any of them reaches pacman, git, mise or a file name.
- **Temporary files.** Omabump's own locks and temporary files live under `~/.cache/omabump` and `~/.local/state`, never in the system temp directory; `bin/sync-upstream` gets a `TMPDIR` there too.

Before `pacman -U`, the verified package (the vendor download or the makepkg output) is copied with `sudo install` into the root-owned `/var/cache/omabump` (read by you, written by root, so a symlink in its place cannot make root copy a file you cannot read), checked again there (its digest: the vendor's published one on the vendor route, the sha256 of the file makepkg built, taken right after the build, on the omarchy route; and the name and full version), and pacman installs that copy. The copy in the user-writable cache can no longer be swapped between verification and install. The staged copy is removed once pacman finishes, whether or not it installed; only a copy that fails its own check is kept, and the message names it.

### Permissions and capabilities

Omabump uses sudo for one thing: installing a package after you pressed Update or Switch, in a visible terminal. It copies the verified file into `/var/cache/omabump` (`sudo install`), runs `sudo pacman -U` on that copy, where pacman asks before it installs, and removes the copy (`sudo rm`). makepkg also calls `sudo pacman -S --asdeps` when a recipe's build dependencies are missing, and pacman asks before it installs them. What runs as root is pacman, the package's install script and pacman's hooks. Omabump never changes sudo configuration and never installs from the background check.

Omabump itself writes to `~/.cache/omabump`, `~/.local/state/omarchy/plugins/io.github.vladkarok.omabump`, `/var/cache/omabump` (the staged package, through sudo) and, when you change a setting, Omarchy's `~/.config/omarchy/shell.json`. Beyond that, pacman installs packages, `mise up` (and `mise outdated`) may write under `~/.local/share/mise`, and `bin/sync-upstream`, its hooks and your own `command` feeds can write wherever your user can.

The marketplace's static security baseline will report these capabilities, all expected:

- `privilege`: `sudo pacman -U` in `bin/omabump-install`
- `package-manager`: pacman, makepkg and mise
- `installer`: `bin/omabump-install` (scanned by its name)
- `remote-build`: makepkg builds the omarchy-pkgs recipe at the pinned commit

The two baseline findings that apply to this kind of plugin are addressed: omarchy-pkgs code runs only from a pinned 40-hex commit checked out detached (the clone fetches that commit by its SHA; only when a server refuses that does it fetch the pin's ref, and the commit must then be in it), and the vendor package is verified against the vendor's published digest before pacman sees it. Following master instead is an explicit opt-in (Pinned snapshots), and pinning the recipe code does not authenticate the vendor payload it downloads; see the checksum note above.

### External services contacted

The background check (every hour by default) fetches version feeds:

- `downloads.claude.ai` (Claude Desktop apt index)
- `persistent.oaistatic.com` (Codex apt index)
- `packages.perplexity.ai` (Perplexity apt index)
- `downloads.cursor.com` (Grok apt index)
- `github.com` (`/releases/latest` redirects for T3 Code, Hermes, voxtype and Omabump itself; the omarchy-pkgs clone)
- `registry.npmjs.org` (OpenClaw)
- `lmstudio.ai` (LM Studio download page)
- `zcode.z.ai` (ZCode update manifest)
- `kimi-img.moonshot.cn` (Kimi update feed)
- `aur.archlinux.org` RPC (Antigravity, Antigravity IDE, Trae)
- the registries mise uses for each tool (`mise outdated`: npm, GitHub, PyPI and mise's own registry, depending on the tool's backend)

Update additionally contacts:

- omarchy rows: every host the recipe's sources and its upstream hook name: the vendor hosts above, GitHub release assets and `raw.githubusercontent.com` (voxtype), and the npm registry's tarballs (OpenClaw)
- vendor rows: `cdn-zcode.z.ai` (the ZCode package)
- mise rows: the tool's registry
- Omabump's own row: `github.com` (the release tag)

No other host, no telemetry.

## Remove

```sh
omarchy plugin remove io.github.vladkarok.omabump
```

That leaves the cache (the omarchy-pkgs clone, downloaded recipe sources, any failed build) and the state directory (the last check, which versions were announced). Remove them with:

```sh
rm -rf ~/.cache/omabump
rm -rf ~/.local/state/omarchy/plugins/io.github.vladkarok.omabump
rm -rf ~/.config/omarchy/omabump   # only if you created overrides
sudo rm -rf /var/cache/omabump     # only if a staged package failed its check
```

Packages Omabump installed stay installed; pacman manages them like any other.

## Tested on

Omarchy 4.0.0 r6692 (host and a lab VM), Quickshell 0.3.1, x86_64.

## License

MIT, see [LICENSE](LICENSE).

`assets/claude.svg`, `assets/codex.svg` and `assets/codex-light.svg` are copied from Omarchy's first-party Agents plugin, MIT licensed. The marks belong to their owners. The ZCode and T3 Code marks are plain letter shapes drawn for this plugin.

# Omabump internals

How Omabump works inside: when it checks, what it reads, and what Update and Build now run. Installing and using it is in the [README](../README.md).

## Contents

- [Checks and the local refresh](#checks-and-the-local-refresh)
  - [When a check runs](#when-a-check-runs)
  - [A check you ask for](#a-check-you-ask-for)
  - [The local refresh](#the-local-refresh)
  - [IPC](#ipc)
- [Exit codes](#exit-codes)
- [status.json](#statusjson)
- [Mute and skip in detail](#mute-and-skip-in-detail)
- [Notifications](#notifications)
- [How CLI tools are found](#how-cli-tools-are-found)
- [Update routes](#update-routes)
  - [Route facts](#route-facts)
  - [repo](#repo)
  - [Build now](#build-now)
    - [PGP keyring](#pgp-keyring)
  - [vendor](#vendor)
  - [mise](#mise)
  - [Already installed](#already-installed)
  - [Omabump itself](#omabump-itself)
  - [Self-updating apps](#self-updating-apps)
  - [indicator](#indicator)
  - [Switch](#switch)
  - [Trying a route with --prepare](#trying-a-route-with---prepare)
- [Pinned snapshots](#pinned-snapshots)
- [Security model](#security-model)
  - [Marketplace baseline](#marketplace-baseline)
  - [External services contacted](#external-services-contacted)
  - [GitHub API calls](#github-api-calls)
- [apps.json fields](#appsjson-fields)
- [Development and tests](#development-and-tests)

## Checks and the local refresh

### When a check runs

Each bar asks `bin/omabump-check --if-due` once a minute, and when the panel opens, whether a check is due. The checker decides under its lock, counting from the last check's start in status.json, which all bars share, or from its own last attempt when that run wrote nothing (it counts as failed, and its retry as the retry). A check is due an interval after the last one started, less 30 seconds of slack, so the bars on several monitors agree on one check.

A check that failed (the summary says "Check failed": offline after a resume, a feed that timed out, a run that stopped early) is tried once more about 5 minutes after it started, instead of a whole interval later. If that one fails too, the next check comes the usual interval after it, so an outage, or a GitHub rate limit that lasts the hour, is not asked again every few minutes. A muted row's failure earns no retry. A check killed outright leaves status.json marked as checking; the panel shows it as checking for up to 10 minutes, but the next bar to ask finds the lock free, so it knows the run is dead and retries it on the same 5-minute schedule.

### A check you ask for

A check you ask for with a click or `r` while one runs is not lost: a check that starts after your request answers it (yours, or another bar's or a terminal's that takes the lock first). IPC `refresh` does the same unless it is throttled (see [IPC](#ipc)). If the running check holds its lock for over 11 minutes, yours is not run, and the panel says "Check not run: another check held the lock for over 11 min" until a later check completes. The timer's own check skips while any check runs. Turning Show CLI tools on or off also checks again, after any check in progress.

### The local refresh

Between checks, apps also change outside Omabump: Omarchy updates a mise CLI when it launches, and `omarchy update` runs `mise up` and pacman. So the panel rereads the installed versions, offline, when it opens (or runs the full check instead, when one is due) and, while the bar counts an update or a release ahead of the repo, every 5 minutes: with no update shown there is nothing a refresh could take back, and nothing runs between checks. That local refresh reads `pacman -Q`, `mise ls` (offline), Omabump's own `manifest.json` and a self-updating app's AppImage version, as the check reads them; it keeps everything else the last check found, except each row's `icon` and `iconLight`, which it takes from `apps.json` again, and never notifies.

A repo row is derived again by `repo_derive` from the stored `repoVersion` and `vendorVersion` and the installed version, so an install of the repo's package, or of one Build now made, clears the row without a check. Update's and Build now's own reasons (Update off, missing tools) are read again; the recipe's reason (`buildNoteFrom` `recipe`) is kept as the check left it. A version it cannot judge on its own (past the newest known one, a mise tool at another version, an app new since the check or moved between package and AppImage) shows "Not checked yet" and starts one full check. Another package name, or a mise tool that reached the newest known version, shows as read and starts one too. It never moves "checked N min ago" or puts off the next check.

### IPC

`omarchy-shell io.github.vladkarok.omabump status|open|close|toggle|refresh|settings`. `status` counts what the bar counts, including unchecked rows, and the rows ahead of the repo (`2 updates, 1 ahead of the repo`), and adds "(+N muted/skipped)" when quiet rows have updates, with "check failed for N muted apps" inside it when muted rows failed. `refresh` answers `throttled` and starts nothing while this bar's own Refresh check runs or within a minute after its last check ended (a run that left because another check held the lock, or never ran, does not count); during another bar's or a terminal's check it waits for that one and then checks. `open`, `close`, `toggle` and `settings` go through the shell's own panel handling, as `omarchy-shell shell toggle io.github.vladkarok.omabump` does, so the panel opens on the focused monitor (or the open one closes), whichever monitor's bar received the call.

## Exit codes

Run by hand, `bin/omabump-check` exits 0 when it ran a check, 75 when it did not because another check holds the lock (one line on stderr; `--wait` runs one after it instead, and exits 75 if that wait passes 11 minutes), and anything else when the check failed (status.json's `runError` says how). `--if-due --interval SEC` runs a check only when one is due, SEC after the last one started, or the retry of one that failed (saying `due` on stdout first), and otherwise exits 76 having written nothing. A check that finds a local refresh, or an `--if-due` run still deciding, holding the lock waits for it (at most 130 seconds) and then runs. `bin/omabump-check --local` is the local refresh: it exits 0 when done, 80 when a change needs a full check, 81 without a finished check's status.json to start from, 82 while pacman is mid-transaction (it writes nothing then), and 75 when a check or another local refresh holds the lock. What `bin/omabump-install --prepare` exits with is under [Trying a route with --prepare](#trying-a-route-with---prepare).

## status.json

The last check's result is `~/.local/state/omarchy/plugins/io.github.vladkarok.omabump/status.json`, with a top-level `schemaVersion` (1). Fields are added within a schema version, never removed or renamed, so a panel still loaded from an older release reads the file a newer checker wrote. The checker, the local refresh and the installer read the file only when its `schemaVersion` is 1 and every row is an object with a `pkg`; any other file counts as no check at all. The scripts write and read it only through the status.json section of `bin/omabump-common`.

Top level:

| Field | Meaning |
|---|---|
| `checkedAt`, `startedAt` | when the last check ended, and when the last (or running) one started |
| `checking` | true while a check runs; a killed run leaves it, and `startedAt` tells the panel the run is stale |
| `inventoryAt` | when the installed versions were last read: a full check's start, or a local refresh |
| `runError`, `retry`, `miseError` | why the check failed as a whole; whether it was the retry of a failed one (`--if-due` chose it, or `--retry` said so); why mise's inventory could not be read |
| `omarchyPkgs` | `{commit, following, error, note}`: the omarchy-pkgs pin. `error` counts as a failed check only while a listed, unmuted row is `ahead` |
| `apps` | the rows, in the panel's order |

A row:

| Field | Meaning |
|---|---|
| `pkg`, `label`, `source`, `section`, `switchRoute` | the entry; `section` is `desktop`, `cli` or `plugin`, and `switchRoute` whether the route installs a package by `pkg` (repo and vendor rows). Both come from the route, unless `apps.json` names the section |
| `installedName`, `installed` | what is installed, and under which name; `installed` is empty when the version is unknown |
| `latest`, `versionFrom` | the newest version the row shows and where it came from (`feed`, `repo`, `mise`) |
| `repoVersion` | the full version (`[epoch:]pkgver-pkgrel`) Omarchy's repo has of a repo row's package, empty when unknown (no repo, no such package, a database that could not be read) |
| `vendorVersion` | the feed's newest version on a repo row, empty without a feed; kept from the last check when the feed fails |
| `updateAvailable` | the installed version is behind the repo's, or the row is `ahead` |
| `installable` | Update can run now: the repo's package is newer than the installed one and the route works. A current repo row has `installable: false` |
| `ahead` | the vendor's version is newer than the installed one and than the repo's upstream version, or the repo has no package |
| `buildable` | Build now could run: `ahead`, the entry has `"build": true`, Update is not off, the app is not a self-updating copy, no recipe blocker or hold is known, and the build tools are there. It does not depend on `buildAhead`; with that off no recipe is read |
| `buildNote`, `buildNoteFrom` | why not, while ahead and not buildable, and which reason that is: `entry`, `off`, `tools` or `recipe` |
| `held`, `holdClause` | a repo row waiting for Omarchy's repo (`Not in Omarchy's repo yet`) while the repo has an older package; the clause leads `note`, and the local refresh takes exactly it off once the version is installed |
| `note`, `error` | the row's exceptions (not "installed under another name": that is in `installedName`, `switchable` and `updateAvailable`) and its failure |
| `switchable` | installed under another name, at a version not newer than the repo's full version (repo rows) or the vendor's (vendor rows) |
| `stale`, `unchecked`, `unread` | the version is the last known one; the newest version is not known; a local refresh wrote the row and no check has read it since |
| `skipped`, `skipEnded` | the settings' skip applies to the row; whether a check found it over |
| `blocked` | Update is off by `updateBlocked` |
| `omarchyUpdate` | an indicator row that `omarchy update` updates |
| `selfUpdating` | the app updates itself (see [Self-updating apps](#self-updating-apps)); its `installedName` is the AppImage's or npm package's path as `apps.json` writes it |
| `icon`, `iconLight` | the marks, from `apps.json` |

0.2.0 added `vendorVersion`, `ahead`, `buildable`, `buildNote` and `buildNoteFrom`, and no longer writes `muted`, `request` and `recipe`, which nothing read. `schemaVersion` stays 1. A row the local refresh carries over from an older file lacks the new fields until a check reads it.

Meanings that changed in 0.2.0: `latest` is the vendor's version while the row is ahead, else the repo's (by its upstream version when that equals the vendor's), and the repo's alone without a feed. Every packaged app's `source` is `repo` now, and `switchRoute` is true on those rows. `omarchyPkgs.error` fails the check only while an unmuted row is ahead; it used to fail it unless every omarchy row was muted.

## Mute and skip in detail

Mute, skip, Notify, Show CLI tools and Build now apply to every check, whoever starts it: the shell's timer, `bin/omabump-check` in a terminal, or the refresh after an Update. The checker reads them itself from the widget's entry in `~/.config/omarchy/shell.json` (in `bar.layout` or the top-level `plugins` list), up to 1 MiB of file and 200 entries each; an id or version it does not accept is ignored with a line in the shell log. `--no-notify` and `--no-cli` (`--no-mise` is kept as an alias) still win, and the settings are read once the check holds its lock. Show CLI tools is the key `showCli`; a `showMise` in `shell.json` counts while `showCli` is absent, and the panel's next settings write stores `showCli` and drops `showMise`. Build now's `buildAhead` is read the same way, by the checker and by the installer.

A muted row's failed check shows only on the row itself ("Check failed: ...") and in the tooltip and IPC status ("check failed for N muted apps"), not in the header or the bar; an omarchy-pkgs or mise failure that only muted rows share, or an omarchy-pkgs failure with no unmuted row ahead, does not fail the check. The settings list the muted rows the last check showed; a mute for a row hidden by Show CLI tools is kept, not listed.

Once a skip no longer applies, the settings stop listing it once a check has seen that, and it is dropped the next time the panel writes a setting. A skip on a row the last check could not judge (failed, stale, still checking, unchecked or not listed) is kept. pacman and feed versions are compared with `vercmp`, so a feed that rolls back below the skipped version stays skipped; mise and Omabump's own versions must match exactly, so `1.0.0` after a skipped `1.0.0-beta.1` is new. Those comparisons are the checker's, which writes its answer into status.json; the panel shows a skip of the row's newest version, and an undone skip, at once, and any other change to the setting from the next check.

## Notifications

A check announces what notified.json (in the state directory) has not recorded for a key, once, and records it as soon as it is sent. Nothing notifies with `--no-notify` or with Notify off, and a muted or skipped row announces nothing.

| Key | Sent when | Text |
|---|---|---|
| `<pkg>` | the row has an update Update installs (a repo row: the repo's package is newer, installed under any name), or another route's update | `<App> <version> available`, body `Installed: <v>. Open the Omabump panel to update.` |
| `ahead:<pkg>` | the row is ahead and buildable, `buildAhead` is on, once per vendor version | `<App> <version> released`, low urgency (`-u low`), body `Not in Omarchy's repo yet. Build now is available.` |

A repo row's `<pkg>` entry holds the repo's full version, and its text names the repo's version when the row is also ahead. The `ahead:<pkg>` entry holds the vendor's version. When the repo later has that version and it is still not installed, the `<pkg>` notification follows. With `buildAhead` off an ahead row never notifies.

## How CLI tools are found

A CLI row is one of two kinds of `apps.json` entry.

Since Omarchy's migration 1795441383 (2026-11-23) the coding agents are packages of the [omarchy] repo, not mise tools, and `omarchy update` is what updates them: the packaged `claude` runs with its own updater turned off, `codex` with its update check off. Each of the twenty has an entry on the [repo](#repo) route with `"section": "cli"`, found with `pacman -Q` like a desktop app, and listed in the CLI section. Its newest version in the vendor's feed shows when the vendor is ahead, and its Update installs the signed package from Omarchy's repo. For `cursor-cli`, `muse-code` and `deepseek-dsh`, whose package version is put together from two parts of the vendor's answer, which no feed type does, the entry has no feed: the repo's version is the only newest one and the row is never ahead.

The other kind is a `mise` entry, for an agent your own mise config still asks for (Omarchy's migration leaves those alone), and for tools Omarchy never packaged. Each `mise` entry of `apps.json` that names the keys mise may have the tool under (`"tool": ["claude", "npm:@anthropic-ai/claude-code"]`). The first of them `mise ls` reports as installed and active is the row's tool; a tool mise does not have shows no row. The shipped entries cover the agents Omarchy's menu offers and a few more.

Until 0.1.13 Omabump found the agents itself, in Omarchy's menu and the wrappers Omarchy wrote to `~/.local/bin`. Omarchy 4 renamed the menu's entries and no longer writes those wrappers, so the list is now the only source.

Every mise call Omabump makes, in the check and in Update, runs with `MISE_DISABLE_BACKENDS` set to `asdf`, `vfox` and the name of every plugin in mise's plugins directory (a vfox backend plugin is disabled by its own name), plus the backends you disabled yourself (your `MISE_DISABLE_BACKENDS` and mise's `disable_backends` setting, read once per run with `mise settings get`), so a tool named with an `asdf:`, `vfox:` or plugin backend runs no plugin script while mise resolves your config; `mise ls` still lists such a tool. A bare name that mise resolves to an installed asdf plugin is not covered: when its configured version is not installed, mise may run that plugin's version-listing script (once per mise cache period). `mise outdated` is asked only about the key each row resolved to, and only when one `mise ls --backend` call puts it on a backend agent CLIs ship on: aqua, github, gitlab, forgejo, npm, http, ubi, pipx, cargo. A tool on any other backend (asdf, vfox, another plugin, or mise's core, go and gem) shows its installed version and "Update check skipped", has no Update button and counts as unchecked in the summary. When `mise ls` fails (a broken mise config), or `mise outdated` cannot fetch a tool's versions (offline, rate limited; mise still exits 0 then, and for a pinned or ranged request names only the backend's tool, `openai/codex` for `codex`), the rows keep the last known version and the check reads as failed.

## Update routes

A button on a row runs `bin/omabump-install` in a floating terminal, and the row's route decides what happens. Update is `omabump-install <pkg>`, Build now is `omabump-install --build <pkg>`, Switch is `omabump-install --switch <pkg>`.

### Route facts

One table in `bin/omabump-common` (`route_table`) holds what differs between routes. The check, the local refresh and the installer ask it with `route <source> <fact> <value>`, never by the source's name.

| Route | versions | newest | installed | switch | section | build |
|---|---|---|---|---|---|---|
| `repo` | vercmp | repo | pacman | yes | desktop | yes |
| `vendor-pkg` | vercmp | feed | pacman | yes | desktop | no |
| `indicator` | vercmp | feed | pacman | no | desktop | no |
| `mise` | exact | mise | mise | no | cli | no |
| `self` (Omabump's own row) | exact | feed | manifest | no | plugin | no |

- `versions`: `vercmp`, or `exact` (a string that differs, since mise decides what is newer and vercmp would call `1.0.0` and `1.0.0-beta.1` equal).
- `newest repo`: the repo's version is the row's newest, with the entry's feed, when it has one, giving the vendor's release for the window where the vendor is ahead.
- `build yes`: Build now may build the entry's recipe, when the entry says `"build": true` (`build_allowed`).
- An app installed as a self-updating copy keeps its source's section and switch but takes no route.

`"source": "omarchy"`, the route of 0.1.19 and before, is gone. `apps_table` reads an entry with it as `repo` and `"build": true` (unless the entry sets `build`), silently.

### repo

Omarchy builds its packages, the coding agents among them, in its own pacman repo [omarchy] and signs each with its key. A repo row's Update installs the package from there, the one `omarchy update` would install next:

1. It finds the repo's server with `pacman-conf --repo omarchy Server` (the first https one) and reads the database, `omarchy.db`, again, never from status.json. The database is not signed (`SigLevel = Required DatabaseOptional`), so it only names the file: the entry whose `%NAME%` is exactly the row's package (`crush-bin-debug` is not `crush-bin`), its `%VERSION%`, its `%FILENAME%` (one path component, `<name>-<version>-<arch>.pkg.tar.<ext>` for this machine's architecture or `any`) and its `%SHA256SUM%`.
2. When that version is not newer than the installed one, it ends as under [Already installed](#already-installed). A success when the installed version has reached the row's newest; otherwise `Omarchy's repo has 0.103.0-1, not the 0.104.0 the vendor's feed shows; Update cannot install it yet. It usually follows within the hour.`, and for an entry with `"build": true` the sentence `Build now (b in the panel) builds it from Omarchy's recipe meanwhile.`
3. It downloads the package and its `.sig` over HTTPS into `~/.cache/omabump/packages` (an epoch's `:` in the file name is sent as `%3A`). The file's sha256 must be the database's.
4. gpg, run as `pacman-key --verify` runs it in pacman's keyring (`pacman-conf GPGDir`), must find a good signature by a key that keyring trusts fully or ultimately, which is how Omarchy's own key is there. A signature that does not verify, a good one by a key the keyring holds but does not trust, or an armored one deletes both files and Update refuses.
5. `pacman -Qp` must name exactly that package at that full version, newer than what is installed now, and the package's files must all be root's.
6. The file is staged in `/var/cache/omabump`, checked again there, its signature included, and installed with `sudo pacman -U`, which asks first. When pacman refuses (a dependency the rest of the system does not have yet), Update says to run `omarchy update`.

Omabump reads gpg's status lines itself rather than run `pacman-key --verify`, which in pacman 7.1.0 tests the trust in a `PIPESTATUS` an earlier test has already reset and so passes an untrusted key's good signature. The sha256 comes from the unsigned database, so the signature is what ties the root-owned copy to Omarchy's key. `pacman -U` on a local file would not check it (`LocalFileSigLevel = Optional`), which is why Omabump does, before sudo (a bad file never asks for a password) and on the staged copy.

No code from omarchy-pkgs runs and its clone is not touched. What is trusted is the keys in pacman's keyring: a package Omarchy's key, or another key pacman trusts, signed is installed, whatever the database says. Update never builds.

What the check records for such a row:

- It reads the database once (at most 8 MB), on the first repo row, and records the repo's full version in each row (`repoVersion`). A machine without the [omarchy] repo, or a repo without the package, has rows with no Update that say why.
- With a feed, it records the vendor's newest release (`vendorVersion`). `repo_derive` then decides, as the one home of this rule, the fields below.
- A database that cannot be fetched or read fails a row only when the row shows an update it cannot say Update will install, or when its feed failed too.

| Fact | Rule |
|---|---|
| `updateAvailable` | the repo's package is newer than the installed one (`repo_new`, so a pkgrel counts), or the row is ahead |
| `installable` (Update) | `repo_new` and the route works (Update not off, its tools there) |
| `ahead` | `vendor_ahead`: the vendor's release is newer than the installed upstream version and than the repo's upstream version, or the repo has no package |
| `latest` | the vendor's version while ahead; else the repo's, by its upstream version when that equals the vendor's; the repo's alone without a feed |
| `held` | ahead, the repo has an older package and the route works: the note starts `Not in Omarchy's repo yet` |

An app installed under another package name (`chatgpt-desktop`) is replaced by Update when the repo's package is newer, and by Switch at the same version, as on the vendor route. The notification of a repo row is recorded by the repo's full version, whatever the row's newest shows: `latest` is the feed's upstream version at one check and the repo's full version at another, and an epoch-less `1.2` ranks below `1:1.1-1`.

The row's functions, all in `bin/omabump-common`:

| Function | Does |
|---|---|
| `vendor_ahead` | true when the vendor's release is newer than the installed version and than the repo's package |
| `build_why` | sets `build_reason` and `build_from` (`entry`, `off`, `tools`, `recipe`): why Build now could not run, in that order |
| `repo_derive` | the fields above, from the repo's version, the vendor's, the installed one and `build_why`'s answer |
| `row_derive` | the rest of a row (switchable, quiet, skipped), calling `repo_derive` for a route whose newest is the repo's |

The check, the local refresh and the installer all call these, so a rule has one home.

### Build now

Build now is the other path of a repo row, for a vendor release the repo does not have yet. `omabump-install --build <pkg>` builds Omarchy's recipe at the pinned omarchy-pkgs commit (see [Pinned snapshots](#pinned-snapshots)) in `~/.cache/omabump/omarchy-pkgs`, with the code Update never runs. It dispatches apart from Update: `install_main` calls `install_build` and `build_recipe` for `--build`, `install_repo` otherwise.

`rule_refusal` refuses before anything is written or fetched:

| Case | Refusal |
|---|---|
| `--switch --build` | `--switch and --build do not go together: Build now replaces a package installed under another name itself, as Update does` |
| entry without `"build": true` | `Build now is not available for <App>: Omabump does not build its recipe ...` |
| `buildAhead` off | `Build now is off. It builds <App> on this machine from Omarchy's own recipe ...`, with the `omarchy bar set` command that turns it on |
| Update off, a self-updating app, an indicator row | as for Update |

Then `install_build` reads the vendor's newest release again (the feed, else `vendorVersion` of the panel's row) and reads the repo:

- The repo has a newer package and the vendor is not ahead of it: Build now refuses and says to use Update, which installs the signed package. When the vendor's version is unknown too, it says that as well.
- The vendor is known and not ahead of what is installed: it ends as under [Already installed](#already-installed).
- The vendor is unknown and the repo has nothing newer: it goes on, and the recipe's sync decides.

When the check reads a recipe: only for a row that is ahead, whose entry has `"build": true`, with Update not off, the build tools present and `buildAhead` on. It then fetches the pinned clone (as before) and reads the recipe's blocker and `min_release_age` as text. With `buildAhead` off it never clones or fetches omarchy-pkgs; the installer fetches it only for a Build now. While an install holds the clone, the check reads no recipe and the row's note says `The omarchy-pkgs clone is busy with an update; Build now reads its recipe when asked`.

The recipe's other reasons show as the row's `buildNote`: `No <pkg> recipe in omarchy-pkgs`, `Repo recipe has no upstream watch yet` (also `... (sync: false)`), `Could not fetch omarchy-pkgs: <git's last line>` and `Could not read Omarchy's <pkg> recipe: <reason>`. Without `"build": true` the note is `Not in Omarchy's repo yet`; with Update off, `Update off: <reason>`; with tools missing, `Missing: <tools>; sudo pacman -S --needed <packages>`.

`build_recipe` then runs:

1. Takes the clone's lock, reads `buildAhead` again (the wait can be long; turned off meanwhile, the run refuses), fetches the pinned commit and checks it out detached.
2. Reads the recipe's blocker and `PKGBUILD` as text and makes the build's keyring ([PGP keyring](#pgp-keyring)) before any recipe code runs.
3. Runs `bin/sync-upstream <pkg>` and the recipe's hook, as you, with an HTTPS-only `.curlrc`, a scratch `TMPDIR`, the build's keyring as `GNUPGHOME` and without `BYPASS_MIN_RELEASE_AGE` or `UPSTREAM_GITHUB_TOKEN`.
4. Prints `Build now: building <App> on this machine from Omarchy's recipe. The package is not signed by Omarchy.` and the recipe diff, checks the recipe builds the expected package at a version newer than the installed one and newer than the repo's (a recipe that reaches only what the repo has is refused: `use Update instead`), builds it with makepkg (every makepkg call of the run has the build's keyring as `GNUPGHOME`), and stages and installs it with `sudo pacman -U`.
5. Puts the clone back as the pin has it.

A recipe may hold new releases for a while (`min_release_age`), and `bin/sync-upstream` does not move it to a younger release. Such a row says `omarchy-pkgs holds new releases for <N> h, Build now from <Mon D HH:MM>` and is not buildable until then. A feed gives no release date, so the wait counts from the first check that saw the version.

Update is off for `openclaw` (`updateBlocked`): since [omarchy-pkgs#797](https://github.com/omacom/omarchy-pkgs/pull/797) the package is the seed of a copy in `~/.openclaw` that updates itself, and a build would take OpenClaw out of `/usr` on a machine that still runs it from there. Build now is off for it too. Its copy's row is under [Self-updating apps](#self-updating-apps).

#### PGP keyring

A recipe that checks a vendor's signature on its sources (Claude Code's) lists the keys in `validpgpkeys`, and omarchy-pkgs ships each as `keys/pgp/<FPR>.asc`. The functions are in the keyring section of `bin/omabump-common`, which knows nothing about rows:

| Function | Does |
|---|---|
| `pgp_fingerprints` | reads `validpgpkeys` from the PKGBUILD text, every `=` and `+=` assignment, parsed and never sourced; an entry that is not a 40-hex fingerprint, or a form it does not read, refuses |
| `pgp_keyring` | makes a new directory (mode 700, `no-auto-key-retrieve`) and imports each `keys/pgp/<FPR>.asc`, read with git at the pinned commit, whose one primary key must be exactly that fingerprint; then checks the keyring holds exactly the listed keys |
| `pgp_keyring_drop` | stops the keyring's gpg-agent and removes it |

Every build gets such a keyring, an empty one when nothing is listed, in `~/.cache/omabump/gnupg.XXXXXX`, and makepkg runs with `GNUPGHOME` set to it. Your own keyring is never used, there is no keyserver and no `--skippgpcheck`. It is removed after the build or on any exit. The refusal texts name the recipe, the fingerprint and the commit. This is covered by unit tests of the keyring; a full makepkg of a signed recipe is not part of the test suite.

### vendor

The vendor publishes a ready Arch package (ZCode does). `apps.json` gives its URL and a feed for the newest version. When the feed's version is not newer than the installed one, Update ends as under [Already installed](#already-installed), before it reads the package URL or checksum; otherwise it downloads the file over HTTPS, and verifies it against the sha512 the vendor lists for that exact file in its update manifest. It refuses if the manifest has no checksum for the file, and deletes a file that does not match. Then `pacman -Qp` checks the package name and full version, the installed version is read again, and only then is the file staged and installed with `sudo pacman -U`, after pacman asks. pacman does not fetch the URL itself because it would check a remote file against `SigLevel = Required`, and the vendor does not sign the package. On a fresh install ZCode's install script links `/usr/bin/zcode` to `/opt/ZCode/zcode`, and no package owns that link, so pacman refuses the AUR's `zcode` (which ships that path) and `omarchy update` fails. After a vendor install Omabump therefore removes `/usr/bin/<pkg>` with `sudo rm` when it is a link no package owns, pointing at a file of the package just installed. While the vendor build is installed, `zcode` is not on PATH: start ZCode from the app launcher or run `/opt/ZCode/zcode`. If Omabump falls behind or is uninstalled, a normal update replaces the vendor build with the AUR's `zcode`, which brings `/usr/bin/zcode` back.

### mise

The check asks `mise outdated` for the version each tool's configured request reaches, and Update installs exactly that version with `mise install <tool>@<version>` in `$HOME`, with asdf and vfox disabled; your config is not touched, and its request makes the new version the active one (a `latest` request uses the newest version installed, which is also what Omarchy's wrappers then run). Both run with `MISE_MINIMUM_RELEASE_AGE=0`, as Omarchy's own agent wrappers and `omarchy update` do, so an agent CLI's new release shows and installs at once. Finding it skips mise's versions host (`mise-versions.jdx.dev`), which can list a release hours after its tag (Codex 0.164.0: more than nine hours): mise asks each installed tool's own source instead, one light request per tool (GitHub's `/releases/latest` for aqua and github tools), cached for an hour, and never resolves the tools your config names but you have not installed (they are passed to mise as `MISE_DISABLE_TOOLS`, with the ones you disabled yourself; not to Update's install, which rewrites every tool's shims, and an unused tool's shim is how Omarchy installs it on first use). That is one request per installed tool an hour for a `latest` request; a pinned or ranged one makes mise list the tool's releases, for aqua and github tools GitHub's whole paged list. Installing goes through the host: there mise maps the version to its release from the host's cache, where GitHub's own list of a tool's releases can be tens of MB (45 MB for Codex) and often times out. So while the host answers, Update needs no GitHub API request; if it fails, mise falls back to GitHub's list. If you turned the host off yourself (`use_versions_host = false`), Update keeps it off. When a lockfile keeps the request on the old version, so that the new one is installed but not active, Update then runs `mise up <tool>`, which rewrites the lockfile. Without a token those count against GitHub's 60 requests an hour per address; if a check goes past it, those rows show the check as failed until the limit resets. A token raises the limit. The panel's check starts from the session, not from your shell, so either let mise ask gh for it (`mise settings set github.credential_command 'gh auth token'`) or put `GITHUB_TOKEN` in the session's environment (a file in `~/.config/uwsm/env.d/`, then log in again). mise's install counter (`use_versions_host_track`) is off for every call Omabump makes. A tool pinned below the newest release shows "Pinned to 0.96, 0.97.1 exists" (the newest release itself, not mise's rewritten request) and no Update button. Omabump passes `mise outdated` only the key each row resolved to, on the allowed backends, never every tool in your mise config, and Update asks only about its own tool (see [How CLI tools are found](#how-cli-tools-are-found)).

### Already installed

The panel may offer a version that was installed some other way since the last check. When the route has nothing newer than what is installed, it compares the installed version with the row's newest known one: if it has reached it, Update says `<app> <version> is already installed; nothing to do.`, refreshes the panel and ends as a success. Otherwise it fails and names both versions, for example `omarchy-pkgs' recipe reaches 0.75.2-1, not the 0.76.0 the vendor's feed shows; Build now cannot install it yet.` `--switch` still installs at the same version, and an older version is never installed.

### Omabump itself

Update installs the release the row names, in a terminal: in the plugin's own clone it checks that `origin` is `https://github.com/vladkarok/omabump` and that there are no local changes, fetches the tag `v<version>` and nothing else, and requires the tagged commit to be a fast-forward of the installed one. It prints that commit, the commits since the installed one and a diffstat, then asks `Update Omabump to <version>? [y/N]`. On `y` it fast-forwards to the tagged commit, validates the plugin with `omarchy-plugin-validate` and reloads the shell's plugins. If the fast-forward or the validation fails, or the run is stopped before the validation passes, it resets the clone to the installed commit with `git reset --hard` and `git clean -fd` (your ignored files stay) and says the old version is still installed; if the rollback fails, it prints the `git reset --hard` to run. `omabump-install --prepare self:omabump` stops before the question. When the release the row offered is installed already (by `omarchy plugin update` or a git pull), Update says so and refreshes the panel, as for any app ([Already installed](#already-installed)); the local refresh reads Omabump's version from `manifest.json`, so the row usually clears by itself.

### Self-updating apps

An app installed as a copy that replaces itself when it updates has no Update or Switch, and `bin/omabump-install` refuses it; the row's note says how the app updates. The copy is the vendor's own AppImage (T3 Code, since Omarchy's migration 1792345511: open the app to update it), whose version is read with 7z from its desktop entry without running it, or an npm package that updates itself in place (OpenClaw, since Omarchy's migration 1792334754 set it up in `~/.openclaw`: run `openclaw update`), whose version is its `package.json`'s, read with jq. The row compares it with the newest release and notifies once per new version. A stable version is compared with vercmp; a pre-release (`0.1.1-nightly.20261019.1`) or an unknown version is not compared and counts as unchecked, with the reason in its note. The local refresh follows the app's own updates. When the package is installed too, it wins over an AppImage, which Omarchy installs in the package's place, and loses to an npm package's copy: Omarchy sets that copy up from the package and keeps the package installed as its seed.

### indicator

No Update button. These rows show the installed and newest version. Update them the way you installed them. `omarchy update` runs pacman, then `yay -Sua`: a row whose package one of pacman's repos has says "Updates with omarchy update", an AUR row installed from the AUR says "Updates with omarchy update (AUR)".

### Switch

Codex may be installed as the AUR's `chatgpt-desktop` and ZCode as `z-code-bin`. When the canonical package has the same or a newer version, the row offers Switch (`w`), which runs `omabump-install --switch <pkg>`. It works on repo rows and vendor rows; `--switch` on another row is refused (`--switch works for rows from Omarchy's repo and vendor rows only`), and so is `--switch --build`.

- It checks that one package declares a conflict with the other, prints both packages' install scripts and the app's config directory, and lets pacman ask before removing the old package.
- On repo and vendor rows the conflict is read from the downloaded, verified package. On a Build now run the installer never switches, but replaces a package installed under another name the way Update does, and reads the conflict from the recipe (`makepkg --printsrcinfo`, this machine's architecture included) before makepkg builds, so a refusal costs no build; it is checked again on the built package.
- On a repo row, Switch refuses a package older than the installed one: `<repo version> is older than the installed <name> <installed>; nothing to do`.
- Both names are read again right before staging. If the target is installed under the row's own name already, at a version it is not newer than, the run ends with `<pkg> is installed now, at <v>, which <target> is not newer than; not installing`.
- They are read a third time with the copy staged and checked, right before `sudo pacman -U`: sudo may have waited for a password meanwhile. A refusal there removes the staged copy.
- If pacman installed the package but the old one is still there (its conflict does not cover that version), the run says so and prints the `sudo pacman -R <old>` to run.

### Trying a route with --prepare

`bin/omabump-install --prepare <pkg>` goes as far as it can without installing: with `--build` it syncs the recipe and stops before makepkg builds; on vendor rows it downloads and verifies the package and stops before `pacman -U`; on repo rows it reads the repo's database, says each step a run would take, and stops before it downloads the package. Where a real run would refuse by Omabump's rules (Update off, Build now off or not allowed for the entry, a self-updating app, a hold, a mise request or backend, an indicator row, no [omarchy] repo or no such package in it, no https package or published checksum, a vendor package with files another account would own, a switch with nothing to switch or no declared conflict, nothing newer, a local checkout of Omabump), it prints `Would refuse: ...` or `Would say: ... already installed ...` and stops there, with exit 0. A failure on the way (a download, a build, git) still exits 1.

## Pinned snapshots

`pins.json` holds the omarchy-pkgs commit every check that reads a recipe and every Build now starts from:

```json
{ "omarchyPkgs": { "commit": "a4a3f954e32067a06561cc5845326db24976792a", "date": "2026-11-27T09:51:01Z", "ref": "refs/heads/master" } }
```

Build now executes code from that repository (`bin/sync-upstream` and each recipe's upstream hook), so it runs only code from a commit reviewed for the release, never a moving branch. Update runs none of it. The marketplace baseline checks for exactly this. Bumping the pin is a plugin release: resolve the new commit with `git ls-remote https://github.com/omacom/omarchy-pkgs.git refs/heads/master`, read the diff of `bin/` and the recipes, update `pins.json`, and release.

The pin moves when there is a reason, not on a schedule: a weekly workflow (`.github/workflows/pin-watch.yml`) compares it with master and keeps one issue open while the code Build now runs or a shipped app's recipe changed beyond a routine sync. A shipped app is an entry with `"build": true` (or the legacy `omarchy` source). The code Build now runs is `bin/sync-upstream` and the files in `bin/` and `helpers/` that it or a shipped app's hook names in code (not in comments), followed through the files they name, at the pin and on master; the rest of `helpers/` is omarchy-pkgs' own build and publish tooling, whose changes the issue lists without counting them. Where that code computes a helper's name instead, every file in `helpers/` counts again, and the issue says which file does it. A file the clone cannot fetch fails the run rather than reading as unchanged.

A routine sync is what a build rewrites itself: a recipe's pkgver, pkgrel and checksums (`bin/sync-upstream`), what a recipe's own hook writes, listed in the script's `hook_writes` (grok-bot's `_commit`, which its hook points at Cursor's newest build), and the variables under `.upstream.watch.variables` of the recipe's `.omarchy/package.json` at the pin (`_build` and `_hash` of openrouter-ori and amp-cli, `_npmver` of deepseek-dsh), which `bin/sync-upstream` fills from the vendor's answer as it fills pkgver.

The issue holds the diff and the newest master commit at least 3 days old to bump to, and closes once nothing worth a look is left. `.github/scripts/pin-watch` prints the same report from a terminal. Close the issue once the pin moves; closed by hand while the changes are still there, it comes back as a new one the next week. GitHub pauses scheduled workflows after 60 days without commits; Actions then offers to enable it again.

omarchy-pkgs merges most of these recipes' bot pull requests on its own, so a recipe can change on master without a person reading it. A pin bump is where that reading happens: the whole diff of the code Build now runs, hooks, install scripts and `package()` included, not only the version lines.

To track master instead, at your own risk, create `~/.config/omarchy/omabump/pins.json`:

```json
{ "omarchyPkgs": { "follow": "master" } }
```

The bar tooltip and the panel footer then say "omarchy-pkgs: following master (unpinned)". The same file can also set `"commit"` to another 40-hex commit. A file whose values have the wrong type is a pin error on the rows that read a recipe, never a stopped check.

## Security model

Which uses of sudo there are, and where Omabump writes, is in the README's [What Update and Build now do to your machine](../README.md#what-update-and-build-now-do-to-your-machine).

| Step | What runs | As whom |
|---|---|---|
| Background check (timer, Refresh) | curl of the feeds below and of Omarchy's repo database, read with bsdtar as text; with Build now on, for a row the vendor is ahead on, the pinned omarchy-pkgs commit, fetched with git, and its recipes read as text with `git show`; your `shell.json` read for the widget's settings; a self-updating app's AppImage read with 7z, never run; `mise ls` and `mise outdated` for the listed tools on the allowed backends, asdf and vfox disabled; your own `command` feeds | you |
| Local refresh (panel open; every 5 minutes while the bar counts an update) | `pacman -Q`; `mise ls` and `mise settings get` with `MISE_OFFLINE=1`, asdf and vfox disabled; your `shell.json` and Omabump's `manifest.json` read as text; a self-updating app's AppImage read with 7z as in the background check; no network, no notification | you |
| Build now (`--build`) | the pinned omarchy-pkgs commit checked out, a keyring made from the recipe's own key files, `bin/sync-upstream` and the recipe's upstream hook, then makepkg and the PKGBUILD | you; sudo for missing build dependencies |
| Update, vendor row | download, digest check against the vendor's published list, `pacman -Qp` | you |
| Update, repo row | `pacman-conf`, Omarchy's repo database read with bsdtar as text, download of the package and its signature, sha256 check against the database, `gpg --verify` in pacman's keyring with a trusted key required, `pacman -Qp`; the signature again on the staged copy | you |
| Install of any built, repo or vendor package | `sudo install` into `/var/cache/omabump`, `pacman -U` on that copy, the package's install script, pacman hooks | root |
| Update, mise row | `mise install <tool>@<version>` and the tool's backend, asdf and vfox disabled | you |
| Update, Omabump row | git fetch of the release tag into the plugin's clone, after you answer y a fast-forward to it, `omarchy-plugin-validate`, then the shell loads the new plugin code | you |

What each guarantee covers, exactly:

- **No fetched code in the background check.** Feeds and recipes are parsed as text; nothing Omabump downloads is executed. A self-updating app's AppImage is only read: 7z extracts its one top-level desktop entry to standard output (at most 64 KiB, within 20 seconds); it is never run or mounted. mise runs with asdf, vfox and every installed plugin disabled as backends, so a tool named with one of them runs no plugin script (another plugin backend mise may add later is not covered by that setting; `mise outdated` is still asked only about tools on the allowed backends). A plugin you installed yourself can still run its version-listing script for a bare tool name whose configured version is missing (see [How CLI tools are found](#how-cli-tools-are-found)); that is your plugin's code, not something Omabump downloads. A `command` feed in your own `apps.json` is your code, and it runs. The shipped table has no command feeds. The whole check runs under `timeout -k 10 600`.
- **HTTPS only.** Omabump's own downloads allow only HTTPS, redirects included, with connect, total-time and size limits (8 MB for a feed, 4 GB for a package). Code from omarchy-pkgs that Build now runs is held to the same rule from outside: `bin/sync-upstream` and its hooks run with `CURL_HOME` pointing at a generated `.curlrc` (`proto = "=https"`, `proto-redir = "=https"`, time and size limits), and makepkg runs with a generated `--config` that sources your makepkg configuration and replaces `DLAGENTS` with an HTTPS-only curl (`http`, `ftp`, `scp` and `rsync` sources fail). Not covered: a hook that bypasses curl, git calls inside `bin/sync-upstream` (git does not read `.curlrc`), a PKGBUILD that sets its own `DLAGENTS`, and VCS sources (`git+https://...`), which makepkg fetches with git. None of the shipped apps' recipes does any of these at the pinned commit. `bin/sync-upstream` gets `TMPDIR` under `~/.cache/omabump/scratch` and runs without the maintainer-only `BYPASS_MIN_RELEASE_AGE`.
- **Checksums are integrity, not authenticity.** The vendor package's digest comes from the vendor's own unsigned manifest or list over HTTPS. It catches a corrupted or swapped download on the way (transport, CDN), not a compromised vendor. Build now likewise takes its hashes from the vendor's unsigned index through `bin/sync-upstream`, except for a source the recipe signs: that one is checked against the recipe's own keys (see [PGP keyring](#pgp-keyring)). Update's sha256 comes from Omarchy's unsigned database; what authenticates its package is the signature, by a key pacman's keyring trusts, which gpg checks before sudo and again on the root-owned staged copy pacman installs.
- **Every file a package installs is root's.** pacman installs each file with the numeric owner its package records. A vendor archive unpacked in `package()` without `--no-same-owner` keeps the IDs of the machine that packed it, as does a vendor package built that way: omarchy-pkgs found 222 files of bitwarden's aarch64 build owned by 1001:1001, a GitHub runner's IDs. On your machine uid 1001 is the second account, which could then replace them. So Update refuses a package, built or downloaded, with an entry not owned by root or in a group other than root, tty (5), ftp (11) or games (50), the fixed IDs Arch's own packages use. omarchy-pkgs' builds follow the same rule since 98353c6b; Build now builds newer releases than theirs, here, so it checks for itself: a vendor download before sudo (`--prepare` too), and every staged copy again. A listing that cannot be read refuses as well. The message names the first entries and their owners, the staged copy goes, and the package stays in `~/.cache/omabump/packages`.
- **Build now is not signed by Omarchy.** It runs Omarchy's recipe code, `bin/sync-upstream`, the recipe's upstream hook and the PKGBUILD, as you, from a commit reviewed for the release, and installs what makepkg built. The package carries no Omarchy signature. It is off until `buildAhead` is on, and it never runs from a check or in the background. Signed sources are verified in a keyring made for the build alone, from the key files the recipe ships at the pinned commit; your own keyring and keyservers are not consulted, and `--skippgpcheck` is never passed.
- **pacman asks before it installs.** Every install runs plain `sudo pacman -U`, so pacman shows the package and asks "Proceed with installation?". sudo may not ask for a password at all (a cached credential, or makepkg's own `sudo pacman -S` a moment earlier), so the pacman prompt is the point where you can still stop. Answering n prints "pacman did not install <pkg> <version> (you answered no, or it failed above)", and the verified package stays in `~/.cache/omabump/packages` for a retry. When pacman exits with an error after installing (a failed hook or install script), the install counts as done, with a warning to read pacman's output. makepkg installs missing build dependencies with `sudo pacman -S --asdeps`, and pacman asks for those too.
- **What is printed before pacman is inert.** Install scripts and the recipe diff go through a filter that shows ESC as `^[` and drops other control characters, so they cannot drive the terminal.
- **git and limits.** git, for the omarchy-pkgs clone and Omabump's own update alike, runs with hooks, fsmonitor, automatic gc and maintenance off and only the `https` protocol allowed. For the omarchy-pkgs clone, Omabump's own, your and the system's git config do not apply, so a `url.*.insteadOf` rule cannot point it elsewhere; only their `http.*` settings (proxy, CA bundle) are passed on, and proxy environment variables apply too. git fetches, `bin/sync-upstream` and mise calls run under `timeout -k`. Names from `apps.json` and `pins.json` (packages, mise tools, git refs) are checked before any of them reaches pacman, git, mise or a file name.
- **Temporary files.** Omabump's own locks and temporary files live under `~/.cache/omabump` and `~/.local/state`, never in the system temp directory; `bin/sync-upstream` gets a `TMPDIR` there too. Each check removes what a killed check left at once, and, once they are a day old, the scratch files a killed Update or an older release left (half downloads in `~/.cache/omabump/packages`, sync-upstream's temporary directories).

Before `pacman -U`, the verified package (the repo's or the vendor's download, or the makepkg output) is copied with `sudo install` into the root-owned `/var/cache/omabump` (read by you, written by root, so a symlink in its place cannot make root copy a file you cannot read), checked again there (its digest: the vendor's published one on the vendor route, the repo database's on the repo route, the sha256 of the file makepkg built, taken right after the build, for Build now; the name and full version; and who owns its files), and pacman installs that copy. The copy in the user-writable cache can no longer be swapped between verification and install.

The staged copy is removed once pacman finishes, whether or not it installed, and when its files have a foreign owner; only a copy that fails its digest or version check is kept, and the message names it. A run stopped while its copy is written or checked removes it with `sudo -n rm`. A run stopped while pacman runs (killed, or the terminal closed at pacman's prompt) leaves the copy to pacman, which may still be reading it: the path is recorded and printed with the `sudo rm -f --` to run once pacman has ended, and the next Update of that app removes recorded copies first, before it reads a feed or downloads anything (not while `/var/lib/pacman/db.lck` exists). Nothing is staged while that lock file exists; Update says a pacman is running, or that the lock file is stale.

### Marketplace baseline

The marketplace's static security baseline will report these capabilities, all expected:

- `privilege`: `sudo pacman -U` in `bin/omabump-install`
- `package-manager`: pacman (and gpg in pacman's keyring, and in a scratch keyring for a build), makepkg and mise
- `installer`: `bin/omabump-install` (scanned by its name)
- `remote-build`: Build now, once turned on, builds the omarchy-pkgs recipe at the pinned commit with makepkg

The two baseline findings that apply to this kind of plugin are addressed: omarchy-pkgs code runs only from a pinned 40-hex commit checked out detached (the clone fetches that commit by its SHA; only when a server refuses that does it fetch the pin's ref, and the commit must then be in it), and the vendor package is verified against the vendor's published digest before pacman sees it. Following master instead is an explicit opt-in ([Pinned snapshots](#pinned-snapshots)), and pinning the recipe code does not authenticate the vendor payload it downloads; see the checksum note above.

### External services contacted

The local refresh contacts no host: it fetches nothing, and runs mise with `MISE_OFFLINE=1`. The background check (every hour by default) fetches version feeds:

- `downloads.claude.ai` (Claude Desktop apt index)
- `persistent.oaistatic.com` (Codex apt index)
- `packages.perplexity.ai` (Perplexity apt index)
- `api2.cursor.sh` (Grok's update feed)
- `github.com` (`/releases/latest` redirects for T3 Code, Hermes and Omabump itself; the omarchy-pkgs clone, fetched only while Build now is on and a row is ahead), and `api.github.com` for such a release when github.com's page fails
- `registry.npmjs.org` (OpenClaw)
- `lmstudio.ai` (LM Studio download page)
- `zcode.z.ai` (ZCode update manifest)
- `kimi-img.moonshot.cn` (Kimi update feed)
- `aur.archlinux.org` RPC (Antigravity, Antigravity IDE, Trae)
- the [omarchy] repo's server pacman.conf names (`pkgs.omarchy.org`), for its database, `omarchy.db`, once a check, when a repo row is installed
- the source mise uses for each installed tool (`mise outdated`: npm, GitHub's API, PyPI or the vendor's URL, and mise's own registry, depending on the tool's backend; not mise's versions host). `mise ls` runs offline.

Update and Build now additionally contact:

- Update on repo rows: the [omarchy] repo's server (the database, the package and its signature)
- Build now: Omarchy's repo server too (its database, to see whether the repo has the release), then every host the recipe's sources and its upstream hook name: the vendor hosts above, `downloads.cursor.com` (Grok's packages), and GitHub release assets (T3 Code)
- vendor rows: `cdn-zcode.z.ai` (the ZCode package)
- mise rows: mise's versions host `mise-versions.jdx.dev` (the release's metadata, from its cache) and the tool's download host
- Omabump's own row: `github.com` (the release tag)

No other host, no telemetry.

### GitHub API calls

Without a token GitHub's REST API allows 60 calls an hour per IP address, shared by everything on the machine (and behind the same NAT) that calls it without one, mise in your terminal included; calls with a token count against your account's own 5,000 an hour instead. Omabump sends no token of its own: mise sends the one you gave it. `bin/sync-upstream` runs without `UPSTREAM_GITHUB_TOKEN`, even when your environment has it: with a token it replaces the `.curlrc` that holds its downloads to HTTPS and to their limits, and writes the token to a file under the cache. What it calls:

- mise rows: the check's `mise outdated` asks the API for the newest release of each installed tool whose versions come from GitHub (aqua and github backends, such as Claude Code, Codex, Crush and herdr), and mise caches each answer for an hour: about one call per such tool an hour, however often the panel checks. Tools from npm (OpenCode) or a vendor's site ask those instead. The check asks mise about a tool on GitHub only while at least 20 of the hour's calls are left, counting the ones it is about to spend on the tools before it: the rest keep the versions the last check found and say why, and so do all of them when GitHub does not say how many are left. If you gave mise a token (`MISE_GITHUB_TOKEN`, `GITHUB_TOKEN`, `github.credential_command`, git's credentials, or gh's when gh keeps it in its `hosts.yml` rather than the keyring), its calls count against your account, and the check asks as usual. Update installs through mise's versions host, which needs no call while it answers; it calls the API when that host fails, when you turned the host off (`use_versions_host = false`), and when a lockfile keeps the old version and Update runs `mise up`.
- GitHub release feeds (T3 Code, Hermes, Omabump itself): none, since the `/releases/latest` page is not the API. Only when github.com does not answer that page, or answers it with a 5xx, 403 or 429, does a feed ask the API: one call, and only while at least 20 of the hour's calls are left, counting the ones the check's mise rows may spend. A check reads that count once, from `/rate_limit`, which GitHub does not count against the limit. With fewer left, or no answer about them, the row says so and the check tries again later.

When the limit runs out, GitHub answers 403 or 429 until the hour is over. Omabump then shows the check as failed and tries once more five minutes later, not again until the next check.

## apps.json fields

How your own `~/.config/omarchy/omabump/apps.json` is merged over the shipped one, with an example, is in the README's [Adding an app](../README.md#adding-an-app). An entry larger than 64 KiB, after the merge, is dropped with a line on stderr. The fields:

- `pkg`: the package name in Omarchy's repo (also the omarchy-pkgs recipe's name), or the package name the vendor's package installs as. Any unique id for mise entries (`mise:<name>`).
- `source`: `repo`, `vendor-pkg`, `mise` or `indicator`; an entry with any other source (`self` is Omabump's own row) is dropped. `omarchy`, the source of 0.1.19 and before, is read as `repo` with `"build": true`, unless the entry sets `build` itself.
- `build` (optional, `repo` entries): `true` lets Build now build the entry's recipe in omarchy-pkgs. It must be a boolean: any other value drops the entry with a line on stderr. Without it the row is never buildable, and its note says `Not in Omarchy's repo yet`.
- `installed` (optional): package names to look for with `pacman -Q`, default `[pkg]`.
- `section` (optional, not for mise): `"cli"` lists a pacman package among the CLI tools, which Show CLI tools hides with the mise rows; `"desktop"` is the default. An entry with any other value is dropped.
- `tool` (mise only): the mise tool name, or a list of names; the first one mise has active is used. Setting it in your file replaces the list.
- `vendorPkg` (vendor-pkg): HTTPS package URL per architecture (`uname -m`), with `{version}` replaced by the feed's version.
- `checksum` (vendor-pkg, required for Update): `"feed"` reads the base64 `sha512` listed next to the file's `url` in the feed document (electron-updater's `latest.yml` format, as ZCode's manifest uses), or `{"url": ..., "algo": "sha256"|"sha512"}` reads a `sha256sum`-style list.
- `configDir` (optional): where the app keeps its settings, printed before a switch.
- `appImage` (optional, not for mise): the app's self-updating AppImage, a path under your home written `~/...` (letters, digits and `._+-`, no `.` or `..` component, at most 200 characters), used only when none of the `installed` packages is there. It must be a regular file you own, not a symlink, at most 2 GiB. `"appImage": ""` in your own file turns a shipped one off.
- `npmPackage` (optional, not for mise): the directory of the app's self-updating npm package, a path written as for `appImage`. Its `package.json`, a regular file you own, not a symlink, at most 1 MiB, gives the version, and while it is there the row is that copy's, whatever packages are installed. `"npmPackage": ""` in your own file turns a shipped one off.
- `selfUpdate` (optional): how the app updates itself, at most 100 characters, for a self-updating row's note (`Updates itself: <selfUpdate>`), its notification and the installer's refusal. The default is `open <label> to update`.
- `updateBlocked` (optional): a short reason, at most 200 characters, that turns Omabump's Update off for the row: the row still shows its versions and notifies, and says "Update off: <reason>", and `bin/omabump-install` refuses it. The shipped table uses it for a known problem in what Update would install. `"updateBlocked": ""` in your own file turns a shipped block off.
- `feed`: where the newest version comes from. Optional on a `repo` entry: without one the repo's version is the only newest one and the row is never ahead. `url` may be a string or an object keyed by `uname -m`, and must be HTTPS.
  - `apt-index` with `url` and `package`: a Debian `Packages` file.
  - `zcode-manifest` or `latest-yml` with `url`: YAML with `version:`.
  - `github-release` with `repo`: the tag behind `/releases/latest`. When github.com does not answer that page or answers it with a 5xx, 403 or 429, the REST API's latest release names it instead, one unauthenticated call. A 404 or a redirect to the releases page means no release.
  - `json` with `url` and `path`: a jq path into a JSON document. The body must be exactly one JSON document and the path must give one value.
  - `regex` with `url` and `pattern`: a Python regex with one capture group.
  - `aur-rpc` with `name`: the AUR's version, pkgrel stripped.
  - `command` with `command`: a local shell command that prints the version. It runs during the background check, so it is accepted only when your own `~/.config/omarchy/omabump/apps.json` sets the entry's `feed`; a command feed from the shipped `apps.json` is refused.
- `icon` and `iconLight` (optional): SVG marks for dark and light themes, as paths relative to the plugin directory. Absolute paths, URLs and `..` are ignored. Put your own marks in `assets/user/`, which git ignores, so they never count as local changes that would stop Omabump's own Update. A mark under a new path, or a removed one, shows at the next [local refresh](#the-local-refresh), the next time the panel opens. An SVG edited in place can keep its old picture until the shell restarts (`omarchy restart shell`), because the shell caches a picture by its path; give the file a new name to see it at once.

pacman versions are compared with `vercmp`; mise versions are left to mise; a self-updating AppImage's stable version is compared with `vercmp` as it is, and a pre-release not at all.

## Development and tests

`bash tests/run.sh` runs every suite: the bash helpers, whole checks and installs against fake `pacman`, `pacman-conf`, `gpg`, `sudo`, `curl`, `git` and `mise` (no network, no root; Omarchy's repo database is a zstd tar the tests build with bsdtar), the widget's logic in `Model.js` through node (`tests/model.test.mjs`), the panel's cursor under the pointer (`tests/tst_pointer.qml`, offscreen through qmltestrunner), and the weekly pin report's script. It needs `vercmp` (pacman), `jq` and `python`; without `node` the `Model.js` tests and the runs of `bin/omabump-check` by the command lines `Model.js` builds (`tests/qml.sh`), and without `qt6-declarative` the pointer test, are reported as skipped, except on CI, where they fail. Run it in the foreground: the Ctrl-C tests need a shell that can trap INT. The suite comes in parts, which `tests/run.sh --list` names (`unit`, `model`, `qml`, `check`, `install`, `pin-watch`): `tests/run.sh check install` runs only those two, each from a clean scratch directory, and every part prints its time as it ends. After a change to one file, run the part that tests it (`unit` for `bin/omabump-common`, `model` and `qml` for `Model.js`, `qml` for the QML), then the whole suite before a commit. CI also runs `bash -n` and shellcheck on the scripts and checks that `manifest.json`, `apps.json` and `pins.json` parse.

# Changelog

## 0.1.14 (2026-11-13)

- When a check runs is decided by the checker, under its lock, instead of by each bar's panel: every minute, and when the panel opens, each bar asks `bin/omabump-check --if-due`, which runs a check only when one is due by the times in status.json and otherwise exits 76 having written nothing. The bars on several monitors now agree on when a check is due. A check killed outright is retried about five minutes after it started, by the next bar to find its lock free, instead of after ten minutes of waiting for its "checking" mark to go stale. A check that died before it wrote anything counts as failed by its attempt (`check-attempt` in the state directory), so it is retried once, not every minute. The panel shows no "Checking…" for a question that finds no check due.
- Ask agent is gone, with Copy prompt (`c`) and `bin/omabump-prompt`. It started your default coding agent on a row Omabump cannot update, and `omarchy-agent` starts most agents without their own approval prompts, so the agent could run commands on the system without asking, for a case where the row's note already says how the app updates. Such a row now has no action: `Enter` does nothing on it and the cursor's first-action logic skips it; its note and tooltip stay.
- Mute and skip take the checker's word: the panel reads whether a skip applies from status.json instead of working it out with its own copy of vercmp. A skip or unskip with `K` still shows at once; a skip set by hand in shell.json, of any version but the row's newest, shows after the next check. A skip leaves the settings only once a check found it over (status.json's new `skipEnded`): before, pressing `m` or `K` on any row could delete a skip no check had read yet, such as `0.66.0` against a newest of `0.66`. The panel reads the settings with the checker's limits too (the first 200 entries, only skip versions it accepts), so it no longer shows a row as quiet that the checker notifies about.
- Omabump's own Update rolls back plainly: when the fast-forward or the validation fails, or the run is stopped before the validation passed, it resets the clone with `git reset --hard` and `git clean -fd` and says the old version is still installed. What still holds: the clone ends at the installed commit or at a released, validated one; Ctrl-C, a closing terminal or a `kill` of the installer during the merge or the validation waits for that step to end and then rolls back, so a rollback never races a merge still running; neither cuts the rollback short, so it finishes and says how it went; `git clean` never takes `-x`, so your ignored files stay; and the clean-tree checks see untracked files even under `status.showUntrackedFiles=no`, which hid files the rollback then deleted. What no longer does: a rollback after a merge that git itself failed part way no longer removes the files that release added that git ignores.
- The tests run in parts: `tests/run.sh --list` names them (unit, model, qml, check, install, pin-watch), `tests/run.sh check install` runs only those, each from a clean scratch directory, and each part prints its time as it ends. No argument runs them all, as CI does.
- The README is the short one now: what Update does to your machine, using it, the supported apps, adding an app. How it works inside, from the check's schedule and exit codes to the security model and the full apps.json reference, moved to [docs/internals.md](docs/internals.md). The development notes no longer say CI runs `py_compile`, which it does not, and say which tools a missing test skips for.
- Less code behind the panel: the JavaScript port of vercmp and its 310-row parity table, the panel's own check schedule, and some of the tests that only read source text are gone.

## 0.1.13 (2026-11-12)

- The CLI rows come from the list in apps.json alone: Omabump no longer reads Omarchy's menu and the `~/.local/bin` wrappers to find agents. Omarchy 4 renamed the menu's entries and stopped writing those wrappers, so the search found nothing there and the panel said "Agent discovery: … lists no entries". The list gains the agents it lacked: Kilo, Kiro CLI, Devin CLI, DeepSeek Harness, MiniMax Code, Command Code, Freebuff, Muse Code, and Omarchy's Kimi package under Kimi CLI. An agent Omarchy adds later shows once apps.json, or your own, names it. An entry's `command` field went with the search, and so did hiding a row by Omarchy's command name: `{"pkg": "mise:grok", "disabled": true}` no longer hides Grok CLI, its own `mise:grok-cli` does.
- voxtype-bin is no longer in the list; `omarchy update` updates it as before. Its recipe is the heaviest of these apps' and changed often enough that keeping Update working took a plugin release each time (0.1.5, 0.1.8, 0.1.11, 0.1.12), for a lead of hours: the recipe holds a new release for 24 h, then the [omarchy] repo follows. A row without Update would show GitHub's newer version for that day with nothing to do about it, and dictation is now a choice of three in Omarchy. The build keyring 0.1.12 added for its signed downloads goes with it. To keep a row, add `{"pkg": "voxtype-bin", "label": "Dictation (voxtype)", "source": "indicator", "feed": {"type": "github-release", "repo": "peteonrails/voxtype"}}` to your own apps.json.
- An indicator row whose package one of pacman's repos has says "Updates with omarchy update", as an AUR one installed from the AUR already did.
- An Update of a mise tool that did not make the new version the active one now fails. It said so and then ended as a success.
- A check no longer spends GitHub's last 20 unauthenticated API calls on a batch of mise tools: with 20 left and 17 tools on GitHub it asked about all 17. Each tool now counts, and those past the reserve keep the last check's versions and say why.
- A check that runs while pacman is replacing a package keeps that package's row, marked failed and read again by the retry five minutes later, instead of dropping it.
- The panel's header says "N updates" for the rows with an Update button only, as the bar icon counts them. Newer releases Omabump does not install read "N newer, no Update here". The list follows: a new version is red only on a row with an Update, and plain where it is held, updated elsewhere or has no install path.
- Less work in the background: the offline refresh of the installed versions, every 5 minutes on each bar, now runs only while the bar counts an update, and when the panel opens, as before.
- The check interval is at least 5 minutes. It was one, and set that low by hand it meant a full check every minute. The shell's settings page words the toggles as the panel does.
- The weekly pin-watch issue keeps a recipe's diff inside its code block when the recipe has a line of three backticks of its own; such a line closed the block, and the rest of the diff then read as the issue's Markdown, mentions included.
- Removed: the `recipeCommit`, `recipeFetch` and `recipeNote` options of apps.json, which no shipped row has used since 0.1.4, and the handling of a status.json written by 0.1.1 or older.

## 0.1.12 (2026-11-12)

- Update works for voxtype-bin again. The omarchy-pkgs pin moves from c1f46a3 (2026-11-01) to a988526 (2026-11-12), the merge of [omarchy-pkgs#2518](https://github.com/omacom/omarchy-pkgs/pull/2518). The recipe now downloads a GGUF worker for every voxtype binary, checks its signature like the binary's, and installs it beside the binary; requires `vulkan-icd-loader` on x86_64, which the workers of the Vulkan and ONNX binaries link; and ships voxtype's Settings panel for Omarchy in `/usr/share/voxtype/omarchy-plugin`. To lay the panel out, `package()` runs `scripts/stage-omarchy-plugin.sh` from voxtype's source archive, whose signature the recipe checks too; in 1.2.1 that script only copies files into the package. Nothing else Update runs differs between the two pins: `bin/sync-upstream` and the helpers it names are the same files, and the other shipped apps' recipes changed only in the lines a sync rewrites. The pin is hours old, not the three days the weekly pin report waits for, because that one recipe is all that changed and it was read in full. The `updateBlocked` entry from 0.1.11 is gone.
- Update of voxtype-bin no longer needs voxtype's signing key in your keyring. The recipe checks a PGP signature on every file it downloads, and makepkg looked for the key in your own keyring: without it there, the build stopped at "unknown public key", after the downloads (so the Update 0.1.11 turned off could install a 1.2.1 without workers only where the key was). Since omarchy-pkgs c05469c8 a recipe ships the keys it trusts as `keys/pgp/<FINGERPRINT>.asc`, and omarchy-pkgs' own builds import exactly those. Update now does the same: the build gets a keyring of its own in `~/.cache/omabump/gnupg`, made from the files `validpgpkeys` names at the pinned commit, each of which must hold that one key and nothing else, and removed after the build. Your keyring is neither read nor changed, no keyserver is asked, and with that keyring makepkg signs nothing (`--nosign`). The run names the keys the build trusts, under `--prepare` too. A recipe that lacks the file of any key it trusts builds with your keyring, as before.

## 0.1.11 (2026-11-12)

- Update is off for voxtype-bin until [omarchy-pkgs#2518](https://github.com/omacom/omarchy-pkgs/pull/2518) is merged and pinned. Since voxtype 1.2.0 every voxtype binary runs GGUF models, its new default Parakeet model among them, through a worker binary shipped beside it (`*.gguf-worker`), and the recipe at the pinned omarchy-pkgs commit lists only the files 1.1 had. Every file that recipe names still exists in the 1.2.1 release, so the build does not fail: once the recipe's 24-hour hold on 1.2.1 is over (2026-11-11 21:23 UTC at the earliest), Update in 0.1.10 and older builds and installs it without its workers. If you ran that Update, `sudo pacman -S voxtype-bin` puts the repo's package back. The row still shows its versions and notifies; Update and Ask agent are gone, and the row says why. `omarchy update` installs 1.2 as soon as the [omarchy] repo has it.

## 0.1.10 (2026-11-08)

- Update refuses a package whose files pacman would install with an owner other than root. pacman installs each file with the numeric owner its package records, and a vendor archive unpacked without `--no-same-owner` keeps the IDs of the machine that packed it: omarchy-pkgs found 222 files of bitwarden's aarch64 build owned by 1001:1001, which on your machine is the second account, able to replace them. Every file must be root's, in group root, tty, ftp or games, the rule omarchy-pkgs' own builds follow since 98353c6b. Update builds newer releases than theirs, here, so it checks for itself: a vendor download before sudo (and under `--prepare`), and every staged copy, built or downloaded, again. The message names the first entries and their owners, and the package stays in `~/.cache/omabump/packages`. omarchy-pkgs' builds of all its other packages pass.
- The weekly omarchy-pkgs pin report ([#2](https://github.com/Vladkarok/omabump/issues/2)) no longer flags what an Update would not do differently after a bump. It follows the files `bin/sync-upstream` and the shipped apps' hooks name in code, through what those name, at the pin and on master, instead of all of `helpers/`; the rest, such as `artifact-helpers.sh` and `package-owners.sh`, is omarchy-pkgs' build and publish tooling, listed but not counted. Should that code start computing a helper's name, every helper counts again. A file the blob-less clone fails to fetch now fails the run; before, a recipe could read as unchanged and the issue close. grok-bot's `_commit`, which its hook points at Cursor's newest build on every Update, counts as routine, as pkgver does. The pin stays at c1f46a3: nothing Update runs has changed since.

## 0.1.9 (2026-11-08)

- A GitHub release feed (T3 Code, Hermes, voxtype, Omabump itself) no longer fails the check when github.com's release pages fail. On 2026-11-08 they answered 504 for minutes, cached at GitHub's edge, while the REST API answered: a feed now asks the API's latest release when the `/releases/latest` page gives no answer, a 5xx, a 403 or a 429, one unauthenticated call. Those 60 calls an hour per address are shared with everything else here that calls the API without a token, mise in your terminal included, so the fallback first reads `/rate_limit` (not counted) and leaves the last 20 alone.
- The check leaves those last 20 calls alone for mise too. While fewer are left, or GitHub does not say, it does not ask mise about the tools whose versions come from GitHub (aqua, github and ubi backends), and their rows keep the last versions found and say why. Unless mise sends a token of yours: then its calls count against your account's 5,000 an hour. A check reads `/rate_limit` once and counts what its mise rows and fallbacks may spend. The error no longer reads "has no latest release (504)" for a page that failed: it names what github.com and the API answered.
- The README's new "GitHub API calls" section lists every call Omabump makes to GitHub's API and when.

## 0.1.8 (2026-11-02)

- Update works for voxtype-bin again. The omarchy-pkgs pin moves from eba2a95 (2026-10-13) to c1f46a3 (2026-11-01), which has omarchy-pkgs#937: the recipe's install script hands the active backend from `pre_upgrade` to `post_upgrade` through `/run/voxtype-backend-upgrade`, which only root can write, and installs only a binary from `/usr/lib/voxtype`. The `updateBlocked` entry from 0.1.5 is gone.
- OpenClaw's row has no Update. omarchy-pkgs made the `openclaw` package the seed of a copy in `~/.openclaw` that updates itself (omarchy-pkgs#797), which Omarchy's migration 1792334754 sets up. Update built the package from the pinned recipe: at the old pin it put OpenClaw back in `/usr`, ahead of that copy on PATH, and at the new one it would take OpenClaw out of `/usr` on a machine that still runs it from there. Once the copy is there, the row shows its version, read from its `package.json` without running it, against npm's newest, says "Updates itself: run openclaw update", and notifies once per release, as T3 Code's AppImage row does. While only the package is there, the row says Update is off and why. New `apps.json` fields `npmPackage` and `selfUpdate`. A self-updating row's notification now ends as its note does ("Updates itself: open T3 Code to update.").
- Grok's newest version comes from Cursor's update feed, as its recipe's watch now does; Cursor's apt index, which the row read before, can lag it. On an Update the recipe's hook downloads both architectures' packages to hash them, about 210 MB more.
- What else the bump brings: routine version bumps, Hermes on aarch64 (still no upstream watch, so still no Update), and in `bin/sync-upstream`'s helpers GitHub requests over HTTP/1.1 with retries and at most 30 s per attempt; the rest of what changed in `bin/` and `helpers/` is the [omarchy] repo's own build and publish tooling, which Update does not run. Every recipe's version bump now merges once CI passes.

## 0.1.7 (2026-10-23)

- A new agent CLI release shows and installs as soon as its source has it. Finding it no longer goes through mise's versions host, which listed Codex 0.164.0 more than nine hours after its release while T3 Code already offered it: mise asks each installed tool's own source, one light request per tool (GitHub's `/releases/latest`), cached for an hour. Update now installs exactly the version the check found (`mise install <tool>@<version>` instead of `mise up`, which still runs when a lockfile keeps the old version active), through the host unless you turned it off, so it no longer pulls GitHub's 45 MB list of Codex releases, which timed out with 504s, and needs no GitHub API request while the host answers. The check leaves alone the tools Omarchy's config names but you have not installed (`MISE_DISABLE_TOOLS`) and runs `mise ls` offline, which cut its GitHub requests from about 14 an hour to one per installed tool. mise's install counter is off. Without a GitHub token the requests count against GitHub's 60 an hour per address; the README says how to give mise one.
- A pinned or ranged mise tool whose version list could not be fetched (a rate limit, a 504) reads as a failed check, not as current.
- A check that failed (offline after a resume, a feed that timed out) is tried once more 5 minutes after it started instead of an hour later. Only once: a retry that fails waits the usual interval. status.json gains `retry`; `bin/omabump-check` gains `--retry`.
- The panel's cursor follows the pointer onto a row again when one fast move lands there, which 0.1.6 missed. A pointer at rest still moves nothing, now also when the card moves under it (a bar at the bottom or a side, as the content grows) or when it rests on a section header while the list scrolls. The rule is in `PointerGate.qml`, and `tests/tst_pointer.qml` runs it under qmltestrunner.

## 0.1.6 (2026-10-23)

- The panel rereads installed versions between checks, offline (mise with `MISE_OFFLINE=1`): when it opens (or it runs the full check, when one is due) and every 5 minutes (`bin/omabump-check --local`). An app updated outside Omabump, by `omarchy update` or an Omarchy wrapper updating a mise CLI on launch, no longer keeps offering an Update that is already installed; nor does Omabump's own row after `omarchy plugin update`. A version the refresh cannot judge alone (past the newest known one, a mise tool at another version, a new app) shows "Not checked yet" and starts one full check. status.json gains `inventoryAt`; a check that meets a local refresh waits for it.
- Update no longer ends in a red "Failed" when the version the panel offered is already installed: it says so, refreshes the panel and succeeds. When the route cannot reach the version the panel showed, it fails naming both versions. Omabump's own Update ends the same way. On vendor rows, a missing checksum no longer fails an Update with nothing to download. `--prepare` prints the decision and stops where a real run would: a refusal by Omabump's rules prints `Would refuse: ...` and exits 0, while a failure (a download, a build, git) still exits 1.
- T3 Code shows again after Omarchy's migration 1792345511 replaced its package with T3 Code's self-updating AppImage: the row reads the AppImage's version with 7z (optional dependency `7zip`), without running it, and offers no Update, Switch or Ask agent, since the app updates itself; the installer refuses it. A nightly or unreadable version is shown but not compared, and counts as unchecked. The local refresh follows the app's own updates. New `apps.json` field `appImage`; status.json rows gain `selfUpdating`.
- The panel's cursor stays on its app when the rows change under it (a check, or the refresh on open), or, until you move it or act on a row, goes to the first row with something to do, and scrolls into view: Enter no longer does nothing, or acts on another app, right after the panel opens. A pointer at rest over the rows no longer pulls the cursor to its row when they are rewritten.

## 0.1.5 (2026-10-20)

- Update is off for voxtype-bin until omarchy-pkgs#937 is merged and pinned. Its recipe's root install script hands the active backend from `pre_upgrade` to `post_upgrade` through `/tmp/.voxtype-backend-upgrade`, and another local user can plant that file to have their own executable installed as `/usr/bin/voxtype` (reported in the marketplace review, omacom/omarchy-plugin-marketplace#10910). The row still shows its versions and notifies; Update and Ask agent are gone, and the row says why.
- A new `apps.json` field, `updateBlocked`, turns Update off for a row with a reason; the checker marks such rows `blocked` in status.json and `bin/omabump-install` refuses them.

## 0.1.4 (2026-10-16)

- The omarchy-pkgs pin moves from 2c1d7c0 (2026-10-01) to eba2a95 (2026-10-13). T3 Code 0.1.0 renamed the compatibility libraries inside its AppImage, and the old recipe's check stopped the build ("Unexpected files in the AppImage's usr/ tree"); the new recipe accepts the new names, which are still left out of the package.
- Grok's recipe is omarchy-pkgs' own now (PR #725 was merged), with its own watch on Cursor's apt index; the `recipeCommit` entry in apps.json is gone.
- What else the bump brings: routine version bumps, LM Studio's recipe adds aarch64 (on x86_64 its sync also downloads the arm64 AppImage to hash it, about 1.3 GB), and `auto_merge` in omarchy-pkgs for most of these recipes, so the [omarchy] repo follows their vendors within hours. The code Update runs (`bin/sync-upstream`, `helpers/`) changed only where no shipped app reaches it. Hermes still has no upstream watch, so it still has no Update.

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

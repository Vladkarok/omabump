.pragma library

// The widget's rules, apart from the QML that shows them: Main.qml and
// Panel.qml bind to these, and tests/model.test.mjs runs them under node.
// Nothing here may touch QML types or Quickshell; values in, values out.
//
// The bar hands lists over as a QVariantList, which Array.isArray does not
// accept, so lists from the settings are read by index (isList).

// --- text --------------------------------------------------------------------

// Every word the panel shows comes from the catalogs in i18n/, one flat
// JSON file per Omarchy language code; i18n/en.json is English's one home.
// A function here that returns text takes a translator tr first, which
// Panel.qml builds over Omarchy's Commons.Translations (or, on a shell
// without it, catalogTranslator over en.json):
//   tr.t(key)       the string for key (a plural entry's "other" form)
//   tr.tn(key, n)   the form of a plural entry for the count n
//   tr.has(key)     whether the catalogs hold key
//   tr.num(n)       the number n written the language's way
//   tr.date(sec)    the moment sec (epoch seconds) written the language's way
// Model.js picks the key and the arguments; fill puts them in the string's
// %1..%n holes. A key is always written out whole here, never put together
// from pieces, so that tests/model.test.mjs finds every key in use.

// text with its %1..%n holes filled from args, in one pass: an argument
// that holds "%1" itself stays as it is. A hole with no argument stays.
function fill(text, args) {
  var list = args || []
  return String(text).replace(/%([0-9]+)/g, function(hole, n) {
    var i = Number(n) - 1
    return i >= 0 && i < list.length ? String(list[i]) : hole
  })
}

// The string for key, filled with args.
function say(tr, key, args) { return fill(tr.t(key), args) }

// The form of the plural entry key for the count n, n (in the language's
// digits) its %1, args after it.
function sayCount(tr, key, n, args) { return fill(tr.tn(key, n), [tr.num(n)].concat(args || [])) }

// A note the panel made itself ({key, args}, as skipToggled and
// buildOffNote give it), in the language; "" for none.
function noteText(tr, note) {
  return note && typeof note.key === "string" ? say(tr, note.key, isList(note.args) ? note.args : []) : ""
}

// A catalog's text as an object, {} for anything else: what
// Commons.Translations makes of a file it cannot read.
function parseCatalog(text) {
  try {
    var parsed = JSON.parse(String(text || "{}"))
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {}
  } catch (e) {
    return {}
  }
}

// English's plural rule: the CLDR category of the count n.
function englishPlural(n) { return Math.abs(Math.trunc(Number(n) || 0)) === 1 ? "one" : "other" }

// A translator over catalogs, nearest first, by the rules
// Commons.Translations follows: layers is a list of {strings, plural},
// strings a parsed catalog and plural(n) its language's CLDR category for
// a count. A key no layer has is itself. The fallback Panel.qml uses on a
// shell without Commons.Translations (Omarchy before 4.5.0): en.json alone,
// by englishPlural, numbers as JavaScript writes them; date is the
// panel's. tests/model.test.mjs builds its translators with it too.
// A catalog value the translator can word: a string, or plural forms with
// an "other".
function usable(v) {
  return typeof v === "string" && v.length > 0 || !!v && typeof v === "object" && typeof v.other === "string" && v.other.length > 0
}

// The highest %n hole of a string: how many arguments it needs.
function holesOf(text) {
  var max = 0, re = /%([0-9]+)/g, found
  while ((found = re.exec(String(text))) !== null) max = Math.max(max, Number(found[1]))
  return max
}

function catalogTranslator(layers, date) {
  function value(layer, key) {
    var v = layer.strings ? layer.strings[key] : undefined
    return typeof v === "string" || (v && typeof v === "object") ? v : undefined
  }
  function first(key) {
    for (var i = 0; i < layers.length; i++) {
      var v = value(layers[i], key)
      if (v !== undefined) return v
    }
    return undefined
  }
  return {
    t: function(key) {
      var v = first(key)
      if (v && typeof v === "object") v = v.other
      return typeof v === "string" && v.length > 0 ? v : key
    },
    tn: function(key, n) {
      for (var i = 0; i < layers.length; i++) {
        var v = value(layers[i], key)
        if (v && typeof v === "object") {
          var form = v[layers[i].plural(n)]
          v = typeof form === "string" && form.length > 0 ? form : v.other
        }
        if (typeof v === "string" && v.length > 0) return v
      }
      return key
    },
    has: function(key) { return usable(first(key)) },
    num: function(n) { return String(n) },
    date: date
  }
}

// --- settings ----------------------------------------------------------------

function isList(value) {
  return !!value && typeof value === "object" && typeof value.length === "number"
}

function setting(settings, name, fallback) {
  var value = settings ? settings[name] : undefined
  return value === undefined || value === null ? fallback : value
}

// `omarchy bar set <id> notify false` without --json stores the string
// "false", so "true" and "false" in any case count as the booleans, as
// load_quiet in bin/omabump-common reads them. Anything else is the fallback.
function boolSetting(settings, name, fallback) {
  var value = setting(settings, name, fallback)
  if (typeof value === "string") value = value.trim().toLowerCase()
  if (value === true || value === "true") return true
  if (value === false || value === "false") return false
  return fallback
}

// Settings renamed since an earlier release, new name to old: the old key
// counts while the new one is absent, as load_quiet in bin/omabump-common
// reads it, and the next settings write stores the new one
// (settingsEntry). showCli was showMise until 0.1.19; the shim can go once
// no shell.json written before 0.2.0 is left to read.
var legacyKeys = { showCli: "showMise" }

// A boolean setting by its current name, the old one standing in.
function settingValue(settings, name, fallback) {
  var old = legacyKeys[name]
  if (old !== undefined && setting(settings, name, undefined) === undefined)
    return boolSetting(settings, old, fallback)
  return boolSetting(settings, name, fallback)
}

// Show CLI tools (default on) and Build now (default off).
function showCli(settings) { return settingValue(settings, "showCli", true) }
function buildAhead(settings) { return settingValue(settings, "buildAhead", false) }

// Between five minutes and a day, whatever shell.json holds: a check asks
// every feed, and nothing they say changes faster than that.
function refreshIntervalSec(settings) {
  return Math.min(86400, Math.max(300, Number(setting(settings, "refreshIntervalSec", 3600)) || 3600))
}

// --- mute and skip settings ----------------------------------------------------

// A version as mise or a feed prints it, or a full pacman version with its
// epoch (a repo row's 1:2.0-1): skip_version_ok in bin/omabump-common,
// which load_quiet applies to every skip it reads. skippedVersions drops
// one it refuses and skipToggled refuses to store one: the panel would
// show that skip while the checker never applies it.
function versionOk(v) {
  return v.length <= 64 && /^[0-9A-Za-z][A-Za-z0-9._+~]*$/.test(v) && v.indexOf("..") === -1
}
// full_version_ok: [epoch:]pkgver-pkgrel.
function fullVersionOk(v) {
  var m = /^(?:([0-9]{1,9}):)?(.*)-([0-9]+(?:\.[0-9]+)?)$/.exec(v)
  return !!m && versionOk(m[2])
}
function skipVersionOk(v) {
  if (typeof v !== "string") return false
  return v.length <= 64 && /^[0-9A-Za-z][A-Za-z0-9._+~-]*$/.test(v) && v.indexOf("..") === -1 || fullVersionOk(v)
}

// load_quiet reads only the first quietMax strings of each setting, and
// drops the ones it refuses after that cut, not before. The bar may hand
// the skips over in another key order than shell.json has, so only past
// the cap could the two keep different ones.
var quietMax = 200

// Rows the user muted (pkg ids): no badge, no count, no notification. Only
// listed rows are looked up in it, and every row's id is one load_quiet
// accepts, so the strings need no check of their own.
function mutedApps(settings) {
  var list = setting(settings, "mutedApps", [])
  var out = []
  if (!isList(list)) return out
  for (var i = 0, n = 0; i < list.length && n < quietMax; i++) {
    if (typeof list[i] !== "string") continue
    n++
    if (out.indexOf(list[i]) === -1) out.push(list[i])
  }
  return out
}

// {pkg: version} the user skipped. Whether a skip still applies is the
// checker's answer, the row's skipped (isSkipped).
function skippedVersions(settings) {
  var map = setting(settings, "skippedVersions", {})
  var out = {}
  if (!map || typeof map !== "object" || isList(map)) return out
  var n = 0
  for (var pkg in map) {
    if (typeof map[pkg] !== "string") continue
    if (n++ >= quietMax) break
    if (skipVersionOk(map[pkg])) out[pkg] = map[pkg]
  }
  return out
}

// --- mute and skip -------------------------------------------------------------

// The row the last check listed for pkg, or null.
function appFor(apps, pkg) {
  for (var i = 0; i < apps.length; i++) if (apps[i].pkg === pkg) return apps[i]
  return null
}

// A row's label by pkg, from the last check, else the pkg itself.
function appName(apps, pkg) {
  var app = appFor(apps, pkg)
  return app ? String(app.label || pkg) : pkg
}

function isMuted(muted, app) { return !!app && muted.indexOf(String(app.pkg)) !== -1 }

// The version skipped for this row, if any.
function skippedVersion(skipped, app) {
  return app && Object.prototype.hasOwnProperty.call(skipped, app.pkg) ? skipped[app.pkg] : ""
}

// Whether a skip of version still applies to the row. The checker decides
// (row_skipped in bin/omabump-common, by vercmp or by string) and writes
// the answer as the row's skipped; the panel compares no versions. Until a
// check has read a new skip, the row's newest version being the skipped
// one stands in for that answer: K stores exactly that, so a skip shows at
// once. A newer release comes with skipped false and another newest
// version, and an install of the skipped one with no update, so either
// ends the skip.
function skipHolds(app, version) {
  version = String(version || "")
  return version !== "" && app.updateAvailable === true
    && (app.skipped === true || version === String(app.latest || ""))
}

// A row whose update the user skipped. There is a skip only while the
// settings as they are now hold one, so an unskip shows at once too.
function isSkipped(skipped, app) {
  return !!app && app.updateAvailable === true && skipHolds(app, skippedVersion(skipped, app))
}

// A row that signals nothing: muted, or at a skipped version.
function isQuiet(muted, skipped, app) { return isMuted(muted, app) || isSkipped(skipped, app) }

// Whether the settings keep the skip of version for pkg: until the last
// check or local refresh read that very skip and found it over (the row's
// skipEnded, from skip_over in bin/omabump-common), so a skip no run has
// read yet stays whatever its version. Kept too while the last check
// cannot tell: a row it did not list (hidden by Show CLI tools, not
// installed now) and one that failed, is stale, is being checked, was not
// checked or has no newest version.
function skipKept(apps, pkg, version) {
  var app = appFor(apps, pkg)
  if (!app || app.checking === true || app.stale === true || app.unchecked === true
    || String(app.error || "") !== "" || String(app.latest || "") === "") return true
  return String(app.skipEnded || "") !== String(version)
}

// The skips a settings write keeps: one goes once a run found it no
// longer applies (a newer release than the skipped one, or that version or
// a later one installed); one the last check cannot judge stays.
function liveSkips(apps, skips) {
  var out = {}
  for (var pkg in skips) if (skipKept(apps, pkg, skips[pkg])) out[pkg] = skips[pkg]
  return out
}

// Whether every listed row from source is muted (and there is one). A
// self-updating app takes no route of its source, so a failure of that
// route (mise's inventory) is none of its business.
function allMuted(apps, muted, source) {
  var any = false
  for (var i = 0; i < apps.length; i++) {
    if (apps[i].source !== source || selfUpdating(apps[i])) continue
    if (!isMuted(muted, apps[i])) return false
    any = true
  }
  return any
}

// mutedApps after m on app: unmuted if it was muted, else muted.
function mutedToggled(muted, app) {
  var list = muted.filter(function(pkg) { return pkg !== app.pkg })
  if (!isMuted(muted, app)) list.push(app.pkg)
  return list
}

// skippedVersions after K on app, as { skips }; { note } when its newest
// version is not one the checker reads (skipVersionOk), the note as
// noteText reads it; null with nothing to skip.
function skipToggled(skipped, app) {
  var skips = {}
  for (var pkg in skipped) if (pkg !== app.pkg) skips[pkg] = skipped[pkg]
  if (!isSkipped(skipped, app)) {
    if (app.updateAvailable !== true || String(app.latest || "") === "") return null
    if (!skipVersionOk(String(app.latest))) return { note: { key: "row.skipRefused", args: [String(app.latest)] } }
    skips[app.pkg] = app.latest
  }
  return { skips: skips }
}

// The settings line under the toggles. Only rows the last check listed: a
// mute or skip for a row hidden by Show CLI tools (or not installed now)
// is kept but not shown. Only skips the settings keep (skipKept): one that
// no longer applies is dropped on the next write, not listed as active
// until then.
function quietText(tr, apps, muted, skipped) {
  var names = []
  for (var i = 0; i < muted.length; i++)
    if (appFor(apps, muted[i]) !== null) names.push(appName(apps, muted[i]))
  var skips = []
  for (var pkg in skipped)
    if (appFor(apps, pkg) !== null && skipKept(apps, pkg, skipped[pkg]))
      skips.push(appName(apps, pkg) + " " + skipped[pkg])
  var parts = []
  if (names.length > 0) parts.push(say(tr, "settings.muted", [names.join(", ")]))
  if (skips.length > 0) parts.push(say(tr, "settings.skipped", [skips.join(", ")]))
  return parts.join(" · ")
}

// What Clear leaves: it clears what the quiet line lists, nothing more, so
// a mute or skip for a row the line leaves out (hidden by Show CLI tools,
// not installed now) stays.
function quietCleared(apps, muted, skipped) {
  var keepMuted = muted.filter(function(pkg) { return appFor(apps, pkg) === null })
  var keepSkips = {}
  for (var pkg in skipped) if (appFor(apps, pkg) === null) keepSkips[pkg] = skipped[pkg]
  return { mutedApps: keepMuted, skippedVersions: keepSkips }
}

// The widget's whole shell.json entry after changes: shell.json
// hot-reloads and the bar injects the new settings, so the controls bind
// to settings and a change writes the merged entry. Every write also drops
// skips that no longer apply (liveSkips).
function settingsEntry(id, settings, changes, apps, skipped) {
  var entry = { id: id }
  for (var existing in settings) if (existing !== "id") entry[existing] = settings[existing]
  // A renamed setting goes under its new name (legacyKeys).
  for (var name in legacyKeys) {
    var old = legacyKeys[name]
    if (entry[old] === undefined) continue
    if (entry[name] === undefined) entry[name] = entry[old]
    delete entry[old]
  }
  for (var key in changes) entry[key] = changes[key]
  var skips = liveSkips(apps, changes.skippedVersions !== undefined ? changes.skippedVersions : skipped)
  if (Object.keys(skips).length > 0 || entry.skippedVersions !== undefined) entry.skippedVersions = skips
  return entry
}

// --- counts --------------------------------------------------------------------

function count(apps, test) {
  var n = 0
  for (var i = 0; i < apps.length; i++) if (test(apps[i])) n++
  return n
}

// Counts, the urgent icon and the bar icon's visibility leave quiet rows
// out; quietCount says how many updates that hides.
function updateCount(apps, muted, skipped) {
  return count(apps, function(app) { return updatable(app) && !isQuiet(muted, skipped, app) })
}

// The vendor's releases Omarchy's repo does not have yet, on rows with no
// Update to offer meanwhile: the second level, apart from updateCount, in
// the theme's warning colour. A row whose Update installs the repo's
// package counts as an update, ahead or not.
function aheadCount(apps, muted, skipped) {
  return count(apps, function(app) { return aheadOnly(app) && !isQuiet(muted, skipped, app) })
}

// Newer upstream releases with no install path (an indicator-only app, a
// feed that failed with a newer version known). Not a release only the
// vendor has: aheadCount counts those.
function waitingCount(apps, muted, skipped) {
  return count(apps, function(app) {
    return app.updateAvailable === true && app.installable !== true && !ahead(app) && !isQuiet(muted, skipped, app)
  })
}

function quietCount(apps, muted, skipped) {
  return count(apps, function(app) { return app.updateAvailable === true && isQuiet(muted, skipped, app) })
}

// Failed rows. Mute takes a row out of every signal, its failure too:
// that shows on its own row, and in mutedErrorCount for the status text.
// A skip silences one version, not the row, so a skipped row's failure
// still counts.
function errorCount(apps, muted) {
  return count(apps, function(app) { return String(app.error || "") !== "" && !isMuted(muted, app) })
}

function mutedErrorCount(apps, muted) {
  return count(apps, function(app) { return String(app.error || "") !== "" && isMuted(muted, app) })
}

// mise rows on no backend Omabump queries: their newest version is
// unknown, so no summary may call them current, muted or not (mute
// silences an update, it does not make an unknown state known). So are
// self-updating apps whose version is unknown or a pre-release the feed
// cannot be compared with.
function uncheckedCount(apps) {
  return count(apps, function(app) { return app.unchecked === true })
}

// Rows showing the version from an earlier run because this one failed;
// muted ones count in mutedErrorCount (a stale row has its error).
function staleCount(apps, muted) {
  return count(apps, function(app) { return app.stale === true && !isMuted(muted, app) })
}

// Whether the bar shows its icon (Panel.qml's visible), s being Main.qml's
// summary. Like the system update icon, it can stay out of the bar until
// there is something to install (onlyWithUpdates). A failed check shows it
// too, or a broken check would be invisible (a muted row's failure does
// does not, as mute promises). A release only the vendor has shows it too.
// While the panel is open (IPC open/toggle) it shows, so the panel has an
// anchor.
function barIconShown(s, onlyWithUpdates, panelOpen) {
  return !onlyWithUpdates || s.updateCount > 0 || s.aheadCount > 0 || s.checkFailed || s.errorCount > 0 || !!panelOpen
}

// The bar icon's colour, by level: "urgent" while an update exists,
// "warning" while only releases the repo does not have yet do, else "" (the
// bar's foreground). Panel.qml maps the level to the theme's colours.
function barIconLevel(s) {
  if (s.updateCount > 0) return "urgent"
  return s.aheadCount > 0 ? "warning" : ""
}

// --- status.json -----------------------------------------------------------------

// status.json as the widget reads it, or null while it is empty. Throws on
// text that is not JSON.
function parseStatus(text, showCli) {
  if (String(text || "").trim() === "") return null
  var parsed = JSON.parse(String(text))
  var file = parsed && typeof parsed === "object" ? parsed : {}
  // A check that ran before Show CLI tools was turned off still lists them.
  // The rows status_apps in bin/omabump-common lists, but for an array
  // row, which no checker writes (tests/model.sh).
  var apps = (Array.isArray(file.apps) ? file.apps : []).filter(function(app) {
    return !!app && typeof app === "object" && (showCli || rowSection(app) !== "cli")
  })
  var started = file.startedAt ? new Date(file.startedAt).getTime() : NaN
  // When the installed versions were last read, by a check or a local
  // refresh; a file from before the field has none.
  var inventory = file.inventoryAt ? new Date(file.inventoryAt).getTime() : NaN
  var pkgs = file.omarchyPkgs && typeof file.omarchyPkgs === "object" ? file.omarchyPkgs : {}
  return {
    apps: apps,
    checkedAt: file.checkedAt ? String(file.checkedAt) : "",
    checking: file.checking === true,
    startedMs: isFinite(started) ? started : 0,
    inventoryMs: isFinite(inventory) ? inventory : 0,
    pkgsCommit: String(pkgs.commit || ""),
    // The user opted out of the pinned omarchy-pkgs commit (pins.json).
    pkgsFollowing: pkgs.following === true,
    pkgsError: String(pkgs.error || ""),
    pkgsNote: String(pkgs.note || ""),
    // Its parts (partsKnown), null from a checker before them.
    pkgsNoteParts: isList(pkgs.noteParts) ? pkgs.noteParts : null,
    miseError: showCli ? String(file.miseError || "") : "",
    runError: String(file.runError || "")
  }
}

// How often each bar asks whether a check is due (Main.qml's runDue).
var pollSec = 60

// --- this shell's checks ------------------------------------------------------------

// How long after this shell's last check ended an IPC refresh starts none.
var ipcThrottleMs = 60000

// What an IPC refresh does (Panel.qml's ipcRefresh). Anything on the
// session bus can call it, so it may not keep this shell checking back to
// back. "pending": a check that starts after the call is already on its
// way (queued, or waiting for another check to end), and that one answers
// it. "throttled": this shell's own check for a Refresh runs (running), or
// its last check ended (lastEndMs) less than ipcThrottleMs ago with none
// running now; it starts nothing. Else "refresh", as Refresh does: queued
// behind the timer's check or one for a Show CLI tools change, and after
// another's (a terminal's, another monitor's) when one runs. pending,
// running and checking are Main.qml's refreshPending, refreshRunning and
// checking.
function ipcRefreshAction(pending, running, checking, nowMs, lastEndMs) {
  if (pending) return "pending"
  if (running || !checking && nowMs - lastEndMs < ipcThrottleMs) return "throttled"
  return "refresh"
}

// What a run that never took the lock exits with: Main.qml's waitScript
// when the lock stayed held past its wait, and bin/omabump-check when it
// found the lock taken (or, with --wait, held past its own wait).
var lockBusyExit = 75

// What bin/omabump-check --if-due exits with when no check is due
// (not_due_exit there): it ran nothing and wrote nothing.
var notDueExit = 76

// The words a check's run says on stdout (Main.qml's checkProcess):
// waitScript's that its wait is over and the check starts, and
// bin/omabump-check --if-due's that a check is due and runs.
var startedWord = "started"
var dueWord = "due"

// A check's overall deadline: checkDeadlineSec, then TERM, then KILL
// killAfterSec later (timeout -k). Other waiters count on a check ending by
// then: the installer's refresh (bin/omabump-check --wait) and another
// bar's waitScript wait lockWaitSec for it, which is longer. Every wait for
// the lock comes before the deadline (waitScript), so it bounds the check
// alone, and a wait that gives up says so (lockBusyExit) instead of ending
// in the deadline's kill.
var checkDeadlineSec = 600
var killAfterSec = 10
// How long a run waits for a check holding the lock (waitScript): as long
// as the checker's own --wait (flock -w in bin/omabump-check).
var lockWaitSec = 660

// What a run that waits for the lock runs before the checker's deadline
// (checkCommand): $1 the checker's lock, $2 how long to wait for it, then
// the command. It takes the lock and lets go at once, says startedWord on
// stdout and runs the command. A lock still held after the wait is left
// be, and the script exits lockBusyExit having run nothing; a lock file
// that cannot be opened (no check has made its directory yet) has no check
// behind it. With today's values:
//   flock -E 75 -w "$2" "$1" true 2>/dev/null; (( $? == 75 )) && exit 75; echo started; shift 2; exec "$@"
var waitScript = "flock -E " + lockBusyExit + ' -w "$2" "$1" true 2>/dev/null; (( $? == ' + lockBusyExit
  + " )) && exit " + lockBusyExit + "; echo " + startedWord + '; shift 2; exec "$@"'

// The command line of this shell's check (Main.qml's runCheck), under the
// deadline. o.wait: wait for a check that holds lockPath first
// (waitScript), instead of leaving at once on it; the checker itself never
// gets --wait. o.ifDue: run only when a check is due, by o.intervalSec
// (--if-due). o.notify and o.showCli false pass --no-notify and --no-cli.
function checkCommand(checkScript, lockPath, o) {
  var command = ["timeout", "-k", String(killAfterSec), String(checkDeadlineSec), checkScript]
  if (!o.notify) command.push("--no-notify")
  if (!o.showCli) command.push("--no-cli")
  if (o.ifDue) command.push("--if-due", "--interval", String(o.intervalSec))
  if (o.wait) command = ["bash", "-c", waitScript, "omabump-wait", lockPath, String(lockWaitSec)].concat(command)
  return command
}

// What a check's exit means for this shell (Main.qml's onExited). Both
// "notRun" and "left" ran nothing. "notRun": waitScript gave up on the
// lock (waited: it had not said "started"), held past its wait by checks
// from before the request. "left": the checker found the lock taken and
// left the check to the one holding it. The timer's run does not wait; a
// run that waited lost it, after waitScript's wait, to a check that
// therefore started after the request, and so did a queued run that did
// not wait (queuedRunWaits): either way that check answers it. "notDue":
// the timer's or the panel's run found no check due. "ok" or "failed"
// otherwise.
function checkOutcome(exitCode, waited) {
  if (exitCode === lockBusyExit) return waited ? "notRun" : "left"
  if (exitCode === notDueExit) return "notDue"
  return exitCode === 0 ? "ok" : "failed"
}

// Whether the run queued behind this shell's own check (Main.qml's
// runQueued) waits for the lock, by how that check ended. Not after one
// that completed: its checker took the lock with none held (it never
// waits) and kept it until it ended, which was after the Refresh or Show
// mise tools change that queued the run, so a check holding the lock now
// took it later and answers that. The queued run then leaves on it
// instead of running a second check after it. After any other end, a
// check from before the request may hold the lock: one that failed may
// have failed before it took it.
function queuedRunWaits(outcome) {
  return outcome !== "ok"
}

// checkError for a run that took the lock, or for "notRun": "" once a check
// of this shell's ran. A run that left keeps the error it had.
// outcome is checkOutcome's answer for this shell's last check that set
// it, "" for none (Main.qml keeps the outcome and the exit, and words them
// here, so a change of language words them again).
function checkErrorText(tr, outcome, exitCode, lockWaitSec) {
  if (outcome === "" || outcome === "ok") return ""
  if (outcome === "notRun") return sayCount(tr, "error.notRun", Math.round(lockWaitSec / 60))
  return say(tr, "error.checkFailed", [String(exitCode)])
}

// Whether status.json (parseStatus's answer) holds the answer this shell's
// check could not give: a run that started after afterMs and completed.
// startedAt has whole seconds, so a run in that same second does not count.
function answersError(status, afterMs) {
  return !!status && !status.checking && status.runError === "" && status.startedMs > afterMs
}

// What a change of Show CLI tools starts (Main.qml's onShowCliChanged):
// "" before the timer's first tick, which reads the setting as it is then;
// "queue" behind this shell's own check; else "wait", a run that waits for
// any check holding the lock and starts after it.
function showCliRun(settingsReady, timerTicked, running) {
  if (!settingsReady || !timerTicked) return ""
  return running ? "queue" : "wait"
}

// Why no summary may read as up to date, or "": the checker itself failed,
// omarchy-pkgs could not be fetched, or mise could not list its tools. A
// failure only muted rows share (every mise row muted; the omarchy-pkgs
// fetch, which a check makes only for a row the vendor is ahead on, with
// no such row left unmuted) signals nothing, like their own failures. f holds checkError,
// runError, pkgsError and miseError. With errorCount, the rule the checker
// retries a failed check by (check_failed in bin/omabump-common), save
// this shell's own checkError: tests/model.sh sets the two side by side.
function failureText(f, apps, muted) {
  if (f.checkError !== "") return f.checkError
  if (f.runError !== "") return f.runError
  if (f.pkgsError !== "" && apps.some(function(app) { return app.ahead === true && !isMuted(muted, app) })) return f.pkgsError
  if (f.miseError !== "" && !allMuted(apps, muted, "mise")) return f.miseError
  return ""
}

// --- local refreshes ----------------------------------------------------------------

// How often each bar reads the installed versions again
// (bin/omabump-check --local, Main.qml's localTimer).
var localIntervalSec = 300

// What bin/omabump-check --local exits with besides 0 and lockBusyExit
// (full_check_exit, no_status_exit and pacman_busy_exit there).
var localFullExit = 80
var localNoStatusExit = 81
var localRetryExit = 82

// A local refresh's deadline, then KILL killAfterSec later: a check that
// finds one holding the lock waits for it as long as that (flock -w in
// bin/omabump-check).
var localDeadlineSec = 120

// The command line of a local refresh (Main.qml's localRefresh).
function localCommand(checkScript, showCli) {
  var command = ["timeout", "-k", String(killAfterSec), String(localDeadlineSec), checkScript, "--local"]
  if (!showCli) command.push("--no-cli")
  return command
}

// What a local refresh's exit means (Main.qml's localProcess): "done";
// "full", a row changed in a way only a check reads, or there is no
// status.json of a check to start from; "retry", pacman was in the middle
// of a transaction, so nothing changed and the next tick reads it all again
// (never a check meanwhile, which would read pacman half way); "left", a
// check or another local refresh held the lock; else "failed", which is
// only logged.
function localOutcome(exitCode) {
  if (exitCode === 0) return "done"
  if (exitCode === localFullExit || exitCode === localNoStatusExit) return "full"
  if (exitCode === localRetryExit) return "retry"
  return exitCode === lockBusyExit ? "left" : "failed"
}

// Whether a check follows a local refresh: the one it asked for, unless
// this shell's own check runs. That one takes the lock after the refresh
// let go of it (a check that finds a local refresh holding the lock waits
// for it), so it reads what the refresh found. Never one per bar: the
// other bars' refreshes left on the lock, or ran after this one and found
// the rows as it left them, with nothing more to ask.
function localWantsCheck(outcome, checkRunning) {
  return outcome === "full" && !checkRunning
}

// The slack every bar allows a run that started at about the same time
// (due_slack_sec and run_recent in bin/omabump-common, which decide when a
// check is due).
var dueSlackSec = 30

// Whether the timer's local refresh is due. Every monitor's bar runs one,
// so installed versions read less than an interval (less dueSlackSec)
// ago, by another bar's refresh or by a check (inventoryAt), are recent
// enough. A time ahead of the clock proves nothing.
function localDue(nowMs, inventoryMs, intervalSec) {
  var age = nowMs - inventoryMs
  return !(inventoryMs > 0 && age >= 0 && age < (intervalSec - dueSlackSec) * 1000)
}

// --- rows ------------------------------------------------------------------------

// An app installed as a copy that updates itself (the checker's
// selfUpdating: its AppImage or its npm package): its own updater replaces
// the copy, so the row has no Update and no Switch, whatever else it says.
function selfUpdating(app) { return !!app && app.selfUpdating === true }

function updatable(app) { return !!app && app.updateAvailable === true && app.installable === true && !selfUpdating(app) }

// The vendor has a release Omarchy's repo does not have yet (the checker's
// ahead, from repo_derive in bin/omabump-common).
function ahead(app) { return !!app && app.ahead === true && !selfUpdating(app) }

// Ahead, with no Update meanwhile: the warning level (aheadCount).
function aheadOnly(app) { return ahead(app) && !updatable(app) }

// Build now could run for the row (the checker's buildable): it builds
// Omarchy's own recipe at the vendor's version. Whether the buildAhead
// setting lets it run is buildStep's to say.
function buildable(app) { return ahead(app) && app.buildable === true }

// What b, or the row's Build now button, does: "" on a row Build now
// cannot build; "build", in a terminal, while the buildAhead setting is on;
// with it off, "explain" first, which says in the row what Build now does
// and that it is off (buildOffNote), then, once explained (explainedPkg is
// the pkg of the row it was explained on), "enable", which turns the
// setting on: the next press builds.
function buildStep(app, buildAheadOn, explainedPkg) {
  if (!buildable(app)) return ""
  if (buildAheadOn) return "build"
  return explainedPkg === app.pkg ? "enable" : "explain"
}

// The row's note while Build now is off and was asked for, as noteText
// reads it; null without a row. Short: the row has five narrow lines
// beside the button. The button's tooltip says the rest (buildTooltip).
function buildOffNote(app) {
  return app ? { key: "build.offNote", args: [] } : null
}

// The Build now button's text and tooltip, by buildStep.
function buildButtonText(tr, step) { return say(tr, step === "enable" ? "build.buttonEnable" : "build.button") }
function buildTooltip(tr, app, step) {
  if (!app || step === "") return ""
  if (step === "enable") return say(tr, "build.tooltipEnable", [String(app.label || app.pkg), String(app.latest || "")])
  if (step === "explain") return say(tr, "build.tooltipExplain")
  return say(tr, "build.tooltip", [String(app.latest)])
}

// How the row's "→ newest" reads: "dim" on a quiet row, "urgent" for an
// update Update installs, "warning" for a release only the vendor has,
// else "plain". Panel.qml maps it to the theme's colours.
function latestTone(app, quiet) {
  if (quiet) return "dim"
  if (updatable(app)) return "urgent"
  return aheadOnly(app) ? "warning" : "plain"
}

// Whether the row's route installs a package by the row's pkg, and so can
// replace one installed under another name: the checker's switchRoute
// (route_table in bin/omabump-common). A row a checker of 0.1.17 or
// earlier wrote has no such field; the routes of then that could are
// omarchy and vendor-pkg (and repo, as route_table has it now, which no
// such row names). A shim for such a status.json, which the next check
// replaces: it can go once no 0.1.17 is expected to be upgraded from.
function switchRoute(app) {
  if (!app) return false
  if (typeof app.switchRoute === "boolean") return app.switchRoute
  return app.source === "omarchy" || app.source === "repo" || app.source === "vendor-pkg"
}

// Installed under another package name at a version the canonical package
// matches (the checker's switchable): Switch replaces it.
function switchable(app) { return !!app && app.switchable === true && !selfUpdating(app) }

// An update exists but the plugin cannot install it: an indicator row, a
// recipe without a watch, or a feed that failed with a newer version known.
// Or a mise tool whose request holds it below a newer release. Not a
// release omarchy-pkgs still holds (held): Update comes back by itself.
// Not an AUR package omarchy update already updates (omarchyUpdate, its
// note says so), nor an app that updates itself: those have a way to
// update. Not a row no check has read (unchecked): a local refresh found a
// mise tool at another version than its newest one was known for, and the
// check it asked for says. Such a row has no action; its second line says
// why (extraLine).
function noRoute(app) {
  if (!app || app.installable === true || app.source === "self" || app.held === true || ahead(app)
    || app.omarchyUpdate === true || app.blocked === true || app.unchecked === true || selfUpdating(app)) return false
  if (app.updateAvailable === true) return true
  return app.source === "mise" && String(app.error || "") === ""
    && String(app.latest || "") !== "" && app.latest !== app.installed
}

function hasAction(app) { return updatable(app) || switchable(app) || buildable(app) }

// What Enter does: "update" when the plugin can install the row, else
// nothing.
function primaryAction(app) {
  return updatable(app) ? "update" : ""
}

// A fresh list puts the cursor on the first row with something to do (else
// the first row), so Enter acts without an arrow key first.
function firstActionIndex(rows, muted, skipped) {
  for (var i = 0; i < rows.length; i++)
    if (hasAction(rows[i]) && !isQuiet(muted, skipped, rows[i])) return i
  return 0
}

// The cursor's row once the list changes (a check or a local refresh wrote
// it, say the one the panel starts on open): the app pkg while it is listed
// and the cursor was moved there by hand (moved), else the first row with
// something to do, as on a fresh list. So Enter never lands on another app
// than the one highlighted, nor on a row that lost its action meanwhile.
function cursorIndex(rows, pkg, moved, muted, skipped) {
  if (moved)
    for (var i = 0; i < rows.length; i++)
      if (rows[i].pkg === pkg) return i
  return firstActionIndex(rows, muted, skipped)
}

// A row installed under another package name (chatgpt-desktop, z-code-bin)
// that the plugin installs: Update replaces it when a newer version
// exists, Switch does it at the same one. The checker writes the fields
// and the widget says it (status.json schemaVersion 1).
function switchClause(tr, app) {
  if (!app || !switchRoute(app)) return ""
  var name = String(app.installedName || "")
  if (name === "" || name === app.pkg) return ""
  if (updatable(app)) return say(tr, "row.switchClauseUpdate", [name, app.pkg])
  if (switchable(app)) return say(tr, "row.switchClause", [name, app.pkg])
  return ""
}

// What a note's clauses are joined with, as the checker joins them in its
// English fields: each clause is a whole sentence of its own.
var clauseJoin = "; "

// Whether parts, a field the checker writes beside an English one
// (noteParts beside note, buildNoteParts beside buildNote), can be read:
// a list of {key, args}, every key one the catalogs hold and every argument
// a string or {date: epoch seconds}. A status.json from a checker before
// 0.3.0 has no parts, and one from a newer checker may name a key this
// panel does not know: the English field stands in for those.
function partsKnown(tr, parts) {
  // Parsed JSON: a real array, not anything that only has a length.
  if (!Array.isArray(parts)) return false
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (!part || typeof part !== "object" || typeof part.key !== "string" || !tr.has(part.key) || !Array.isArray(part.args)) return false
    // Fewer arguments than the string has holes: a checker that words the
    // part otherwise. The English field then.
    if (part.args.length < holesOf(tr.t(part.key))) return false
    for (var j = 0; j < part.args.length; j++) {
      var arg = part.args[j]
      if (typeof arg !== "string" && !(arg && typeof arg === "object" && typeof arg.date === "number" && isFinite(arg.date))) return false
    }
  }
  return true
}

// One part's argument as the language writes it.
function partArg(tr, arg) { return typeof arg === "string" ? arg : tr.date(arg.date) }

// One part in the language. short: the release-age hold (build.hold) as the
// row's second line says it, by its end alone, so the date fits; the
// tooltip keeps it whole.
function partText(tr, part, short) {
  var args = []
  for (var i = 0; i < part.args.length; i++) args.push(partArg(tr, part.args[i]))
  if (short && part.key === "build.hold") return say(tr, "build.holdShort", [args[1]])
  return say(tr, part.key, args)
}

// The clauses of a field the checker writes, in the language: from its
// parts when partsKnown, else the English field's own, split where the
// checker joins them. first: only the first clause. short: as partText.
function clauses(tr, parts, english, first, short) {
  var out = []
  if (partsKnown(tr, parts)) {
    for (var i = 0; i < parts.length && (!first || i < 1); i++) out.push(partText(tr, parts[i], short))
    return out
  }
  var text = String(english || "")
  if (text === "") return out
  return first ? [text.split(clauseJoin)[0]] : [text]
}

// The checker's note, and its build note (why Build now cannot run), in
// the language. And status.json's omarchyPkgs note ({note, noteParts}).
function checkerNote(tr, app) { return clauses(tr, app.noteParts, app.note, false, false).join(clauseJoin) }
function pkgsNoteText(tr, pkgs) { return clauses(tr, pkgs.noteParts, pkgs.note, false, false).join(clauseJoin) }
function buildNoteText(tr, app, short) { return clauses(tr, app.buildNoteParts, app.buildNote, false, short).join(clauseJoin) }

// The row's whole note: the switch clause, then the checker's own.
function fullNote(tr, app) {
  var note = checkerNote(tr, app)
  var clause = switchClause(tr, app)
  if (clause === "") return note
  return note !== "" ? clause + clauseJoin + note : clause
}

// The row's second line keeps the first clause, and of a switch only the
// name it is installed as: the tooltip and the Switch button say the rest.
function shortNote(tr, app) {
  if (switchClause(tr, app) !== "") return say(tr, "row.installedAs", [String(app.installedName)])
  return clauses(tr, app.noteParts, app.note, true, false).join("")
}

// The package release (-1) says nothing next to an upstream version, so
// rows drop it unless it is the only difference. A self-updating copy's
// version has none and shows as it is, or as unknown when the checker could
// not read it.
function installedText(tr, app) {
  if (!app) return ""
  var full = String(app.installed || "")
  if (selfUpdating(app)) return full !== "" ? full : say(tr, "row.versionUnknown")
  if (app.source === "mise") return full
  var short = full.replace(/-[0-9.]+$/, "")
  return app.updateAvailable === true && short === String(app.latest || "") ? full : short
}

// The second line of a row: exceptions only. actionNote is why the last
// Skip did nothing (skipToggled's note), or what Build now does while it
// is off (buildOffNote), as noteText reads it. A release only the vendor
// has says why Build now cannot run for it, when it cannot (the build
// note, a recipe's release-age hold by its end alone), else the note.
function extraLine(tr, app, actionNote) {
  if (!app) return ""
  if (app.checking === true) return say(tr, "common.checking")
  if (actionNote) return noteText(tr, actionNote)
  if (String(app.error || "") !== "") return say(tr, "row.checkFailed", [String(app.error)])
  var build = aheadOnly(app) && !buildable(app) ? buildNoteText(tr, app, true) : ""
  var note = build !== "" ? build : shortNote(tr, app)
  if (note !== "") return note
  if (noRoute(app)) return say(tr, "row.noRoute")
  if (app.stale === true) return say(tr, "row.lastKnown")
  return ""
}

// The tooltip's line on the newest version and where it is from.
function newestLine(tr, app) {
  var latest = String(app.latest)
  if (app.stale === true) return say(tr, "tip.newestStale", [latest])
  if (app.versionFrom === "mise") return say(tr, "tip.newestMise", [latest])
  if (app.versionFrom === "feed") return say(tr, "tip.newestFeed", [latest])
  if (app.versionFrom === "repo") return say(tr, "tip.newestRepo", [latest])
  var from = String(app.versionFrom || "")
  return from !== "" ? say(tr, "tip.newestFrom", [latest, from]) : say(tr, "tip.newest", [latest])
}

// How the row knows what it shows and what Update would do. A row with no
// Update says so, with the reason its second line gives, instead of a
// route it cannot take. A self-updating app's says which copy updates
// itself (its installedName, the path apps.json gives), then the note. A
// row from Omarchy's repo with an update names the version Update
// installs (the checker's repoVersion), and one the vendor is ahead on says
// so, and what Build now can do about it.
function rowTooltip(tr, app, muted, skipped, pkgsCommit) {
  if (!app) return ""
  var lines = []
  var note = fullNote(tr, app)
  var name = String(app.installedName || "")
  var itself = selfUpdating(app)
  var installed = itself ? installedText(tr, app) : String(app.installed || "")
  lines.push(name !== "" && name !== app.pkg && app.source !== "mise" && !itself
    ? say(tr, "tip.installedAs", [installed, name]) : say(tr, "tip.installed", [installed]))
  if (String(app.latest || "") !== "") lines.push(newestLine(tr, app))
  if (itself) lines.push(name !== "" ? say(tr, "tip.selfAt", [name]) : say(tr, "tip.self"))
  else if (app.source === "self") lines.push(say(tr, app.installable === true ? "tip.pluginUpdate" : "tip.pluginNoUpdate"))
  else if (app.installable !== true) {
    // A held release gets its Update once the hold ends.
    var why = shortNote(tr, app)
    if (app.held === true) lines.push(why !== "" ? say(tr, "tip.noUpdateYetWhy", [why]) : say(tr, "tip.noUpdateYet"))
    else lines.push(why !== "" ? say(tr, "tip.noUpdateWhy", [why]) : say(tr, "tip.noUpdate"))
    if (why === note) note = ""
  } else if (app.source === "mise") lines.push(say(tr, "tip.mise"))
  else if (app.source === "repo") {
    var repo = String(app.repoVersion || "")
    lines.push(repo !== "" && app.updateAvailable === true && app.held !== true
      ? say(tr, "tip.repoTo", [repo]) : say(tr, "tip.repo"))
  } else if (app.source === "vendor-pkg") lines.push(say(tr, "tip.vendorPkg"))
  if (ahead(app)) {
    var commit = String(pkgsCommit || "")
    var build = buildNoteText(tr, app, false)
    lines.push(say(tr, "tip.ahead", [String(app.vendorVersion || app.latest)]))
    if (buildable(app)) lines.push(commit !== "" ? say(tr, "tip.buildAt", [commit.substring(0, 7)]) : say(tr, "tip.build"))
    else lines.push(build !== "" ? say(tr, "tip.noBuildWhy", [build]) : say(tr, "tip.noBuild"))
  }
  if (note !== "") lines.push(note)
  if (String(app.error || "") !== "") lines.push(say(tr, "row.checkFailed", [String(app.error)]))
  if (isMuted(muted, app)) lines.push(say(tr, "tip.muted"))
  if (isSkipped(skipped, app)) lines.push(say(tr, "tip.skipped", [skippedVersion(skipped, app)]))
  return lines.join("\n")
}

// The tooltips of a row's buttons: Update, Switch, Skip and Mute.
function updateTooltip(tr, app) {
  return app ? say(tr, "row.updateTip", [installedText(tr, app), String(app.latest)]) : ""
}
function switchTooltip(tr, app) {
  return app ? say(tr, "row.switchTip", [String(app.installedName), String(app.pkg)]) : ""
}
function skipTooltip(tr, skipped, app) {
  if (!app) return ""
  return isSkipped(skipped, app) ? say(tr, "row.unskipTip", [skippedVersion(skipped, app)])
    : say(tr, "row.skipTip", [String(app.latest)])
}
function muteTooltip(tr, muted, app) { return say(tr, isMuted(muted, app) ? "row.unmuteTip" : "row.muteTip") }

// White marks ship a dark twin for light themes, the same convention the
// first-party agents panel uses. Only relative paths inside this plugin
// load: an absolute path, a URL or a ".." component shows the fallback.
function iconPathOk(path) {
  return path !== "" && path.charAt(0) !== "/" && path.indexOf(":") === -1
    && path.indexOf("\\") === -1 && path.split("/").indexOf("..") === -1
}

// The row's mark, relative to the plugin, or "".
function iconPath(app, lightSurface) {
  if (!app) return ""
  var path = String(app.icon || "")
  var light = String(app.iconLight || "")
  if (light !== "" && lightSurface) path = light
  return iconPathOk(path) ? path : ""
}

// Relative luminance of a color's r, g and b (0 to 1).
function luminance(c) {
  function channel(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
}

// --- the panel's layout ------------------------------------------------------------

// Omabump's own row (the plugin section's, rowSection) shows while a newer
// release exists or its check failed; it hides while current.
function selfRowShown(app) {
  return !!app && rowSection(app) === "plugin" && (app.updateAvailable === true || String(app.error || "") !== "")
}

// The row's section: "desktop", "cli" (a CLI tool, of pacman or mise) or "plugin" (Omabump
// itself), the checker's section (route_table in bin/omabump-common). A
// row a checker of 0.1.17 or earlier wrote has no such field, and its
// source says it.
var rowSections = ["desktop", "cli", "plugin"]
function rowSection(app) {
  if (!app) return "desktop"
  if (rowSections.indexOf(app.section) !== -1) return app.section
  return app.source === "mise" ? "cli" : app.source === "self" ? "plugin" : "desktop"
}

// The panel's rows by section (Panel.qml's three Repeaters): desktop apps,
// then the CLI tools, then Omabump's own row (selfRowShown). rows is all of
// them in that order, the one the keyboard cursor walks across sections,
// and offsets says where each section starts in it. Only the rows apps
// holds: parseStatus already left out mise rows while Show CLI tools is
// off.
function panelLayout(apps) {
  var desktop = [], cli = [], plugin = []
  for (var i = 0; i < apps.length; i++) {
    var app = apps[i]
    var section = rowSection(app)
    if (section === "cli") cli.push(app)
    else if (section === "plugin") { if (selfRowShown(app)) plugin.push(app) }
    else desktop.push(app)
  }
  return {
    desktop: desktop, cli: cli, plugin: plugin,
    rows: desktop.concat(cli).concat(plugin),
    offsets: { desktop: 0, cli: desktop.length, plugin: desktop.length + cli.length }
  }
}

// Where the cursor's row (index into layout.rows) sits: its section, its
// index there, and whether it is that section's first row, whose header
// comes into view with it. An index past the end lands past the end of the
// last section.
function rowPlace(layout, index) {
  var section = index < layout.offsets.cli ? "desktop" : index < layout.offsets.plugin ? "cli" : "plugin"
  var local = index - layout.offsets[section]
  return { section: section, index: local, first: local === 0 && layout[section].length > 0 }
}

// The settings view's rows: the check interval dropdown, then the toggles
// (toggleCount of them, from toggleOffset), then the quiet line with its
// Clear button, shown only while it lists something (quietShown). lastRow
// is the last row the cursor may reach.
function settingsLayout(toggleCount, quietShown) {
  return {
    intervalRow: 0,
    toggleOffset: 1,
    quietRow: toggleCount + 1,
    lastRow: toggleCount + (quietShown ? 1 : 0)
  }
}

// --- panel text ------------------------------------------------------------------

function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

// Qt.ShiftModifier, in the modifiers the key catcher passes.
var shiftModifier = 0x02000000

// What a key the panel's catcher hands over as text does (Panel.qml's
// onTextKey), or "". k moves the cursor up (PanelKeyCatcher), so skip is
// Shift+K, a settings write. With CapsLock on, j and k arrive as J and K
// without Shift and move the cursor as j and k do. A shell whose catcher
// passes no modifiers keeps K as skip. b is Build now (buildStep says what
// it does on the row).
function keyAction(text, modifiers, settingsOpen, cursorActive) {
  var shifted = modifiers === undefined || modifiers === null || (modifiers & shiftModifier) !== 0
  if ((text === "J" || text === "K") && !shifted) return text === "J" ? "down" : "up"
  if (text === "s" || text === "S") return "settings"
  if (text === "\b") return settingsOpen ? "back" : ""
  if (settingsOpen) return ""
  if (text === "r" || text === "R") return "refresh"
  if (!cursorActive) return ""
  if (text === "w" || text === "W") return "switch"
  if (text === "b" || text === "B") return "build"
  if (text === "m" || text === "M") return "mute"
  return text === "K" ? "skip" : ""
}

// What the footer's key hints are joined with: each is whole on its own.
var hintJoin = " · "

// The footer's keys for the cursor's row. buildStepNow is buildStep's
// answer for it: b is listed only on a row that offers Build now.
function hintText(tr, settingsOpen, app, rowCount, muted, skipped, buildStepNow) {
  if (settingsOpen) return say(tr, "hint.settings")
  var quiet = []
  if (app && app.updateAvailable === true) quiet.push(say(tr, isSkipped(skipped, app) ? "hint.unskip" : "hint.skip"))
  if (app) quiet.push(say(tr, isMuted(muted, app) ? "hint.unmute" : "hint.mute"))
  var build = !buildStepNow ? [] : [say(tr, buildStepNow === "enable" ? "hint.buildEnable" : "hint.build")]
  var close = [say(tr, "hint.close")]
  if (updatable(app)) return [say(tr, "hint.update")].concat(build, quiet, close).join(hintJoin)
  if (switchable(app)) return [say(tr, "hint.switch")].concat(build, quiet, close).join(hintJoin)
  if (build.length > 0) return build.concat(quiet, close).join(hintJoin)
  return (rowCount > 0 ? [say(tr, "hint.select")] : []).concat([say(tr, "hint.refresh"), say(tr, "hint.openSettings")], quiet)
    .join(hintJoin)
}

function checkedText(tr, checking, checkedAt, nowMs) {
  if (checking) return say(tr, "checked.checking")
  if (checkedAt === "") return say(tr, "checked.never")
  var ms = new Date(checkedAt).getTime()
  if (!isFinite(ms)) return ""
  var minutes = Math.floor(Math.max(0, nowMs - ms) / 60000)
  if (minutes < 1) return say(tr, "checked.justNow")
  if (minutes < 60) return sayCount(tr, "checked.minutes", minutes)
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return sayCount(tr, "checked.hours", hours)
  return sayCount(tr, "checked.days", Math.floor(hours / 24))
}

function intervalLabel(tr, sec) {
  if (sec % 3600 === 0) return say(tr, "unit.hours", [tr.num(sec / 3600)])
  if (sec % 60 === 0) return say(tr, "unit.minutes", [tr.num(sec / 60)])
  return say(tr, "unit.seconds", [tr.num(sec)])
}

// A value set by hand that is not one of the choices stays selectable.
function intervalOptions(tr, choices, current) {
  var list = choices.slice()
  if (list.indexOf(current) === -1) {
    list.push(current)
    list.sort(function(a, b) { return a - b })
  }
  return list.map(function(sec) { return { value: String(sec), label: intervalLabel(tr, sec) } })
}

// The summaries below read s, the checker's state (Main.qml's summary):
// checking, checkFailed, checkedAt, appCount, the counts above by name
// (updateCount, aheadCount, waitingCount, quietCount, errorCount,
// mutedErrorCount, uncheckedCount, staleCount) and pkgsFollowing.

// "1 ahead of the repo": the releases only the vendor has (aheadCount).
function aheadText(tr, s) { return s.aheadCount > 0 ? sayCount(tr, "count.ahead", s.aheadCount) : "" }

// What the items of a summary list are joined with ("2 updates, check
// failed"), and the header's two counts ("2 updates · 1 ahead of the
// repo"): each item is whole on its own.
var listJoin = ", "
var headerJoin = " · "

// What quiet rows hold back, in one wording for the header, the tooltip
// and IPC status: "+N muted/skipped" for their updates. The tooltip and
// IPC status (withFailures) also say when a muted row's check failed; the
// header and the bar leave that out, as they leave out its update. ""
// when there is nothing to say; withQuiet puts it beside the summary.
function quietNote(tr, s, withFailures) {
  var parts = []
  if (s.quietCount > 0) parts.push(sayCount(tr, "quiet.count", s.quietCount))
  var failed = withFailures ? s.mutedErrorCount : 0
  if (failed > 0) parts.push(sayCount(tr, "quiet.mutedFailed", failed))
  return parts.join(listJoin)
}

// A summary with what quiet rows hold back beside it.
function withQuiet(tr, text, quiet) { return quiet !== "" ? say(tr, "summary.withQuiet", [text, quiet]) : text }

// The hero's one state, as { kind, text }: kind "" (nothing to say),
// "notChecked" or "state". All current, N updates, check failed, or last
// known (rows from an earlier run because this one failed for them). "N
// updates" counts what the bar icon counts, the rows with an Update
// (updateCount); newer releases Omabump does not install (waitingCount)
// are named apart, and only when there is no update to say first.
function heroState(tr, s, checked) {
  function state(text) { return { kind: "state", text: text } }
  if (s.checkFailed) return state(say(tr, "hero.checkFailed"))
  var ahead = aheadText(tr, s)
  if (s.updateCount > 0) {
    var updates = sayCount(tr, "count.updates", s.updateCount)
    return state(ahead !== "" ? updates + headerJoin + ahead : updates)
  }
  if (ahead !== "") return state(ahead)
  if (s.waitingCount > 0) return state(sayCount(tr, "hero.waiting", s.waitingCount))
  if (s.staleCount > 0) return state(say(tr, "hero.lastKnown", [checked]))
  if (s.errorCount > 0) return state(say(tr, "hero.checkFailed"))
  if (s.checkedAt === "") return { kind: "notChecked", text: say(tr, "hero.notChecked") }
  if (s.uncheckedCount > 0) return state(sayCount(tr, "summary.allCheckedCurrent", s.uncheckedCount))
  return s.appCount > 0 ? state(say(tr, "summary.allCurrent")) : { kind: "", text: "" }
}

// The hero says one thing (heroState), then what quiet rows hold back.
// checked is checkedText's answer.
function heroMeta(tr, s, settingsOpen, checked) {
  if (settingsOpen) return say(tr, "hero.settings")
  if (s.checking) return say(tr, "common.checking")
  var state = heroState(tr, s, checked)
  return state.kind === "state" ? withQuiet(tr, state.text, quietNote(tr, s, false)) : state.text
}

// What the bar tooltip and the status IPC call summarise, with the full
// count, as { kind, text }: kind "list" (the items, joined), "allCurrent",
// "allCheckedCurrent" or "" (nothing checked, or nothing installed), and
// text without what quiet rows hold back.
function summary(tr, s) {
  var parts = []
  if (s.updateCount > 0) parts.push(sayCount(tr, "count.updates", s.updateCount))
  if (s.aheadCount > 0) parts.push(aheadText(tr, s))
  if (s.waitingCount > 0) parts.push(sayCount(tr, "summary.waiting", s.waitingCount))
  var failed = s.errorCount
  if (s.checkFailed) parts.push(say(tr, "summary.checkFailed"))
  else if (failed > 0) parts.push(sayCount(tr, "summary.failedApps", failed))
  if (s.staleCount > 0) parts.push(sayCount(tr, "summary.staleApps", s.staleCount))
  if (parts.length > 0) {
    if (s.uncheckedCount > 0) parts.push(sayCount(tr, "summary.unchecked", s.uncheckedCount))
    return { kind: "list", text: parts.join(listJoin) }
  }
  if (s.checkedAt === "" || s.appCount === 0) return { kind: "", text: "" }
  if (s.uncheckedCount > 0) return { kind: "allCheckedCurrent", text: sayCount(tr, "summary.allCheckedCurrent", s.uncheckedCount) }
  return { kind: "allCurrent", text: say(tr, "summary.allCurrent") }
}

// The summary as one line, with what quiet rows hold back.
function summaryText(tr, s) {
  var sum = summary(tr, s)
  return sum.kind !== "" ? withQuiet(tr, sum.text, quietNote(tr, s, true)) : ""
}

function followingText(tr, s) { return s.pkgsFollowing ? say(tr, "bar.following") : "" }

function tooltipText(tr, s) {
  var sum = summary(tr, s)
  var quiet = quietNote(tr, s, true)
  var text = sum.kind === "allCurrent" ? (quiet !== "" ? say(tr, "bar.upToDateQuiet", [quiet]) : say(tr, "bar.upToDate"))
    : sum.kind !== "" ? say(tr, "bar.summary", [withQuiet(tr, sum.text, quiet)])
    : s.checkedAt === "" ? say(tr, "bar.notChecked") : say(tr, "bar.noneInstalled")
  var following = followingText(tr, s)
  if (following !== "") text += "\n" + following
  return text
}

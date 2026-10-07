.pragma library

// The widget's rules, apart from the QML that shows them: Main.qml and
// Panel.qml bind to these, and tests/model.test.mjs runs them under node.
// Nothing here may touch QML types or Quickshell; values in, values out.
//
// The bar hands lists over as a QVariantList, which Array.isArray does not
// accept, so lists from the settings are read by index (isList).

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

// Between a minute and a day, whatever shell.json holds.
function refreshIntervalSec(settings) {
  return Math.min(86400, Math.max(60, Number(setting(settings, "refreshIntervalSec", 3600)) || 3600))
}

// --- ids and versions the checker accepts --------------------------------------

// pkg_name_ok, app_id_ok and skip_version_ok in bin/omabump-common. The
// checker drops a muted id or a skipped entry these refuse (load_quiet), so
// the widget must too: else a row the checker notifies about would show as
// quiet here.
var selfPkg = "self:omabump"

function pkgNameOk(name) {
  return typeof name === "string" && /^[a-z0-9@_+][a-z0-9@._+-]*$/.test(name)
}

function appIdOk(id) {
  return pkgNameOk(id) || (typeof id === "string" && id.indexOf("mise:") === 0 && pkgNameOk(id.substring(5)))
    || id === selfPkg
}

// A version as mise or a feed prints it. skipToggled checks it before a
// skip is stored.
function skipVersionOk(v) {
  return typeof v === "string" && v.length <= 64 && /^[0-9A-Za-z][A-Za-z0-9._+~-]*$/.test(v) && v.indexOf("..") === -1
}

// load_quiet reads only the first quietMax strings of each setting, and
// drops the ones the rules above refuse after that cut, not before. The
// bar may hand the skips over in another key order than shell.json has,
// so only past the cap could the two keep different ones.
var quietMax = 200

// Rows the user muted (pkg ids): no badge, no count, no notification.
function mutedApps(settings) {
  var list = setting(settings, "mutedApps", [])
  var out = []
  if (!isList(list)) return out
  for (var i = 0, kept = 0; i < list.length && kept < quietMax; i++) {
    if (typeof list[i] !== "string") continue
    kept++
    if (appIdOk(list[i]) && out.indexOf(list[i]) === -1) out.push(list[i])
  }
  return out
}

// {pkg: version} the user skipped. While a row's newest version is that
// one it signals nothing; a newer release lights it up again (skipHolds).
function skippedVersions(settings) {
  var map = setting(settings, "skippedVersions", {})
  var out = {}
  if (!map || typeof map !== "object" || isList(map)) return out
  var kept = 0
  for (var pkg in map) {
    if (typeof map[pkg] !== "string") continue
    if (kept++ >= quietMax) break
    if (appIdOk(pkg) && skipVersionOk(map[pkg])) out[pkg] = map[pkg]
  }
  return out
}

// --- pacman's vercmp -------------------------------------------------------------

// alpm_pkg_vercmp: below zero, zero or above zero as a is older than, the
// same as or newer than b. The checker runs vercmp itself; the panel needs
// the same answer for skips between checks.
function vercmp(a, b) {
  a = String(a)
  b = String(b)
  if (a === b) return 0
  var x = splitEvr(a), y = splitEvr(b)
  var ret = rpmvercmp(x.epoch, y.epoch)
  if (ret === 0) ret = rpmvercmp(x.version, y.version)
  // A release counts only when both versions have one.
  if (ret === 0 && x.release !== null && y.release !== null) ret = rpmvercmp(x.release, y.release)
  return ret
}

// [epoch:]version[-release]: no epoch is 0, no release is null.
function splitEvr(v) {
  var digits = /^[0-9]*/.exec(v)[0].length
  var epoch = "0"
  if (v.charAt(digits) === ":") {
    if (digits > 0) epoch = v.substring(0, digits)
    v = v.substring(digits + 1)
  }
  var dash = v.lastIndexOf("-")
  return dash < 0 ? { epoch: epoch, version: v, release: null }
    : { epoch: epoch, version: v.substring(0, dash), release: v.substring(dash + 1) }
}

// Compares runs of digits (as numbers) or of letters (as text) in turn;
// anything else separates them.
function rpmvercmp(a, b) {
  if (a === b) return 0
  var digit = /[0-9]/, alpha = /[A-Za-z]/
  var one = 0, two = 0
  while (one < a.length && two < b.length) {
    var from1 = one, from2 = two
    while (one < a.length && !digit.test(a.charAt(one)) && !alpha.test(a.charAt(one))) one++
    while (two < b.length && !digit.test(b.charAt(two)) && !alpha.test(b.charAt(two))) two++
    if (one >= a.length || two >= b.length) break
    // The longer separator is newer.
    if (one - from1 !== two - from2) return one - from1 < two - from2 ? -1 : 1
    var run = digit.test(a.charAt(one)) ? digit : alpha
    var end1 = one, end2 = two
    while (end1 < a.length && run.test(a.charAt(end1))) end1++
    while (end2 < b.length && run.test(b.charAt(end2))) end2++
    // Digits against letters: the digits are newer.
    if (end2 === two) return run === digit ? 1 : -1
    var s1 = a.substring(one, end1), s2 = b.substring(two, end2)
    if (run === digit) {
      s1 = s1.replace(/^0+/, "")
      s2 = s2.replace(/^0+/, "")
      if (s1.length !== s2.length) return s1.length > s2.length ? 1 : -1
    }
    if (s1 !== s2) return s1 < s2 ? -1 : 1
    one = end1
    two = end2
  }
  if (one >= a.length && two >= b.length) return 0
  // What is left decides: letters are older than nothing (1.0a < 1.0),
  // anything else is newer.
  return (one >= a.length && !alpha.test(b.charAt(two))) || alpha.test(a.charAt(one)) ? -1 : 1
}

// The installed version less epoch and pkgrel (upstream_part in
// bin/omabump-common).
function upstreamPart(v) { return String(v).replace(/^[^:]*:/, "").replace(/-[^-]*$/, "") }

// string_versions in bin/omabump-common: versions mise or Omabump's
// release feed print compare as strings, since mise decides what is newer
// there and vercmp would call 1.0.0 and 1.0.0-beta.1 equal. Every other
// source compares with vercmp.
function stringVersions(source) { return source === "mise" || source === "self" }

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

// Whether a skip of version still applies to the row, by the rule
// row_skipped in bin/omabump-common applies to an update: mise and
// Omabump's own rows while their update is exactly that version; the
// others (vercmp) while their newest version is not newer than it and the
// installed one is older, so a feed that rolls back below a skip stays
// skipped and an install of that version or a later one ends it. The
// installed version loses epoch and pkgrel, as the checker compares it
// with a feed's.
function skipHolds(app, version) {
  var latest = String(app.latest || "")
  version = String(version || "")
  if (version === "" || latest === "") return false
  if (stringVersions(app.source)) return app.updateAvailable === true && latest === version
  return vercmp(latest, version) <= 0 && vercmp(upstreamPart(String(app.installed || "")), version) < 0
}

// A row whose update the user skipped. Decided from the settings as they
// are now, by the checker's rule, so a skip shows at once and a skip
// changed since the last check does not keep that check's answer.
function isSkipped(skipped, app) {
  return !!app && app.updateAvailable === true && skipHolds(app, skippedVersion(skipped, app))
}

// A row that signals nothing: muted, or at a skipped version.
function isQuiet(muted, skipped, app) { return isMuted(muted, app) || isSkipped(skipped, app) }

// Whether the settings keep the skip of version for pkg: while it applies,
// and while the last check cannot tell. That is a row it did not list
// (hidden by Show mise tools, not installed now) and one that failed, is
// stale, is being checked, was not checked or has no newest version.
function skipKept(apps, pkg, version) {
  var app = appFor(apps, pkg)
  if (!app || app.checking === true || app.stale === true || app.unchecked === true
    || String(app.error || "") !== "" || String(app.latest || "") === "") return true
  return skipHolds(app, version)
}

// The skips a settings write keeps: one goes once its row shows it no
// longer applies (a newer release than the skipped one, or that version or
// a later one installed); one the last check cannot judge stays.
function liveSkips(apps, skips) {
  var out = {}
  for (var pkg in skips) if (skipKept(apps, pkg, skips[pkg])) out[pkg] = skips[pkg]
  return out
}

// Whether every listed row from source is muted (and there is one).
function allMuted(apps, muted, source) {
  var any = false
  for (var i = 0; i < apps.length; i++) {
    if (apps[i].source !== source) continue
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
// version is not one the checker stores; null with nothing to skip.
function skipToggled(skipped, app) {
  var skips = {}
  for (var pkg in skipped) if (pkg !== app.pkg) skips[pkg] = skipped[pkg]
  if (!isSkipped(skipped, app)) {
    if (app.updateAvailable !== true || String(app.latest || "") === "") return null
    if (!skipVersionOk(String(app.latest))) return { note: "Cannot skip " + app.latest + ": not a version Omabump stores" }
    skips[app.pkg] = app.latest
  }
  return { skips: skips }
}

// The settings line under the toggles. Only rows the last check listed: a
// mute or skip for a row hidden by Show mise tools (or not installed now)
// is kept but not shown. Only skips the settings keep (skipKept): one that
// no longer applies is dropped on the next write, not listed as active
// until then.
function quietText(apps, muted, skipped) {
  var names = []
  for (var i = 0; i < muted.length; i++)
    if (appFor(apps, muted[i]) !== null) names.push(appName(apps, muted[i]))
  var skips = []
  for (var pkg in skipped)
    if (appFor(apps, pkg) !== null && skipKept(apps, pkg, skipped[pkg]))
      skips.push(appName(apps, pkg) + " " + skipped[pkg])
  var parts = []
  if (names.length > 0) parts.push("Muted: " + names.join(", "))
  if (skips.length > 0) parts.push("Skipped: " + skips.join(", "))
  return parts.join(" · ")
}

// What Clear leaves: it clears what the quiet line lists, nothing more, so
// a mute or skip for a row the line leaves out (hidden by Show mise tools,
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

// Newer upstream releases with no install path (no recipe watch, or an
// indicator-only app).
function waitingCount(apps, muted, skipped) {
  return count(apps, function(app) {
    return app.updateAvailable === true && app.installable !== true && !isQuiet(muted, skipped, app)
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
// silences an update, it does not make an unknown state known).
function uncheckedCount(apps) {
  return count(apps, function(app) { return app.unchecked === true })
}

// Rows showing the version from an earlier run because this one failed;
// muted ones count in mutedErrorCount (a stale row has its error).
function staleCount(apps, muted) {
  return count(apps, function(app) { return app.stale === true && !isMuted(muted, app) })
}

// --- status.json -----------------------------------------------------------------

// status.json as the widget reads it, or null while it is empty. Throws on
// text that is not JSON. schemaVersion is 0 for a file from before the
// field: its notes carry the switch clause themselves (fullNote).
function parseStatus(text, showMise) {
  if (String(text || "").trim() === "") return null
  var parsed = JSON.parse(String(text))
  var file = parsed && typeof parsed === "object" ? parsed : {}
  // A check that ran before Show mise tools was turned off still lists them.
  var apps = (Array.isArray(file.apps) ? file.apps : []).filter(function(app) {
    return !!app && typeof app === "object" && (showMise || app.source !== "mise")
  })
  var started = file.startedAt ? new Date(file.startedAt).getTime() : NaN
  var pkgs = file.omarchyPkgs && typeof file.omarchyPkgs === "object" ? file.omarchyPkgs : {}
  var schema = Number(file.schemaVersion)
  return {
    schemaVersion: isFinite(schema) && schema > 0 ? Math.floor(schema) : 0,
    apps: apps,
    checkedAt: file.checkedAt ? String(file.checkedAt) : "",
    checking: file.checking === true,
    startedMs: isFinite(started) ? started : 0,
    pkgsCommit: String(pkgs.commit || ""),
    // The user opted out of the pinned omarchy-pkgs commit (pins.json).
    pkgsFollowing: pkgs.following === true,
    pkgsError: String(pkgs.error || ""),
    pkgsNote: String(pkgs.note || ""),
    discoveryError: String(file.discoveryError || ""),
    miseError: showMise ? String(file.miseError || "") : "",
    runError: String(file.runError || "")
  }
}

// Whether the timer's check is due. Every monitor's bar runs its own copy
// of the widget and a shell reload starts them all, so a check that
// started less than an interval (less 30 s of slack) ago is recent enough.
// That start, not checkedAt (the end), is what counts: from the end, this
// widget's own next tick would come up short by however long its last
// check took and be skipped.
function checkDue(nowMs, checkedAt, startedMs, intervalSec) {
  var checked = checkedAt !== "" ? new Date(checkedAt).getTime() : NaN
  // A run that died half way leaves startedAt past checkedAt, and its rows
  // are partly the run before's: then that run's end is all there is.
  var last = startedMs > 0 && isFinite(checked) && startedMs <= checked ? startedMs : checked
  // A time ahead of the clock (it was set back) proves nothing.
  var age = nowMs - last
  return !(isFinite(age) && age >= 0 && age < (intervalSec - 30) * 1000)
}

// --- this shell's checks ------------------------------------------------------------

// What a run that never took the lock exits with: Main.qml's waitScript
// when the lock stayed held past its wait, and bin/omabump-check when it
// found the lock taken (or, with --wait, held past its own wait).
var lockBusyExit = 75

// What a check's exit means for this shell (Main.qml's onExited). Both
// "notRun" and "left" ran nothing. "notRun": waitScript gave up on the
// lock (waited: it had not said "started"), held past its wait by checks
// from before the request. "left": the checker found the lock taken and
// left the check to the one holding it. The timer's run does not wait; a
// run that waited lost it, after waitScript's wait, to a check that
// therefore started after the request, and that one answers it. "ok" or
// "failed" otherwise.
function checkOutcome(exitCode, waited) {
  if (exitCode === lockBusyExit) return waited ? "notRun" : "left"
  return exitCode === 0 ? "ok" : "failed"
}

// checkError for a run that took the lock, or for "notRun": "" once a check
// of this shell's ran. A run that left keeps the error it had.
function checkErrorText(outcome, exitCode, lockWaitSec) {
  if (outcome === "notRun")
    return "Check not run: another check held the lock for over " + Math.round(lockWaitSec / 60) + " min"
  return outcome === "ok" ? "" : "Check failed (exit " + exitCode + "), see the shell log"
}

// Whether status.json (parseStatus's answer) holds the answer this shell's
// check could not give: a run that started after afterMs and completed.
// startedAt has whole seconds, so a run in that same second does not count.
function answersError(status, afterMs) {
  return !!status && !status.checking && status.runError === "" && status.startedMs > afterMs
}

// What a change of Show mise tools starts (Main.qml's onShowMiseChanged):
// "" before the timer's first tick, which reads the setting as it is then;
// "queue" behind this shell's own check; else "wait", a run that waits for
// any check holding the lock and starts after it.
function showMiseRun(settingsReady, timerTicked, running) {
  if (!settingsReady || !timerTicked) return ""
  return running ? "queue" : "wait"
}

// Why no summary may read as up to date, or "": the checker itself failed,
// omarchy-pkgs could not be fetched, or mise could not list its tools. A
// failure only muted rows share (the omarchy-pkgs fetch with every omarchy
// row muted) signals nothing, like their own failures. f holds checkError,
// runError, pkgsError and miseError.
function failureText(f, apps, muted) {
  if (f.checkError !== "") return f.checkError
  if (f.runError !== "") return f.runError
  if (f.pkgsError !== "" && !allMuted(apps, muted, "omarchy")) return f.pkgsError
  if (f.miseError !== "" && !allMuted(apps, muted, "mise")) return f.miseError
  return ""
}

// --- rows ------------------------------------------------------------------------

function updatable(app) { return !!app && app.updateAvailable === true && app.installable === true }

// An update exists but the plugin cannot install it: an indicator row, a
// recipe without a watch, or a feed that failed with a newer version known.
// Or a mise tool whose request holds it below a newer release. Not a
// release omarchy-pkgs still holds (held): Update comes back by itself.
// Not an AUR package omarchy update already updates (omarchyUpdate, its
// note says so): there is nothing to plan.
function askable(app) {
  if (!app || app.installable === true || app.source === "self" || app.held === true
    || app.omarchyUpdate === true) return false
  if (app.updateAvailable === true) return true
  return app.source === "mise" && String(app.error || "") === ""
    && String(app.latest || "") !== "" && app.latest !== app.installed
}

function hasAction(app) { return updatable(app) || askable(app) || (!!app && app.switchable === true) }

// What Enter does: "update" when the plugin can install the row, else
// "ask" (Ask agent) when an agent can plan it, else nothing.
function primaryAction(app) {
  if (askable(app)) return "ask"
  return updatable(app) ? "update" : ""
}

// A fresh list puts the cursor on the first row with something to do (else
// the first row), so Enter acts without an arrow key first.
function firstActionIndex(rows, muted, skipped) {
  for (var i = 0; i < rows.length; i++)
    if (hasAction(rows[i]) && !isQuiet(muted, skipped, rows[i])) return i
  return 0
}

// A row installed under another package name (chatgpt-desktop, z-code-bin)
// that the plugin installs: Update replaces it when a newer version
// exists, Switch does it at the same one. The checker writes the fields
// and the widget says it (status.json schemaVersion 1).
function switchClause(app) {
  if (!app || (app.source !== "omarchy" && app.source !== "vendor-pkg") || app.installable !== true) return ""
  var name = String(app.installedName || "")
  if (name === "" || name === app.pkg) return ""
  if (app.updateAvailable === true) return "Installed as " + name + ", Update switches to " + app.pkg
  if (app.switchable === true) return "Installed as " + name + ", switch to " + app.pkg
  return ""
}

// The row's whole note: the switch clause, then the checker's own. A file
// from before schemaVersion 1 has the clause in its note already. So do
// rows the first check after an upgrade carries over from such a file
// (write_status copies the rows it has not reached, and a run that dies
// half way keeps them): a note that already starts with the clause this
// composes from the row's fields keeps it once.
function fullNote(app, schema) {
  var note = String(app.note || "")
  var clause = schema >= 1 ? switchClause(app) : ""
  if (clause === "" || note === clause || note.indexOf(clause + "; ") === 0) return note
  return note !== "" ? clause + "; " + note : clause
}

// The row's second line keeps the first clause, and of a switch only the
// name it is installed as: the tooltip and the Switch button say the rest.
function shortNote(app, schema) {
  if (schema < 1) return legacyFirstClause(app.note)
  if (switchClause(app) !== "") return "Installed as " + app.installedName
  return String(app.note || "").split("; ")[0]
}

// The first clause of a note in a file from before schemaVersion 1, which
// still says the switch: "Installed as chatgpt-desktop, switch to
// chatgpt-bin" is "Installed as chatgpt-desktop", as that release's panel
// showed it. The one place the widget reads the checker's wording, and
// only for such a file: since then the row's fields say it (switchClause).
function legacyFirstClause(note) {
  var first = String(note || "").split("; ")[0]
  var cut = first.indexOf(", Update switches to ")
  if (cut < 0) cut = first.indexOf(", switch to ")
  return cut < 0 ? first : first.substring(0, cut)
}

// The package release (-1) says nothing next to an upstream version, so
// rows drop it unless it is the only difference.
function installedText(app) {
  if (!app) return ""
  var full = String(app.installed || "")
  if (app.source === "mise") return full
  var short = full.replace(/-[0-9.]+$/, "")
  return app.updateAvailable === true && short === String(app.latest || "") ? full : short
}

// The second line of a row: exceptions only. actionNote is what the last
// Ask agent or Copy prompt did for it.
function extraLine(app, schema, actionNote) {
  if (!app) return ""
  if (app.checking === true) return "Checking…"
  if (actionNote) return actionNote
  if (String(app.error || "") !== "") return "Check failed: " + app.error
  var note = shortNote(app, schema)
  if (note !== "") return note
  if (askable(app)) return "No install route"
  if (app.stale === true) return "Last known version"
  return ""
}

function sourceLabel(app) {
  if (app.stale === true) return "an earlier check"
  if (app.versionFrom === "mise") return "mise"
  if (app.versionFrom === "feed") return "the vendor's release feed"
  return String(app.versionFrom || "")
}

// How the row knows what it shows and what Update would do. A row with no
// Update says so, with the reason its second line gives, instead of a
// route it cannot take.
function rowTooltip(app, schema, muted, skipped, pkgsCommit) {
  if (!app) return ""
  var lines = []
  var note = fullNote(app, schema)
  var name = String(app.installedName || "")
  lines.push("Installed " + String(app.installed || "")
    + (name !== "" && name !== app.pkg && app.source !== "mise" ? " as " + name : ""))
  if (String(app.latest || "") !== "") {
    var from = sourceLabel(app)
    lines.push("Newest " + app.latest + (from !== "" ? " from " + from : ""))
  }
  if (app.source === "self") lines.push(app.installable === true
    ? "Updates to the release's tagged commit, after showing its log and asking"
    : "omarchy update does not update plugins")
  else if (app.installable !== true) {
    // A held release gets its Update once the hold ends.
    var why = shortNote(app, schema)
    lines.push((app.held === true ? "No Update yet" : "No Update here") + (why !== "" ? ": " + why : ""))
    if (why === note) note = ""
  } else if (app.source === "mise") lines.push("Updates with mise up")
  else if (app.source === "omarchy") {
    var commit = String(app.recipeCommit || pkgsCommit || "")
    lines.push("Updates through Omarchy's recipe"
      + (String(app.recipe || "") !== "" ? " " + app.recipe : "")
      + (commit !== "" ? " at " + commit.substring(0, 7) : ""))
  } else if (app.source === "vendor-pkg") lines.push("Updates with the vendor's Arch package")
  if (note !== "") lines.push(note)
  if (String(app.error || "") !== "") lines.push("Check failed: " + app.error)
  if (isMuted(muted, app)) lines.push("Muted: no badge, no notification")
  if (isSkipped(skipped, app)) lines.push("Skipped " + skippedVersion(skipped, app) + ": no badge, no notification until a newer version")
  return lines.join("\n")
}

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

// What bin/omabump-prompt's wrapper printed: the first line says what
// happened, agent (the prompt follows), copied, noagent (copied instead)
// or error (the message follows). { prompt } for the agent, { note } for
// the row otherwise.
function promptOutcome(output) {
  output = String(output || "")
  var newline = output.indexOf("\n")
  var kind = newline < 0 ? output.trim() : output.substring(0, newline)
  var rest = newline < 0 ? "" : output.substring(newline + 1)
  if (kind === "agent") return { prompt: rest }
  if (kind === "copied") return { note: "Prompt copied" }
  if (kind === "noagent") return { note: "No default agent set, prompt copied" }
  return { note: "Prompt failed: " + (rest.trim() || kind || "no output") }
}

// --- panel text ------------------------------------------------------------------

function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

// Qt.ShiftModifier, in the modifiers the key catcher passes.
var shiftModifier = 0x02000000

// What a key the panel's catcher hands over as text does (Panel.qml's
// onTextKey), or "". k moves the cursor up (PanelKeyCatcher), so skip is
// Shift+K, a settings write. With CapsLock on, j and k arrive as J and K
// without Shift and move the cursor as j and k do. A shell whose catcher
// passes no modifiers keeps K as skip.
function keyAction(text, modifiers, settingsOpen, cursorActive) {
  var shifted = modifiers === undefined || modifiers === null || (modifiers & shiftModifier) !== 0
  if ((text === "J" || text === "K") && !shifted) return text === "J" ? "down" : "up"
  if (text === "s" || text === "S") return "settings"
  if (text === "\b") return settingsOpen ? "back" : ""
  if (settingsOpen) return ""
  if (text === "r" || text === "R") return "refresh"
  if (!cursorActive) return ""
  if (text === "c" || text === "C") return "copy"
  if (text === "w" || text === "W") return "switch"
  if (text === "m" || text === "M") return "mute"
  return text === "K" ? "skip" : ""
}

function hintText(settingsOpen, app, rowCount, muted, skipped) {
  if (settingsOpen) return "Space change · Esc back"
  var mute = app ? (isMuted(muted, app) ? " · m unmute" : " · m mute") : ""
  if (app && app.updateAvailable === true) mute = (isSkipped(skipped, app) ? " · K unskip" : " · K skip") + mute
  if (askable(app)) return "Enter ask agent · c copy prompt" + mute
  if (updatable(app)) return "Enter update" + mute + " · Esc close"
  if (app && app.switchable === true) return "w switch package" + mute + " · Esc close"
  return (rowCount > 0 ? "↑↓ select · " : "") + "r refresh · s settings" + mute
}

function checkedText(checking, checkedAt, nowMs) {
  if (checking) return "checking"
  if (checkedAt === "") return "not checked yet"
  var ms = new Date(checkedAt).getTime()
  if (!isFinite(ms)) return ""
  var minutes = Math.floor(Math.max(0, nowMs - ms) / 60000)
  if (minutes < 1) return "checked just now"
  if (minutes < 60) return "checked " + minutes + " min ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return "checked " + hours + " h ago"
  return "checked " + Math.floor(hours / 24) + " d ago"
}

function intervalLabel(sec) {
  if (sec % 3600 === 0) return (sec / 3600) + " h"
  if (sec % 60 === 0) return (sec / 60) + " min"
  return sec + " s"
}

// A value set by hand that is not one of the choices stays selectable.
function intervalOptions(choices, current) {
  var list = choices.slice()
  if (list.indexOf(current) === -1) {
    list.push(current)
    list.sort(function(a, b) { return a - b })
  }
  return list.map(function(sec) { return { value: String(sec), label: intervalLabel(sec) } })
}

// The summaries below read s, the checker's state (Main.qml's summary):
// checking, checkFailed, checkedAt, appCount, the counts above by name
// (updateCount, waitingCount, quietCount, errorCount, mutedErrorCount,
// uncheckedCount, staleCount), pkgsFollowing and discoveryError.

// What quiet rows hold back, in one wording for the header, the tooltip
// and IPC status: " (+N muted/skipped)" for their updates. The tooltip and
// IPC status (withFailures) also say when a muted row's check failed; the
// header and the bar leave that out, as they leave out its update.
function quietNote(s, withFailures) {
  var parts = []
  if (s.quietCount > 0) parts.push("+" + s.quietCount + " muted/skipped")
  var failed = withFailures ? s.mutedErrorCount : 0
  if (failed > 0) parts.push("check failed for " + failed + " muted " + (failed === 1 ? "app" : "apps"))
  return parts.length > 0 ? " (" + parts.join(", ") + ")" : ""
}

// All current, N updates, check failed, or last known (rows from an
// earlier run because this one failed for them).
function heroState(s, checked) {
  if (s.checkFailed) return "Check failed"
  var updates = s.updateCount + s.waitingCount
  if (updates > 0) return updates + (updates === 1 ? " update" : " updates")
  if (s.staleCount > 0) return "Last known, " + checked
  if (s.errorCount > 0) return "Check failed"
  if (s.checkedAt === "") return "Not checked yet"
  if (s.uncheckedCount > 0) return "All checked current, " + s.uncheckedCount + " unchecked"
  return s.appCount > 0 ? "All current" : ""
}

// The hero says one thing (heroState), then what quiet rows hold back.
// checked is checkedText's answer.
function heroMeta(s, settingsOpen, checked) {
  if (settingsOpen) return "Settings"
  if (s.checking) return "Checking…"
  var state = heroState(s, checked)
  return state !== "" && state !== "Not checked yet" ? state + quietNote(s, false) : state
}

// The bar tooltip and the status IPC call keep the full count.
function summaryText(s) {
  var parts = []
  if (s.updateCount > 0) parts.push(s.updateCount + (s.updateCount === 1 ? " update" : " updates"))
  if (s.waitingCount > 0) parts.push(s.waitingCount + " newer without an install path")
  var failed = s.errorCount
  if (s.checkFailed) parts.push("check failed")
  else if (failed > 0) parts.push("check failed for " + failed + (failed === 1 ? " app" : " apps"))
  if (s.staleCount > 0) parts.push("last known for " + s.staleCount + (s.staleCount === 1 ? " app" : " apps"))
  var unchecked = s.uncheckedCount > 0 ? s.uncheckedCount + " unchecked" : ""
  var text = parts.length > 0 ? parts.concat(unchecked !== "" ? [unchecked] : []).join(", ")
    : s.checkedAt === "" || s.appCount === 0 ? ""
    : unchecked !== "" ? "All checked current, " + unchecked : "All current"
  return text !== "" ? text + quietNote(s, true) : text
}

function followingText(s) { return s.pkgsFollowing ? "omarchy-pkgs: following master (unpinned)" : "" }

// A failure or a warning (a wrapper Omabump no longer recognises).
function discoveryText(s) { return s.discoveryError !== "" ? "Agent discovery: " + s.discoveryError : "" }

function tooltipText(s) {
  var summary = summaryText(s)
  var text = summary.indexOf("All current") === 0 ? "Omabump up to date" + summary.substring(11)
    : summary !== "" ? "Omabump: " + summary
    : s.checkedAt === "" ? "Omabump: not checked yet" : "Omabump: none installed"
  if (followingText(s) !== "") text += "\n" + followingText(s)
  if (discoveryText(s) !== "") text += "\n" + discoveryText(s)
  return text
}

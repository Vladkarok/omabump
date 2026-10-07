import QtQuick
import Quickshell
import Quickshell.Io

// The display side of the plugin. bin/omabump-check does all the work and
// writes status.json; this file runs it on a timer and watches the result, so
// a check started from a terminal (or by omabump-install) lands here too.
Item {
  id: root
  visible: false

  property var settings: ({})
  // A check started at creation would run with the defaults (mise rows
  // listed, notifications on): the bar injects the real settings later. The
  // owner sets this once they have arrived; checks wait for it.
  property bool settingsReady: false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string statusPath: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state")
    + "/omarchy/plugins/io.github.vladkarok.omabump/status.json"
  // A file URL percent-encodes spaces and non-ASCII characters in the path.
  readonly property string binDir: decodeURIComponent(String(Qt.resolvedUrl("bin"))
    .replace(/^file:\/\//, "").replace(/[?#].*$/, ""))
  readonly property string checkScript: binDir + "/omabump-check"
  readonly property string installScript: binDir + "/omabump-install"
  readonly property string promptScript: binDir + "/omabump-prompt"

  // Between a minute and a day, whatever shell.json holds.
  readonly property int refreshIntervalSec: Math.min(86400, Math.max(60, Number(setting("refreshIntervalSec", 3600)) || 3600))
  readonly property bool notify: boolSetting("notify", true)
  readonly property bool showMise: boolSetting("showMise", true)
  onShowMiseChanged: { parse(statusFile.text()); if (settingsReady) refresh() }
  // Rows the user muted (pkg ids): no badge, no count, no notification.
  // Their update stays visible in the panel and installable. The checker
  // reads the same two settings from shell.json itself (load_quiet).
  // The bar hands lists over as a QVariantList, which Array.isArray does
  // not accept, so they are read by index.
  readonly property var mutedApps: {
    var list = setting("mutedApps", [])
    var out = []
    if (list && typeof list === "object" && typeof list.length === "number")
      for (var i = 0; i < list.length; i++)
        if (typeof list[i] === "string" && list[i] !== "") out.push(list[i])
    return out
  }
  // {pkg: version} the user skipped. While a row's newest version is that
  // one it signals nothing; a newer release lights it up again (skipHolds).
  readonly property var skippedVersions: {
    var map = setting("skippedVersions", {})
    var out = {}
    if (map && typeof map === "object")
      for (var pkg in map)
        if (typeof map[pkg] === "string" && map[pkg] !== "") out[pkg] = map[pkg]
    return out
  }

  property var apps: []
  // The rows apps was last set from, as JSON: see parse().
  property string appsJson: ""
  property string checkedAt: ""
  property string pkgsCommit: ""
  // The user opted out of the pinned omarchy-pkgs commit (pins.json).
  property bool pkgsFollowing: false
  property string pkgsError: ""
  property string pkgsNote: ""
  // This shell's own check exited non-zero. Kept until a run that started
  // after it completes, from here or anywhere else.
  property string checkError: ""
  // status.json says its run stopped part way (killed, timed out, a failed
  // command), whoever started it: every bar and a run from a terminal see it.
  property string runError: ""
  // bin/omabump-discover could not read Omarchy's agent menu (the curated
  // mise rows still show, discovered ones do not), or found a wrapper it no
  // longer recognises.
  property string discoveryError: ""
  // mise could not list its tools: no CLI row could be read this run.
  property string miseError: ""
  // When this shell's last check ended; IPC refresh is throttled on it.
  property double lastCheckEndMs: 0
  // A Refresh that came while this shell's own check ran: that run may have
  // read versions from before the request, so one more runs after it.
  property bool refreshQueued: false
  // A run from a terminal marks status.json as in progress too. A run killed
  // half way leaves that mark behind, so one older than staleMs no longer
  // counts and Refresh comes back.
  readonly property double staleMs: 10 * 60 * 1000
  property bool fileCheckingRaw: false
  property double fileStartedMs: 0
  // status.json has been read, or found missing. The timer's first check
  // waits for it, or it could not tell that another one just ran.
  property bool statusRead: false
  property double nowMs: Date.now()
  readonly property bool fileChecking: fileCheckingRaw && nowMs - fileStartedMs < staleMs
  readonly property bool checking: checkProcess.running || fileChecking
  // The checker itself failed, omarchy-pkgs could not be fetched, or mise
  // could not list its tools: no summary may then read as up to date. A
  // failure only muted rows share (the omarchy-pkgs fetch with every
  // omarchy row muted) signals nothing, like their own failures.
  readonly property bool pkgsFailed: pkgsError !== "" && !allMuted("omarchy")
  readonly property bool miseFailed: miseError !== "" && !allMuted("mise")
  readonly property bool checkFailed: checkError !== "" || runError !== "" || pkgsFailed || miseFailed
  // Why checkFailed, for the line under the panel's header.
  readonly property string failureText: checkError !== "" ? checkError
    : runError !== "" ? runError
    : pkgsFailed ? pkgsError
    : miseFailed ? miseError : ""
  // Counts, the urgent icon and the bar icon's visibility leave quiet rows
  // out (isQuiet); quietCount says how many updates that hides.
  readonly property int updateCount: {
    var count = 0
    for (var i = 0; i < apps.length; i++)
      if (apps[i].updateAvailable === true && apps[i].installable === true && !isQuiet(apps[i])) count++
    return count
  }
  // Newer upstream releases with no install path (no recipe watch, or an
  // indicator-only app).
  readonly property int waitingCount: {
    var count = 0
    for (var i = 0; i < apps.length; i++)
      if (apps[i].updateAvailable === true && apps[i].installable !== true && !isQuiet(apps[i])) count++
    return count
  }
  readonly property int quietCount: {
    var count = 0
    for (var i = 0; i < apps.length; i++)
      if (apps[i].updateAvailable === true && isQuiet(apps[i])) count++
    return count
  }
  // Failed rows. Mute takes a row out of every signal, its failure too:
  // that shows on its own row, and in mutedErrorCount for the status text.
  // A skip silences one version, not the row, so a skipped row's failure
  // still counts.
  readonly property int errorCount: {
    var count = 0
    for (var i = 0; i < apps.length; i++) if (String(apps[i].error || "") !== "" && !isMuted(apps[i])) count++
    return count
  }
  readonly property int mutedErrorCount: {
    var count = 0
    for (var i = 0; i < apps.length; i++) if (String(apps[i].error || "") !== "" && isMuted(apps[i])) count++
    return count
  }
  // mise rows on no backend Omabump queries ("Update check skipped"): their
  // newest version is unknown, so no summary may call them current, muted or
  // not (mute silences an update, it does not make an unknown state known).
  readonly property int uncheckedCount: {
    var count = 0
    for (var i = 0; i < apps.length; i++)
      if (apps[i].unchecked === true || String(apps[i].note || "").indexOf("Update check skipped") === 0) count++
    return count
  }
  // Rows showing the version from an earlier run because this one failed;
  // muted ones count in mutedErrorCount (a stale row has its error).
  readonly property int staleCount: {
    var count = 0
    for (var i = 0; i < apps.length; i++) if (apps[i].stale === true && !isMuted(apps[i])) count++
    return count
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // `omarchy bar set <id> notify false` without --json stores the string
  // "false", so "true" and "false" in any case count as the booleans.
  // Anything else is the fallback.
  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "string") value = value.trim().toLowerCase()
    if (value === true || value === "true") return true
    if (value === false || value === "false") return false
    return fallback
  }

  function isMuted(app) { return !!app && mutedApps.indexOf(String(app.pkg)) !== -1 }
  // The row the last check listed for pkg, or null.
  function appFor(pkg) {
    for (var i = 0; i < apps.length; i++) if (apps[i].pkg === pkg) return apps[i]
    return null
  }
  // Whether every listed row from source is muted (and there is one).
  function allMuted(source) {
    var any = false
    for (var i = 0; i < apps.length; i++) {
      if (apps[i].source !== source) continue
      if (!isMuted(apps[i])) return false
      any = true
    }
    return any
  }
  // The version skipped for this row, if any.
  function skippedVersion(app) {
    return app && skippedVersions.hasOwnProperty(app.pkg) ? skippedVersions[app.pkg] : ""
  }
  // A row whose update the user skipped. Decided here from the settings as
  // they are now, by the checker's rule, so a skip shows at once and a skip
  // changed since the last check does not keep that check's answer.
  function isSkipped(app) {
    return !!app && app.updateAvailable === true && skipHolds(app, skippedVersion(app))
  }
  // A row that signals nothing: muted, or at a skipped version.
  function isQuiet(app) { return isMuted(app) || isSkipped(app) }

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
    if (version === "" || latest === "") return false
    if (app.source === "mise" || app.source === "self") return app.updateAvailable === true && latest === version
    return vercmp(latest, version) <= 0 && vercmp(upstreamPart(String(app.installed || "")), version) < 0
  }

  // Whether the settings keep the skip of version for pkg: while it applies,
  // and while the last check cannot tell. That is a row it did not list
  // (hidden by Show mise tools, not installed now) and one that failed, is
  // stale, is being checked, was not checked or has no newest version.
  function skipKept(pkg, version) {
    var app = appFor(pkg)
    if (!app || app.checking === true || app.stale === true || app.unchecked === true
      || String(app.error || "") !== "" || String(app.latest || "") === "") return true
    return skipHolds(app, version)
  }

  // The installed version less epoch and pkgrel (upstream_part in
  // bin/omabump-common).
  function upstreamPart(v) { return String(v).replace(/^[^:]*:/, "").replace(/-[^-]*$/, "") }

  // pacman's vercmp (alpm_pkg_vercmp): below zero, zero or above zero as a
  // is older than, the same as or newer than b. The checker runs vercmp
  // itself; the panel needs the same answer for skips between checks.
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

  // Refresh (click, r, IPC, a changed Show mise tools) always gets a check
  // that starts after it. While this shell's own check runs it is queued
  // for when that one ends. While another one runs (another monitor's bar,
  // a terminal) the checker gets --wait, so it runs after that one instead
  // of leaving at once on the lock.
  function refresh() {
    if (!settingsReady) return
    if (checkProcess.running) {
      refreshQueued = true
      return
    }
    nowMs = Date.now()
    runCheck(fileChecking)
  }

  function runQueued() {
    if (refreshQueued && !checkProcess.running) runCheck(false)
  }

  function runCheck(wait) {
    refreshQueued = false
    // An overall deadline: ten minutes, then TERM, then KILL ten seconds
    // later. --wait first waits up to 660 s for the running check (flock -w
    // in bin/omabump-check), so the deadline grows by that.
    var command = ["timeout", "-k", "10", wait ? "1260" : "600", checkScript]
    if (!notify) command.push("--no-notify")
    if (!showMise) command.push("--no-mise")
    if (wait) command.push("--wait")
    checkProcess.command = command
    checkProcess.running = true
  }

  // The timer's check. Every monitor's bar runs its own copy of this widget
  // and a shell reload starts them all, so this one stays out while a check
  // runs (its own, or one status.json shows), or a finished one started less
  // than an interval (less 30 s of slack) ago. That start, not checkedAt
  // (the end), is what counts: from the end, this widget's own next tick
  // would come up short by however long its last check took and be skipped.
  // Refresh (click, r, IPC) always checks.
  function scheduledRefresh() {
    nowMs = Date.now()
    if (checkProcess.running || fileChecking) return
    var checked = checkedAt !== "" ? new Date(checkedAt).getTime() : NaN
    // A run that died half way leaves startedAt past checkedAt, and its rows
    // are partly the run before's: then that run's end is all there is.
    var last = fileStartedMs > 0 && isFinite(checked) && fileStartedMs <= checked ? fileStartedMs : checked
    // A time ahead of the clock (it was set back) proves nothing.
    var age = nowMs - last
    if (isFinite(age) && age >= 0 && age < (refreshIntervalSec - 30) * 1000) return
    runCheck(false)
  }

  function parse(content) {
    if (String(content || "").trim() === "") return
    try {
      var parsed = JSON.parse(String(content || ""))
      var all = parsed && Array.isArray(parsed.apps) ? parsed.apps : []
      // A check run from a terminal lists mise tools whatever the setting says.
      var list = showMise ? all : all.filter(function(app) { return app.source !== "mise" })
      // A check rewrites the file once per row, and the file watch and the
      // end of the check both read it. A new array re-runs everything bound
      // to apps, in each monitor's copy of the widget, so rows that did not
      // change keep the old one.
      var json = JSON.stringify(list)
      if (json !== appsJson) {
        appsJson = json
        apps = list
      }
      checkedAt = parsed && parsed.checkedAt ? String(parsed.checkedAt) : ""
      fileCheckingRaw = !!parsed && parsed.checking === true
      var started = parsed && parsed.startedAt ? new Date(parsed.startedAt).getTime() : NaN
      fileStartedMs = isFinite(started) ? started : 0
      nowMs = Date.now()
      var pkgs = parsed && parsed.omarchyPkgs ? parsed.omarchyPkgs : {}
      pkgsCommit = String(pkgs.commit || "")
      pkgsFollowing = pkgs.following === true
      pkgsError = String(pkgs.error || "")
      pkgsNote = String(pkgs.note || "")
      discoveryError = parsed ? String(parsed.discoveryError || "") : ""
      miseError = parsed && showMise ? String(parsed.miseError || "") : ""
      runError = parsed ? String(parsed.runError || "") : ""
      // A run that started after this shell's failed one ended, and
      // completed, has the answer that one could not give. startedAt has
      // whole seconds, so a run in that same second does not count.
      if (checkError !== "" && !fileCheckingRaw && runError === "" && fileStartedMs > lastCheckEndMs)
        checkError = ""
    } catch (e) {
      console.warn("omabump", "Ignoring bad status file", statusPath, e)
    }
  }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.parse(text())
      root.statusRead = true
    }
    onLoadFailed: root.statusRead = true
  }

  Process {
    id: checkProcess
    running: false
    // The checker replaces status.json with a rename, which a watch on the
    // old inode can miss; reading it back here covers that.
    onExited: function(exitCode) {
      root.lastCheckEndMs = Date.now()
      root.checkError = exitCode === 0 ? "" : "Check failed (exit " + exitCode + "), see the shell log"
      statusFile.reload()
      Qt.callLater(root.runQueued)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("omabump", text.trim())
    }
  }

  Timer {
    interval: 60000
    running: root.fileCheckingRaw
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // A host that never injects settings still gets checks, with the defaults.
  Timer {
    interval: 5000
    running: !root.settingsReady
    onTriggered: root.settingsReady = true
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: root.settingsReady && root.statusRead
    repeat: true
    triggeredOnStart: true
    onTriggered: root.scheduledRefresh()
  }
}

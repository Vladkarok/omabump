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
  // one it signals nothing; a newer release lights it up again.
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
  property string checkError: ""
  // bin/omabump-discover could not read Omarchy's agent menu (the curated
  // mise rows still show, discovered ones do not), or found a wrapper it no
  // longer recognises.
  property string discoveryError: ""
  // mise could not list its tools: no CLI row could be read this run.
  property string miseError: ""
  // When this shell's last check ended; IPC refresh is throttled on it.
  property double lastCheckEndMs: 0
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
  // could not list its tools: no summary may then read as up to date.
  readonly property bool checkFailed: checkError !== "" || pkgsError !== "" || miseError !== ""
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
  readonly property int errorCount: {
    var count = 0
    for (var i = 0; i < apps.length; i++) if (String(apps[i].error || "") !== "") count++
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
  // Rows showing the version from an earlier run because this one failed.
  readonly property int staleCount: {
    var count = 0
    for (var i = 0; i < apps.length; i++) if (apps[i].stale === true) count++
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
  // The version skipped for this row, if any.
  function skippedVersion(app) {
    return app && skippedVersions.hasOwnProperty(app.pkg) ? skippedVersions[app.pkg] : ""
  }
  // The checker decides (vercmp for pacman rows, exact strings for mise and
  // self rows) from the settings it read; right after a skip, before the
  // next check, an exact match stands in for its answer.
  function isSkipped(app) {
    var version = skippedVersion(app)
    return version !== "" && app.updateAvailable === true && (app.latest === version || app.skipped === true)
  }
  // A row that signals nothing: muted, or at a skipped version.
  function isQuiet(app) { return isMuted(app) || isSkipped(app) }

  function refresh() {
    if (!settingsReady || checkProcess.running) return
    // An overall deadline: ten minutes, then TERM, then KILL ten seconds later.
    var command = ["timeout", "-k", "10", "600", checkScript]
    if (!notify) command.push("--no-notify")
    if (!showMise) command.push("--no-mise")
    checkProcess.command = command
    checkProcess.running = true
  }

  // The timer's check. Every monitor's bar runs its own copy of this widget
  // and a shell reload starts them all, so this one stays out while
  // status.json shows a check running, or a finished one that started less
  // than an interval (less 30 s of slack) ago. That start, not checkedAt
  // (the end), is what counts: from the end, this widget's own next tick
  // would come up short by however long its last check took and be skipped.
  // Refresh (click, r, IPC) always checks.
  function scheduledRefresh() {
    nowMs = Date.now()
    if (fileChecking) return
    var checked = checkedAt !== "" ? new Date(checkedAt).getTime() : NaN
    // A run that died half way leaves startedAt past checkedAt, and its rows
    // are partly the run before's: then that run's end is all there is.
    var last = fileStartedMs > 0 && isFinite(checked) && fileStartedMs <= checked ? fileStartedMs : checked
    // A time ahead of the clock (it was set back) proves nothing.
    var age = nowMs - last
    if (isFinite(age) && age >= 0 && age < (refreshIntervalSec - 30) * 1000) return
    refresh()
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

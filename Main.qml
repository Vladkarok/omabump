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
  readonly property int refreshIntervalSec: Math.min(86400, Math.max(60, Number(setting("refreshIntervalSec", 900)) || 900))
  readonly property bool notify: setting("notify", true) !== false
  readonly property bool showMise: setting("showMise", true) !== false
  onShowMiseChanged: { parse(statusFile.text()); if (settingsReady) refresh() }

  property var apps: []
  property string checkedAt: ""
  property string pkgsCommit: ""
  // The user opted out of the pinned omarchy-pkgs commit (pins.json).
  property bool pkgsFollowing: false
  property string pkgsError: ""
  property string pkgsNote: ""
  property string checkError: ""
  // bin/omabump-discover could not read Omarchy's agent menu: the curated
  // mise rows still show, discovered ones do not.
  property string discoveryError: ""
  // When this shell's last check ended; IPC refresh is throttled on it.
  property double lastCheckEndMs: 0
  // A run from a terminal marks status.json as in progress too. A run killed
  // half way leaves that mark behind, so one older than staleMs no longer
  // counts and Refresh comes back.
  readonly property double staleMs: 10 * 60 * 1000
  property bool fileCheckingRaw: false
  property double fileStartedMs: 0
  property double nowMs: Date.now()
  readonly property bool fileChecking: fileCheckingRaw && nowMs - fileStartedMs < staleMs
  readonly property bool checking: checkProcess.running || fileChecking
  // The checker itself failed, or omarchy-pkgs could not be fetched: no
  // summary may then read as up to date.
  readonly property bool checkFailed: checkError !== "" || pkgsError !== ""
  readonly property int updateCount: {
    var count = 0
    for (var i = 0; i < apps.length; i++)
      if (apps[i].updateAvailable === true && apps[i].installable === true) count++
    return count
  }
  // Newer upstream releases with no install path (no recipe watch, or an
  // indicator-only app).
  readonly property int waitingCount: {
    var count = 0
    for (var i = 0; i < apps.length; i++)
      if (apps[i].updateAvailable === true && apps[i].installable !== true) count++
    return count
  }
  readonly property int errorCount: {
    var count = 0
    for (var i = 0; i < apps.length; i++) if (String(apps[i].error || "") !== "") count++
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

  function refresh() {
    if (!settingsReady || checkProcess.running) return
    // An overall deadline: ten minutes, then TERM, then KILL ten seconds later.
    var command = ["timeout", "-k", "10", "600", checkScript]
    if (!notify) command.push("--no-notify")
    if (!showMise) command.push("--no-mise")
    checkProcess.command = command
    checkProcess.running = true
  }

  function parse(content) {
    if (String(content || "").trim() === "") return
    try {
      var parsed = JSON.parse(String(content || ""))
      var all = parsed && Array.isArray(parsed.apps) ? parsed.apps : []
      // A check run from a terminal lists mise tools whatever the setting says.
      apps = showMise ? all : all.filter(function(app) { return app.source !== "mise" })
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
    onLoaded: root.parse(text())
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
    running: root.settingsReady
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}

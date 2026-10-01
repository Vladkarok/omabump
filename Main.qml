import QtQuick
import Quickshell
import Quickshell.Io

// The display side of the plugin. bin/agent-apps-check does all the work and
// writes status.json; this file runs it on a timer and watches the result, so
// a check started from a terminal (or by agent-apps-install) lands here too.
Item {
  id: root
  visible: false

  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string statusPath: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state")
    + "/omarchy/plugins/io.github.vladkarok.agent-apps/status.json"
  // A file URL percent-encodes spaces and non-ASCII characters in the path.
  readonly property string binDir: decodeURIComponent(String(Qt.resolvedUrl("bin"))
    .replace(/^file:\/\//, "").replace(/[?#].*$/, ""))
  readonly property string checkScript: binDir + "/agent-apps-check"
  readonly property string installScript: binDir + "/agent-apps-install"
  readonly property string promptScript: binDir + "/agent-apps-prompt"

  readonly property int refreshIntervalSec: Math.max(60, Number(setting("refreshIntervalSec", 900)) || 900)
  readonly property bool notify: setting("notify", true) !== false
  readonly property bool showMise: setting("showMise", true) !== false
  onShowMiseChanged: { parse(statusFile.text()); refresh() }

  property var apps: []
  property string checkedAt: ""
  property string pkgsCommit: ""
  property string pkgsError: ""
  property string checkError: ""
  // A run from a terminal marks status.json as in progress too.
  property bool fileChecking: false
  readonly property bool checking: checkProcess.running || fileChecking
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

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function refresh() {
    if (checkProcess.running) return
    var command = [checkScript]
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
      fileChecking = !!parsed && parsed.checking === true
      var pkgs = parsed && parsed.omarchyPkgs ? parsed.omarchyPkgs : {}
      pkgsCommit = String(pkgs.commit || "")
      pkgsError = String(pkgs.error || "")
    } catch (e) {
      console.warn("agent-apps", "Ignoring bad status file", statusPath, e)
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
      root.checkError = exitCode === 0 ? "" : "Check failed (exit " + exitCode + "), see the shell log"
      statusFile.reload()
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agent-apps", text.trim())
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The display side of the plugin. bin/omabump-check does all the work and
// writes status.json; this file runs it on a timer and watches the result, so
// a check started from a terminal (or by omabump-install) lands here too. The
// rules it applies to the result live in Model.js.
Item {
  id: root
  visible: false

  property var settings: ({})
  // A check started at creation would run with the defaults (mise rows
  // listed, notifications on): the bar injects the real settings later. The
  // owner sets this once they have arrived; checks wait for it.
  property bool settingsReady: false

  readonly property string home: Quickshell.env("HOME") || ""
  // state_dir in bin/omabump-common.
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state")
    + "/omarchy/plugins/io.github.vladkarok.omabump"
  readonly property string statusPath: stateDir + "/status.json"
  // The lock bin/omabump-check holds while it runs.
  readonly property string lockPath: stateDir + "/.check.lock"
  // A file URL percent-encodes spaces and non-ASCII characters in the path.
  readonly property string binDir: decodeURIComponent(String(Qt.resolvedUrl("bin"))
    .replace(/^file:\/\//, "").replace(/[?#].*$/, ""))
  readonly property string checkScript: binDir + "/omabump-check"
  readonly property string installScript: binDir + "/omabump-install"
  readonly property string promptScript: binDir + "/omabump-prompt"
  // A run that waits for the lock runs this before the checker: $1 the
  // checker's lock, $2 how long to wait for it (lockWaitSec), then the
  // command. It takes the lock and lets go at once, says "started" on
  // stdout and runs the command. A lock still held after the wait is left
  // be, and the script exits 75 (lockBusyExit) having run nothing; a lock
  // file that cannot be opened (no check has made its directory yet) has
  // no check behind it.
  readonly property string waitScript: 'flock -E 75 -w "$2" "$1" true 2>/dev/null; (( $? == 75 )) && exit 75; echo started; shift 2; exec "$@"'
  readonly property int lockBusyExit: 75
  // The checker's own --wait (flock -w in bin/omabump-check).
  readonly property int lockWaitSec: 660

  readonly property int refreshIntervalSec: Model.refreshIntervalSec(settings)
  readonly property bool notify: Model.boolSetting(settings, "notify", true)
  readonly property bool showMise: Model.boolSetting(settings, "showMise", true)
  // A check that started before the change runs with the old setting: this
  // shell's own, and one from a terminal or the installer too, since
  // bin/omabump-check reads showMise from shell.json itself. Turned on,
  // such a run lists no CLI rows, so one more must start after it: behind
  // this shell's own check it is queued; otherwise each monitor's copy of
  // the widget waits for the lock, then starts one that leaves on the lock
  // (runCheck(true, false)), and the first to take it runs for all. The
  // wait asks the lock, not status.json's mark, which a killed run leaves
  // behind. Turned off, the run keeps status.json free of CLI rows;
  // parse() filters them out meanwhile. Before the timer's first tick (the
  // bar is still handing the settings over), that tick reads the setting as
  // it is then.
  onShowMiseChanged: {
    parse(statusFile.text())
    if (!settingsReady || !timerTicked) return
    if (checkProcess.running) refreshQueued = true
    else runCheck(true, false)
  }
  // Rows the user muted (pkg ids): no badge, no count, no notification.
  // Their update stays visible in the panel and installable. And {pkg:
  // version} the user skipped. The checker reads the same two settings from
  // shell.json itself (load_quiet), by the same rules (Model.mutedApps and
  // Model.skippedVersions).
  readonly property var mutedApps: Model.mutedApps(settings)
  readonly property var skippedVersions: Model.skippedVersions(settings)

  property var apps: []
  // The rows apps was last set from, as JSON: see parse().
  property string appsJson: ""
  // status.json's schemaVersion: 0 for a file from before the field.
  property int schemaVersion: 0
  property string checkedAt: ""
  property string pkgsCommit: ""
  // The user opted out of the pinned omarchy-pkgs commit (pins.json).
  property bool pkgsFollowing: false
  property string pkgsError: ""
  property string pkgsNote: ""
  // This shell's own check exited non-zero, or could not start for the lock.
  // Kept until a run that started after it completes, from here or anywhere
  // else.
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
  // This shell's running check is for a Refresh (it runs with --wait; the
  // timer's does not).
  property bool runForRefresh: false
  // That run still waits for another check to end (waitScript has not said
  // "started"): a Refresh now needs nothing more, that run starts after it.
  property bool runWaiting: false
  // IPC refresh is throttled on these two. A check that starts after now is
  // on its way already:
  readonly property bool refreshPending: refreshQueued || checkProcess.running && runWaiting
  // and this shell's own check for a Refresh is past its wait.
  readonly property bool refreshRunning: checkProcess.running && runForRefresh && !runWaiting
  // A run from a terminal marks status.json as in progress too. A run killed
  // half way leaves that mark behind, so one older than staleMs no longer
  // counts and Refresh comes back.
  readonly property double staleMs: 10 * 60 * 1000
  property bool fileCheckingRaw: false
  property double fileStartedMs: 0
  // status.json has been read, or found missing. The timer's first check
  // waits for it, or it could not tell that another one just ran.
  property bool statusRead: false
  // The timer has ticked once, with the settings the bar handed over.
  property bool timerTicked: false
  property double nowMs: Date.now()
  readonly property bool fileChecking: fileCheckingRaw && nowMs - fileStartedMs < staleMs
  readonly property bool checking: checkProcess.running || fileChecking
  // Why no summary may read as up to date, for the line under the panel's
  // header; checkFailed while there is one.
  readonly property string failureText: Model.failureText({ checkError: checkError, runError: runError,
    pkgsError: pkgsError, miseError: miseError }, apps, mutedApps)
  readonly property bool checkFailed: failureText !== ""
  readonly property int updateCount: Model.updateCount(apps, mutedApps, skippedVersions)
  readonly property int waitingCount: Model.waitingCount(apps, mutedApps, skippedVersions)
  readonly property int quietCount: Model.quietCount(apps, mutedApps, skippedVersions)
  readonly property int errorCount: Model.errorCount(apps, mutedApps)
  readonly property int mutedErrorCount: Model.mutedErrorCount(apps, mutedApps)
  readonly property int uncheckedCount: Model.uncheckedCount(apps)
  readonly property int staleCount: Model.staleCount(apps, mutedApps)
  // What the hero, the bar tooltip and IPC status summarise (Model.heroMeta,
  // Model.tooltipText).
  readonly property var summary: ({
    checking: checking, checkFailed: checkFailed, checkedAt: checkedAt, appCount: apps.length,
    updateCount: updateCount, waitingCount: waitingCount, quietCount: quietCount,
    errorCount: errorCount, mutedErrorCount: mutedErrorCount, uncheckedCount: uncheckedCount,
    staleCount: staleCount, pkgsFollowing: pkgsFollowing, discoveryError: discoveryError
  })

  // Refresh (click, r, IPC) always gets a check that starts after it. While
  // this shell's own check runs, one more is queued for when it ends, unless
  // that one is still waiting for another check and so starts later anyway.
  // Otherwise it runs with --wait: a check already running (another
  // monitor's bar, a terminal, the installer) may have read versions from
  // before the request, and this one then runs after it instead of leaving
  // at once on the lock. With the lock free it runs at once.
  function refresh() {
    if (!settingsReady) return
    if (checkProcess.running) {
      if (!runWaiting) refreshQueued = true
      return
    }
    runCheck(true, true)
  }

  // A queued Refresh waits too: the run it came during may have left at
  // once on the lock (the timer's does) while a check from before the
  // request held it.
  function runQueued() {
    if (refreshQueued && !checkProcess.running) runCheck(true, true)
  }

  // wait: wait for a check that holds the lock now (waitScript) instead of
  // leaving at once on it, as the timer's run does. own: a Refresh's, which
  // also runs after a check that takes the lock between the wait and its
  // start (the checker's --wait); without it, that check, which started
  // after the wait, answers instead and this one leaves on the lock.
  function runCheck(wait, own) {
    refreshQueued = false
    runForRefresh = wait && own
    runWaiting = wait
    // An overall deadline: ten minutes, then TERM, then KILL ten seconds
    // later. A Refresh waits for a running check before it (waitScript), so
    // the deadline bounds its own run alone, like any other: other waiters
    // (the installer, another bar) count on a check ending by then.
    var command = ["timeout", "-k", "10", "600", checkScript]
    if (!notify) command.push("--no-notify")
    if (!showMise) command.push("--no-mise")
    if (wait && own) command.push("--wait")
    if (wait)
      command = ["bash", "-c", waitScript, "omabump-wait", lockPath, String(lockWaitSec)].concat(command)
    checkProcess.command = command
    checkProcess.running = true
  }

  // The timer's check. This one stays out while a check runs (its own, or
  // one status.json shows) or a finished one is recent (Model.checkDue).
  // Refresh (click, r, IPC) always checks.
  function scheduledRefresh() {
    timerTicked = true
    nowMs = Date.now()
    if (checkProcess.running || fileChecking) return
    if (Model.checkDue(nowMs, checkedAt, fileStartedMs, refreshIntervalSec)) runCheck(false, false)
  }

  function parse(content) {
    try {
      var status = Model.parseStatus(content, showMise)
      if (!status) return
      schemaVersion = status.schemaVersion
      // A check rewrites the file once per row, and the file watch and the
      // end of the check both read it. A new array re-runs everything bound
      // to apps, in each monitor's copy of the widget, so rows that did not
      // change keep the old one.
      var json = JSON.stringify(status.apps)
      if (json !== appsJson) {
        appsJson = json
        apps = status.apps
      }
      checkedAt = status.checkedAt
      fileCheckingRaw = status.checking
      fileStartedMs = status.startedMs
      nowMs = Date.now()
      pkgsCommit = status.pkgsCommit
      pkgsFollowing = status.pkgsFollowing
      pkgsError = status.pkgsError
      pkgsNote = status.pkgsNote
      discoveryError = status.discoveryError
      miseError = status.miseError
      runError = status.runError
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
      var waited = root.runWaiting
      root.runWaiting = false
      if (waited && exitCode === root.lockBusyExit) {
        // waitScript gave up on the lock and ran nothing: this shell's last
        // check and when it ended stand, and the Refresh says it was not
        // done rather than pass for one that was.
        root.checkError = "Check not run: another check held the lock for over "
          + Math.round(root.lockWaitSec / 60) + " min"
      } else {
        root.lastCheckEndMs = Date.now()
        root.checkError = exitCode === 0 ? "" : "Check failed (exit " + exitCode + "), see the shell log"
      }
      statusFile.reload()
      Qt.callLater(root.runQueued)
    }

    // waitScript's word that the wait is over.
    stdout: SplitParser {
      onRead: function(line) { if (line === "started") root.runWaiting = false }
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

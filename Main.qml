import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The display side of the plugin. bin/omabump-check does all the work and
// writes status.json; this file runs it on a timer (and its local refresh
// in between) and watches the result, so a check started from a terminal
// (or by omabump-install) lands here too. The rules it applies to the
// result live in Model.js.
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
  // A run that waits for the lock runs this before the checker's deadline
  // (runCheck): $1 the checker's lock, $2 how long to wait for it
  // (lockWaitSec), then the command. It takes the lock and lets go at once,
  // says "started" on stdout and runs the command. A lock still held after
  // the wait is left be, and the script exits 75 (Model.lockBusyExit)
  // having run nothing; a lock file that cannot be opened (no check has
  // made its directory yet) has no check behind it.
  readonly property string waitScript: 'flock -E 75 -w "$2" "$1" true 2>/dev/null; (( $? == 75 )) && exit 75; echo started; shift 2; exec "$@"'
  // As long as the checker's own --wait (flock -w in bin/omabump-check),
  // which the installer's refresh passes: a check lasts at most ten minutes.
  readonly property int lockWaitSec: 660

  readonly property int refreshIntervalSec: Model.refreshIntervalSec(settings)
  readonly property bool notify: Model.boolSetting(settings, "notify", true)
  readonly property bool showMise: Model.boolSetting(settings, "showMise", true)
  // A check that started before the change runs with the old setting: this
  // shell's own, and one from a terminal or the installer too, since
  // bin/omabump-check reads showMise from shell.json itself. Turned on,
  // such a run lists no CLI rows, so one more must start after it: behind
  // this shell's own check it is queued (runQueued); otherwise it waits for
  // the lock (runCheck(true, false)). Each monitor's copy of the widget
  // does the same, and their checkers then reach the lock together: the
  // first to take it runs for all and the others leave on it. A queued run
  // behind a check that completed does not wait first
  // (Model.queuedRunWaits), so it too leaves on a check another copy
  // started after that one ended. It is not a Refresh's run: an IPC
  // refresh during it still gets one after it, as during the timer's
  // (refreshRunning). The wait asks the lock, not status.json's mark,
  // which a killed run leaves behind. Turned off, the run keeps
  // status.json free of CLI rows; parse() filters them out meanwhile.
  // Before the timer's first tick (the bar is still handing the settings
  // over), that tick reads the setting as it is then (Model.showMiseRun).
  onShowMiseChanged: {
    parse(statusFile.text())
    var run = Model.showMiseRun(settingsReady, timerTicked, checkProcess.running)
    if (run === "queue") checkQueued = true
    else if (run === "wait") runCheck(true, false)
  }
  // Rows the user muted (pkg ids): no badge, no count, no notification.
  // Their update stays visible in the panel and installable. And {pkg:
  // version} the user skipped. The checker reads the same two settings from
  // shell.json itself (load_quiet) and writes whether each row's skip
  // applies, which Model.isSkipped reads.
  readonly property var mutedApps: Model.mutedApps(settings)
  readonly property var skippedVersions: Model.skippedVersions(settings)

  property var apps: []
  // The rows apps was last set from, as JSON: see parse().
  property string appsJson: ""
  property string checkedAt: ""
  property string pkgsCommit: ""
  // The user opted out of the pinned omarchy-pkgs commit (pins.json).
  property bool pkgsFollowing: false
  property string pkgsError: ""
  property string pkgsNote: ""
  // This shell's own check failed, or gave up waiting for the lock. One that
  // left on the lock (Model.checkOutcome's "left") neither sets nor clears
  // it. Kept until a run that started after checkErrorAfterMs completes,
  // from here or anywhere else (Model.answersError).
  property string checkError: ""
  // When the failed check ended, or when the run that could not start was
  // asked for: the check that held the lock then started before it, and
  // its answer is not the one asked for.
  property double checkErrorAfterMs: 0
  // When this shell's running check was asked for.
  property double runAskedMs: 0
  // status.json says its run stopped part way (killed, timed out, a failed
  // command), whoever started it: every bar and a run from a terminal see it.
  property string runError: ""
  // mise could not list its tools: no CLI row could be read this run.
  property string miseError: ""
  // When this shell's last check ended, not counting a run that never took
  // the lock; IPC refresh is throttled on it.
  property double lastCheckEndMs: 0
  // A Refresh or a change of Show mise tools that came while this shell's
  // own check ran: that run may have read versions or the setting from
  // before it, so one more runs after it.
  property bool checkQueued: false
  // That one is for a Refresh (runForRefresh), not for Show mise tools alone.
  property bool queuedForRefresh: false
  // This shell's running check is for a Refresh, not the timer's or one for
  // Show mise tools.
  property bool runForRefresh: false
  // That run still waits for another check to end (waitScript has not said
  // "started"): a Refresh now needs nothing more, that run starts after it.
  property bool runWaiting: false
  // IPC refresh is throttled on these two. A check that starts after now is
  // on its way already:
  readonly property bool refreshPending: checkQueued || checkProcess.running && runWaiting
  // and this shell's own check for a Refresh is past its wait.
  readonly property bool refreshRunning: checkProcess.running && runForRefresh && !runWaiting
  // A run from a terminal marks status.json as in progress too. A run killed
  // half way leaves that mark behind, so one older than staleMs no longer
  // counts and Refresh comes back.
  readonly property double staleMs: 10 * 60 * 1000
  property bool fileCheckingRaw: false
  property double fileStartedMs: 0
  // status.json's inventoryAt: when the installed versions were last read,
  // by a check or a local refresh (localRefresh); 0 when it does not say.
  property double inventoryMs: 0
  // This shell's running check is the timer's or the panel's (runDue), and
  // the checker has not said "due" yet. It may find none due and run
  // nothing, so until then it is no check: the panel shows no "Checking…"
  // every minute.
  property bool runIfDue: false
  // A local refresh asked for while that run decides: it runs after it when
  // no check read the installed versions (checkProcess's onExited).
  property bool localAfterDue: false
  // A check a local refresh asked for while that run decides: it runs after
  // it only when none was due. A check that was due took the lock after the
  // refresh, so it read what the refresh asked about.
  property bool checkAfterDue: false
  // A local refresh asked for while one ran: one more runs after it.
  property bool localPending: false
  // status.json has been read, or found missing. The timer, the panel and
  // the local refresh wait for it.
  property bool statusRead: false
  // The timer has ticked once, with the settings the bar handed over.
  property bool timerTicked: false
  property double nowMs: Date.now()
  readonly property bool fileChecking: fileCheckingRaw && nowMs - fileStartedMs < staleMs
  readonly property bool checking: checkProcess.running && !runIfDue || fileChecking
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
    staleCount: staleCount, pkgsFollowing: pkgsFollowing
  })

  // Refresh (click, r, IPC) always gets a check that starts after it. While
  // this shell's own check runs, one more is queued for when it ends, unless
  // that one is still waiting for another check and so starts later anyway.
  // Otherwise it waits for the lock: a check already running (another
  // monitor's bar, a terminal, the installer) may have read versions from
  // before the request, and this one then runs after it instead of leaving
  // at once on the lock. With the lock free it runs at once.
  function refresh() {
    if (!settingsReady) return
    if (checkProcess.running) {
      if (!runWaiting) {
        checkQueued = true
        queuedForRefresh = true
      }
      return
    }
    runCheck(true, true)
  }

  // The run queued behind this shell's own check, once that one has ended.
  // wait (Model.queuedRunWaits): that check may not have held the lock to
  // its end, as when it left at once on it (the timer's does), and a check
  // from before the request may hold it now; this one then runs after it.
  // Behind a check that completed it does not wait: a check holding the
  // lock now took it later and answers the request, and this one leaves on
  // it instead of running a second check after it.
  function runQueued(wait) {
    if (checkQueued && !checkProcess.running) runCheck(wait, queuedForRefresh)
  }

  // wait: wait for a check that holds the lock now (waitScript) instead of
  // leaving at once on it, as the timer's run does. own: a Refresh's
  // (refreshRunning), with or without the wait. The checker itself never
  // waits for a check (no --wait): one that finds the lock taken after
  // waitScript's wait lost it to a check that started after the request
  // (or to another bar's waitScript, whose check starts next), and leaves
  // the answer to that one (Model.checkOutcome's "left"). A local refresh
  // holding the lock is no check: the checker waits for it to end.
  // ifDue: the timer's or the panel's (runDue), which the checker runs only
  // when it is due.
  function runCheck(wait, own, ifDue) {
    checkQueued = false
    queuedForRefresh = false
    runForRefresh = own
    runWaiting = wait
    runIfDue = !!ifDue
    runAskedMs = Date.now()
    // An overall deadline: ten minutes, then TERM, then KILL ten seconds
    // later; other waiters (the installer, another bar) count on a check
    // ending by then. Every wait for the lock comes before it (waitScript),
    // so it bounds the check alone, and a wait that gives up says so (exit
    // 75) instead of ending in the deadline's kill.
    var command = ["timeout", "-k", "10", "600", checkScript]
    if (!notify) command.push("--no-notify")
    if (!showMise) command.push("--no-mise")
    if (ifDue) command.push("--if-due", "--interval", String(refreshIntervalSec))
    if (wait)
      command = ["bash", "-c", waitScript, "omabump-wait", lockPath, String(lockWaitSec)].concat(command)
    checkProcess.command = command
    checkProcess.running = true
  }

  // The timer's check, or the retry of one that failed, when one is due:
  // bin/omabump-check --if-due decides, under its lock, from status.json's
  // times, which every bar shares, and exits Model.notDueExit otherwise. A
  // check holding the lock is the one that was due, and this one leaves on
  // it.
  function runDue() {
    runCheck(false, false, true)
  }

  // The timer's tick. It stays out while this shell's own check runs.
  // Refresh (click, r, IPC) always checks.
  function scheduledRefresh() {
    timerTicked = true
    nowMs = Date.now()
    if (!checkProcess.running) runDue()
  }

  // A local refresh (bin/omabump-check --local) reads the installed
  // versions again, from pacman and mise, without the network, in a second
  // or so. Apps are updated outside Omabump (Omarchy's wrappers run mise up
  // on launch, omarchy update runs pacman), and until the next check a row
  // would offer an Update that is already installed. One runs when the
  // panel opens (panelOpened) and, while the bar counts an update, on each
  // bar's localTimer. It holds the
  // checker's lock, so no check runs beside it, and leaves at once when
  // the lock is taken (Model.lockBusyExit). It never moves checkedAt or
  // startedAt, so the timer's check stays due as it was, and it is none of
  // this shell's checks: checkError, lastCheckEndMs and Refresh do not see
  // it. A request while one runs gets one more after it.
  function localRefresh() {
    if (!settingsReady || !statusRead) return
    if (localProcess.running) {
      localPending = true
      return
    }
    // A check reads the installed versions too.
    if (checking) return
    // This shell's runDue run holds the lock or is about to: the refresh
    // follows it, unless it ran a check.
    if (checkProcess.running) {
      localAfterDue = true
      return
    }
    var command = ["timeout", "-k", "10", "120", checkScript, "--local"]
    if (!showMise) command.push("--no-mise")
    localProcess.command = command
    localProcess.running = true
  }

  // localTimer's run, unless another bar's local refresh or a check read
  // the versions recently (Model.localDue).
  function localTick() {
    nowMs = Date.now()
    if (Model.localDue(nowMs, inventoryMs, Model.localIntervalSec)) localRefresh()
  }

  // The panel opened: it shows what is installed now, by the timer's check
  // when one is due, else by a local refresh after it (localAfterDue).
  // Nothing while a check runs, which reads the installed versions too.
  function panelOpened() {
    if (!settingsReady || !statusRead) return
    nowMs = Date.now()
    if (checking) return
    if (!checkProcess.running) runDue()
    localAfterDue = true
  }

  function parse(content) {
    try {
      var status = Model.parseStatus(content, showMise)
      if (!status) return
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
      inventoryMs = status.inventoryMs
      nowMs = Date.now()
      pkgsCommit = status.pkgsCommit
      pkgsFollowing = status.pkgsFollowing
      pkgsError = status.pkgsError
      pkgsNote = status.pkgsNote
      miseError = status.miseError
      runError = status.runError
      // A run that started after this shell's failed one, and completed,
      // has the answer that one could not give.
      if (checkError !== "" && Model.answersError(status, checkErrorAfterMs)) checkError = ""
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
      var outcome = Model.checkOutcome(exitCode, root.runWaiting)
      var local = root.localAfterDue
      var check = root.checkAfterDue
      root.runWaiting = false
      root.localAfterDue = false
      root.checkAfterDue = false
      if (outcome === "notRun") {
        // Nothing ran: this shell's last check and when it ended stand, and
        // the Refresh says it was not done rather than pass for one that
        // was. The check that held the lock started before it was asked
        // for, so only a later one clears that.
        root.checkError = Model.checkErrorText(outcome, exitCode, root.lockWaitSec)
        root.checkErrorAfterMs = root.runAskedMs
      } else if (outcome !== "left" && outcome !== "notDue") {
        root.checkError = Model.checkErrorText(outcome, exitCode, root.lockWaitSec)
        root.lastCheckEndMs = Date.now()
        root.checkErrorAfterMs = root.lastCheckEndMs
      }
      // A run that left on the lock, or found no check due, changes neither
      // checkError nor lastCheckEndMs: the check holding the lock answers,
      // and clears an error by the same rule as any other's (parse()). Its
      // lines on stderr are for a terminal; here they are no news (with two
      // bars, one copy leaves on every tick), so they stay out of the
      // shell's log.
      var err = checkStderr.text.trim()
      if (err !== "" && outcome !== "left" && outcome !== "notDue") console.warn("omabump", err)
      statusFile.reload()
      if (check && outcome === "notDue") root.checkQueued = true
      Qt.callLater(root.runQueued, Model.queuedRunWaits(outcome))
      // The local refresh asked for meanwhile, when this run read no
      // versions: none was due, or it left on another bar's run.
      if (local && (outcome === "notDue" || outcome === "left")) Qt.callLater(root.localRefresh)
    }

    // waitScript's word that the wait is over, and the checker's that a
    // check is due (--if-due).
    stdout: SplitParser {
      onRead: function(line) {
        if (line === "started") root.runWaiting = false
        else if (line === "due") root.runIfDue = false
      }
    }

    // Logged by onExited, by the run's outcome: Quickshell ends the stream
    // before it reports the exit, so the whole text is there by then.
    stderr: StdioCollector {
      id: checkStderr
      waitForEnd: true
    }
  }

  Process {
    id: localProcess
    running: false
    // What the refresh asks for next (Model.localOutcome): the check it
    // asked for runs as the timer's would, with the lock deciding who runs
    // it (Model.localWantsCheck). Only a failure is logged: a refresh that
    // left on the lock, or found pacman mid-transaction, has its next tick.
    onExited: function(exitCode) {
      var outcome = Model.localOutcome(exitCode)
      var err = localStderr.text.trim()
      if (outcome === "failed")
        console.warn("omabump", "local refresh failed (exit " + exitCode + ")" + (err !== "" ? ": " + err : ""))
      statusFile.reload()
      // Behind this shell's runDue run, which may find none due, it waits
      // for that one's answer (checkAfterDue).
      if (Model.localWantsCheck(outcome, checkProcess.running && !root.runIfDue)) {
        if (checkProcess.running) root.checkAfterDue = true
        else root.runCheck(false, false)
      }
      if (root.localPending) {
        root.localPending = false
        Qt.callLater(root.localRefresh)
      }
    }

    stderr: StdioCollector {
      id: localStderr
      waitForEnd: true
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

  // Asks every minute whether a check, or a failed one's retry, is due
  // (runDue).
  Timer {
    interval: Model.pollSec * 1000
    running: root.settingsReady && root.statusRead
    repeat: true
    triggeredOnStart: true
    onTriggered: root.scheduledRefresh()
  }

  // Each bar's local refresh, between the checks (localTick), only while
  // the bar counts an update: that is what a refresh can take back when the
  // app was updated elsewhere. With none, the icon has nothing to get
  // wrong, and no process starts until the next check or until the panel
  // opens (panelOpened).
  Timer {
    interval: Model.localIntervalSec * 1000
    running: root.settingsReady && root.statusRead && root.updateCount > 0
    repeat: true
    onTriggered: root.localTick()
  }
}

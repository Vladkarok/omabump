pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.vladkarok.omabump"
  ipcTarget: "io.github.vladkarok.omabump"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string glyph: ""
  readonly property string fallbackMark: ""

  readonly property var apps: checker.apps
  // Desktop apps first, then the mise CLIs: the keyboard cursor walks
  // this order across both sections.
  readonly property var desktopApps: apps.filter(function(app) { return app.source !== "mise" && app.source !== "self" })
  readonly property var cliApps: apps.filter(function(app) { return app.source === "mise" })
  // Omabump's own row, only while a newer release exists.
  readonly property var pluginApps: apps.filter(function(app) { return app.source === "self" && app.updateAvailable === true })
  readonly property var orderedApps: desktopApps.concat(cliApps).concat(pluginApps)
  readonly property int updateCount: checker.updateCount
  readonly property bool iconOnlyWithUpdates: settings && settings.barIconOnlyWithUpdates === true

  property int rowIndex: 0
  property bool cursorActive: false
  // What the last Ask agent or Copy prompt did, by pkg, shown as the row's
  // second line until the panel closes.
  property var actionNotes: ({})

  // The settings view swaps in for the app list. Its rows are the check
  // interval dropdown, then the toggles in settingRows. The dropdown comes
  // first because the stock Dropdown always opens downward: here its list
  // falls over the toggles, inside the card, instead of past its bottom.
  property bool settingsOpen: false
  property int settingIndex: 0
  readonly property var settingRows: [
    { key: "showMise", fallback: true, label: "Show mise tools", description: "CLI agents managed by mise, below the desktop apps" },
    { key: "barIconOnlyWithUpdates", fallback: false, label: "Bar icon only when updates exist", description: "" },
    { key: "notify", fallback: true, label: "Notify on new releases", description: "" }
  ]
  readonly property int intervalRow: 0
  // The "Muted: …" line with its Clear button, after the toggles, when any.
  readonly property int quietRow: settingRows.length + 1
  // Only rows the last check listed: a mute or skip for a row hidden by Show
  // mise tools (or not installed now) is kept but not shown.
  readonly property string quietText: {
    var names = []
    for (var i = 0; i < checker.mutedApps.length; i++)
      if (listed(checker.mutedApps[i])) names.push(appName(checker.mutedApps[i]))
    var skips = []
    for (var pkg in checker.skippedVersions)
      if (listed(pkg)) skips.push(appName(pkg) + " " + checker.skippedVersions[pkg])
    var parts = []
    if (names.length > 0) parts.push("Muted: " + names.join(", "))
    if (skips.length > 0) parts.push("Skipped: " + skips.join(", "))
    return parts.join(" · ")
  }
  readonly property var intervalChoices: [300, 900, 1800, 3600, 21600, 86400]

  // "checked 3 min ago" reads this instead of Date.now() so it keeps moving
  // while the panel sits open.
  property double nowMs: Date.now()

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  function refreshNow() { checker.refresh() }

  // IPC refresh: anything on the session bus can call it, so a check that
  // ended less than a minute ago is not started again.
  function ipcRefresh() {
    if (!checker.checking && Date.now() - checker.lastCheckEndMs < 60000) return "throttled"
    checker.refresh()
    return "ok"
  }

  function selectedApp() {
    return orderedApps.length > 0 ? orderedApps[clamp(rowIndex, 0, orderedApps.length - 1)] : null
  }

  function moveCursor(dy) {
    if (settingsOpen) {
      settingIndex = clamp(settingIndex + dy, 0, settingRows.length + (quietText !== "" ? 1 : 0))
      return
    }
    if (orderedApps.length === 0) return
    rowIndex = clamp(rowIndex + dy, 0, orderedApps.length - 1)
    ensureRowVisible()
  }

  function rowItem(index) {
    if (index < desktopApps.length) return desktopRepeater.itemAt(index)
    if (index < desktopApps.length + cliApps.length) return cliRepeater.itemAt(index - desktopApps.length)
    return pluginRepeater.itemAt(index - desktopApps.length - cliApps.length)
  }

  // Keeps the keyboard cursor on screen when the list scrolls.
  function ensureRowVisible() {
    var item = rowItem(rowIndex)
    if (!item) return
    var top = item.mapToItem(body, 0, 0).y
    if (top < panelFlick.contentY) panelFlick.contentY = top
    else if (top + item.height > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = top + item.height - panelFlick.height
  }

  function showSettings(on, withCursor) {
    settingsOpen = on
    settingIndex = 0
    if (on) cursorActive = withCursor
    else resetCursor()
    if (panelFlick) panelFlick.contentY = 0
  }

  function listed(pkg) {
    for (var i = 0; i < checker.apps.length; i++) if (checker.apps[i].pkg === pkg) return true
    return false
  }

  // A row's label by pkg, from the last check, else the pkg itself.
  function appName(pkg) {
    for (var i = 0; i < checker.apps.length; i++)
      if (checker.apps[i].pkg === pkg) return String(checker.apps[i].label || pkg)
    return pkg
  }

  function hasAction(app) {
    return !!app && ((app.updateAvailable === true && app.installable === true)
      || askable(app) || app.switchable === true)
  }

  // A fresh list puts the cursor on the first row with something to do (else
  // the first row), so Enter acts without an arrow key first.
  function resetCursor() {
    var first = 0
    for (var i = 0; i < orderedApps.length; i++)
      if (hasAction(orderedApps[i]) && !checker.isQuiet(orderedApps[i])) { first = i; break }
    rowIndex = first
    cursorActive = orderedApps.length > 0
  }

  // shell.json hot-reloads and the bar injects the new settings, so the
  // controls bind to settings and this only writes the merged entry.
  // Every write also drops skips a newer release has overtaken.
  function setSettings(changes) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in changes) entry[key] = changes[key]
    var skips = liveSkips(changes.skippedVersions !== undefined ? changes.skippedVersions : checker.skippedVersions)
    if (Object.keys(skips).length > 0 || entry.skippedVersions !== undefined) entry.skippedVersions = skips
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setSetting(key, value) {
    var changes = {}
    changes[key] = value
    setSettings(changes)
  }

  // A skip is stale once the row has an update the checker no longer calls
  // skipped (its newest version moved past the skip). A skip made since the
  // last check matches the newest version exactly and stays. Skips for rows
  // the check did not list stay too.
  function liveSkips(skips) {
    var out = {}
    for (var pkg in skips) {
      var app = null
      for (var i = 0; i < checker.apps.length; i++) if (checker.apps[i].pkg === pkg) app = checker.apps[i]
      var stale = !!app && app.updateAvailable === true && app.skipped !== true && app.latest !== skips[pkg]
      if (!stale) out[pkg] = skips[pkg]
    }
    return out
  }

  function settingOn(row) { return root.setting(row.key, row.fallback) === true }

  function activateSetting() {
    if (settingIndex === intervalRow) {
      intervalDropdown.open()
      return
    }
    if (settingIndex === quietRow) {
      clearQuiet()
      return
    }
    var row = settingRows[settingIndex - 1]
    setSetting(row.key, !settingOn(row))
  }

  // Mute: the row stays, its update keeps Update and Enter, but it adds no
  // badge, no count and no notification until unmuted.
  function toggleMute(app) {
    if (!app) return
    var list = checker.mutedApps.filter(function(pkg) { return pkg !== app.pkg })
    if (!checker.isMuted(app)) list.push(app.pkg)
    setSetting("mutedApps", list)
  }

  // Skip: the row's current newest version stops signalling; a newer one
  // signals again. Update and Enter keep working.
  function toggleSkip(app) {
    if (!app) return
    var skips = {}
    for (var pkg in checker.skippedVersions) if (pkg !== app.pkg) skips[pkg] = checker.skippedVersions[pkg]
    if (!checker.isSkipped(app)) {
      if (app.updateAvailable !== true || String(app.latest || "") === "") return
      if (!skipVersionOk(String(app.latest))) {
        setActionNote(app.pkg, "Cannot skip " + app.latest + ": not a version Omabump stores")
        return
      }
      skips[app.pkg] = app.latest
    }
    setSetting("skippedVersions", skips)
  }

  // skip_version_ok in bin/omabump-common: the checker drops anything else.
  function skipVersionOk(v) {
    return v.length <= 64 && /^[0-9A-Za-z][A-Za-z0-9._+~-]*$/.test(v) && v.indexOf("..") === -1
  }

  function clearQuiet() {
    setSettings({ mutedApps: [], skippedVersions: {} })
    settingIndex = clamp(settingIndex, 0, settingRows.length)
  }

  function intervalLabel(sec) {
    if (sec % 3600 === 0) return (sec / 3600) + " h"
    if (sec % 60 === 0) return (sec / 60) + " min"
    return sec + " s"
  }

  // A value set by hand that is not one of the choices stays selectable.
  function intervalOptions() {
    var list = intervalChoices.slice()
    if (list.indexOf(checker.refreshIntervalSec) === -1) {
      list.push(checker.refreshIntervalSec)
      list.sort(function(a, b) { return a - b })
    }
    return list.map(function(sec) { return { value: String(sec), label: root.intervalLabel(sec) } })
  }

  // The launcher joins its arguments into one bash -c string, so the command
  // is quoted once for that inner shell and once more for bar.run's own shell.
  function updateApp(app) {
    if (!app || app.updateAvailable !== true || app.installable !== true || !root.bar) return
    var inner = Util.shellQuote(checker.installScript) + " " + Util.shellQuote(app.pkg)
    root.bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(inner))
    root.close()
  }

  // Installed under another package name at a version the canonical package
  // matches: replace it in a terminal, where pacman asks first.
  function switchApp(app) {
    if (!app || app.switchable !== true || !root.bar) return
    var inner = Util.shellQuote(checker.installScript) + " --switch " + Util.shellQuote(app.pkg)
    root.bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(inner))
    root.close()
  }

  // An update exists but the plugin cannot install it: an indicator row, a
  // recipe without a watch, or a feed that failed with a newer version known.
  // Or a mise tool whose request holds it below a newer release.
  function askable(app) {
    if (!app || app.installable === true || app.source === "self") return false
    if (app.updateAvailable === true) return true
    return app.source === "mise" && String(app.error || "") === ""
      && String(app.latest || "") !== "" && app.latest !== app.installed
  }

  function setActionNote(pkg, text) {
    var notes = {}
    for (var key in actionNotes) notes[key] = actionNotes[key]
    notes[pkg] = text
    actionNotes = notes
  }

  // Enter: Update when the plugin can install the row, else Ask agent.
  function primaryAction(app) {
    if (askable(app)) promptFor(app, "ask")
    else updateApp(app)
  }

  // mode "ask" opens the default agent with the prompt (or copies it when no
  // default agent is set), "copy" only copies it.
  function promptFor(app, mode) {
    if (!askable(app) || promptProcess.running) return
    promptProcess.pkg = app.pkg
    promptProcess.command = ["bash", "-c", promptProcess.script, "omabump-prompt", checker.promptScript, app.pkg, mode]
    promptProcess.running = true
  }

  function promptDone(pkg, output) {
    var newline = output.indexOf("\n")
    var kind = newline < 0 ? output.trim() : output.substring(0, newline)
    var rest = newline < 0 ? "" : output.substring(newline + 1)
    if (kind === "agent" && root.bar) {
      root.bar.run("omarchy-agent --prompt " + Util.shellQuote(rest))
      root.close()
    } else if (kind === "copied") setActionNote(pkg, "Prompt copied")
    else if (kind === "noagent") setActionNote(pkg, "No default agent set, prompt copied")
    else setActionNote(pkg, "Prompt failed: " + (rest.trim() || kind || "no output"))
  }

  function hintText() {
    if (root.settingsOpen) return "Space change · Esc back"
    var app = root.cursorActive ? root.selectedApp() : null
    var mute = app ? (checker.isMuted(app) ? " · m unmute" : " · m mute") : ""
    if (app && app.updateAvailable === true) mute = (checker.isSkipped(app) ? " · K unskip" : " · K skip") + mute
    if (root.askable(app)) return "Enter ask agent · c copy prompt" + mute
    if (app && app.updateAvailable === true && app.installable === true) return "Enter update" + mute + " · Esc close"
    if (app && app.switchable === true) return "w switch package" + mute + " · Esc close"
    return (root.orderedApps.length > 0 ? "↑↓ select · " : "") + "r refresh · s settings" + mute
  }

  function checkedText() {
    if (checker.checking) return "checking"
    if (checker.checkedAt === "") return "not checked yet"
    var ms = new Date(checker.checkedAt).getTime()
    if (!isFinite(ms)) return ""
    var minutes = Math.floor(Math.max(0, root.nowMs - ms) / 60000)
    if (minutes < 1) return "checked just now"
    if (minutes < 60) return "checked " + minutes + " min ago"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return "checked " + hours + " h ago"
    return "checked " + Math.floor(hours / 24) + " d ago"
  }

  // The hero says one thing: all current, N updates, check failed, or last
  // known (rows from an earlier run because this one failed for them).
  function heroMeta() {
    if (root.settingsOpen) return "Settings"
    if (checker.checking) return "Checking…"
    if (checker.checkFailed) return "Check failed"
    var updates = updateCount + checker.waitingCount
    if (updates > 0) return updates + (updates === 1 ? " update" : " updates")
    if (checker.staleCount > 0) return "Last known, " + checkedText()
    if (checker.errorCount > 0) return "Check failed"
    if (checker.checkedAt === "") return "Not checked yet"
    return apps.length > 0 ? "All current" : ""
  }

  // The bar tooltip and the status IPC call keep the full count.
  function summaryText() {
    var parts = []
    if (updateCount > 0) parts.push(updateCount + (updateCount === 1 ? " update" : " updates"))
    if (checker.waitingCount > 0) parts.push(checker.waitingCount + " newer without an install path")
    var failed = checker.errorCount
    if (checker.checkFailed) parts.push("check failed")
    else if (failed > 0) parts.push("check failed for " + failed + (failed === 1 ? " app" : " apps"))
    if (checker.staleCount > 0) parts.push("last known for " + checker.staleCount + (checker.staleCount === 1 ? " app" : " apps"))
    var text = parts.length === 0 && checker.checkedAt !== "" && apps.length > 0 ? "All current" : parts.join(", ")
    return text !== "" && checker.quietCount > 0 ? text + " (+" + checker.quietCount + " muted/skipped)" : text
  }

  readonly property string followingText: checker.pkgsFollowing ? "omarchy-pkgs: following master (unpinned)" : ""
  // A failure or a warning (a wrapper Omabump no longer recognises).
  readonly property string discoveryText: checker.discoveryError !== "" ? "Agent discovery: " + checker.discoveryError : ""

  function tooltipText() {
    var summary = summaryText()
    var text = summary.indexOf("All current") === 0 ? "Omabump up to date" + summary.substring(11)
      : summary !== "" ? "Omabump: " + summary
      : checker.checkedAt === "" ? "Omabump: not checked yet" : "Omabump: none installed"
    if (followingText !== "") text += "\n" + followingText
    if (discoveryText !== "") text += "\n" + discoveryText
    return text
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

  // Notes from the checker carry the route ("switch to …"); the tooltip
  // keeps that, the row keeps the first clause.
  function shortNote(note) {
    var first = String(note || "").split("; ")[0]
    return first.replace(/, (Update switches|switch) to \S+$/, "")
  }

  // The second line of a row: exceptions only.
  function extraLine(app) {
    if (!app) return ""
    if (app.checking === true) return "Checking…"
    var action = actionNotes[app.pkg]
    if (action) return action
    if (String(app.error || "") !== "") return "Check failed: " + app.error
    var note = shortNote(app.note)
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

  // How the row knows what it shows and what Update would do.
  function rowTooltip(app) {
    if (!app) return ""
    var lines = []
    var name = String(app.installedName || "")
    lines.push("Installed " + String(app.installed || "")
      + (name !== "" && name !== app.pkg && app.source !== "mise" ? " as " + name : ""))
    if (String(app.latest || "") !== "") {
      var from = sourceLabel(app)
      lines.push("Newest " + app.latest + (from !== "" ? " from " + from : ""))
    }
    if (app.source === "mise") lines.push("Updates with mise up")
    else if (app.source === "self") lines.push(app.installable === true
      ? "Updates with omarchy plugin update, which installs the repository's current HEAD"
      : "omarchy update does not update plugins")
    else if (app.source === "omarchy") {
      var commit = String(app.recipeCommit || checker.pkgsCommit || "")
      lines.push("Updates through Omarchy's recipe"
        + (String(app.recipe || "") !== "" ? " " + app.recipe : "")
        + (commit !== "" ? " at " + commit.substring(0, 7) : ""))
    } else if (app.source === "vendor-pkg") lines.push("Updates with the vendor's Arch package")
    if (String(app.note || "") !== "") lines.push(app.note)
    if (String(app.error || "") !== "") lines.push("Check failed: " + app.error)
    if (checker.isMuted(app)) lines.push("Muted: no badge, no notification")
    if (checker.isSkipped(app)) lines.push("Skipped " + checker.skippedVersion(app) + ": no badge, no notification until a newer version")
    return lines.join("\n")
  }

  function colorLuminance(c) {
    function channel(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
  }

  // White marks ship a dark twin for light themes, the same convention the
  // first-party agents panel uses. Only relative paths inside this plugin
  // load: an absolute path, a URL or a ".." component shows the fallback.
  function iconPathOk(path) {
    return path !== "" && path.charAt(0) !== "/" && path.indexOf(":") === -1
      && path.indexOf("\\") === -1 && path.split("/").indexOf("..") === -1
  }
  function iconUrl(app) {
    if (!app) return ""
    var path = String(app.icon || "")
    var light = String(app.iconLight || "")
    if (light !== "" && colorLuminance(root.surface) >= 0.5) path = light
    return iconPathOk(path) ? Qt.resolvedUrl(path) : ""
  }

  // Like the system update icon, it can stay out of the bar until there is
  // something to install. While the panel is open (IPC open/toggle) it shows,
  // so the panel has an anchor.
  visible: !iconOnlyWithUpdates || updateCount > 0 || opened
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    actionNotes = {}
    settingsOpen = false
    resetCursor()
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  // The plugin loader hands the widget an empty settings object while it is
  // built; the bar later sets bar, then the entry's settings, with
  // Qt.callLater. The first settings to arrive with a bar are the real ones.
  onSettingsChanged: if (root.bar) checker.settingsReady = true
  onOrderedAppsChanged: rowIndex = clamp(rowIndex, 0, Math.max(0, orderedApps.length - 1))

  Main {
    id: checker
    settings: root.settings
  }

  Process {
    id: promptProcess
    property string pkg: ""
    // The first output line says what happened: agent (the prompt follows),
    // copied, noagent (copied instead) or error (the message follows).
    // wl-copy stays behind to serve the clipboard, so its output goes to
    // /dev/null or the collector would never see the end of the stream.
    readonly property string script: 'out=$("$1" "$2" 2>&1) || { printf "error\\n%s" "$out"; exit 0; }\n'
      + 'if [[ $3 == ask && -n $(omarchy-default-agent 2>/dev/null) ]]; then printf "agent\\n%s" "$out"; exit 0; fi\n'
      + 'printf %s "$out" | wl-copy >/dev/null 2>&1 || { echo error; echo "wl-copy failed"; exit 0; }\n'
      + '[[ $3 == ask ]] && echo noagent || echo copied\n'
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.promptDone(promptProcess.pkg, text)
    }
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // Quickshell's own IpcHandler rather than Omarchy's ShellIpc, which older
  // shells (r2083) lack: a missing type stops the whole file from loading.
  // qs ipc and omarchy-shell ipc both reach it; omarchy-shell just takes its
  // qs ipc fallback instead of the shell socket.
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { return root.ipcRefresh() }
    function status(): string { return root.tooltipText() }
    function settings(): void { root.open(); root.showSettings(true, false) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    active: root.updateCount > 0
    tooltipText: root.tooltipText()
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton || buttonCode === Qt.RightButton) root.refreshNow()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(header.implicitHeight + body.implicitHeight + footer.implicitHeight + column.spacing * 2, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The open dropdown list takes the keys until it closes.
      blocked: intervalDropdown.popupOpen

      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: {
        if (!root.cursorActive) return
        if (root.settingsOpen) root.activateSetting()
        else root.primaryAction(root.selectedApp())
      }
      onCloseRequested: root.settingsOpen ? root.showSettings(false, false) : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") root.showSettings(!root.settingsOpen, true)
        else if (t === "\b" && root.settingsOpen) root.showSettings(false, false)
        else if ((t === "r" || t === "R") && !root.settingsOpen) root.refreshNow()
        else if ((t === "c" || t === "C") && !root.settingsOpen && root.cursorActive) root.promptFor(root.selectedApp(), "copy")
        else if ((t === "w" || t === "W") && !root.settingsOpen && root.cursorActive) root.switchApp(root.selectedApp())
        else if ((t === "m" || t === "M") && !root.settingsOpen && root.cursorActive) root.toggleMute(root.selectedApp())
        // k moves the cursor up (PanelKeyCatcher), so skip is K.
        else if (t === "K" && !root.settingsOpen && root.cursorActive) root.toggleSkip(root.selectedApp())
      }

      // The hero and the footer stay put; only the rows scroll.
      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(12)

        Column {
          id: header
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Omabump"
            meta: root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily

            trailingControl: Component {
              Row {
                spacing: Style.spacing.xs

                // The header buttons sit at the card's right edge, and a
                // centred tooltip would run past it (and off a screen the
                // panel hugs), so these two keep their tooltip's right edge
                // on the button instead of using PanelActionButton's own.
                PanelActionButton {
                  id: refreshButton
                  property bool hot: false
                  visible: !root.settingsOpen
                  enabled: !checker.checking
                  iconText: "󰑐"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onHovered: function(isHovered) { hot = isHovered }
                  onClicked: root.refreshNow()

                  PanelToolTip {
                    visible: refreshButton.hot
                    text: root.checkedText() + " · Refresh  r"
                    fontFamily: root.fontFamily
                    x: refreshButton.width - width
                  }
                }

                PanelActionButton {
                  id: gearButton
                  property bool hot: false
                  iconText: "󰒓"
                  bordered: root.settingsOpen
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onHovered: function(isHovered) { hot = isHovered }
                  onClicked: root.showSettings(!root.settingsOpen, false)

                  PanelToolTip {
                    visible: gearButton.hot
                    text: root.settingsOpen ? "Back to the apps  Esc" : "Settings  s"
                    fontFamily: root.fontFamily
                    x: gearButton.width - width
                  }
                }
              }
            }

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.glyph
                color: root.updateCount > 0 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // Why the hero says Check failed, or that the result is not fresh.
          Text {
            textFormat: Text.PlainText
            visible: !root.settingsOpen && text !== ""
            width: parent.width
            text: checker.checkError !== "" ? checker.checkError
              : checker.pkgsError !== "" ? checker.pkgsError : checker.pkgsNote
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }

          PanelSeparator { foreground: root.foreground }
        }

        Flickable {
          id: panelFlick
          width: parent.width
          height: Math.max(0, column.height - header.height - footer.height - column.spacing * 2)
          contentWidth: width
          contentHeight: body.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { id: scrollBar; policy: ScrollBar.AsNeeded }

          Column {
            id: body
            // Rows stop short of the scroll bar so it never covers a button.
            width: panelFlick.width - (panelFlick.interactive ? scrollBar.width + Style.space(4) : 0)
            spacing: Style.space(12)

            Column {
              visible: !root.settingsOpen && root.desktopApps.length + root.cliApps.length === 0
              width: parent.width
              topPadding: Style.space(24)
              bottomPadding: Style.space(24)
              spacing: Style.spacing.sm

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: checker.checking ? "Checking for new versions…" : "No agent desktop apps or CLIs installed"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
              }

              Text {
                textFormat: Text.PlainText
                visible: !checker.checking
                width: parent.width
                text: "Install from the Omarchy menu, AI"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
              }
            }

            Column {
              visible: !root.settingsOpen && root.desktopApps.length > 0
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "DESKTOP APPS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Column {
                width: parent.width
                spacing: Style.spacing.xxs

                Repeater {
                  id: desktopRepeater
                  model: root.desktopApps

                  AppRow {
                    required property var modelData
                    required property int index
                    width: parent.width
                    app: modelData
                    rowIndex: index
                  }
                }
              }
            }

            PanelSeparator {
              visible: !root.settingsOpen && root.desktopApps.length > 0 && root.cliApps.length > 0
              foreground: root.foreground
            }

            Column {
              visible: !root.settingsOpen && root.cliApps.length > 0
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "CLI TOOLS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Column {
                width: parent.width
                spacing: Style.spacing.xxs

                Repeater {
                  id: cliRepeater
                  model: root.cliApps

                  AppRow {
                    required property var modelData
                    required property int index
                    width: parent.width
                    app: modelData
                    rowIndex: root.desktopApps.length + index
                  }
                }
              }
            }

            PanelSeparator {
              visible: !root.settingsOpen && root.pluginApps.length > 0 && root.desktopApps.length + root.cliApps.length > 0
              foreground: root.foreground
            }

            // omarchy update does not update plugins, so Omabump says when
            // a newer release of itself exists.
            Column {
              visible: !root.settingsOpen && root.pluginApps.length > 0
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "PLUGIN"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Column {
                width: parent.width
                spacing: Style.spacing.xxs

                Repeater {
                  id: pluginRepeater
                  model: root.pluginApps

                  AppRow {
                    required property var modelData
                    required property int index
                    width: parent.width
                    app: modelData
                    rowIndex: root.desktopApps.length + root.cliApps.length + index
                  }
                }
              }
            }

            Column {
              visible: root.settingsOpen
              width: parent.width
              spacing: Style.space(6)

              // Laid out like a Toggle row, with the stock dropdown where the
              // switch would be.
              BorderSurface {
                id: intervalSurface
                readonly property bool hot: root.cursorActive && root.settingIndex === root.intervalRow
                width: parent.width
                implicitHeight: Math.max(54, intervalTitle.implicitHeight + Style.spacing.huge)
                radius: Style.cornerRadius
                color: Style.controlFill(false, hot, root.foreground, Color.accent)
                borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", root.foreground, Color.accent)

                HoverHandler {
                  onHoveredChanged: if (hovered) {
                    root.cursorActive = true
                    root.settingIndex = root.intervalRow
                  }
                }

                Text {
                  id: intervalTitle
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.right: intervalDropdown.left
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: intervalSurface.borderLeft + Style.spacing.rowPaddingX
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  text: "Check every"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }

                Dropdown {
                  id: intervalDropdown
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.rightMargin: intervalSurface.borderRight + Style.spacing.rowPaddingX
                  width: Style.space(110)
                  showLabel: false
                  options: root.intervalOptions()
                  value: String(checker.refreshIntervalSec)
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.setSetting("refreshIntervalSec", Number(v)) }
                  onPopupOpenChanged: if (!popupOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                }
              }

              Repeater {
                model: root.settingRows

                Toggle {
                  required property var modelData
                  required property int index
                  width: parent.width
                  label: modelData.label
                  description: modelData.description
                  checked: root.settingOn(modelData)
                  hasCursor: root.cursorActive && root.settingIndex === index + 1
                  titleSize: Style.font.body
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onHovered: function(on) {
                    if (!on) return
                    root.cursorActive = true
                    root.settingIndex = index + 1
                  }
                  onClicked: root.setSetting(modelData.key, !root.settingOn(modelData))
                }
              }

              // Muted and skipped rows, undone one by one on their own row
              // (m, K) or all at once here.
              BorderSurface {
                id: quietSurface
                readonly property bool hot: root.cursorActive && root.settingIndex === root.quietRow
                visible: root.quietText !== ""
                width: parent.width
                implicitHeight: Math.max(54, quietLabel.implicitHeight + Style.spacing.huge)
                radius: Style.cornerRadius
                color: Style.controlFill(false, hot, root.foreground, Color.accent)
                borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", root.foreground, Color.accent)

                HoverHandler {
                  onHoveredChanged: if (hovered) {
                    root.cursorActive = true
                    root.settingIndex = root.quietRow
                  }
                }

                Text {
                  id: quietLabel
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.right: clearButton.left
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: quietSurface.borderLeft + Style.spacing.rowPaddingX
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  text: root.quietText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                }

                Button {
                  id: clearButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.rightMargin: quietSurface.borderRight + Style.spacing.rowPaddingX
                  text: "Clear"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  tooltipText: "Unmute and unskip every row  Space"
                  onClicked: root.clearQuiet()
                }
              }
            }
          }
        }

        Column {
          id: footer
          width: parent.width

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.hintText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: root.followingText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: root.discoveryText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // One line per app: mark, name, version. A second dim line only for an
  // exception. The row's action shows only while it holds the cursor, in
  // place of the version.
  component AppRow: CursorSurface {
    id: appRow
    property var app: null
    property int rowIndex: 0
    readonly property bool hasUpdate: !!app && app.updateAvailable === true
    readonly property bool updatable: hasUpdate && app.installable === true
    readonly property bool askable: root.askable(app)
    readonly property bool switchable: !!app && app.switchable === true && !updatable
    readonly property bool showAction: hasCursor && (updatable || askable || switchable)
    readonly property bool muted: checker.isMuted(app)
    readonly property bool quiet: checker.isQuiet(app)
    readonly property bool skipped: checker.isSkipped(app)
    readonly property string extra: root.extraLine(app)
    property bool actionHovered: false
    onShowActionChanged: if (!showAction) actionHovered = false

    hasCursor: root.cursorActive && root.rowIndex === rowIndex
    foreground: root.foreground
    implicitHeight: Math.max(rowContent.implicitHeight, updateButton.implicitHeight) + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.rowIndex = appRow.rowIndex
      }
    }

    PanelToolTip {
      visible: rowMouse.containsMouse && !appRow.actionHovered
      text: root.rowTooltip(appRow.app)
      fontFamily: root.fontFamily
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      Item {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: Style.font.icon
        implicitHeight: Style.font.icon

        Image {
          id: mark
          anchors.fill: parent
          source: root.iconUrl(appRow.app)
          sourceSize.width: Style.font.icon * 2
          sourceSize.height: Style.font.icon * 2
          fillMode: Image.PreserveAspectFit
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: mark.status !== Image.Ready
          text: root.fallbackMark
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: appRow.app ? String(appRow.app.label || appRow.app.pkg) + (appRow.muted ? "  󰖁" : "") : ""
          color: appRow.muted ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: appRow.extra !== ""
          Layout.fillWidth: true
          text: appRow.extra
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        visible: !appRow.showAction
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.spacing.sm

        Text {
          textFormat: Text.PlainText
          text: root.installedText(appRow.app)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          visible: appRow.hasUpdate
          text: appRow.app ? "→ " + appRow.app.latest : ""
          color: appRow.quiet ? root.dim : root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: !appRow.quiet
        }

        Text {
          textFormat: Text.PlainText
          visible: appRow.skipped
          text: "skipped"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Button {
        id: updateButton
        visible: appRow.showAction && appRow.updatable
        Layout.alignment: Qt.AlignVCenter
        text: "Update"
        bordered: true
        foreground: root.urgent
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        tooltipText: appRow.app ? root.installedText(appRow.app) + " → " + appRow.app.latest + ", in a terminal  Enter" : ""
        onHovered: function(on) { appRow.actionHovered = on }
        onClicked: root.updateApp(appRow.app)
      }

      Button {
        visible: appRow.showAction && appRow.switchable
        Layout.alignment: Qt.AlignVCenter
        text: "Switch"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        tooltipText: appRow.app ? "Replace " + appRow.app.installedName + " with " + appRow.app.pkg + " in a terminal; pacman asks first  w" : ""
        onHovered: function(on) { appRow.actionHovered = on }
        onClicked: root.switchApp(appRow.app)
      }

      PanelActionButton {
        visible: appRow.showAction && appRow.askable
        Layout.alignment: Qt.AlignVCenter
        iconText: "󰆏"
        tooltipText: "Copy prompt  c"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onHovered: function(on) { appRow.actionHovered = on }
        onClicked: root.promptFor(appRow.app, "copy")
      }

      Button {
        visible: appRow.showAction && appRow.askable
        Layout.alignment: Qt.AlignVCenter
        text: "Ask agent"
        bordered: true
        foreground: root.urgent
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        tooltipText: "Open your default agent with a prompt to plan the update; it may change the system  Enter"
        onHovered: function(on) { appRow.actionHovered = on }
        onClicked: root.promptFor(appRow.app, "ask")
      }

      PanelActionButton {
        visible: appRow.hasCursor && appRow.hasUpdate
        Layout.alignment: Qt.AlignVCenter
        iconText: "󰒭"
        bordered: appRow.skipped
        tooltipText: appRow.skipped ? "Unskip " + checker.skippedVersion(appRow.app) + "  K"
          : appRow.app ? "Skip " + appRow.app.latest + ": quiet until a newer version  K" : ""
        foreground: appRow.skipped ? root.foreground : root.dim
        fontFamily: root.fontFamily
        onHovered: function(on) { appRow.actionHovered = on }
        onClicked: root.toggleSkip(appRow.app)
      }

      PanelActionButton {
        visible: appRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        iconText: "󰖁"
        bordered: appRow.muted
        tooltipText: appRow.muted ? "Unmute  m" : "Mute: no badge, no notification  m"
        foreground: appRow.muted ? root.foreground : root.dim
        fontFamily: root.fontFamily
        onHovered: function(on) { appRow.actionHovered = on }
        onClicked: root.toggleMute(appRow.app)
      }
    }
  }
}

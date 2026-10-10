pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.vladkarok.omabump"
  ipcTarget: "io.github.vladkarok.omabump"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  // Part way from the foreground to the card's background, so it is dimmer
  // on light themes too (Qt.darker turns dark text darker still). Flattened
  // rather than Util.alpha(foreground, …): buttons that take dim as their
  // foreground replace its alpha. 0.6 about matches the old
  // Qt.darker(foreground, 1.55) on dark themes.
  readonly property color dim: Qt.tint(Qt.rgba(surface.r, surface.g, surface.b, 1), Util.alpha(foreground, 0.6))
  readonly property color surface: Commons.Color.popups.background
  readonly property bool lightSurface: Model.luminance(surface) >= 0.5
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string glyph: ""
  readonly property string fallbackMark: ""

  // The bar's plugin facade (PluginBarApi) as var: Panel types bar as a
  // bare QtObject, which has none of its members.
  readonly property var barApi: root.bar
  readonly property var shellApi: barApi ? barApi.shell : null

  readonly property var apps: checker.apps
  // Desktop apps first, then the mise CLIs: the keyboard cursor walks
  // this order across both sections.
  readonly property var desktopApps: apps.filter(function(app) { return app.source !== "mise" && app.source !== "self" })
  readonly property var cliApps: apps.filter(function(app) { return app.source === "mise" })
  // Omabump's own row, while a newer release exists or its check failed;
  // hidden while current.
  readonly property var pluginApps: apps.filter(function(app) {
    return app.source === "self" && (app.updateAvailable === true || String(app.error || "") !== "")
  })
  readonly property var orderedApps: desktopApps.concat(cliApps).concat(pluginApps)
  // The row Repeaters build rows only while the panel shows, its fade-out
  // included. A check replaces apps once per row it writes and each time
  // every row is rebuilt, tooltips and all; otherwise that happened in
  // every monitor's closed panel too.
  readonly property bool rowsShown: root.opened || panel.visible
  readonly property int updateCount: checker.updateCount
  readonly property bool iconOnlyWithUpdates: Model.boolSetting(root.settings, "barIconOnlyWithUpdates", false)

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
    { key: "barIconOnlyWithUpdates", fallback: false, label: "Bar icon only when updates exist", description: "It also shows while a check fails" },
    { key: "notify", fallback: true, label: "Notify on new releases", description: "" }
  ]
  readonly property int intervalRow: 0
  // The "Muted: …" line with its Clear button, after the toggles, when any.
  readonly property int quietRow: settingRows.length + 1
  readonly property string quietText: Model.quietText(apps, checker.mutedApps, checker.skippedVersions)
  readonly property var intervalChoices: [300, 900, 1800, 3600, 21600, 86400]

  // "checked 3 min ago" reads this instead of Date.now() so it keeps moving
  // while the panel sits open.
  property double nowMs: Date.now()
  readonly property string checkedText: Model.checkedText(checker.checking, checker.checkedAt, nowMs)

  function refreshNow() { checker.refresh() }

  // IPC refresh: anything on the session bus can call it, so it may not keep
  // this shell checking back to back. A check that starts after the call is
  // already on its way (queued, or waiting for another check to end): that
  // one answers it. While this shell's own check for a Refresh runs, or for
  // a minute after its last check ended with none running now, it is
  // throttled and starts nothing. So it queues one more only behind the
  // timer's check or one for a Show mise tools change, and during
  // another's (a terminal's, another monitor's) it runs after that one, as
  // Refresh does.
  function ipcRefresh() {
    if (checker.refreshPending) return "ok"
    if (checker.refreshRunning || !checker.checking && Date.now() - checker.lastCheckEndMs < 60000) return "throttled"
    checker.refresh()
    return "ok"
  }

  // Every monitor's bar builds its own copy of this widget, each with the
  // same IPC target, and a call reaches whichever copy holds the target,
  // not the one on the focused monitor. The shell's own summon, hide and
  // toggle (what `omarchy-shell shell toggle <id>` runs) act on the open
  // copy, else the focused monitor's. A shell without them leaves this
  // copy to it, as before.
  function viaShell(method) {
    return !!shellApi && typeof shellApi[method] === "function" && shellApi[method](root.moduleName, "") === true
  }

  function ipcOpen() { if (!viaShell("summon")) root.open() }
  function ipcClose() { if (!viaShell("hide")) root.close() }
  function ipcToggle() { if (!viaShell("toggle")) root.toggle() }

  // The settings view, on the copy that opened. The bar keeps one panel
  // open at a time.
  function ipcSettings() {
    if (viaShell("summon")) {
      var copies = barApi && typeof barApi.moduleWidgets === "function" ? barApi.moduleWidgets(root.moduleName) : []
      for (var i = 0; i < copies.length; i++) {
        if (copies[i] && copies[i].opened === true && typeof copies[i].showSettings === "function") {
          copies[i].showSettings(true, false)
          return
        }
      }
    }
    root.open()
    root.showSettings(true, false)
  }

  function selectedApp() {
    return orderedApps.length > 0 ? orderedApps[Model.clamp(rowIndex, 0, orderedApps.length - 1)] : null
  }

  // An arrow, j or k: the first one only shows the cursor.
  function cursorKey(dy) {
    if (dy === 0) return
    if (!cursorActive) {
      cursorActive = true
      ensureCursorVisible()
      return
    }
    moveCursor(dy)
  }

  function moveCursor(dy) {
    if (settingsOpen) settingIndex = Model.clamp(settingIndex + dy, 0, settingRows.length + (quietText !== "" ? 1 : 0))
    else if (orderedApps.length > 0) rowIndex = Model.clamp(rowIndex + dy, 0, orderedApps.length - 1)
    ensureCursorVisible()
  }

  function rowItem(index) {
    if (index < desktopApps.length) return desktopRepeater.itemAt(index)
    if (index < desktopApps.length + cliApps.length) return cliRepeater.itemAt(index - desktopApps.length)
    return pluginRepeater.itemAt(index - desktopApps.length - cliApps.length)
  }

  function cursorItem() {
    if (!settingsOpen) return rowItem(rowIndex)
    if (settingIndex === intervalRow) return intervalSurface
    if (settingIndex === quietRow) return quietSurface
    return settingsRepeater.itemAt(settingIndex - 1)
  }

  // The section whose first row holds the cursor: its header comes into
  // view with that row.
  function cursorSection() {
    if (settingsOpen) return null
    if (rowIndex === 0 && desktopApps.length > 0) return desktopSection
    if (rowIndex === desktopApps.length && cliApps.length > 0) return cliSection
    if (rowIndex === desktopApps.length + cliApps.length && pluginApps.length > 0) return pluginSection
    return null
  }

  // Keeps the keyboard cursor on screen: on open, back from the settings
  // and on every move. Columns lay their children out once per frame, and
  // rows the panel built a moment ago (it builds them only while it shows)
  // have no place yet, so they are laid out here first, innermost first.
  // A hover moves the cursor too, but onto a row already in view.
  function ensureCursorVisible() {
    var item = cursorItem()
    if (!item || !panelFlick) return
    var columns = [desktopRows, cliRows, pluginRows, desktopSection, cliSection, pluginSection, settingsSection, body, header, footer]
    for (var i = 0; i < columns.length; i++) columns[i].forceLayout()
    if (panelFlick.height <= 0) return
    var section = cursorSection()
    var bottom = item.mapToItem(body, 0, item.height).y
    var top = section ? section.mapToItem(body, 0, 0).y : bottom - item.height
    if (top < panelFlick.contentY) panelFlick.contentY = top
    else if (bottom > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = Math.min(bottom - panelFlick.height, Math.max(0, panelFlick.contentHeight - panelFlick.height))
  }

  function showSettings(on, withCursor) {
    settingsOpen = on
    settingIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    if (on) cursorActive = withCursor
    else resetCursor()
  }

  // A fresh list puts the cursor on the first row with something to do.
  function resetCursor() {
    rowIndex = Model.firstActionIndex(orderedApps, checker.mutedApps, checker.skippedVersions)
    cursorActive = orderedApps.length > 0
    Qt.callLater(ensureCursorVisible)
  }

  // shell.json hot-reloads and the bar injects the new settings, so the
  // controls bind to settings and this only writes the merged entry
  // (Model.settingsEntry, which also drops skips that no longer apply).
  function setSettings(changes) {
    if (!shellApi || typeof shellApi.updateEntryInline !== "function") return
    shellApi.updateEntryInline(root.moduleName,
      Model.settingsEntry(root.moduleName, root.settings, changes, apps, checker.skippedVersions))
  }

  function setSetting(key, value) {
    var changes = {}
    changes[key] = value
    setSettings(changes)
  }

  function settingOn(row) { return Model.boolSetting(root.settings, row.key, row.fallback) }

  function activateSetting() {
    if (settingIndex === intervalRow) {
      intervalDropdown.open()
      return
    }
    // The quiet row is hidden while it has nothing to list.
    if (settingIndex === quietRow) {
      if (quietText !== "") clearQuiet()
      return
    }
    var row = settingRows[settingIndex - 1]
    setSetting(row.key, !settingOn(row))
  }

  // Mute: the row stays, its update keeps Update and Enter, but it adds no
  // badge, no count and no notification until unmuted.
  function toggleMute(app) {
    if (app) setSetting("mutedApps", Model.mutedToggled(checker.mutedApps, app))
  }

  // Skip: the row's current newest version stops signalling; a newer one
  // signals again. Update and Enter keep working.
  function toggleSkip(app) {
    var result = app ? Model.skipToggled(checker.skippedVersions, app) : null
    if (!result) return
    if (result.note) setActionNote(app.pkg, result.note)
    else setSetting("skippedVersions", result.skips)
  }

  // Clears what the quiet line lists (Model.quietCleared).
  function clearQuiet() { setSettings(Model.quietCleared(apps, checker.mutedApps, checker.skippedVersions)) }

  // The launcher joins its arguments into one bash -c string, so the command
  // is quoted once for that inner shell and once more for bar.run's own shell.
  function updateApp(app) {
    if (!Model.updatable(app) || !root.bar) return
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

  function setActionNote(pkg, text) {
    var notes = {}
    for (var key in actionNotes) notes[key] = actionNotes[key]
    notes[pkg] = text
    actionNotes = notes
  }

  // Enter: Update when the plugin can install the row, else Ask agent.
  function primaryAction(app) {
    var action = Model.primaryAction(app)
    if (action === "ask") promptFor(app, "ask")
    else if (action === "update") updateApp(app)
  }

  // mode "ask" opens the default agent with the prompt (or copies it when no
  // default agent is set), "copy" only copies it.
  function promptFor(app, mode) {
    if (!Model.askable(app) || promptProcess.running) return
    promptProcess.pkg = app.pkg
    promptProcess.command = ["bash", "-c", promptProcess.script, "omabump-prompt", checker.promptScript, app.pkg, mode]
    promptProcess.running = true
  }

  // omarchy-agent-prompt is the public way in, the one the agents panel
  // uses; omarchy-agent --prompt is its internal flag.
  function promptDone(pkg, output) {
    var outcome = Model.promptOutcome(output)
    if (outcome.prompt !== undefined) {
      Util.execArgv(["omarchy-agent-prompt", outcome.prompt])
      root.close()
    } else setActionNote(pkg, outcome.note)
  }

  function iconUrl(app) {
    var path = Model.iconPath(app, root.lightSurface)
    return path !== "" ? Qt.resolvedUrl(path) : ""
  }

  // Like the system update icon, it can stay out of the bar until there is
  // something to install. A failed check shows it too, or a broken check
  // would be invisible (a muted row's failure does not, as mute promises).
  // While the panel is open (IPC open/toggle) it shows, so the panel has an
  // anchor.
  visible: !iconOnlyWithUpdates || updateCount > 0 || checker.checkFailed || checker.errorCount > 0 || opened
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    actionNotes = {}
    settingsOpen = false
    if (panelFlick) panelFlick.contentY = 0
    resetCursor()
    nowMs = Date.now()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  // The plugin loader hands the widget an empty settings object while it is
  // built; the bar later sets bar, then the entry's settings, with
  // Qt.callLater. The first settings to arrive with a bar are the real ones.
  onSettingsChanged: if (root.bar) checker.settingsReady = true
  onOrderedAppsChanged: rowIndex = Model.clamp(rowIndex, 0, Math.max(0, orderedApps.length - 1))
  // Clear, or a settings change from elsewhere, can leave the quiet line
  // empty, and then it hides: the settings cursor must not stay on it.
  onQuietTextChanged: if (quietText === "") settingIndex = Model.clamp(settingIndex, 0, settingRows.length)

  Main {
    id: checker
    settings: root.settings
  }

  Process {
    id: promptProcess
    property string pkg: ""
    // The first output line says what happened (Model.promptOutcome).
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
    function open(): void { root.ipcOpen() }
    function close(): void { root.ipcClose() }
    function show(): void { root.ipcOpen() }
    function hide(): void { root.ipcClose() }
    function toggle(): void { root.ipcToggle() }
    function refresh(): string { return root.ipcRefresh() }
    function status(): string { return Model.tooltipText(checker.summary) }
    function settings(): void { root.ipcSettings() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    active: root.updateCount > 0
    tooltipText: Model.tooltipText(checker.summary)
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

      onMoveRequested: function(dx, dy) { root.cursorKey(dy) }
      onActivateRequested: {
        if (!root.cursorActive) return
        if (root.settingsOpen) root.activateSetting()
        else root.primaryAction(root.selectedApp())
      }
      onCloseRequested: root.settingsOpen ? root.showSettings(false, false) : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // Skip is Shift+K, and CapsLock j and k move the cursor
      // (Model.keyAction).
      onTextKey: function(t, modifiers) {
        var action = Model.keyAction(t, modifiers, root.settingsOpen, root.cursorActive)
        if (action === "down" || action === "up") root.cursorKey(action === "down" ? 1 : -1)
        else if (action === "settings") root.showSettings(!root.settingsOpen, true)
        else if (action === "back") root.showSettings(false, false)
        else if (action === "refresh") root.refreshNow()
        else if (action === "copy") root.promptFor(root.selectedApp(), "copy")
        else if (action === "switch") root.switchApp(root.selectedApp())
        else if (action === "mute") root.toggleMute(root.selectedApp())
        else if (action === "skip") root.toggleSkip(root.selectedApp())
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
            meta: Model.heroMeta(checker.summary, root.settingsOpen, root.checkedText)
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
                    text: root.checkedText + " · Refresh  r"
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
            text: checker.failureText !== "" ? checker.failureText : checker.pkgsNote
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
              id: desktopSection
              visible: !root.settingsOpen && root.desktopApps.length > 0
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "DESKTOP APPS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Column {
                id: desktopRows
                width: parent.width
                spacing: Style.spacing.xxs

                Repeater {
                  id: desktopRepeater
                  model: root.rowsShown ? root.desktopApps : []

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
              id: cliSection
              visible: !root.settingsOpen && root.cliApps.length > 0
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "CLI TOOLS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Column {
                id: cliRows
                width: parent.width
                spacing: Style.spacing.xxs

                Repeater {
                  id: cliRepeater
                  model: root.rowsShown ? root.cliApps : []

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
              id: pluginSection
              visible: !root.settingsOpen && root.pluginApps.length > 0
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "PLUGIN"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Column {
                id: pluginRows
                width: parent.width
                spacing: Style.spacing.xxs

                Repeater {
                  id: pluginRepeater
                  model: root.rowsShown ? root.pluginApps : []

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
              id: settingsSection
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
                color: Style.controlFill(false, hot, root.foreground, Commons.Color.accent)
                borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", root.foreground, Commons.Color.accent)

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
                  options: Model.intervalOptions(root.intervalChoices, checker.refreshIntervalSec)
                  value: String(checker.refreshIntervalSec)
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onChanged: function(v) {
                    root.setSetting("refreshIntervalSec", Number(v))
                    // A pick assigns value, which ends the binding above; put
                    // it back so a later change from shell.json still shows.
                    intervalDropdown.value = Qt.binding(function() { return String(checker.refreshIntervalSec) })
                  }
                  onPopupOpenChanged: if (!popupOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                }
              }

              Repeater {
                id: settingsRepeater
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
                color: Style.controlFill(false, hot, root.foreground, Commons.Color.accent)
                borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", root.foreground, Commons.Color.accent)

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
                  tooltipText: "Unmute and unskip these rows  Space"
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
            text: Model.hintText(root.settingsOpen, root.cursorActive ? root.selectedApp() : null, root.orderedApps.length,
              checker.mutedApps, checker.skippedVersions)
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
            text: Model.followingText(checker.summary)
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
            text: Model.discoveryText(checker.summary)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 2
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
    readonly property bool askable: Model.askable(app)
    readonly property bool switchable: !!app && app.switchable === true && !updatable
    readonly property bool showAction: hasCursor && (updatable || askable || switchable)
    readonly property bool muted: Model.isMuted(checker.mutedApps, app)
    readonly property bool quiet: Model.isQuiet(checker.mutedApps, checker.skippedVersions, app)
    readonly property bool skipped: Model.isSkipped(checker.skippedVersions, app)
    readonly property string extra: Model.extraLine(app, checker.schemaVersion, app ? root.actionNotes[app.pkg] : "")
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
      text: Model.rowTooltip(appRow.app, checker.schemaVersion, checker.mutedApps, checker.skippedVersions, checker.pkgsCommit)
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
          text: Model.installedText(appRow.app)
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
        tooltipText: appRow.app ? Model.installedText(appRow.app) + " → " + appRow.app.latest + ", in a terminal  Enter" : ""
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
        tooltipText: appRow.skipped ? "Unskip " + Model.skippedVersion(checker.skippedVersions, appRow.app) + "  K"
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

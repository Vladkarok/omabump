pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.vladkarok.agent-apps"
  ipcTarget: "io.github.vladkarok.agent-apps"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string glyph: ""
  readonly property string fallbackMark: ""

  readonly property var apps: checker.apps
  readonly property int updateCount: checker.updateCount
  readonly property bool iconOnlyWithUpdates: settings && settings.barIconOnlyWithUpdates === true

  property int rowIndex: 0
  property bool cursorActive: false

  // The settings view swaps in for the app list. Its rows are the toggles in
  // settingRows, then the check interval dropdown.
  property bool settingsOpen: false
  property int settingIndex: 0
  readonly property var settingRows: [
    { key: "showMise", fallback: true, label: "Show mise tools", description: "CLI agents managed by mise, below the desktop apps" },
    { key: "barIconOnlyWithUpdates", fallback: false, label: "Bar icon only when updates exist", description: "" },
    { key: "notify", fallback: true, label: "Notify on new releases", description: "" }
  ]
  readonly property int intervalRow: settingRows.length
  readonly property var intervalChoices: [300, 900, 1800, 3600, 21600, 86400]

  // "checked 3 min ago" reads this instead of Date.now() so it keeps moving
  // while the panel sits open.
  property double nowMs: Date.now()

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  function refreshNow() { checker.refresh() }

  function selectedApp() {
    return apps.length > 0 ? apps[clamp(rowIndex, 0, apps.length - 1)] : null
  }

  function moveCursor(dy) {
    if (settingsOpen) {
      settingIndex = clamp(settingIndex + dy, 0, intervalRow)
      return
    }
    if (apps.length === 0) return
    rowIndex = clamp(rowIndex + dy, 0, apps.length - 1)
    ensureRowVisible()
  }

  // Keeps the keyboard cursor on screen when the list scrolls.
  function ensureRowVisible() {
    var item = appRepeater.itemAt(rowIndex)
    if (!item) return
    var top = item.mapToItem(body, 0, 0).y
    if (top < panelFlick.contentY) panelFlick.contentY = top
    else if (top + item.height > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = top + item.height - panelFlick.height
  }

  function showSettings(on, withCursor) {
    settingsOpen = on
    settingIndex = 0
    cursorActive = withCursor
    if (panelFlick) panelFlick.contentY = 0
  }

  // shell.json hot-reloads and the bar injects the new settings, so the
  // controls bind to settings and this only writes the merged entry.
  function setSetting(key, value) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry[key] = value
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function settingOn(row) { return root.setting(row.key, row.fallback) === true }

  function activateSetting() {
    if (settingIndex === intervalRow) {
      intervalDropdown.open()
      return
    }
    var row = settingRows[settingIndex]
    setSetting(row.key, !settingOn(row))
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

  function footerText() {
    var commit = checker.pkgsCommit !== "" ? "omarchy-pkgs " + checker.pkgsCommit.substring(0, 7) + " · " : ""
    return commit + checkedText()
  }

  function summaryText() {
    var parts = []
    if (updateCount > 0) parts.push(updateCount + (updateCount === 1 ? " update" : " updates"))
    if (checker.waitingCount > 0) parts.push(checker.waitingCount + " newer without an install path")
    var failed = checker.errorCount
    if (failed > 0) parts.push("check failed for " + failed + (failed === 1 ? " app" : " apps"))
    return parts.join(", ")
  }

  function tooltipText() {
    var summary = summaryText()
    return summary === "" ? "Agent apps up to date" : "Agent apps: " + summary
  }

  function badgeText(app) {
    if (!app) return ""
    return app.source === "vendor-pkg" ? "vendor" : String(app.source || "")
  }

  // openai-codex-desktop may be installed as the AUR's chatgpt-desktop.
  function aliasText(app) {
    if (!app || !app.installedName || app.installedName === app.pkg || app.source === "mise") return ""
    return ", installed as " + app.installedName
  }

  function versionText(app) {
    if (!app) return ""
    if (app.updateAvailable === true) return app.installed + " → " + app.latest
    return app.installed
  }

  function statusText(app) {
    if (!app) return ""
    if (checker.checking) return "Checking…"
    var note = String(app.note || "")
    if (String(app.error || "") !== "") return "Check failed: " + app.error
    if (app.updateAvailable === true && app.installable !== true) return note !== "" ? note : "No update path"
    if (note !== "") return note
    if (app.updateAvailable === true) {
      if (app.source === "omarchy") return "Update builds Omarchy's recipe at " + app.latest
      if (app.source === "mise") return "Update runs mise up"
      return "Update installs the vendor's package"
    }
    return "Up to date" + aliasText(app)
  }

  function colorLuminance(c) {
    function channel(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
  }

  // White marks ship a dark twin for light themes, the same convention the
  // first-party agents panel uses. Relative paths belong to this plugin;
  // a user apps.json may also point at an absolute file.
  function iconUrl(app) {
    if (!app) return ""
    var path = String(app.icon || "")
    var light = String(app.iconLight || "")
    if (light !== "" && colorLuminance(root.surface) >= 0.5) path = light
    if (path === "") return ""
    return path.charAt(0) === "/" ? "file://" + path : Qt.resolvedUrl(path)
  }

  // Like the system update icon, it can stay out of the bar until there is
  // something to install. While the panel is open (IPC open/toggle) it shows,
  // so the panel has an anchor.
  visible: !iconOnlyWithUpdates || updateCount > 0 || opened
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    settingsOpen = false
    rowIndex = 0
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onAppsChanged: rowIndex = clamp(rowIndex, 0, Math.max(0, apps.length - 1))

  Main {
    id: checker
    settings: root.settings
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
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
    contentHeight: panel.fittedContentHeight(header.implicitHeight + body.implicitHeight + footer.implicitHeight + column.spacing * 2, Style.space(560))

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
        else root.updateApp(root.selectedApp())
      }
      onCloseRequested: root.settingsOpen ? root.showSettings(false, false) : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") root.showSettings(!root.settingsOpen, true)
        else if (t === "\b" && root.settingsOpen) root.showSettings(false, false)
        else if ((t === "r" || t === "R") && !root.settingsOpen) root.refreshNow()
      }

      // The hero and the footer stay put; only the rows scroll, so the
      // settings button never scrolls away.
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
            title: "Agent apps"
            meta: root.settingsOpen ? "Settings"
              : root.summaryText() !== "" ? root.summaryText() : (root.apps.length > 0 ? "Up to date" : "")
            detail: ""
            foreground: root.foreground
            fontFamily: root.fontFamily

            trailingControl: Component {
              PanelActionButton {
                iconText: "󰒓"
                tooltipText: root.settingsOpen ? "Back to the apps  Esc" : "Settings  s"
                bordered: root.settingsOpen
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.showSettings(!root.settingsOpen, false)
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

          Text {
            textFormat: Text.PlainText
            visible: checker.checkError !== ""
            width: parent.width
            text: checker.checkError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
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

            Text {
              textFormat: Text.PlainText
              visible: !root.settingsOpen && root.apps.length === 0
              width: parent.width
              topPadding: Style.space(12)
              bottomPadding: Style.space(12)
              text: checker.checking ? "Checking for new versions…" : "None of the tracked apps are installed."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Column {
              visible: !root.settingsOpen && root.apps.length > 0
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                id: appRepeater
                model: root.apps

                AppRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  app: modelData
                  rowIndex: index
                }
              }
            }

            Column {
              visible: root.settingsOpen
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.settingRows

                Toggle {
                  required property var modelData
                  required property int index
                  width: parent.width
                  label: modelData.label
                  description: modelData.description
                  checked: root.settingOn(modelData)
                  hasCursor: root.cursorActive && root.settingIndex === index
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onHovered: function(on) {
                    if (!on) return
                    root.cursorActive = true
                    root.settingIndex = index
                  }
                  onClicked: root.setSetting(modelData.key, !root.settingOn(modelData))
                }
              }

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
                  font.pixelSize: Style.font.subtitle
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
            }
          }
        }

        Column {
          id: footer
          width: parent.width
          spacing: Style.space(12)

          PanelSeparator { foreground: root.foreground }

          Text {
            textFormat: Text.PlainText
            visible: !root.settingsOpen
            width: parent.width
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.settingsOpen && checker.pkgsError !== ""
            width: parent.width
            text: checker.pkgsError
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.settingsOpen ? "Space change · Esc back" : "Enter update · s settings · Esc close"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Button {
              visible: !root.settingsOpen
              text: checker.checking ? "Checking…" : "Refresh  r"
              enabled: !checker.checking
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.refreshNow()
            }
          }
        }
      }
    }
  }

  component AppRow: CursorSurface {
    id: appRow
    property var app: null
    property int rowIndex: 0
    readonly property bool hasUpdate: !!app && app.updateAvailable === true
    readonly property bool updatable: hasUpdate && app.installable === true
    readonly property bool failed: !!app && String(app.error || "") !== ""

    hasCursor: root.cursorActive && root.rowIndex === rowIndex
    foreground: root.foreground
    implicitHeight: Math.max(rowContent.implicitHeight, updateButton.implicitHeight) + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.rowIndex = appRow.rowIndex
      }
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
        implicitWidth: Style.font.title
        implicitHeight: Style.font.title

        Image {
          id: mark
          anchors.fill: parent
          source: root.iconUrl(appRow.app)
          sourceSize.width: Style.font.title * 2
          sourceSize.height: Style.font.title * 2
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
        spacing: Style.space(1)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: appRow.app ? String(appRow.app.label || appRow.app.pkg) : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Rectangle {
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: badgeText.implicitWidth + Style.space(8)
            implicitHeight: badgeText.implicitHeight + Style.space(2)
            radius: Style.space(3)
            color: "transparent"
            border.width: 1
            border.color: root.dim

            Text {
              id: badgeText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.badgeText(appRow.app)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            textFormat: Text.PlainText
            text: root.versionText(appRow.app)
            color: appRow.hasUpdate ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: appRow.hasUpdate
          }
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: root.statusText(appRow.app)
          color: appRow.failed ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Button {
        id: updateButton
        visible: appRow.updatable
        Layout.alignment: Qt.AlignVCenter
        text: "Update"
        bordered: true
        foreground: root.urgent
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        tooltipText: !appRow.app ? ""
          : appRow.app.source === "mise" ? "Run mise up in a terminal"
          : appRow.app.source === "omarchy" ? "Build " + appRow.app.latest + " from the Omarchy recipe in a terminal"
          : "Install the vendor's " + appRow.app.latest + " package in a terminal"
        onClicked: root.updateApp(appRow.app)
      }
    }
  }
}

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

  property int rowIndex: 0
  property bool cursorActive: false

  // "checked 3 min ago" reads this instead of Date.now() so it keeps moving
  // while the panel sits open.
  property double nowMs: Date.now()

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  function refreshNow() { checker.refresh() }

  function selectedApp() {
    return apps.length > 0 ? apps[clamp(rowIndex, 0, apps.length - 1)] : null
  }

  function moveCursor(dy) {
    if (apps.length === 0) return
    rowIndex = clamp(rowIndex + dy, 0, apps.length - 1)
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
    if (checker.waitingCount > 0) parts.push(checker.waitingCount + " newer release, not in the recipe yet")
    var failed = checker.errorCount
    if (failed > 0) parts.push("check failed for " + failed + (failed === 1 ? " app" : " apps"))
    return parts.join(", ")
  }

  function tooltipText() {
    var summary = summaryText()
    return summary === "" ? "Agent apps up to date" : "Agent apps: " + summary
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
      return "Update builds the AUR recipe at " + app.latest
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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.updateApp(root.selectedApp())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Agent apps"
            meta: root.summaryText() !== "" ? root.summaryText() : (root.apps.length > 0 ? "Up to date" : "")
            detail: ""
            foreground: root.foreground
            fontFamily: root.fontFamily

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

          Text {
            textFormat: Text.PlainText
            visible: root.apps.length === 0
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
            visible: root.apps.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
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

          PanelSeparator { foreground: root.foreground }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            visible: checker.pkgsError !== ""
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
              text: "j/k select · Enter update · Esc close"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Button {
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
              text: appRow.app ? String(appRow.app.source || "") : ""
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
        tooltipText: !appRow.app ? "" : appRow.app.source === "mise"
          ? "Run mise up in a terminal"
          : "Build " + appRow.app.latest + " from the " + (appRow.app.source === "omarchy" ? "Omarchy" : "AUR") + " recipe in a terminal"
        onClicked: root.updateApp(appRow.app)
      }
    }
  }
}

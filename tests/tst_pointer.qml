// The panel's cursor under the pointer, run by tests/qml.sh through
// qmltestrunner (offscreen) when Qt's test runner is installed. The card
// is Panel.qml's in miniature: a header, a scrolling list of rows with a
// section header among them, a footer, a HoverHandler over the whole card
// and rows whose hover moves the cursor only when PointerGate says the
// pointer moved; the cursor is placed by Model.cursorIndex when the list
// changes. The card sits above a bottom bar, as KeyboardPanel puts it, so
// it moves when its content grows. Offscreen, Qt sends no hover when the
// scene changes under a still pointer, as a compositor's frame does:
// settleHover() sends it as Qt would, to the row under the point, then to
// the card's HoverHandler.
import QtQuick
import QtTest
import ".."
import "../Model.js" as Model

Item {
  id: win
  width: 500; height: 600

  // Every hover a row heard, so a test can tell one came.
  property int rowHovers: 0
  property int headerH: 40
  property int rowH: 50
  property int footerH: 40

  Item {
    id: card
    objectName: "card"
    x: 50; width: 400
    height: keyCatcher.implicitHeight
    // Above a bottom bar 40 px high, 10 px from it.
    y: win.height - 40 - 10 - height

    property var apps: []
    readonly property var orderedApps: apps
    property int rowIndex: 0
    property string cursorPkg: ""
    property bool cursorMoved: false

    function selectedApp() { return orderedApps.length > 0 ? orderedApps[Model.clamp(rowIndex, 0, orderedApps.length - 1)] : null }
    function noteCursorPkg() {
      var app = selectedApp()
      cursorPkg = app ? app.pkg : ""
    }
    function resetCursor() {
      rowIndex = Model.firstActionIndex(orderedApps, [], {})
      cursorMoved = false
      pointerGate.reset()
    }
    onOrderedAppsChanged: {
      rowIndex = Model.cursorIndex(orderedApps, cursorPkg, cursorMoved, [], {})
      noteCursorPkg()
    }
    onRowIndexChanged: noteCursorPkg()

    // A hover over row index, at (x, y) in its MouseArea: Panel.qml's
    // rowMouse.onPositionChanged.
    function rowHover(area, index, x, y) {
      win.rowHovers++
      if (!pointerGate.moved(area, x, y)) return
      rowIndex = index
      cursorMoved = true
    }

    PointerGate {
      id: pointerGate
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      implicitHeight: win.headerH + list.height + win.footerH

      HoverHandler {
        onPointChanged: if (hovered) pointerGate.note(keyCatcher, point.position.x, point.position.y)
        onHoveredChanged: if (!hovered) pointerGate.leave()
      }

      Rectangle { id: header; width: 400; height: win.headerH; color: "#334" }

      Flickable {
        id: list
        y: win.headerH; width: 400
        height: Math.min(rows.height, 260)
        clip: true
        contentHeight: rows.height
        Column {
          id: rows
          width: 400
          Repeater {
            model: card.apps
            Rectangle {
              id: row
              required property int index
              readonly property alias area: rowMouse
              width: 400; height: win.rowH
              color: index % 2 ? "#445" : "#556"
              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onPositionChanged: function(mouse) { card.rowHover(rowMouse, row.index, mouse.x, mouse.y) }
              }
            }
          }
          // A section header among the rows, as "CLI TOOLS" is.
          Rectangle { id: section; width: 400; height: 30; color: "#223" }
          Repeater {
            model: 2
            Rectangle { width: 400; height: win.rowH; color: "#667" }
          }
        }
      }

      Rectangle { id: footer; y: list.y + list.height; width: 400; height: win.footerH; color: "#334" }
    }
  }

  TestCase {
    name: "Pointer"
    when: windowShown

    // Row 2 has an update: the first row with something to do.
    function sample() {
      return [{ pkg: "a" }, { pkg: "b" },
        { pkg: "c", source: "omarchy", installed: "1-1", latest: "2", updateAvailable: true, installable: true }, { pkg: "d" }]
    }
    // Where row i's middle is, in the window, at the list's scroll.
    function rowY(i) { return card.y + list.y + i * win.rowH + win.rowH / 2 - list.contentY }
    // The pointer to (x, y) of the window in steps, as a hand moves it.
    function slide(x0, y0, x1, y1) {
      for (var i = 1; i <= 5; i++) {
        mouseMove(win, x0 + (x1 - x0) * i / 5, y0 + (y1 - y0) * i / 5)
        wait(16)
      }
    }
    // A frame after the scene changed under the pointer resting at (x, y)
    // of the window: the hover Qt sends then, to the row under it if any
    // (inside the list's view), then to the card's HoverHandler.
    function settleHover(x, y) {
      wait(30)
      var l = list.mapFromItem(win, x, y)
      if (l.x >= 0 && l.y >= 0 && l.x < list.width && l.y < list.height) {
        var r = rows.mapFromItem(win, x, y)
        var item = rows.childAt(r.x, r.y)
        if (item && item.area) {
          var a = item.area.mapFromItem(win, x, y)
          card.rowHover(item.area, item.index, a.x, a.y)
        }
      }
      var k = keyCatcher.mapFromItem(win, x, y)
      if (k.x >= 0 && k.y >= 0 && k.x < keyCatcher.width && k.y < keyCatcher.height)
        pointerGate.note(keyCatcher, k.x, k.y)
      wait(30)
    }
    function open() {
      card.apps = sample()
      card.resetCursor()
    }

    // Opened with the pointer away from the card, settled.
    function init() {
      win.headerH = 40
      win.rowH = 50
      win.footerH = 40
      list.contentY = 0
      mouseMove(win, 5, 5)
      wait(20)
      open()
      wait(pointerGate.settleMs + 100)
      win.rowHovers = 0
    }

    function test_opens_on_the_first_row_with_something_to_do() {
      compare(card.rowIndex, 2)
      compare(card.cursorMoved, false)
    }
    function test_a_hand_moves_the_cursor_onto_a_row() {
      mouseMove(win, 5, rowY(1))
      wait(20)
      slide(5, rowY(1), 220, rowY(1))
      compare(card.rowIndex, 1)
      compare(card.cursorMoved, true)
    }
    function test_one_fast_move_onto_a_row_counts() {
      mouseMove(win, 5, rowY(1))
      wait(20)
      mouseMove(win, 220, rowY(1))
      wait(50)
      compare(card.rowIndex, 1)
    }
    function test_from_row_to_row() {
      slide(5, rowY(0), 220, rowY(0))
      compare(card.rowIndex, 0)
      slide(220, rowY(0), 220, rowY(2))
      compare(card.rowIndex, 2)
    }
    function test_back_from_another_window_in_one_move() {
      slide(5, rowY(0), 220, rowY(0))
      compare(card.rowIndex, 0)
      mouseMove(win, 5, 5)
      wait(30)
      mouseMove(win, 300, rowY(2))
      wait(50)
      compare(card.rowIndex, 2)
    }
    function test_rows_rewritten_under_a_still_pointer_keep_the_cursor() {
      slide(5, rowY(0), 220, rowY(0))
      card.rowIndex = 3
      card.cursorMoved = true
      var hovers = win.rowHovers
      for (var i = 0; i < 3; i++) {
        card.apps = sample()
        settleHover(220, rowY(0))
      }
      verify(win.rowHovers > hovers, "the rows heard the pointer")
      compare(card.cursorPkg, "d")
    }
    function test_a_list_scrolled_under_a_still_pointer_keeps_the_cursor() {
      win.rowH = 80
      wait(30)
      slide(5, rowY(0), 220, rowY(0))
      card.rowIndex = 3
      card.cursorMoved = true
      list.contentY = 60
      settleHover(220, rowY(0) + 60)
      compare(card.rowIndex, 3)
    }
    function test_a_card_that_moves_under_a_still_pointer_keeps_the_cursor() {
      slide(5, rowY(1), 220, rowY(1))
      card.rowIndex = 3
      card.cursorMoved = true
      var y = rowY(1)
      var hovers = win.rowHovers
      // A row below grows (a second line): the card grows upward and its
      // rows move up under the pointer.
      win.footerH = 60
      settleHover(220, y)
      win.footerH = 40
      settleHover(220, y)
      verify(win.rowHovers > hovers, "the rows heard the pointer")
      compare(card.rowIndex, 3)
    }
    function test_a_row_scrolled_under_a_pointer_resting_on_a_section_header() {
      win.rowH = 80
      wait(30)
      list.contentY = list.contentHeight - list.height
      wait(30)
      var sy = card.y + list.y + section.y + 15 - list.contentY
      slide(5, sy, 220, sy)
      card.rowIndex = 1
      card.cursorMoved = true
      list.contentY = list.contentY - 40
      settleHover(220, sy)
      compare(card.rowIndex, 1)
    }
    function test_opened_under_a_still_pointer_the_pointer_takes_nothing() {
      // Where row 1 will be once the panel is open.
      var y = rowY(1)
      card.apps = []
      wait(30)
      mouseMove(win, 220, y)
      wait(30)
      open()
      settleHover(220, y)
      verify(win.rowHovers > 0, "the rows heard the pointer")
      compare(card.rowIndex, 2)
      wait(pointerGate.settleMs + 100)
      for (var i = 0; i < 3; i++) {
        card.apps = sample()
        settleHover(220, y)
      }
      compare(card.rowIndex, 2)
      compare(card.cursorMoved, false)
      slide(220, y, 220, rowY(0))
      compare(card.rowIndex, 0)
    }
    function test_opened_with_the_pointer_on_the_footer_rows_that_come_under_it_take_nothing() {
      // Rows tall enough that the list's last 40 px in view hold row 3.
      win.rowH = 70
      wait(30)
      var fy = card.y + footer.y + 20
      mouseMove(win, 220, fy)
      wait(30)
      open()
      settleHover(220, fy)
      wait(pointerGate.settleMs + 100)
      // The footer goes: the card shrinks toward the bar, and the list's
      // last rows come under the resting pointer.
      var hovers = win.rowHovers
      win.footerH = 0
      settleHover(220, fy)
      verify(win.rowHovers > hovers, "a row came under the pointer")
      compare(card.rowIndex, 2)
      compare(card.cursorMoved, false)
    }
  }
}

import QtQuick

// Tells a pointer that moved over the rows from rows that moved under a
// still pointer. Rows rebuilt by a check, a list scrolled by the keyboard,
// a card that grows or shrinks (and so moves, with the bar at the bottom or
// a side) and a panel opened under the pointer all report a hover too, at
// the same place on screen, and only a pointer that moved may move the
// cursor. Omarchy's PointerMoveGate does the same in newer shells; this one
// also counts the first hover after the pointer came from outside the
// panel, which a single fast move onto a row may be.
//
// The panel reports every hover over its card with note() (a HoverHandler
// on the card, which hears a hover after the row under it) and the
// pointer leaving the card with leave(); a row asks moved() before it moves
// the cursor.
QtObject {
  id: gate

  // Hovers from a panel opened under a still pointer arrive within a few
  // frames; after this long without one, the pointer is outside the card.
  property int settleMs: 300
  // Where the pointer is: "unknown" (the next hover only notes where it
  // is), "outside" the card (the next hover over a row is a move), or
  // "at" the screen point at.
  property string where: "unknown"
  property point at: Qt.point(0, 0)

  property Timer settle: Timer {
    interval: gate.settleMs
    onTriggered: if (gate.where === "unknown") gate.leave()
  }

  // Forget where the pointer was: the panel opened, or its rows were built
  // again from nothing.
  function reset() {
    where = "unknown"
    settle.restart()
  }

  function leave() {
    where = "outside"
  }

  // The pointer is over the card at (x, y) in item.
  function note(item, x, y) {
    at = item.mapToGlobal(x, y)
    where = "at"
  }

  // True when the pointer, at (x, y) in item, moved since it was last seen.
  function moved(item, x, y) {
    var p = item.mapToGlobal(x, y)
    var didMove = where === "outside" || (where === "at" && (Math.abs(p.x - at.x) > 1 || Math.abs(p.y - at.y) > 1))
    if (didMove || where === "unknown") {
      at = p
      where = "at"
    }
    return didMove
  }
}

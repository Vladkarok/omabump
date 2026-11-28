pragma Singleton
import QtQuick

// A stand-in for Omarchy's Commons.I18n, for tests/tst_strings_new.qml.
QtObject {
  readonly property string formatLocale: "de-DE"
  readonly property bool rightToLeft: true
  function formatNumber(n) { return "#" + n }
}

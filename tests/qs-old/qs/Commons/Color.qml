pragma Singleton
import QtQuick

// The qs.Commons of a shell before Omarchy 4.5.0, for
// tests/tst_strings_old.qml: it has its colours, but neither Translations
// nor I18n.
QtObject {
  readonly property color foreground: "white"
}

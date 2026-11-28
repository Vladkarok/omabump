import QtQuick
import qs.Commons as Commons

// Omarchy's Commons.Translations over the plugin's catalogs (i18n/), in a
// file of its own: Translator.qml loads it with a Loader, so that on a
// shell without Commons.Translations (Omarchy before 4.5.0) only this file
// fails to load, and the panel words its text from en.json alone. An Item,
// since a Loader loads no bare QtObject.
Item {
  readonly property var catalogs: translations

  Commons.Translations {
    id: translations
    directory: Qt.resolvedUrl("i18n")
  }
}

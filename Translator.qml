import QtQuick
import qs.Commons as Commons
import "Model.js" as Model

// The translator the panel words all its text with (Model.js's tr), in the
// language picked under Setup > Region > Language, following it live: a
// new tr whenever the language or a catalog changes, and every binding
// that passes tr to Model.js words its text again.
//
// The catalogs come through Omarchy's Commons.Translations (Strings.qml).
// A shell without it (Omarchy before 4.5.0, which added it and
// Commons.I18n together) fails to load Strings.qml alone, and tr is then
// Model.catalogTranslator over englishText, en.json as Panel.qml reads it:
// English, its numbers and dates as Qt writes them. Not visible: an Item
// only to hold the Loader.
Item {
  id: root
  visible: false

  // i18n/en.json's text, for a shell without Commons.Translations.
  property string englishText: ""

  readonly property var catalogs: loader.status === Loader.Ready && loader.item ? loader.item.catalogs : null
  // Read here, so the binding below follows them: the merged catalog
  // changes with the language and with any catalog file.
  readonly property var strings: catalogs ? catalogs.strings : Model.parseCatalog(englishText)
  readonly property string formatLocale: i18nValue("formatLocale", "")
  readonly property var tr: catalogs ? shellTranslator(catalogs, strings, formatLocale) : fallbackTranslator(strings, formatLocale)

  // A property of Omarchy's Commons.I18n, or fallback on a shell that has
  // none.
  function i18nValue(name, fallback) {
    try {
      var value = Commons.I18n[name]
      return value !== undefined && value !== null && value !== "" ? value : fallback
    } catch (e) {
      return fallback
    }
  }

  // A moment, in epoch seconds, as the language writes it: format is the
  // catalog's format.dateTime, a Qt date format. Qt.locale(formatLocale),
  // not a bare Qt.locale(), which keeps the locale the shell started with.
  function dateText(sec, format, locale) {
    return new Date(sec * 1000).toLocaleString(locale !== "" ? Qt.locale(locale) : Qt.locale(), format)
  }

  function shellTranslator(c, merged, locale) {
    return {
      t: function(key) { return c.t(key) },
      tn: function(key, n) { return c.tn(key, n) },
      has: function(key) { return merged[key] !== undefined },
      num: function(n) {
        try {
          return Commons.I18n.formatNumber(n)
        } catch (e) {
          return String(n)
        }
      },
      date: function(sec) { return root.dateText(sec, c.t("format.dateTime"), locale) }
    }
  }

  function fallbackTranslator(english, locale) {
    var tr = Model.catalogTranslator([{ strings: english, plural: Model.englishPlural }],
      function(sec) { return root.dateText(sec, tr.t("format.dateTime"), locale) })
    return tr
  }

  Loader {
    id: loader
    source: "Strings.qml"
  }
}

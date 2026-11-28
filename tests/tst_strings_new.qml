// Translator.qml on a shell with Commons.Translations (Omarchy 4.5.0 and
// later), run by tests/qml.sh through qmltestrunner with tests/qs-new on
// the import path: stand-ins for Commons.Translations and Commons.I18n.
// The panel's tr goes through them, and a change of their strings (a
// language switch) words the bound text again.
import QtQuick
import QtTest
import ".."
import "../Model.js" as Model

Item {
  Translator {
    id: translator
    englishText: '{"count.updates": {"one": "%1 update", "other": "%1 updates"}}'
  }

  Text {
    id: bound
    text: Model.sayCount(translator.tr, "count.updates", 2)
  }

  TestCase {
    name: "TranslatorNew"

    function test_loads_commons_translations() {
      tryVerify(function() { return translator.catalogs !== null })
      verify(String(translator.catalogs.directory).endsWith("/i18n"), String(translator.catalogs.directory))
    }

    function test_words_through_them() {
      compare(Model.sayCount(translator.tr, "count.updates", 1), "#1 stub update")
      compare(bound.text, "#2 stub updates")
      compare(translator.tr.has("count.updates"), true)
      compare(translator.tr.has("count.nothing"), false)
      compare(translator.tr.date(0), new Date(0).toLocaleString(Qt.locale("de-DE"), "yyyy"))
      compare(translator.i18nValue("rightToLeft", false), true)
    }

    function test_a_language_switch_words_the_text_again() {
      var was = translator.catalogs.strings
      translator.catalogs.strings = { "count.updates": { "one": "%1 оновлення", "other": "%1 оновлень" } }
      compare(bound.text, "#2 оновлень")
      translator.catalogs.strings = was
      compare(bound.text, "#2 stub updates")
    }
  }
}

// Translator.qml on a shell without Commons.Translations or Commons.I18n
// (Omarchy before 4.5.0), run by tests/qml.sh through qmltestrunner with
// tests/qs-old on the import path: a qs.Commons that has neither. Only
// Strings.qml fails to load, and the panel words its text from English
// (englishText, en.json as Panel.qml reads it).
import QtQuick
import QtTest
import ".."
import "../Model.js" as Model

Item {
  Translator {
    id: translator
    englishText: '{"count.updates": {"one": "%1 update", "other": "%1 updates"}, "format.dateTime": "yyyy"}'
  }

  Text {
    id: bound
    text: Model.sayCount(translator.tr, "count.updates", 2)
  }

  TestCase {
    name: "TranslatorOld"

    function test_falls_back_to_english() {
      compare(translator.catalogs, null)
      compare(Model.sayCount(translator.tr, "count.updates", 1), "1 update")
      compare(bound.text, "2 updates")
      compare(translator.tr.has("count.updates"), true)
      compare(translator.tr.t("count.nothing"), "count.nothing")
      compare(translator.tr.date(0), new Date(0).toLocaleString(Qt.locale(), "yyyy"))
      compare(translator.i18nValue("rightToLeft", false), false)
      compare(translator.formatLocale, "")
    }
  }
}

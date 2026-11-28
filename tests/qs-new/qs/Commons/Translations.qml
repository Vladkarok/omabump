import QtQuick

// A stand-in for Omarchy's Commons.Translations (4.5.0 and later), for
// tests/tst_strings_new.qml: the same members Translator.qml reads, over
// strings a test sets, as a language switch replaces them.
QtObject {
  property var directory: ""
  property var strings: ({
    "count.updates": { "one": "%1 stub update", "other": "%1 stub updates" },
    "format.dateTime": "yyyy"
  })
  function t(key) {
    var v = strings[key]
    if (v && typeof v === "object") v = v.other
    return typeof v === "string" ? v : key
  }
  function tn(key, n) {
    var v = strings[key]
    return v && typeof v === "object" ? (n === 1 ? v.one : v.other) : t(key)
  }
}

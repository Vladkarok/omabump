// The panel's catalogs (i18n/) under node, as Omarchy's
// Commons.Translations reads them: a translator for Model.js's text
// functions (Model.catalogTranslator over the language, its base language
// and English, each by its own plural rules).
//
//   translator(model, "uk")   Model.js's tr for Ukrainian
import fs from "node:fs"
import path from "node:path"
import vm from "node:vm"
import { fileURLToPath } from "node:url"

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..")

export const i18nDir = path.join(root, "i18n")

// The language codes the plugin ships: one catalog file each.
export function shipped() {
  return fs.readdirSync(i18nDir).filter(f => f.endsWith(".json")).map(f => f.slice(0, -5)).sort()
}

export function catalog(code) {
  const file = path.join(i18nDir, code + ".json")
  return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {}
}

// Omarchy's plural rules for every language code (Commons/Plural.js), from
// tests/plural.js, a copy, as a script in a context of its own.
export function loadPlural(file) {
  const context = vm.createContext({ module: { exports: {} } })
  vm.runInContext(fs.readFileSync(file, "utf8"), context, { filename: file })
  return context.module.exports
}
export const plural = loadPlural(path.join(root, "tests", "plural.js"))

// The CLDR cardinal category of a whole count in the language code.
export function category(code, count) { return plural.category(code, count) }

// The categories a plural entry of the language must carry: every one its
// counts reach, and "other", which Omarchy requires of every entry.
export function categories(code) { return [...plural.categories(code)] }

// A moment as bin/omabump-common's English fields write it (date
// '+%b %-d %H:%M', in C.UTF-8, local time), whatever the language: the
// panel writes it by its catalog's format.dateTime instead (Translator.qml).
const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
export function englishDate(sec) {
  const d = new Date(sec * 1000)
  const two = v => String(v).padStart(2, "0")
  return `${months[d.getMonth()]} ${d.getDate()} ${two(d.getHours())}:${two(d.getMinutes())}`
}

// Model.js's tr for the language code.
export function translator(model, code) {
  const base = code.split("-")[0]
  const layers = [{ strings: catalog(code), plural: n => category(code, n) }]
  if (base !== code && base !== "en") layers.push({ strings: catalog(base), plural: n => category(base, n) })
  if (code !== "en") layers.push({ strings: catalog("en"), plural: n => category("en", n) })
  return model.catalogTranslator(layers, englishDate)
}

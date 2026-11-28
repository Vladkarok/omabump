// Loads Model.js the way QML does, as a .pragma library: one copy in a
// context of its own. Its first line, ".pragma library", is QML's and not
// JavaScript, so it becomes a blank line (line numbers stay right).
//
//   node tests/model.mjs <function> [<language>] <lines
//
// calls a Model.js function once per line of stdin, each line a JSON array
// of its arguments (after the translator for <language>, tests/strings.mjs's,
// when one is named: for a function that words text), and prints each
// answer as one line of JSON: how
// tests/model.sh and tests/qml.sh set the widget's rules against the
// scripts'. For a value that is no function, it prints that value as JSON
// and reads no stdin: how tests/qml.sh reads the numbers and words Model.js
// reads bin/omabump-check by.
import fs from "node:fs"
import path from "node:path"
import vm from "node:vm"
import { fileURLToPath } from "node:url"

export const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..")

export function loadModel() {
  const file = path.join(root, "Model.js")
  const source = fs.readFileSync(file, "utf8").replace(/^\.pragma library$/m, "")
  const context = vm.createContext({})
  vm.runInContext(source, context, { filename: file })
  return context
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const model = loadModel()
  const name = process.argv[2]
  if (!Object.prototype.hasOwnProperty.call(model, name) || model[name] === undefined) {
    console.error(`model.mjs: Model.js defines no ${name}`)
    process.exit(2)
  }
  if (typeof model[name] !== "function") {
    process.stdout.write(JSON.stringify(model[name]) + "\n")
    process.exit(0)
  }
  const lead = []
  if (process.argv[3]) lead.push((await import("./strings.mjs")).translator(model, process.argv[3]))
  const out = []
  for (const line of fs.readFileSync(0, "utf8").split("\n")) {
    if (line !== "") out.push(JSON.stringify(model[name](...lead, ...JSON.parse(line))))
  }
  process.stdout.write(out.length > 0 ? out.join("\n") + "\n" : "")
}

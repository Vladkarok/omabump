// Loads Model.js the way QML does, as a .pragma library: one copy in a
// context of its own. Its first line, ".pragma library", is QML's and not
// JavaScript, so it becomes a blank line (line numbers stay right).
//
//   node tests/model.mjs <function> <lines
//
// calls a Model.js function once per line of stdin, each line a JSON array
// of its arguments, and prints each answer as one line of JSON: how
// tests/qml.sh sets the widget's rules against the scripts'.
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
  if (typeof model[name] !== "function") {
    console.error(`model.mjs: Model.js has no function ${name}`)
    process.exit(2)
  }
  const out = []
  for (const line of fs.readFileSync(0, "utf8").split("\n")) {
    if (line !== "") out.push(JSON.stringify(model[name](...JSON.parse(line))))
  }
  process.stdout.write(out.length > 0 ? out.join("\n") + "\n" : "")
}

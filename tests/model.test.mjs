// Tests for Model.js, the widget's rules. Run by tests/qml.sh when node is
// installed: one line per test, "ok<TAB>name" or "not ok<TAB>name<TAB>why",
// then "done<TAB>count". Exits non-zero when any test fails.
import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import { loadModel, root } from "./model.mjs"

const model = loadModel()
// The tests call Model.js through m, which notes each function they reach:
// the last test checks that every function has one.
const called = new Set()
const m = {}
for (const name of Object.keys(model)) {
  if (typeof model[name] !== "function") continue
  m[name] = (...args) => { called.add(name); return model[name](...args) }
}

let total = 0, failed = 0
function test(name, fn) {
  total++
  try {
    fn()
    console.log(`ok\t${name}`)
  } catch (e) {
    failed++
    console.log(`not ok\t${name}\t${String(e && e.message || e).replace(/\s+/g, " ").slice(0, 400)}`)
  }
}
// Objects made inside the model's context have its prototypes, which
// deepStrictEqual tells apart from this file's: compare them as JSON.
function same(actual, expected) {
  assert.deepStrictEqual(actual === undefined ? undefined : JSON.parse(JSON.stringify(actual)), expected)
}

// A row as bin/omabump-check writes it.
function row(fields) {
  return Object.assign({
    pkg: "app", label: "App", source: "omarchy", installedName: "app", installed: "1.0.0-1",
    latest: "1.0.0", versionFrom: "feed", updateAvailable: false, installable: true, error: "", note: "",
    stale: false, switchable: false, recipe: "", recipeCommit: "", request: "", muted: false, skipped: false,
    unchecked: false, held: false, omarchyUpdate: false, icon: "", iconLight: ""
  }, fields)
}
// QML hands lists over as QVariantList: indexable, with a length, not an Array.
function variantList(items) {
  const list = { length: items.length }
  items.forEach((item, i) => { list[i] = item })
  return list
}

// --- settings -------------------------------------------------------------------

test("isList: arrays and array-likes, not strings or maps", () => {
  same([m.isList([]), m.isList(variantList(["a"])), m.isList("ab"), m.isList({ a: 1 }), m.isList(null)],
    [true, true, false, false, false])
})

test("setting: the value, else the fallback for missing and null", () => {
  same([m.setting({ a: 0 }, "a", 5), m.setting({ a: null }, "a", 5), m.setting({}, "a", 5), m.setting(null, "a", 5)],
    [0, 5, 5, 5])
})

test("boolSetting: booleans, and true/false strings in any case and padding", () => {
  const s = { t: true, f: false, st: " TRUE ", sf: "False", junk: "maybe", one: 1 }
  same(["t", "f", "st", "sf"].map(k => m.boolSetting(s, k, null)), [true, false, true, false])
})

test("boolSetting: anything else, or nothing, is the fallback", () => {
  const s = { junk: "maybe", one: 1, nul: null }
  same(["junk", "one", "nul", "none"].map(k => m.boolSetting(s, k, true)), [true, true, true, true])
  same(m.boolSetting(s, "junk", false), false)
})

test("refreshIntervalSec: between a minute and a day, 3600 for anything unusable", () => {
  same([{}, { refreshIntervalSec: 30 }, { refreshIntervalSec: 999999 }, { refreshIntervalSec: "900" },
    { refreshIntervalSec: "abc" }, { refreshIntervalSec: 0 }].map(s => m.refreshIntervalSec(s)),
    [3600, 60, 86400, 900, 3600, 3600])
})

// --- ids and versions ----------------------------------------------------------------

test("pkgNameOk: Arch package names, no leading dot or dash", () => {
  same(["claude-desktop", "z-code-bin", "@x", "_x", "+x", "a.b+c_d@e", "-x", ".x", "A", "a b", "a/b", "a\n", "", 5]
    .map(n => m.pkgNameOk(n)),
    [true, true, true, true, true, true, false, false, false, false, false, false, false, false])
})

test("appIdOk: a package name, mise:<name>, or Omabump's own id", () => {
  same(["claude-desktop", "mise:claude", "mise:", "mise:-x", "self:omabump", "self:other", "github:x", null]
    .map(n => m.appIdOk(n)),
    [true, true, false, false, true, false, false, false])
})

test("skipVersionOk: what skip_version_ok allows", () => {
  same(["1.0.0-beta.1", "v1", "1.0~rc1", "1+2_3", "1".repeat(64), "1".repeat(65), "-1", ".1", "1..2", "1:2",
    "1 0", "", "1é", 1].map(v => m.skipVersionOk(v)),
    [true, true, true, true, true, false, false, false, false, false, false, false, false, false])
})

test("mutedApps: valid ids only, once each, from a QVariantList too", () => {
  const list = ["a", 1, "Bad", "mise:x", "", "a", "self:omabump", "x y", null]
  same(m.mutedApps({ mutedApps: list }), ["a", "mise:x", "self:omabump"])
  same(m.mutedApps({ mutedApps: variantList(list) }), ["a", "mise:x", "self:omabump"])
})

test("mutedApps: a setting that is not a list is nothing", () => {
  same([m.mutedApps({ mutedApps: "a,b" }), m.mutedApps({ mutedApps: { a: 1 } }), m.mutedApps({})], [[], [], []])
})

test("mutedApps: only the first quietMax strings count, refused ones included", () => {
  const list = []
  for (let i = 0; i < 150; i++) list.push("Bad" + i, i)
  for (let i = 0; i < 100; i++) list.push("ok" + i)
  same(m.mutedApps({ mutedApps: list }).length, model.quietMax - 150)
  same(model.quietMax, 200)
})

test("skippedVersions: string versions for valid ids, versions skip_version_ok allows", () => {
  same(m.skippedVersions({ skippedVersions: { a: "1.0", "mise:b": "2.0-beta.1", Bad: "1.0", c: "1..2", d: 3, e: "", f: "1.0" } }),
    { a: "1.0", "mise:b": "2.0-beta.1", f: "1.0" })
})

test("skippedVersions: a list or a string is nothing", () => {
  same([m.skippedVersions({ skippedVersions: ["x"] }), m.skippedVersions({ skippedVersions: variantList(["x"]) }),
    m.skippedVersions({ skippedVersions: "x" }), m.skippedVersions({})], [{}, {}, {}, {}])
})

test("skippedVersions: only the first quietMax string entries count", () => {
  const map = {}
  for (let i = 0; i < 150; i++) { map["bad-" + i] = "1..2"; map["num-" + i] = 1 }
  for (let i = 0; i < 100; i++) map["ok-" + i] = "1.0"
  same(Object.keys(m.skippedVersions({ skippedVersions: map })).length, 50)
})

// --- vercmp ------------------------------------------------------------------------------

test("vercmp agrees with /usr/bin/vercmp on every pair in tests/vercmp.tsv", () => {
  const lines = fs.readFileSync(path.join(root, "tests", "vercmp.tsv"), "utf8").split("\n")
    .filter(line => line !== "" && !line.startsWith("#"))
  assert.ok(lines.length >= 300, `only ${lines.length} pairs`)
  const wrong = []
  for (const line of lines) {
    const [a, b, want] = line.split("\t")
    const got = Math.sign(m.vercmp(a, b))
    if (got !== Number(want)) wrong.push(`${a} ${b}: ${got}, vercmp says ${want}`)
  }
  same(wrong, [])
})

test("splitEvr: epoch, version and release", () => {
  same([m.splitEvr("1:2.0-3"), m.splitEvr("2.0"), m.splitEvr(":1"), m.splitEvr("a:1-2-3")], [
    { epoch: "1", version: "2.0", release: "3" }, { epoch: "0", version: "2.0", release: null },
    { epoch: "0", version: "1", release: null }, { epoch: "0", version: "a:1-2", release: "3" }])
})

test("rpmvercmp: runs of digits and letters, separators between", () => {
  same([m.rpmvercmp("1.0", "1.0"), m.rpmvercmp("1.0a", "1.0"), m.rpmvercmp("1.10", "1.9"), m.rpmvercmp("1..0", "1.0")],
    [0, -1, 1, 1])
})

test("upstreamPart: the installed version less epoch and pkgrel", () => {
  same(["1:2.0-3", "2.0-1", "2.0", "1.0-beta-1"].map(v => m.upstreamPart(v)), ["2.0", "2.0", "2.0", "1.0-beta"])
})

test("stringVersions: mise and self compare as strings", () => {
  same(["mise", "self", "omarchy", "vendor-pkg", "indicator"].map(s => m.stringVersions(s)), [true, true, false, false, false])
})

// --- mute and skip -------------------------------------------------------------------

const update = row({ pkg: "claude-desktop", label: "Claude", installed: "1.0.0-1", latest: "1.1.0", updateAvailable: true })
const miseUpdate = row({ pkg: "mise:claude", label: "Claude Code", source: "mise", installed: "2.0.0", latest: "2.0.1", versionFrom: "mise", updateAvailable: true })

test("appFor and appName: the listed row, else null and the pkg", () => {
  const apps = [update, miseUpdate]
  same([m.appFor(apps, "mise:claude").label, m.appFor(apps, "x"), m.appName(apps, "claude-desktop"), m.appName(apps, "x")],
    ["Claude Code", null, "Claude", "x"])
})

test("isMuted and skippedVersion: by pkg", () => {
  same([m.isMuted(["claude-desktop"], update), m.isMuted(["claude-desktop"], miseUpdate), m.isMuted(["x"], null)],
    [true, false, false])
  same([m.skippedVersion({ "claude-desktop": "1.1.0" }, update), m.skippedVersion({}, update), m.skippedVersion({ toString: "1" }, row({ pkg: "x" }))],
    ["1.1.0", "", ""])
})

test("skipHolds: mise and self rows while their update is exactly the skipped version", () => {
  same([m.skipHolds(miseUpdate, "2.0.1"), m.skipHolds(miseUpdate, "2.0.0"), m.skipHolds(row({ source: "self", latest: "0.2.0", updateAvailable: true }), "0.2.0"),
    m.skipHolds(Object.assign({}, miseUpdate, { updateAvailable: false }), "2.0.1")], [true, false, true, false])
})

test("skipHolds: vercmp rows while the newest is not newer and the installed is older", () => {
  same([m.skipHolds(update, "1.1.0"), m.skipHolds(update, "1.2.0"), m.skipHolds(update, "1.0.5"),
    m.skipHolds(row({ installed: "1:1.1.0-2", latest: "1.1.0" }), "1.1.0"), m.skipHolds(update, ""), m.skipHolds(row({ latest: "" }), "1.0")],
    [true, true, false, false, false, false])
})

test("isSkipped and isQuiet: a skip counts only on a row with an update", () => {
  const skipped = { "claude-desktop": "1.1.0", app: "1.0.0" }
  same([m.isSkipped(skipped, update), m.isSkipped(skipped, row({ installed: "0.9-1", latest: "1.0.0" })), m.isSkipped(skipped, null)],
    [true, false, false])
  same([m.isQuiet([], skipped, update), m.isQuiet(["mise:claude"], {}, miseUpdate), m.isQuiet([], {}, update)], [true, true, false])
})

test("skipKept: kept while it holds, and while the last check cannot tell", () => {
  const apps = [update, row({ pkg: "failed", error: "boom", latest: "2.0" }), row({ pkg: "stale", stale: true }),
    row({ pkg: "busy", checking: true }), row({ pkg: "mise:u", source: "mise", unchecked: true, latest: "" }), row({ pkg: "nolatest", latest: "" })]
  same(["claude-desktop", "failed", "stale", "busy", "mise:u", "nolatest", "unlisted"].map(p => m.skipKept(apps, p, "1.1.0")),
    [true, true, true, true, true, true, true])
  same([m.skipKept(apps, "claude-desktop", "1.0.5"), m.skipKept([row({ installed: "1.1.0-1", latest: "1.1.0" })], "app", "1.1.0")], [false, false])
})

test("liveSkips: drops the skips their row shows are over", () => {
  same(m.liveSkips([update], { "claude-desktop": "1.0.5", other: "3.0" }), { other: "3.0" })
})

test("allMuted: every listed row of the source, and at least one", () => {
  const apps = [update, row({ pkg: "b" }), miseUpdate]
  same([m.allMuted(apps, ["claude-desktop", "b"], "omarchy"), m.allMuted(apps, ["claude-desktop"], "omarchy"), m.allMuted(apps, [], "vendor-pkg")],
    [true, false, false])
})

test("mutedToggled: m mutes, and unmutes", () => {
  same([m.mutedToggled(["x"], update), m.mutedToggled(["x", "claude-desktop"], update)], [["x", "claude-desktop"], ["x"]])
})

test("skipToggled: K skips the newest version, and unskips", () => {
  same(m.skipToggled({ x: "1" }, update), { skips: { x: "1", "claude-desktop": "1.1.0" } })
  same(m.skipToggled({ x: "1", "claude-desktop": "1.1.0" }, update), { skips: { x: "1" } })
})

test("skipToggled: nothing without an update, a note for a version Omabump does not store", () => {
  same(m.skipToggled({}, row({})), null)
  same(m.skipToggled({}, row({ latest: "1..2", updateAvailable: true })), { note: "Cannot skip 1..2: not a version Omabump stores" })
})

test("quietText: listed rows only, and skips the settings keep", () => {
  const apps = [update, miseUpdate, row({ pkg: "old", installed: "2.0-1", latest: "2.0", label: "Old" })]
  same(m.quietText(apps, ["mise:claude", "unlisted"], { "claude-desktop": "1.1.0", old: "1.5", gone: "1.0" }),
    "Muted: Claude Code · Skipped: Claude 1.1.0")
  same(m.quietText(apps, [], {}), "")
})

test("quietCleared: Clear keeps what the line leaves out", () => {
  same(m.quietCleared([update], ["claude-desktop", "hidden"], { "claude-desktop": "1.1.0", "mise:x": "1" }),
    { mutedApps: ["hidden"], skippedVersions: { "mise:x": "1" } })
})

test("settingsEntry: the whole entry, id first, changes merged, dead skips dropped", () => {
  same(m.settingsEntry("w", { id: "w", notify: true, skippedVersions: { "claude-desktop": "1.0.5" } }, { notify: false }, [update],
    { "claude-desktop": "1.0.5" }), { id: "w", notify: false, skippedVersions: {} })
  same(m.settingsEntry("w", { showMise: true }, { mutedApps: ["a"] }, [update], {}), { id: "w", showMise: true, mutedApps: ["a"] })
  same(m.settingsEntry("w", {}, { skippedVersions: { "claude-desktop": "1.1.0" } }, [update], {}),
    { id: "w", skippedVersions: { "claude-desktop": "1.1.0" } })
})

// --- counts ----------------------------------------------------------------------------

const rows = [
  update,                                                                        // update
  row({ pkg: "muted", latest: "2.0", updateAvailable: true }),                   // quiet (muted)
  row({ pkg: "skip", latest: "2.0", updateAvailable: true }),                    // quiet (skipped)
  row({ pkg: "waiting", source: "indicator", latest: "3.0", updateAvailable: true, installable: false }), // waiting
  row({ pkg: "failed", error: "feed down", stale: true, latest: "1.0.0" }),      // error, stale
  row({ pkg: "mutedfail", error: "feed down", stale: true }),                    // muted error
  row({ pkg: "mise:u", source: "mise", unchecked: true, installable: false, latest: "" }) // unchecked
]
const muted = ["muted", "mutedfail"], skipped = { skip: "2.0" }

test("count: rows that pass the test", () => {
  same(m.count(rows, app => app.source === "omarchy"), 5)
})

test("updateCount, waitingCount and quietCount leave quiet rows out", () => {
  same([m.updateCount(rows, muted, skipped), m.waitingCount(rows, muted, skipped), m.quietCount(rows, muted, skipped)], [1, 1, 2])
})

test("errorCount and mutedErrorCount split failures on mute", () => {
  same([m.errorCount(rows, muted), m.mutedErrorCount(rows, muted)], [1, 1])
})

test("uncheckedCount reads the unchecked field, not the note", () => {
  same([m.uncheckedCount(rows), m.uncheckedCount([row({ source: "mise", note: "Update check skipped" })])], [1, 0])
})

test("staleCount leaves muted rows out", () => {
  same(m.staleCount(rows, muted), 1)
})

// --- status.json -------------------------------------------------------------------------

test("parseStatus: an empty file is null, a broken one throws", () => {
  same([m.parseStatus("", true), m.parseStatus("  \n", true), m.parseStatus(null, true)], [null, null, null])
  assert.throws(() => m.parseStatus("{", true))
})

test("parseStatus: the fields the widget reads", () => {
  const status = m.parseStatus(JSON.stringify({
    schemaVersion: 1, checkedAt: "2026-10-07T10:00:00+00:00", startedAt: "2026-10-07T09:59:00+00:00", checking: true,
    omarchyPkgs: { commit: "abc", following: true, error: "e", note: "n" }, discoveryError: "d", miseError: "m", runError: "r",
    apps: [row({}), null, 5, row({ pkg: "mise:x", source: "mise" })]
  }), true)
  same(status, {
    schemaVersion: 1, apps: [row({}), row({ pkg: "mise:x", source: "mise" })], checkedAt: "2026-10-07T10:00:00+00:00",
    checking: true, startedMs: Date.parse("2026-10-07T09:59:00+00:00"), pkgsCommit: "abc", pkgsFollowing: true,
    pkgsError: "e", pkgsNote: "n", discoveryError: "d", miseError: "m", runError: "r"
  })
})

test("parseStatus: no schemaVersion (an older file) is 0", () => {
  same([m.parseStatus("{}", true).schemaVersion, m.parseStatus('{"schemaVersion": "x"}', true).schemaVersion,
    m.parseStatus('{"schemaVersion": 2}', true).schemaVersion, m.parseStatus("[]", true).schemaVersion], [0, 0, 2, 0])
})

test("parseStatus: Show mise tools off drops mise rows and mise's error", () => {
  const status = m.parseStatus(JSON.stringify({ miseError: "m", apps: [row({}), row({ pkg: "mise:x", source: "mise" })] }), false)
  same([status.apps.length, status.miseError, status.checkedAt, status.startedMs], [1, "", "", 0])
})

test("checkDue: due with no check, not within the interval less 30 s", () => {
  const now = Date.parse("2026-10-07T12:00:00Z")
  same([m.checkDue(now, "", 0, 3600), m.checkDue(now, "2026-10-07T11:30:00Z", 0, 3600),
    m.checkDue(now, "2026-10-07T11:00:20Z", 0, 3600), m.checkDue(now, "2026-10-07T11:00:40Z", 0, 3600)], [true, false, true, false])
})

test("checkDue: counts from the start, unless the run died past its end; a future time proves nothing", () => {
  const now = Date.parse("2026-10-07T12:00:00Z")
  same([m.checkDue(now, "2026-10-07T11:30:00Z", Date.parse("2026-10-07T10:55:00Z"), 3600),
    m.checkDue(now, "2026-10-07T11:30:00Z", Date.parse("2026-10-07T11:45:00Z"), 3600),
    m.checkDue(now, "2026-10-07T13:00:00Z", 0, 3600)], [true, false, true])
})

test("failureText: the checker's error first, a source failure only while not all muted", () => {
  const f = { checkError: "", runError: "", pkgsError: "", miseError: "" }
  const apps = [row({ pkg: "a" }), row({ pkg: "mise:b", source: "mise" })]
  same([m.failureText(Object.assign({}, f, { checkError: "c", runError: "r" }), apps, []),
    m.failureText(Object.assign({}, f, { runError: "r", pkgsError: "p" }), apps, []),
    m.failureText(Object.assign({}, f, { pkgsError: "p", miseError: "m" }), apps, []),
    m.failureText(Object.assign({}, f, { pkgsError: "p", miseError: "m" }), apps, ["a"]),
    m.failureText(Object.assign({}, f, { pkgsError: "p", miseError: "m" }), apps, ["a", "mise:b"]),
    m.failureText(f, apps, [])], ["c", "r", "p", "m", "", ""])
})

// --- rows -----------------------------------------------------------------------------------

const indicator = row({ pkg: "kimi", installedName: "kimi", source: "indicator", installable: false, latest: "2.0", updateAvailable: true })
const pinned = row({ pkg: "mise:codex", source: "mise", installed: "1.0", latest: "1.2", installable: true, updateAvailable: false })
const pinnedNoRoute = Object.assign({}, pinned, { installable: false })

test("updatable: an update the plugin installs", () => {
  same([m.updatable(update), m.updatable(indicator), m.updatable(row({})), m.updatable(null)], [true, false, false, false])
})

test("askable: an update with no install path, or a mise tool held below a newer release", () => {
  same([m.askable(indicator), m.askable(update), m.askable(pinnedNoRoute), m.askable(Object.assign({}, pinnedNoRoute, { error: "x" })),
    m.askable(row({ source: "self", installable: false, updateAvailable: true })), m.askable(Object.assign({}, indicator, { held: true })),
    m.askable(Object.assign({}, indicator, { omarchyUpdate: true })), m.askable(null)],
    [true, false, true, false, false, false, false, false])
})

test("hasAction and primaryAction: Update, Ask agent or Switch", () => {
  const sw = row({ installedName: "app-bin", switchable: true })
  same([update, indicator, sw, row({})].map(a => m.hasAction(a)), [true, true, true, false])
  same([update, indicator, sw, null].map(a => m.primaryAction(a)), ["update", "ask", "", ""])
})

test("firstActionIndex: the first row with something to do that is not quiet", () => {
  same([m.firstActionIndex([row({}), update, indicator], [], {}), m.firstActionIndex([row({}), update, indicator], ["claude-desktop"], {}),
    m.firstActionIndex([row({})], [], {}), m.firstActionIndex([], [], {})], [1, 2, 0, 0])
})

const renamed = row({ pkg: "chatgpt", installedName: "chatgpt-desktop", installed: "1.0.0-1", latest: "1.1.0", updateAvailable: true, note: "Recipe at abc" })
const sameVersion = row({ pkg: "z-code", source: "vendor-pkg", installedName: "z-code-bin", installed: "2.0-1", latest: "2.0", switchable: true })

test("switchClause: Update switches when newer, switch at the same version", () => {
  same([m.switchClause(renamed), m.switchClause(sameVersion)],
    ["Installed as chatgpt-desktop, Update switches to chatgpt", "Installed as z-code-bin, switch to z-code"])
})

test("switchClause: none for mise, an indicator, no install path, the same name or nothing to switch", () => {
  same([m.switchClause(Object.assign({}, renamed, { source: "mise" })), m.switchClause(Object.assign({}, renamed, { source: "indicator" })),
    m.switchClause(Object.assign({}, renamed, { installable: false })), m.switchClause(Object.assign({}, renamed, { installedName: "chatgpt" })),
    m.switchClause(Object.assign({}, sameVersion, { switchable: false })), m.switchClause(null)], ["", "", "", "", "", ""])
})

test("fullNote: the clause, then the checker's note; an older file has it already", () => {
  same([m.fullNote(renamed, 1), m.fullNote(sameVersion, 1), m.fullNote(row({ note: "n" }), 1), m.fullNote(renamed, 0)],
    ["Installed as chatgpt-desktop, Update switches to chatgpt; Recipe at abc", "Installed as z-code-bin, switch to z-code", "n", "Recipe at abc"])
})

test("shortNote: the name it is installed as, else the note's first clause", () => {
  same([m.shortNote(renamed, 1), m.shortNote(row({ note: "a; b" }), 1),
    m.shortNote(row({ note: "Installed as x, switch to app; b" }), 0)], ["Installed as chatgpt-desktop", "a", "Installed as x, switch to app"])
})

test("installedText: no pkgrel, unless it is the only difference; mise as is", () => {
  same([m.installedText(update), m.installedText(row({ installed: "1.0.0-2", latest: "1.0.0", updateAvailable: true })),
    m.installedText(row({ source: "mise", installed: "2.0-1" })), m.installedText(null)], ["1.0.0", "1.0.0-2", "2.0-1", ""])
})

test("extraLine: the row's exception, in order", () => {
  same([m.extraLine(row({ checking: true, error: "e" }), 1, "n"), m.extraLine(row({ error: "e" }), 1, "Prompt copied"),
    m.extraLine(row({ error: "e", note: "x" }), 1, ""), m.extraLine(renamed, 1, undefined), m.extraLine(indicator, 1, ""),
    m.extraLine(row({ stale: true }), 1, ""), m.extraLine(row({}), 1, ""), m.extraLine(null, 1, "")],
    ["Checking…", "Prompt copied", "Check failed: e", "Installed as chatgpt-desktop", "No install route", "Last known version", "", ""])
})

test("sourceLabel: where the newest version came from", () => {
  same([row({ stale: true }), row({ versionFrom: "mise" }), row({}), row({ versionFrom: "x" }), row({ versionFrom: "" })].map(a => m.sourceLabel(a)),
    ["an earlier check", "mise", "the vendor's release feed", "x", ""])
})

test("rowTooltip: a renamed row's route and the composed note", () => {
  same(m.rowTooltip(Object.assign({}, renamed, { recipe: "chatgpt" }), 1, [], {}, "0123456789abcdef"), [
    "Installed 1.0.0-1 as chatgpt-desktop", "Newest 1.1.0 from the vendor's release feed",
    "Updates through Omarchy's recipe chatgpt at 0123456", "Installed as chatgpt-desktop, Update switches to chatgpt; Recipe at abc"].join("\n"))
})

test("rowTooltip: no Update, held, and quiet rows", () => {
  same(m.rowTooltip(Object.assign({}, indicator, { note: "No supported install path" }), 1, ["kimi"], {}, ""), [
    "Installed 1.0.0-1", "Newest 2.0 from the vendor's release feed", "No Update here: No supported install path",
    "Muted: no badge, no notification"].join("\n"))
  same(m.rowTooltip(row({ held: true, installable: false, note: "held; b", latest: "2.0", updateAvailable: true }), 1, [], { app: "2.0" }, ""), [
    "Installed 1.0.0-1", "Newest 2.0 from the vendor's release feed", "No Update yet: held", "held; b",
    "Skipped 2.0: no badge, no notification until a newer version"].join("\n"))
})

test("rowTooltip: mise, vendor and Omabump's own rows, and a failure", () => {
  same(m.rowTooltip(Object.assign({}, miseUpdate, { installedName: "claude" }), 1, [], {}, ""),
    "Installed 2.0.0\nNewest 2.0.1 from mise\nUpdates with mise up")
  same(m.rowTooltip(row({ source: "vendor-pkg", error: "e", stale: true }), 1, [], {}, ""),
    "Installed 1.0.0-1\nNewest 1.0.0 from an earlier check\nUpdates with the vendor's Arch package\nCheck failed: e")
  same(m.rowTooltip(row({ source: "self", installable: false, latest: "" }), 1, [], {}, ""), "Installed 1.0.0-1\nomarchy update does not update plugins")
  same(m.rowTooltip(null, 1, [], {}, ""), "")
})

test("iconPathOk: relative paths inside the plugin only", () => {
  same(["assets/a.svg", "", "/etc/a.svg", "file:a", "a\\b", "assets/../../a.svg", "..a/b.svg"].map(p => m.iconPathOk(p)),
    [true, false, false, false, false, false, true])
})

test("iconPath: the light twin on a light surface, nothing unsafe", () => {
  const app = row({ icon: "assets/codex.svg", iconLight: "assets/codex-light.svg" })
  same([m.iconPath(app, false), m.iconPath(app, true), m.iconPath(row({ icon: "/x.svg" }), false), m.iconPath(null, true)],
    ["assets/codex.svg", "assets/codex-light.svg", "", ""])
})

test("luminance: black is 0, white is 1", () => {
  same([m.luminance({ r: 0, g: 0, b: 0 }), m.luminance({ r: 1, g: 1, b: 1 }), m.luminance({ r: 0.5, g: 0.5, b: 0.5 }) < 0.5], [0, 1, true])
})

test("promptOutcome: the wrapper's first line says what happened", () => {
  same([m.promptOutcome("agent\nplan this\nplease"), m.promptOutcome("copied\n"), m.promptOutcome("noagent"),
    m.promptOutcome("error\nno check has run yet\n"), m.promptOutcome("error\n"), m.promptOutcome("")], [
    { prompt: "plan this\nplease" }, { note: "Prompt copied" }, { note: "No default agent set, prompt copied" },
    { note: "Prompt failed: no check has run yet" }, { note: "Prompt failed: error" }, { note: "Prompt failed: no output" }])
})

// --- panel text ----------------------------------------------------------------------------

test("clamp", () => {
  same([m.clamp(5, 0, 3), m.clamp(-1, 0, 3), m.clamp(2, 0, 3)], [3, 0, 2])
})

test("hintText: the keys the cursor's row takes", () => {
  same([m.hintText(true, update, 3, [], {}), m.hintText(false, update, 3, [], {}), m.hintText(false, update, 3, ["claude-desktop"], { "claude-desktop": "1.1.0" }),
    m.hintText(false, indicator, 3, [], {}), m.hintText(false, sameVersion, 3, [], {}), m.hintText(false, row({}), 3, [], {}),
    m.hintText(false, null, 3, [], {}), m.hintText(false, null, 0, [], {})], [
    "Space change · Esc back", "Enter update · K skip · m mute · Esc close", "Enter update · K unskip · m unmute · Esc close",
    "Enter ask agent · c copy prompt · K skip · m mute", "w switch package · m mute · Esc close",
    "↑↓ select · r refresh · s settings · m mute", "↑↓ select · r refresh · s settings", "r refresh · s settings"])
})

test("checkedText: how long ago the last check ended", () => {
  const now = Date.parse("2026-10-07T12:00:00Z")
  same([m.checkedText(true, "", now), m.checkedText(false, "", now), m.checkedText(false, "nonsense", now),
    m.checkedText(false, "2026-10-07T11:59:30Z", now), m.checkedText(false, "2026-10-07T11:15:00Z", now),
    m.checkedText(false, "2026-10-07T07:00:00Z", now), m.checkedText(false, "2026-10-04T12:00:00Z", now),
    m.checkedText(false, "2026-10-07T13:00:00Z", now)],
    ["checking", "not checked yet", "", "checked just now", "checked 45 min ago", "checked 5 h ago", "checked 3 d ago", "checked just now"])
})

test("intervalLabel and intervalOptions: a hand-set value stays selectable", () => {
  same([m.intervalLabel(7200), m.intervalLabel(300), m.intervalLabel(90)], ["2 h", "5 min", "90 s"])
  same(m.intervalOptions([300, 3600], 3600), [{ value: "300", label: "5 min" }, { value: "3600", label: "1 h" }])
  same(m.intervalOptions([300, 3600], 90), [{ value: "90", label: "90 s" }, { value: "300", label: "5 min" }, { value: "3600", label: "1 h" }])
})

// The checker's state as Main.qml's summary holds it.
function summary(fields) {
  return Object.assign({
    checking: false, checkFailed: false, checkedAt: "2026-10-07T11:00:00Z", appCount: 3, updateCount: 0, waitingCount: 0,
    quietCount: 0, errorCount: 0, mutedErrorCount: 0, uncheckedCount: 0, staleCount: 0, pkgsFollowing: false, discoveryError: ""
  }, fields)
}

test("quietNote: muted and skipped updates, and with failures a muted row's failure", () => {
  const s = summary({ quietCount: 2, mutedErrorCount: 1 })
  same([m.quietNote(s, false), m.quietNote(s, true), m.quietNote(summary({ mutedErrorCount: 2 }), true), m.quietNote(summary({}), true)],
    [" (+2 muted/skipped)", " (+2 muted/skipped, check failed for 1 muted app)", " (check failed for 2 muted apps)", ""])
})

test("heroState: one state, the most pressing", () => {
  same([summary({ checkFailed: true, updateCount: 2 }), summary({ updateCount: 1 }), summary({ updateCount: 1, waitingCount: 1 }),
    summary({ staleCount: 1, errorCount: 1 }), summary({ errorCount: 1 }), summary({ checkedAt: "" }), summary({ uncheckedCount: 2 }),
    summary({}), summary({ appCount: 0 })].map(s => m.heroState(s, "checked 5 min ago")),
    ["Check failed", "1 update", "2 updates", "Last known, checked 5 min ago", "Check failed", "Not checked yet",
      "All checked current, 2 unchecked", "All current", ""])
})

test("heroMeta: Settings, Checking…, or the state and what quiet rows hold back", () => {
  same([m.heroMeta(summary({ checking: true }), true, ""), m.heroMeta(summary({ checking: true }), false, ""),
    m.heroMeta(summary({ quietCount: 1, mutedErrorCount: 1 }), false, ""), m.heroMeta(summary({ checkedAt: "", quietCount: 1 }), false, ""),
    m.heroMeta(summary({ appCount: 0 }), false, "")], ["Settings", "Checking…", "All current (+1 muted/skipped)", "Not checked yet", ""])
})

test("summaryText: the full count for the tooltip and IPC status", () => {
  same([summary({ updateCount: 2, waitingCount: 1, errorCount: 1, staleCount: 1, uncheckedCount: 1, quietCount: 1 }),
    summary({ checkFailed: true, errorCount: 1 }), summary({ errorCount: 2 }), summary({ uncheckedCount: 1 }),
    summary({ mutedErrorCount: 1 }), summary({ checkedAt: "" }), summary({ appCount: 0 })].map(s => m.summaryText(s)), [
    "2 updates, 1 newer without an install path, check failed for 1 app, last known for 1 app, 1 unchecked (+1 muted/skipped)",
    "check failed", "check failed for 2 apps", "All checked current, 1 unchecked", "All current (check failed for 1 muted app)", "", ""])
})

test("followingText and discoveryText: the footer lines", () => {
  same([m.followingText(summary({ pkgsFollowing: true })), m.followingText(summary({})),
    m.discoveryText(summary({ discoveryError: "no menu" })), m.discoveryText(summary({}))],
    ["omarchy-pkgs: following master (unpinned)", "", "Agent discovery: no menu", ""])
})

test("tooltipText: the bar icon's tooltip and IPC status", () => {
  same([summary({}), summary({ quietCount: 1 }), summary({ updateCount: 1 }), summary({ checkedAt: "" }), summary({ appCount: 0 }),
    summary({ pkgsFollowing: true, discoveryError: "d" })].map(s => m.tooltipText(s)), [
    "Omabump up to date", "Omabump up to date (+1 muted/skipped)", "Omabump: 1 update", "Omabump: not checked yet",
    "Omabump: none installed", "Omabump up to date\nomarchy-pkgs: following master (unpinned)\nAgent discovery: d"])
})

test("every function in Model.js has a test", () => {
  same(Object.keys(m).filter(name => !called.has(name)), [])
})

console.log(`done\t${total}`)
process.exitCode = failed > 0 ? 1 : 0

# shellcheck shell=bash disable=SC2154 # root and the helpers come from tests/run.sh
# Sourced by tests/run.sh: where Main.qml or Model.js repeats a rule of the
# scripts, the two must agree. The QML itself needs a shell to run, so these
# read it; Model.js runs under node (tests/model.test.mjs), when node is here.

# --- Main.qml and the scripts -------------------------------------------------

# Every check, a Refresh's too, runs under the deadline bin/omabump-check
# names: the installer and other bars wait for a check on that bound.
# shellcheck disable=SC2016 # the literal text of the comment
same "Main.qml runs checks under the deadline bin/omabump-check names" \
  "$(grep -o 'under `timeout -k [0-9]* [0-9]*`' "$root/bin/omabump-check" | grep -o 'timeout[^`]*')" \
  "$(grep -o '"timeout", "-k", "[0-9]*", "[0-9]*", checkScript' "$root/Main.qml" | sed 's/, checkScript//' | tr -d '",')"

# A Refresh waits for a running check on the checker's lock, as long as the
# checker's own --wait would.
qml_state=$XDG_STATE_HOME$(sed -n 's|^    + "\(/omarchy/plugins/[^"]*\)"$|\1|p' "$root/Main.qml")
qml_lock=$qml_state$(sed -n 's|^  readonly property string lockPath: stateDir + "\([^"]*\)"$|\1|p' "$root/Main.qml")
# shellcheck disable=SC2016 # the literal text of the script
same "Main.qml waits on the checker's lock" \
  "$state_dir/$(sed -n 's|^exec 9>"$state_dir/\([^"]*\)"$|\1|p' "$root/bin/omabump-check")" "$qml_lock"
same "Main.qml waits as long as the checker's --wait" \
  "$(grep -o 'flock -w [0-9]*' "$root/bin/omabump-check" | grep -o '[0-9]*$')" \
  "$(sed -n 's/^  readonly property int lockWaitSec: \([0-9]*\)$/\1/p' "$root/Main.qml")"

# waitScript, run as Main.qml runs it: lock, seconds, then the command.
wait_script=$(sed -n "s/^  readonly property string waitScript: '\(.*\)'$/\1/p" "$root/Main.qml")
wait_lock=$scratch/wait/.check.lock
mkdir -p "$scratch/wait"
run_wait() { bash -c "$wait_script" omabump-wait "$@" | paste -sd'|'; }
# Waits up to 5 s for a file to appear.
until_exists() { local _; for _ in {1..250}; do [[ -e $1 ]] && return; sleep 0.02; done; }
# Holds the lock in the background until let_go, and writes "released" just
# before it lets go. Its waits are bounded, so a holder that breaks fails a
# test instead of hanging the suite.
hold_lock() {
  rm -f "$scratch/wait/held" "$scratch/wait/go" "$scratch/wait/released"
  (exec 8>"$wait_lock" && flock 8 && : >"$scratch/wait/held" && until_exists "$scratch/wait/go"
   echo released >"$scratch/wait/released") &
  holder=$!
  until_exists "$scratch/wait/held"
}
let_go() { : >"$scratch/wait/go"; wait "$holder"; }

same "waitScript: a free lock runs the command at once" "started|a b" "$(run_wait "$wait_lock" 5 echo a b)"
hold_lock
(sleep 0.3; : >"$scratch/wait/go") &
same "waitScript: a held lock is waited for, then the command runs" "started|released" \
  "$(run_wait "$wait_lock" 5 cat "$scratch/wait/released")"
let_go
# Its exit for a lock held past the wait is the one Model.js reads as a
# check that never ran: the -E, the test and the exit in it all count.
busy_exit=$(sed -n 's/^var lockBusyExit = \([0-9]*\)$/\1/p' "$root/Model.js")
hold_lock
same "waitScript: a lock held past the wait runs nothing and exits Model.lockBusyExit" "exit ${busy_exit:-none}" \
  "$(bash -c "$wait_script" omabump-wait "$wait_lock" 0.2 echo ran; echo "exit $?")"
let_go
check "Main.qml reads a check's exit through Model.checkOutcome" \
  grep -q 'Model.checkOutcome(exitCode, root.runWaiting, root.runForRefresh)' "$root/Main.qml"
same "waitScript: no lock directory yet, nothing to wait for" "started|ran" \
  "$(run_wait "$scratch/wait/none/.check.lock" 5 echo ran)"
same "waitScript: the command's exit status is the run's" "started|exit 3" \
  "$( { bash -c "$wait_script" omabump-wait "$wait_lock" 5 bash -c 'exit 3'; echo "exit $?"; } | paste -sd'|')"

# The panel decides skips between checks: mise and self versions as strings,
# every other source with vercmp, as row_skipped does.
qml_strings=$(grep -o '^function stringVersions(source) { return source === "[a-z-]*" || source === "[a-z-]*" }$' "$root/Model.js" \
  | grep -o '"[a-z-]*"' | tr -d '"' | sort | paste -sd' ')
script_strings=$(for source in $(jq -r '.[].source' "$root/apps.json" | sort -u) self; do
  string_versions "$source" && echo "$source"
done | sort | paste -sd' ')
same "Model.js compares the same sources' skips as strings as the checker" "$script_strings" "$qml_strings"
check "Model.js decides skips by stringVersions" grep -q 'if (stringVersions(app.source)) return app.updateAvailable === true && latest === version' "$root/Model.js"

# status.json's runError: the checker writes the field (tests/check.sh runs
# it), and Model.js must read the same name.
check "Model.js reads the runError field bin/omabump-check writes" \
  grep -q 'file.runError' "$root/Model.js"
check "bin/omabump-check writes runError into status.json" \
  grep -q 'runError: \$rerr' "$root/bin/omabump-check"

# The widget reads states from status.json's fields, never from the
# checker's wording: no "Update check skipped" prefix for unchecked, no
# pattern that strips a switch clause out of a note.
refuse "the widget recognises no state by the checker's wording" \
  grep -qE 'Update check skipped|\(Update switches\|switch\)' "$root/Main.qml" "$root/Panel.qml" "$root/Model.js"

# Every Model.x the QML reads is a function or value Model.js defines: a
# typo would show only as a binding error in the shell's log.
model_missing=$(comm -23 \
  <(grep -ho 'Model\.[A-Za-z]*' "$root/Main.qml" "$root/Panel.qml" | grep -vx 'Model\.js' | sed 's/^Model\.//' | sort -u) \
  <(sed -n 's/^function \([A-Za-z]*\)(.*/\1/p; s/^var \([A-Za-z]*\) = .*/\1/p' "$root/Model.js" | sort -u) | paste -sd' ')
same "Main.qml and Panel.qml read only what Model.js defines" "" "$model_missing"
check "and they read some" grep -q 'Model\.tooltipText(' "$root/Panel.qml"

same "Model.js caps the quiet settings where load_quiet does" "$quiet_max" \
  "$(sed -n 's/^var quietMax = \([0-9]*\)$/\1/p' "$root/Model.js")"

# tests/vercmp.tsv holds vercmp's own answers, so Model.js's port is tested
# against the real thing (tests/model.test.mjs). The fields are split by
# hand: read would merge the tabs around an empty version.
vercmp_wrong=""
while IFS= read -r line; do
  [[ $line == '#'* || -z $line ]] && continue
  a=${line%%$'\t'*} rest=${line#*$'\t'}
  b=${rest%%$'\t'*} want=${rest#*$'\t'}
  got=$(vercmp "$a" "$b")
  (( got > 0 )) && got=1
  (( got < 0 )) && got=-1
  [[ $got == "$want" ]] || vercmp_wrong+="[$a $b: $got, not $want] "
done <"$root/tests/vercmp.tsv"
same "tests/vercmp.tsv: every pair is what vercmp answers" "" "$vercmp_wrong"

# --- Model.js under node -------------------------------------------------------

if ! command -v node >/dev/null 2>&1; then
  # A skip there would pass unseen: CI must install node.
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    fail "Model.js tests run on CI" "node is not installed"
  else
    echo "SKIP - Model.js tests and their checks against the scripts: node is not installed"
  fi
else
  # One harness test per line tests/model.test.mjs prints.
  model_out=$(node "$root/tests/model.test.mjs" </dev/null 2>&1)
  model_rc=$? model_done=0 model_failed=0
  while IFS=$'\t' read -r verdict name why; do
    case $verdict in
      ok) pass "Model.js: $name" ;;
      "not ok") fail "Model.js: $name" "$why"; model_failed=1 ;;
      done) model_done=1 ;;
    esac
  done <<<"$model_out"
  if (( ! model_done || (model_rc != 0 && ! model_failed) )); then
    fail "Model.js: tests/model.test.mjs ran to the end" "exit $model_rc: $(head -c 400 <<<"$model_out")"
  fi

  # model_call <function>: Model.js's answer to each line of stdin, a JSON
  # array of arguments.
  model_call() { node "$root/tests/model.mjs" "$1"; }

  # The ids and versions load_quiet keeps, by the scripts' own functions.
  model_ids=(claude-desktop z-code-bin mise:claude mise: mise:-x mise:npm:x self:omabump self:other github:x
    -x .x _x @x +x a..b A a.B 'a b' a/b é '' x:y 0)
  same "Model.appIdOk accepts the ids app_id_ok accepts" \
    "$(for id in "${model_ids[@]}"; do if app_id_ok "$id"; then echo true; else echo false; fi; done)" \
    "$(for id in "${model_ids[@]}"; do jq -cn --arg v "$id" '[$v]'; done | model_call appIdOk)"
  model_versions=(1.0 1.0.0-beta.1 v1 1.0~rc1 1+2_3 -1 .1 1..2 1:2 '1 0' '' é1 1é
    "$(printf '1%.0s' {1..64})" "$(printf '1%.0s' {1..65})")
  same "Model.skipVersionOk accepts the versions skip_version_ok accepts" \
    "$(for v in "${model_versions[@]}"; do if skip_version_ok "$v"; then echo true; else echo false; fi; done)" \
    "$(for v in "${model_versions[@]}"; do jq -cn --arg v "$v" '[$v]'; done | model_call skipVersionOk)"

  # load_quiet and Model.js read the same shell.json entry alike: wrong
  # types, refused ids and versions, and the cap on each setting. Prints
  # load_quiet's mutes and skips, then Model.js's, one line each.
  model_quiet() {
    local entry
    jq '{plugins: [{id: "io.github.vladkarok.omabump"} + .]}' >"$shell_json"
    load_quiet 2>/dev/null
    echo "$(jq -c 'sort' <<<"$muted_json") $(jq -cS . <<<"$skipped_json")"
    entry=$(jq -c '[.plugins[0]]' "$shell_json")
    echo "$(model_call mutedApps <<<"$entry" | jq -c 'sort') $(model_call skippedVersions <<<"$entry" | jq -cS .)"
  }
  model_pair=$(jq -n '{mutedApps: ["a", 1, "Bad", "mise:x", "", "a", "self:omabump", "x y", null, "mise:"],
    skippedVersions: {a: "1.0", "mise:b": "2.0-beta.1", Bad: "1.0", c: "1..2", d: 3, e: "", "self:omabump": "0.2.0", f: "v1 "}}' | model_quiet)
  same "Model.js keeps the mutes and skips load_quiet keeps" "$(sed -n 1p <<<"$model_pair")" "$(sed -n 2p <<<"$model_pair")"
  model_pair=$(jq -n '{mutedApps: ([range(150) | "Bad\(.)", .] + [range(100) | "ok\(.)"]),
    skippedVersions: ([range(150) | {key: "bad-\(.)", value: "1..2"}, {key: "num-\(.)", value: 1}]
      + [range(100) | {key: "ok-\(.)", value: "1.0"}] | from_entries)}' | model_quiet)
  same "Model.js caps the mutes and skips as load_quiet does" "$(sed -n 1p <<<"$model_pair")" "$(sed -n 2p <<<"$model_pair")"
  same "and the cap leaves 50 of each" "50 50" "$(sed -n 2p <<<"$model_pair" | jq -rs '"\(.[0] | length) \(.[1] | length)"')"
  rm -f "$shell_json"
  load_quiet
fi
check "bin/omabump-check writes schemaVersion 1, the shape Model.parseStatus reads" \
  grep -q '{schemaVersion: 1,' "$root/bin/omabump-check"
check "Model.js reads status.json's schemaVersion" grep -q 'schemaVersion' "$root/Model.js"

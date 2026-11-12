# shellcheck shell=bash disable=SC2154 # root and the helpers come from tests/run.sh
# Sourced by tests/run.sh: where Main.qml or Model.js repeats a rule of the
# scripts, the two must agree. The QML itself needs a shell to run, so these
# read it; tests/model.sh runs Model.js under node, and the panel's pointer
# test runs offscreen below.

# --- Main.qml and the scripts -------------------------------------------------

# Every check, a Refresh's too, runs under the deadline bin/omabump-check
# names: the installer and other bars wait for a check on that bound.
# shellcheck disable=SC2016 # the literal text of the comment
same "Main.qml runs checks under the deadline bin/omabump-check names" \
  "$(grep -o 'under `timeout -k [0-9]* [0-9]*`' "$root/bin/omabump-check" | grep -o 'timeout[^`]*')" \
  "$(grep -o '"timeout", "-k", "[0-9]*", "[0-9]*", checkScript\]' "$root/Main.qml" | sed 's/, checkScript]//' | tr -d '",')"
# A check that finds a local refresh holding the lock waits for it as long
# as Main.qml lets one run: its deadline, then the KILL after it. So does
# an --if-due run, so both waits name the one time.
same "a check waits for a local refresh as long as Main.qml lets one run" \
  "$(sed -n 's/^  flock -w \([0-9]*\) 6 || true$/\1/p' "$root/bin/omabump-check" | sort -u)" \
  "$(sed -n 's/^    var command = \["timeout", "-k", "\([0-9]*\)", "\([0-9]*\)", checkScript, "--local"\]$/\1 \2/p' "$root/Main.qml" \
    | awk '{ print $1 + $2 }')"
# Every wait for the lock comes before that deadline, never under it: a
# wait the deadline cut short would read as a failed check (exit 124), not
# as one that never ran (exit 75). So waitScript comes first, and the
# checker never gets --wait.
check "Main.qml waits for the lock before the deadline starts" \
  grep -q 'command = \["bash", "-c", waitScript, "omabump-wait", lockPath, String(lockWaitSec)\].concat(command)$' "$root/Main.qml"
refuse "Main.qml never passes the checker --wait" grep -q -- '"--wait"' "$root/Main.qml"
# Whether a check, or a failed one's retry, is due is the checker's answer
# (--if-due), from the interval the widget's settings hold: without
# --interval the checker exits 2.
check "Main.qml asks the checker whether a check is due, with its interval" \
  grep -q 'if (ifDue) command.push("--if-due", "--interval", String(refreshIntervalSec))$' "$root/Main.qml"
# Until it says a check is due, that run shows as none (tests/check.sh
# runs the checker's word).
check "Main.qml counts the run as a check once the checker says due" \
  grep -q '^        else if (line === "due") root.runIfDue = false$' "$root/Main.qml"
check "and shows none before" grep -q '^  readonly property bool checking: checkProcess.running && !runIfDue || fileChecking$' "$root/Main.qml"
same "Model.js reads --if-due's exit by the number bin/omabump-check gives" \
  "$(sed -n 's/^not_due_exit=\([0-9]*\) .*/\1/p' "$root/bin/omabump-check")" \
  "$(sed -n 's/^var notDueExit = \([0-9]*\)$/\1/p' "$root/Model.js")"

# A Refresh waits for a running check on the checker's lock, as long as the
# checker's own --wait would.
qml_state=$XDG_STATE_HOME$(sed -n 's|^    + "\(/omarchy/plugins/[^"]*\)"$|\1|p' "$root/Main.qml")
qml_lock=$qml_state$(sed -n 's|^  readonly property string lockPath: stateDir + "\([^"]*\)"$|\1|p' "$root/Main.qml")
# shellcheck disable=SC2016 # the literal text of the script
same "Main.qml waits on the checker's lock" \
  "$state_dir/$(sed -n 's|^exec 9>"$state_dir/\([^"]*\)"$|\1|p' "$root/bin/omabump-check")" "$qml_lock"
same "Main.qml waits as long as the checker's --wait" \
  "$(sed -n 's/.*flock -w \([0-9]*\) 9; }.*/\1/p' "$root/bin/omabump-check")" \
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
same "waitScript: no lock directory yet, nothing to wait for" "started|ran" \
  "$(run_wait "$scratch/wait/none/.check.lock" 5 echo ran)"
same "waitScript: the command's exit status is the run's" "started|exit 3" \
  "$( { bash -c "$wait_script" omabump-wait "$wait_lock" 5 bash -c 'exit 3'; echo "exit $?"; } | paste -sd'|')"

# A local refresh (bin/omabump-check --local) is none of this shell's
# checks: its exit goes through Model.localOutcome by the checker's own
# numbers.
same "Model.js reads --local's exits by the numbers bin/omabump-check gives" \
  "$(sed -n 's/^full_check_exit=\([0-9]*\) no_status_exit=\([0-9]*\) pacman_busy_exit=\([0-9]*\)$/\1 \2 \3/p' "$root/bin/omabump-check")" \
  "$(sed -n 's/^var local\(Full\|NoStatus\|Retry\)Exit = \([0-9]*\)$/\2/p' "$root/Model.js" | paste -sd' ')"

# The checker decides whether a skip applies and writes it as each row's
# skipped; Model.js reads that field and compares no versions itself.
# tests/check.sh reads the fields the checker writes and tests/model.test.mjs
# feeds Model.js rows with them, so only these say both use one name.
check "Model.js reads the skipped field bin/omabump-check writes" grep -q 'app.skipped === true' "$root/Model.js"
check "bin/omabump-check writes skipped into every checked row" grep -q 'muted: \$muted, skipped: \$skipped' "$root/bin/omabump-check"
refuse "Model.js compares no versions" grep -qiE 'vercmp\(|rpmvercmp' "$root/Model.js"
# A skip leaves the settings only once a run read it and found it over.
check "Model.js drops a skip by the skipEnded field bin/omabump-check writes" grep -q 'app.skipEnded' "$root/Model.js"
check "bin/omabump-check writes skipEnded into every checked row" grep -q 'skipped: \$skipped, skipEnded: \$skipEnded' "$root/bin/omabump-check"
same "Model.js caps the quiet settings where load_quiet does" "$quiet_max" \
  "$(sed -n 's/^var quietMax = \([0-9]*\)$/\1/p' "$root/Model.js")"

# status.json's runError, and a row's selfUpdating, by the same name on
# both sides: the panel offers no Update or Switch for a selfUpdating row.
check "Model.js reads the runError field bin/omabump-check writes" grep -q 'file.runError' "$root/Model.js"
check "bin/omabump-check writes runError into status.json" grep -q 'runError: \$rerr' "$root/bin/omabump-check"
check "Model.js reads the selfUpdating field bin/omabump-check writes" \
  grep -q 'function selfUpdating(app) { return !!app && app.selfUpdating === true }' "$root/Model.js"
check "bin/omabump-check writes selfUpdating into every row" grep -q 'selfUpdating: \$selfUpdating, icon' "$root/bin/omabump-check"

# A row without Update has no action at all: the panel starts no agent.
refuse "the widget starts no coding agent" grep -qE 'omarchy-agent|omabump-prompt' "$root/Main.qml" "$root/Panel.qml"

# The widget reads states from status.json's fields, never from the
# checker's wording: no "Update check skipped" prefix for unchecked, no
# pattern that strips a switch clause out of a note.
refuse "the widget recognises no state by the checker's wording" \
  grep -qE 'Update check skipped|\(Update switches\|switch\)|(Update switches|switch) to "\)' \
  "$root/Main.qml" "$root/Panel.qml" "$root/Model.js"

# Every Model.x the QML reads is a function or value Model.js defines: a
# typo would show only as a binding error in the shell's log.
model_missing=$(comm -23 \
  <(grep -ho 'Model\.[A-Za-z]*' "$root/Main.qml" "$root/Panel.qml" | grep -vx 'Model\.js' | sed 's/^Model\.//' | sort -u) \
  <(sed -n 's/^function \([A-Za-z]*\)(.*/\1/p; s/^var \([A-Za-z]*\) = .*/\1/p' "$root/Model.js" | sort -u) | paste -sd' ')
same "Main.qml and Panel.qml read only what Model.js defines" "" "$model_missing"
check "and they read some" grep -q 'Model\.tooltipText(' "$root/Panel.qml"

# --- the cursor under the pointer, in Qt ---------------------------------------

# PointerGate.qml under Panel.qml's rows in miniature (tests/tst_pointer.qml),
# offscreen through qmltestrunner (qt6-declarative), one line per test.
# Qt 6's: /usr/bin/qmltestrunner is Qt 5's, when qt5-declarative is here.
qml_runner=$(command -v /usr/lib/qt6/bin/qmltestrunner || command -v qmltestrunner6 || true)
if [[ -z $qml_runner ]]; then
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    fail "QML tests run on CI" "qmltestrunner is not installed"
  else
    echo "SKIP - QML tests: qmltestrunner is not installed (qt6-declarative)"
  fi
else
  mkdir -p "$scratch/qt-runtime"
  chmod 700 "$scratch/qt-runtime"
  qml_out=$(env QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QML_DISABLE_DISK_CACHE=1 \
    XDG_RUNTIME_DIR="$scratch/qt-runtime" timeout 120 "$qml_runner" -input "$root/tests/tst_pointer.qml" </dev/null 2>&1)
  qml_rc=$?
  while IFS= read -r line; do
    name=${line#*::*::}
    case $line in
      "PASS   : "*) [[ $name == initTestCase* || $name == cleanupTestCase* ]] || pass "QML: ${name%%()*}" ;;
      "FAIL!  : "*) fail "QML: ${name%%()*}" "${name#*() }" ;;
    esac
  done <<<"$qml_out"
  grep -q '^Totals: ' <<<"$qml_out" || fail "QML: tests/tst_pointer.qml ran to the end" "exit $qml_rc: $(head -c 400 <<<"$qml_out")"
fi


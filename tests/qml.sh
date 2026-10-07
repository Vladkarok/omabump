# shellcheck shell=bash disable=SC2154 # root and the helpers come from tests/run.sh
# Sourced by tests/run.sh: where Main.qml repeats a rule of the scripts, the
# two must agree. The QML itself needs a shell to run, so these read it.

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
hold_lock
same "waitScript: a lock held past the wait runs nothing and exits 0" "exit 0" \
  "$(bash -c "$wait_script" omabump-wait "$wait_lock" 0.2 echo ran; echo "exit $?")"
let_go
same "waitScript: no lock directory yet, nothing to wait for" "started|ran" \
  "$(run_wait "$scratch/wait/none/.check.lock" 5 echo ran)"
same "waitScript: the command's exit status is the run's" "started|exit 3" \
  "$( { bash -c "$wait_script" omabump-wait "$wait_lock" 5 bash -c 'exit 3'; echo "exit $?"; } | paste -sd'|')"

# The panel decides skips between checks: mise and self versions as strings,
# every other source with vercmp, as row_skipped does.
qml_strings=$(grep -o 'if (app.source === "[a-z-]*" || app.source === "[a-z-]*") return app.updateAvailable === true && latest === version' "$root/Main.qml" \
  | grep -o '"[a-z-]*"' | tr -d '"' | sort | paste -sd' ')
script_strings=$(for source in $(jq -r '.[].source' "$root/apps.json" | sort -u) self; do
  string_versions "$source" && echo "$source"
done | sort | paste -sd' ')
same "Main.qml compares the same sources' skips as strings as the checker" "$script_strings" "$qml_strings"

# status.json's runError: the checker writes the field (tests/check.sh runs
# it), and Main.qml must read the same name.
check "Main.qml reads the runError field bin/omabump-check writes" \
  grep -q 'parsed.runError' "$root/Main.qml"
check "bin/omabump-check writes runError into status.json" \
  grep -q 'runError: \$rerr' "$root/bin/omabump-check"

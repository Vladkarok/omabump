# shellcheck shell=bash disable=SC2154 # root and the helpers come from tests/run.sh
# Sourced by tests/run.sh: where Main.qml or Model.js repeats a rule of the
# scripts, the two must agree. The QML itself needs a shell to run, so these
# run the command lines Model.js builds for it, or read it; tests/model.sh
# runs Model.js under node, and the panel's pointer test runs offscreen
# below.

# --- the checker's protocol, run ------------------------------------------------

# Main.qml runs bin/omabump-check by the command lines Model.checkCommand
# and Model.localCommand build, and reads its exits and its words on stdout
# by the names Model.js gives them. These run those command lines, and the
# checker directly where the widget never does, against fake tools (no
# network, nothing installed but what $proto/pkgs lists), and set what the
# checker does against what Model.js expects.
if ! command -v node >/dev/null 2>&1; then
  # A skip there would pass unseen: CI must install node.
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    fail "the checker's protocol tests run on CI" "node is not installed"
  else
    echo "SKIP - the checker's protocol against Model.js: node is not installed"
  fi
else
  # model_value <name>: a Model.js value, as JSON. model_call <function>:
  # its answer to each line of stdin, a JSON array of arguments.
  model_value() { node "$root/tests/model.mjs" "$1" </dev/null; }
  model_call() { node "$root/tests/model.mjs" "$1"; }
  busy_exit=$(model_value lockBusyExit) not_due_exit=$(model_value notDueExit)
  local_codes=$(for v in localFullExit localNoStatusExit localRetryExit; do model_value "$v"; done | paste -sd' ')
  lock_wait=$(model_value lockWaitSec) kill_after=$(model_value killAfterSec)
  check_deadline=$(model_value checkDeadlineSec) local_deadline=$(model_value localDeadlineSec)
  started_word=$(model_value startedWord | jq -r .) due_word=$(model_value dueWord | jq -r .)
  wait_script=$(model_value waitScript | jq -r .)

  # The fake tools. pacman knows only $proto/pkgs, and its lock is
  # $proto/pacman-db/db.lck. flock, first on PATH only for proto_flock's
  # runs, notes each call's arguments in $proto/flock.log and waits 0.2 s
  # where it was asked to wait longer, so a held lock reads as one held past
  # the wait without the wait.
  proto=$scratch/proto
  mkdir -p "$proto/bin" "$proto/flock" "$proto/home" "$proto/pacman-db"
  cat >"$proto/bin/pacman" <<'PACMAN'
#!/bin/sh
[ "$1" = -Q ] || exit 1
awk -v n="$3" '$1 == n { print; found = 1 } END { exit !found }' "$OMABUMP_TEST_PKGS"
PACMAN
  printf '#!/bin/sh\necho "%s/pacman-db/"\n' "$proto" >"$proto/bin/pacman-conf"
  printf '#!/bin/sh\nexit 7\n' >"$proto/bin/curl"
  printf '#!/bin/sh\nexit 1\n' | tee "$proto/bin/git" "$proto/bin/sudo" >/dev/null
  printf '#!/bin/sh\necho "{}"\n' >"$proto/bin/mise"
  real_flock=$(command -v flock)
  # shellcheck disable=SC2016 # the fake flock's text, expanded by its sh
  printf '#!/bin/sh\necho "$*" >>"%s/flock.log"\nif [ "$1" = -w ]; then shift 2; exec "%s" -w 0.2 "$@"; fi\nexec "%s" "$@"\n' \
    "$proto" "$real_flock" "$real_flock" >"$proto/flock/flock"
  chmod +x "$proto/bin/"* "$proto/flock/flock"
  : >"$proto/pkgs"
  proto_env=(HOME="$proto/home" XDG_CONFIG_HOME="$proto/config" XDG_STATE_HOME="$proto/state"
    XDG_CACHE_HOME="$proto/cache" OMARCHY_PATH="$proto/omarchy" OMABUMP_TEST_PKGS="$proto/pkgs")
  # The state directory and the lock as Main.qml names them, under this
  # XDG_STATE_HOME: the lock a Refresh waits on, the file it watches.
  qml_dir=$(sed -n 's|^    + "\(/omarchy/plugins/[^"]*\)"$|\1|p' "$root/Main.qml")
  qml_lock=$(sed -n 's|^  readonly property string lockPath: stateDir + "\([^"]*\)"$|\1|p' "$root/Main.qml")
  qml_status=$(sed -n 's|^  readonly property string statusPath: stateDir + "\([^"]*\)"$|\1|p' "$root/Main.qml")
  check "Main.qml's state directory, lock and status file are read from it" test -n "$qml_dir" -a -n "$qml_lock" -a -n "$qml_status"
  qml_lock=$proto/state$qml_dir$qml_lock qml_status=$proto/state$qml_dir$qml_status
  check_script=$root/bin/omabump-check

  # proto_run <command...>: runs it as the shell would, stdout to
  # $proto/out, stderr to $proto/err; prints its exit. proto_flock runs it
  # with the noting flock, from an empty $proto/flock.log.
  proto_run() {
    env "${proto_env[@]}" PATH="$proto/bin:$PATH" timeout -k 5 120 "$@" </dev/null >"$proto/out" 2>"$proto/err"
    echo $?
  }
  proto_flock() {
    : >"$proto/flock.log"
    env "${proto_env[@]}" PATH="$proto/flock:$proto/bin:$PATH" timeout -k 5 120 "$@" </dev/null >"$proto/out" 2>"$proto/err"
    echo $?
  }
  # widget_command <function> <arguments as JSON>: the command line Model.js
  # builds, into the array cmd. check_args <options as JSON> and local_args:
  # Main.qml's arguments to checkCommand and to localCommand (Show mise
  # tools off).
  widget_command() { mapfile -d '' cmd < <(model_call "$1" <<<"$2" | jq -j '.[] | ., "\u0000"'); }
  check_args() { jq -nc --arg c "$check_script" --arg l "$qml_lock" --argjson o "$1" '[$c, $l, $o]'; }
  local_args=$(jq -nc --arg c "$check_script" '[$c, false]')
  # The waits the checker asked flock for, on fd <n>, in the last
  # proto_flock run.
  flock_waits() { sed -n "s/^-w \([0-9]*\) $1\$/\1/p" "$proto/flock.log" | sort -u | paste -sd' '; }
  # outcome <function> <exit> [waited]: what Model.js makes of the exit.
  outcome() { model_call "$1" <<<"[$2${3:+, $3}]" | jq -r .; }
  timer_opts='{"wait": false, "ifDue": true, "intervalSec": 3600, "notify": false, "showMise": false}'

  # Waits up to 5 s for a file to appear.
  until_exists() { local _; for _ in {1..250}; do [[ -e $1 ]] && return; sleep 0.02; done; }
  # hold_lock <lock>: holds it in the background until let_go, and writes
  # "released" just before it lets go. Its waits are bounded, so a holder
  # that breaks fails a test instead of hanging the suite.
  hold_lock() {
    rm -f "$proto/held" "$proto/go" "$proto/released"
    mkdir -p "$(dirname "$1")"
    (exec 8>"$1" && flock 8 && : >"$proto/held" && until_exists "$proto/go"
     echo released >"$proto/released") &
    holder=$!
    until_exists "$proto/held"
  }
  let_go() { : >"$proto/go"; wait "$holder"; }

  # --- a local refresh (Model.localCommand), and the timer's check

  # No check has written status.json yet.
  widget_command localCommand "$local_args"
  rc=$(proto_run "${cmd[@]}")
  same "--local without a check's status.json exits Model.localNoStatusExit, which Model.localOutcome reads as a check wanted" \
    "$(cut -d' ' -f2 <<<"$local_codes")|full" "$rc|$(outcome localOutcome "$rc")"
  : >"$proto/pacman-db/db.lck"
  rc=$(proto_run "${cmd[@]}")
  rm -f "$proto/pacman-db/db.lck"
  same "--local with pacman mid-transaction exits Model.localRetryExit, read as a retry" \
    "$(cut -d' ' -f3 <<<"$local_codes")|retry" "$rc|$(outcome localOutcome "$rc")"

  # The timer's run (runDue) with no check yet: one is due, and the
  # checker says so before it checks. It writes the file Main.qml watches.
  widget_command checkCommand "$(check_args "$timer_opts")"
  rc=$(proto_flock "${cmd[@]}")
  same "--if-due, a check due: the checker's first word on stdout is Model.dueWord, then the check runs" \
    "$due_word|ok" "$(head -1 "$proto/out")|$(outcome checkOutcome "$rc" false)"
  check "the check writes status.json where Main.qml reads it" test -f "$qml_status" -a -s "$qml_status"
  # A check that finds a local refresh holding the lock waits for it as
  # long as Main.qml lets one run: its deadline, then the KILL after it.
  # So does an --if-due run, which takes .local.lock (fd 6) while it decides.
  same "--if-due waits for a local refresh as long as Model.localCommand lets one run" \
    "$(( local_deadline + kill_after ))" "$(flock_waits 6)"
  rc=$(proto_run "${cmd[@]}")
  same "--if-due right after it: exits Model.notDueExit, says nothing, read as none due" \
    "$not_due_exit||notDue" "$rc|$(cat "$proto/out")|$(outcome checkOutcome "$rc" false)"

  # An app installed since that check: only a check can read it.
  echo 'claude-desktop 1.0-1' >"$proto/pkgs"
  widget_command localCommand "$local_args"
  rc=$(proto_run "${cmd[@]}")
  same "--local finding a change only a check reads exits Model.localFullExit, read as a check wanted" \
    "$(cut -d' ' -f1 <<<"$local_codes")|full" "$rc|$(outcome localOutcome "$rc")"
  rc=$(proto_run "${cmd[@]}")
  same "--local with nothing new: exit 0, done" "0|done" "$rc|$(outcome localOutcome "$rc")"

  # --- the lock Main.qml names, held

  # Another check holds the lock (another bar, a terminal): the timer's run
  # leaves on it, as does a local refresh, by the exit Model.js reads as
  # leaving. The checker tries the lock again behind .local.lock, which it
  # waits for as long as a local refresh may run.
  hold_lock "$qml_lock"
  widget_command checkCommand "$(check_args "$(jq -c '.ifDue = false' <<<"$timer_opts")")"
  rc=$(proto_flock "${cmd[@]}")
  same "a check, Main.qml's lock held: exits Model.lockBusyExit, read as one that left on it" \
    "$busy_exit|left" "$rc|$(outcome checkOutcome "$rc" false)"
  same "a check waits for a local refresh as long as Model.localCommand lets one run" \
    "$(( local_deadline + kill_after ))" "$(flock_waits 6)"
  widget_command checkCommand "$(check_args "$timer_opts")"
  rc=$(proto_run "${cmd[@]}")
  same "--if-due, Main.qml's lock held: exits Model.lockBusyExit, says nothing" "$busy_exit|" "$rc|$(cat "$proto/out")"
  widget_command localCommand "$local_args"
  rc=$(proto_run "${cmd[@]}")
  same "--local, Main.qml's lock held: exits Model.lockBusyExit, read as one that left" \
    "$busy_exit|left" "$rc|$(outcome localOutcome "$rc")"
  # The installer's refresh passes --wait (the widget never does: see
  # tests/model.test.mjs's checkCommand). The widget's own wait
  # (Model.lockWaitSec) lasts as long as the checker's, and both outlast a
  # check: its deadline and the KILL after it.
  rc=$(proto_flock "$check_script" --no-notify --no-mise --wait)
  same "--wait, the lock held past its wait: exits Model.lockBusyExit" "$busy_exit" "$rc"
  same "Model.lockWaitSec is as long as the checker's --wait" "$lock_wait" "$(flock_waits 9)"
  check "and a check under Model.checkCommand's deadline ends before that wait gives up" \
    test "$(( check_deadline + kill_after ))" -le "$(flock_waits 9)"
  let_go

  # --- waitScript (Model.waitScript), as Model.checkCommand runs it

  # Lock, seconds, then the command.
  wait_lock=$proto/wait/.check.lock
  mkdir -p "$proto/wait"
  run_wait() { bash -c "$wait_script" omabump-wait "$@" | paste -sd'|'; }
  same "waitScript: a free lock says Model.startedWord and runs the command at once" "$started_word|a b" \
    "$(run_wait "$wait_lock" 5 echo a b)"
  hold_lock "$wait_lock"
  (sleep 0.3; : >"$proto/go") &
  same "waitScript: a held lock is waited for, then the command runs" "$started_word|released" \
    "$(run_wait "$wait_lock" 5 cat "$proto/released")"
  let_go
  # Its exit for a lock held past the wait is the one Model.js reads as a
  # check that never ran: the -E, the test and the exit in it all count.
  hold_lock "$wait_lock"
  out=$(bash -c "$wait_script" omabump-wait "$wait_lock" 0.2 echo ran); rc=$?
  same "waitScript: a lock held past the wait runs nothing and exits Model.lockBusyExit, read as not run" \
    "|$busy_exit|notRun" "$out|$rc|$(outcome checkOutcome "$rc" true)"
  let_go
  same "waitScript: no lock directory yet, nothing to wait for" "$started_word|ran" \
    "$(run_wait "$proto/wait/none/.check.lock" 5 echo ran)"
  same "waitScript: the command's exit status is the run's" "$started_word|exit 3" \
    "$( { bash -c "$wait_script" omabump-wait "$wait_lock" 5 bash -c 'exit 3'; echo "exit $?"; } | paste -sd'|')"
  # A Refresh's run: the wait, then the check under its deadline.
  widget_command checkCommand "$(check_args "$(jq -c '.wait = true | .ifDue = false' <<<"$timer_opts")")"
  rc=$(proto_run "${cmd[@]}")
  same "a Refresh's run, the lock free: Model.startedWord, then a check that completes" "$started_word|ok" \
    "$(head -1 "$proto/out")|$(outcome checkOutcome "$rc" true)"
fi

# --- Main.qml and the scripts -------------------------------------------------

# Main.qml itself needs a shell to run, so where it hands the settings to
# the command lines above, and reads the words they say, these read it.
# shellcheck disable=SC2016 # the literal text of the QML
same "Main.qml runs its checks by Model.checkCommand, with the wait, the due run and the settings as they are" \
  'checkProcess.command = Model.checkCommand(checkScript, lockPath, { wait: wait, ifDue: !!ifDue, intervalSec: refreshIntervalSec, notify: notify, showMise: showMise })' \
  "$(grep -A1 '^    checkProcess.command = ' "$root/Main.qml" | sed 's/^ *//' | paste -sd' ')"
check "Main.qml runs its local refresh by Model.localCommand" \
  grep -qx '    localProcess.command = Model.localCommand(checkScript, showMise)' "$root/Main.qml"
check "Main.qml ends a run's wait on Model.startedWord" \
  grep -qx '        if (line === Model.startedWord) root.runWaiting = false' "$root/Main.qml"
# Until the checker says a check is due, that run shows as none.
check "Main.qml counts the run as a check once the checker says Model.dueWord" \
  grep -qx '        else if (line === Model.dueWord) root.runIfDue = false' "$root/Main.qml"
check "and shows none before" grep -qx '  readonly property bool checking: checkProcess.running && !runIfDue || fileChecking' "$root/Main.qml"

# The checker decides whether a skip applies and writes it as each row's
# skipped; Model.js reads that field and compares no versions itself.
# tests/check.sh reads the fields the checker writes and tests/model.test.mjs
# feeds Model.js rows with them, so only these say both use one name. The
# rows are the checker's own: row_derive and row_json, which build every
# row a check writes, run here on an omarchy row.
# qml_row <installed> <latest> <hold seconds> <jq filter>: that row, with
# a skip of 1.2 in the settings, through the filter; the release first
# seen now.
# shellcheck disable=SC2034 # the row's fields, read by row_derive and row_json
qml_row() {
  local pkg=qml-app source=omarchy app='{"pkg": "qml-app", "label": "Qml App"}' label="Qml App"
  local installed_name=qml-app installed=$1 latest=$2 from=feed mise_update=false self_updating=false
  local hold=$3 now=1767225600 installable=true note="" held=false unchecked=false
  local error="" stale=false recipe="" request="" omarchy_update=false blocked=""
  local muted_json='[]' skipped_json='{"qml-app": "1.2"}' seen_file=$scratch/qml-seen.json
  local update switchable muted skipped skip_end quiet hold_clause unread=false
  mkdir -p "$state_dir"
  rm -f "$seen_file"
  row_derive
  row_json | jq -r "$4"
}
check "Model.js reads the skipped field bin/omabump-check writes" grep -q 'app.skipped === true' "$root/Model.js"
same "the rows a check writes (row_json) carry skipped" true "$(qml_row 1.0-1 1.2 0 .skipped)"
refuse "Model.js compares no versions" grep -qiE 'vercmp\(|rpmvercmp' "$root/Model.js"
# A skip leaves the settings only once a run read it and found it over.
check "Model.js drops a skip by the skipEnded field bin/omabump-check writes" grep -q 'app.skipEnded' "$root/Model.js"
same "the rows a check writes (row_json) carry skipEnded" '1.2|' \
  "$(qml_row 1.0-1 1.3 0 .skipEnded)|$(qml_row 1.0-1 1.2 0 .skipEnded)"
# A row shortens the release-age hold clause by its words (Model.holdNote).
qml_hold_re=$(sed -n 's|^var holdNote = /\(.*\)/$|\1|p' "$root/Model.js")
qml_held=$(qml_row 1.0-1 1.3 86400 .note)
check "a check (row_hold) words the hold clause as Model.holdNote reads it" \
  bash -c '[[ -n $1 && $2 =~ $1 ]]' _ "$qml_hold_re" "$qml_held"
same "Model.js caps the quiet settings where load_quiet does" "$quiet_max" \
  "$(sed -n 's/^var quietMax = \([0-9]*\)$/\1/p' "$root/Model.js")"

# status.json's runError, and a row's selfUpdating, by the same name on
# both sides: the panel offers no Update or Switch for a selfUpdating row.
check "Model.js reads the runError field bin/omabump-check writes" grep -q 'file.runError' "$root/Model.js"
# status_write_check, which writes every check's status.json, into a file
# of its own.
qml_status=$(
  # shellcheck disable=SC2034 # read by status_write_check
  status_file=$scratch/qml-status.json run_tmp=$scratch
  echo '{"apps": []}' >"$scratch/qml-prev.json"
  printf '' | status_write_check 2 2026-01-01T00:00:00+00:00 2026-01-01T00:00:00+00:00 0 "The check stopped early (exit 143)" \
    "" "" "" "" "$scratch/qml-prev.json" '[]'
  jq -r .runError "$status_file")
same "a check (status_write_check) writes runError into status.json" "The check stopped early (exit 143)" "$qml_status"
check "Model.js reads the selfUpdating field bin/omabump-check writes" \
  grep -q 'function selfUpdating(app) { return !!app && app.selfUpdating === true }' "$root/Model.js"
same "the rows a check writes (row_json) carry selfUpdating" false "$(qml_row 1.0-1 1.2 0 .selfUpdating)"

# A row without Update has no action at all: the panel starts no agent.
refuse "the widget starts no coding agent" grep -qE 'omarchy-agent|omabump-prompt' "$root/Main.qml" "$root/Panel.qml"
# 0.1.13's panel, still loaded after an Update until the shell restarts,
# runs bin/omabump-prompt as its prompt script did: it gets an error to show
# as the row's note, not an agent.
# shellcheck disable=SC2016 # 0.1.13's prompt script, expanded by its bash
same "bin/omabump-prompt tells a 0.1.13 panel to restart the shell" \
  'error
Omabump was updated; restart the shell to load its new panel: omarchy restart shell' \
  "$(bash -c 'out=$("$1" "$2" 2>&1) || { printf "error\n%s" "$out"; exit 0; }; printf "ok\n%s" "$out"' \
    omabump-prompt "$root/bin/omabump-prompt" omabump </dev/null)"
refuse "bin/omabump-prompt starts no coding agent" grep -qE 'omarchy-agent|exec|launch' "$root/bin/omabump-prompt"

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


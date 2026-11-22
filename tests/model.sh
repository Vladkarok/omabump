# shellcheck shell=bash disable=SC2154 # root and the helpers come from tests/run.sh
# Sourced by tests/run.sh: Model.js under node (tests/model.test.mjs), and
# where Model.js repeats a rule of the scripts, the two must agree.

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

  # K stores only a version load_quiet keeps, by the script's own function.
  model_versions=(1.0 1.0.0-beta.1 v1 1.0~rc1 1+2_3 -1 .1 1..2 1:2 '1 0' '' é1 1é
    "$(printf '1%.0s' {1..64})" "$(printf '1%.0s' {1..65})")
  same "Model.skipVersionOk accepts the versions skip_version_ok accepts" \
    "$(for v in "${model_versions[@]}"; do if skip_version_ok "$v"; then echo true; else echo false; fi; done)" \
    "$(for v in "${model_versions[@]}"; do jq -cn --arg v "$v" '[$v]'; done | model_call skipVersionOk)"

  # load_quiet and Model.js read the same shell.json entry alike: wrong
  # types, refused versions, and the cap on each setting. Prints
  # load_quiet's mutes and skips, then Model.js's, one line each. The ids
  # are ones app_id_ok keeps: no listed row has another.
  model_quiet() {
    local entry
    jq '{plugins: [{id: "io.github.vladkarok.omabump"} + .]}' >"$shell_json"
    load_quiet 2>/dev/null
    echo "$(jq -c 'sort' <<<"$muted_json") $(jq -cS . <<<"$skipped_json")"
    entry=$(jq -c '[.plugins[0]]' "$shell_json")
    echo "$(model_call mutedApps <<<"$entry" | jq -c 'sort') $(model_call skippedVersions <<<"$entry" | jq -cS .)"
  }
  model_pair=$(jq -n '{mutedApps: ["a", 1, "mise:x", "a", "self:omabump", null],
    skippedVersions: {a: "1.0", "mise:b": "2.0-beta.1", c: "1..2", d: 3, e: "", "self:omabump": "0.2.0", f: "v1 ", g: "1:2"}}' | model_quiet)
  same "Model.js keeps the skips load_quiet keeps" "$(sed -n 1p <<<"$model_pair")" "$(sed -n 2p <<<"$model_pair")"
  model_pair=$(jq -n '{mutedApps: ([range(150) | 7, "m\(.)"] + [range(100) | "ok\(.)"]),
    skippedVersions: ([range(150) | {key: "bad-\(.)", value: "1..2"}, {key: "num-\(.)", value: 1}]
      + [range(100) | {key: "ok-\(.)", value: "1.0"}] | from_entries)}' | model_quiet)
  same "Model.js caps the mutes and skips as load_quiet does" "$(sed -n 1p <<<"$model_pair")" "$(sed -n 2p <<<"$model_pair")"
  same "and the cap leaves 200 mutes and 50 skips" "200 50" "$(sed -n 2p <<<"$model_pair" | jq -rs '"\(.[0] | length) \(.[1] | length)"')"

  # --- did the last check fail ---------------------------------------------------

  # The checker retries a failed check by check_failed (bin/omabump-common);
  # the widget says "Check failed" by Model.failureText, or by
  # Model.errorCount above 0, on the rows and errors Model.parseStatus reads
  # (this shell's own checkError aside, which no file holds). The same
  # status.json and settings go to both. Each case: a name, the file's
  # fields over a clean one ($file), the muted ids, Show mise tools (1 or
  # 0), and the verdict both give ("failed" or "ok"); where they differ,
  # the widget's apart (widget), with the reason beside the case.
  model_failed_cases() {
    local a='{"pkg": "a", "source": "omarchy", "error": ""}' b='{"pkg": "b", "source": "omarchy", "error": ""}'
    local s='{"pkg": "s", "source": "omarchy", "selfUpdating": true, "error": ""}'
    local m='{"pkg": "mise:m", "source": "mise", "error": ""}' v='{"pkg": "v", "source": "vendor-pkg", "error": ""}'
    local rows="[$a, $b, $s, $m, $v]" perr='"omarchyPkgs": {"error": "Could not fetch omarchy-pkgs"}'
    jq -c --argjson rows "$rows" '.file.apps //= $rows' <<EOF
{"name": "nothing failed", "file": {}, "muted": [], "mise": 1, "want": "ok"}
{"name": "a file with nothing in it", "file": {"apps": []}, "muted": [], "mise": 1, "want": "ok"}
{"name": "runError", "file": {"runError": "The check stopped early (exit 143)"}, "muted": [], "mise": 1, "want": "failed"}
{"name": "runError, every row muted", "file": {"runError": "x"}, "muted": ["a", "b", "s", "mise:m", "v"], "mise": 1, "want": "failed"}
{"name": "omarchy-pkgs error, no omarchy row muted", "file": {$perr}, "muted": [], "mise": 1, "want": "failed"}
{"name": "omarchy-pkgs error, some omarchy rows muted", "file": {$perr}, "muted": ["a"], "mise": 1, "want": "failed"}
{"name": "omarchy-pkgs error, every omarchy row muted", "file": {$perr}, "muted": ["a", "b"], "mise": 1, "want": "ok"}
{"name": "omarchy-pkgs error, only the self-updating one muted", "file": {$perr}, "muted": ["s"], "mise": 1, "want": "failed"}
{"name": "omarchy-pkgs error, no omarchy row", "file": {$perr, "apps": [$v, $m]}, "muted": ["v", "mise:m"], "mise": 1, "want": "failed"}
{"name": "omarchy-pkgs error, only a self-updating omarchy row", "file": {$perr, "apps": [$s]}, "muted": ["s"], "mise": 1, "want": "failed"}
{"name": "omarchy-pkgs not an object", "file": {"omarchyPkgs": "Could not fetch"}, "muted": [], "mise": 1, "want": "ok"}
{"name": "miseError, Show mise tools on", "file": {"miseError": "mise ls failed"}, "muted": [], "mise": 1, "want": "failed"}
{"name": "miseError, Show mise tools off", "file": {"miseError": "mise ls failed"}, "muted": [], "mise": 0, "want": "ok"}
{"name": "miseError, every mise row muted", "file": {"miseError": "mise ls failed"}, "muted": ["mise:m"], "mise": 1, "want": "ok"}
{"name": "miseError, no mise row", "file": {"miseError": "mise ls failed", "apps": [$a]}, "muted": [], "mise": 1, "want": "failed"}
{"name": "a muted row's error only", "file": {"apps": [$a, $b], "omarchyPkgs": {}}, "muted": [], "mise": 1, "want": "ok", "rowError": "a", "mutedRow": "a"}
{"name": "an unmuted row's error", "file": {}, "muted": ["b"], "mise": 1, "want": "failed", "rowError": "a"}
{"name": "a self-updating row's error", "file": {}, "muted": [], "mise": 1, "want": "failed", "rowError": "s"}
{"name": "a mise row's error, Show mise tools off", "file": {}, "muted": [], "mise": 0, "want": "ok", "rowError": "mise:m"}
{"name": "a mise row's error, Show mise tools on", "file": {}, "muted": [], "mise": 1, "want": "failed", "rowError": "mise:m"}
{"name": "selfUpdating not exactly true takes its route", "file": {$perr, "apps": [$a, {"pkg": "t", "source": "omarchy", "selfUpdating": "true"}]}, "muted": ["a"], "mise": 1, "want": "failed"}
{"name": "rows that are no objects count for nothing", "file": {$perr, "apps": [1, "x", null, [], $a]}, "muted": ["a"], "mise": 1, "want": "ok"}
{"name": "rows missing fields", "file": {$perr, "apps": [{"pkg": "a"}, {"source": "omarchy"}, {}]}, "muted": [], "mise": 1, "want": "failed"}
{"name": "an error that is no string", "file": {"apps": [{"pkg": "a", "source": "omarchy", "error": 5}, {"pkg": "b", "error": true}]}, "muted": [], "mise": 1, "want": "failed"}
{"name": "an error false is none", "file": {"runError": false, "apps": [{"pkg": "a", "source": "omarchy", "error": false}]}, "muted": [], "mise": 1, "want": "ok"}
{"name": "an error 0", "file": {"apps": [{"pkg": "a", "source": "omarchy", "error": 0}]}, "muted": [], "mise": 1, "want": "failed", "widget": "ok"}
{"name": "an error []", "file": {"apps": [{"pkg": "a", "source": "omarchy", "error": []}]}, "muted": [], "mise": 1, "want": "failed", "widget": "ok"}
{"name": "a runError 0", "file": {"runError": 0}, "muted": [], "mise": 1, "want": "failed", "widget": "ok"}
{"name": "a miseError []", "file": {"miseError": []}, "muted": [], "mise": 1, "want": "failed", "widget": "ok"}
{"name": "a check still marked as running", "file": {"checking": true}, "muted": [], "mise": 1, "want": "failed", "widget": "checking"}
EOF
  }
  # Cases with rowError set that row's error, and mutedRow mutes it too.
  model_failed_cases | jq -c '(.rowError // null) as $e | (.mutedRow // null) as $mr
    | .file.apps |= map(if (type == "object") and $e != null and .pkg == $e then .error = "the feed timed out" else . end)
    | if $mr then .muted += [$mr] else . end
    | .file = ({schemaVersion: 1, runError: "", checking: false, miseError: "", omarchyPkgs: {error: ""}} + .file)' \
    >"$scratch/failed-cases"
  model_failed_bash=$(jq -r "$jq_status"' .name as $n | .muted as $m | .mise as $s
    | "\($n): \(.file | if check_failed($m; $s) then "failed" else "ok" end)"' "$scratch/failed-cases")
  jq -c '[(.file | tojson), .mise == 1]' "$scratch/failed-cases" | model_call parseStatus >"$scratch/failed-parsed"
  model_failed_js=$(jq -nc --slurpfile c "$scratch/failed-cases" --slurpfile p "$scratch/failed-parsed" '
    [$c, $p] | transpose[] | {name: .[0].name, muted: .[0].muted, s: .[1]}' >"$scratch/failed-pairs"
    paste -d'\t' \
      <(jq -r '.name' "$scratch/failed-pairs") \
      <(jq -c '[{checkError: "", runError: .s.runError, pkgsError: .s.pkgsError, miseError: .s.miseError}, .s.apps, .muted]' \
          "$scratch/failed-pairs" | model_call failureText) \
      <(jq -c '[.s.apps, .muted]' "$scratch/failed-pairs" | model_call errorCount) \
      <(jq -r '.s.checking' "$scratch/failed-pairs") \
    | while IFS=$'\t' read -r name text errors checking; do
        if [[ $text != '""' ]] || (( errors > 0 )); then echo "$name: failed"
        elif [[ $checking == true ]]; then echo "$name: checking"
        else echo "$name: ok"; fi
      done)
  same "check_failed: each case's verdict" "$(jq -r '"\(.name): \(.want)"' "$scratch/failed-cases")" "$model_failed_bash"
  # Where they part, on purpose or on input no checker writes:
  # - a check still marked as running: under the checker's lock no check
  #   runs, so the mark is a killed run's and earns a retry; the widget,
  #   which reads the file while checks run, shows a check running (and
  #   after Main.qml's staleMs none), and the next --if-due retries it.
  # - an error 0 or [] (a row's, runError, miseError): check_failed takes
  #   any value but null, false and "" for an error, the widget's
  #   String(x || "") reads those two as none. bin/omabump-check writes
  #   every error as a string (clean_text), and a retry is all it costs.
  same "Model.failureText and Model.errorCount give the widget's verdict on the same files" \
    "$(jq -r '"\(.name): \(.widget // .want)"' "$scratch/failed-cases")" "$model_failed_js"

  # The rows the two read: status_apps drops what is no object, and mise
  # rows while Show mise tools is off, as Model.parseStatus does. An array
  # row is the one difference: an object to JavaScript, so parseStatus keeps
  # it (no checker writes one, and it counts toward no failure, above).
  model_rows_doc='{"apps": [{"pkg": "a", "source": "omarchy"}, {"pkg": "mise:m", "source": "mise"}, 7, null, "x", [],
    {"pkg": "s", "source": "omarchy", "selfUpdating": true}, {"pkg": "n"}, {"pkg": "mise:o", "source": "mise"}]}'
  for model_mise in 1 0; do
    same "status_apps lists the rows Model.parseStatus lists, Show mise tools $model_mise, an array row aside" \
      "$(jq -c --argjson s "$model_mise" "$jq_status"' [status_apps($s)[] | .pkg]' <<<"$model_rows_doc")" \
      "$(jq -c --argjson s "$model_mise" '[tojson, $s == 1]' <<<"$model_rows_doc" | model_call parseStatus \
        | jq -c '[.apps[] | objects | .pkg]')"
  done
  same "and parseStatus keeps the array row" 1 \
    "$(jq -c '[tojson, true]' <<<"$model_rows_doc" | model_call parseStatus | jq '[.apps[] | arrays] | length')"

  # The slack every bar allows a run that started about when its own did:
  # run_recent's for a check (--if-due), Model.localDue's for a local
  # refresh, at each side of the edge, a time ahead of the clock and none.
  same "Model.dueSlackSec is due_slack_sec" "$due_slack_sec" "$(model_call dueSlackSec </dev/null)"
  model_now=1800000000
  model_ages=(-1 0 1 "$(( 300 - due_slack_sec - 1 ))" "$(( 300 - due_slack_sec ))" 299 300 100000 none)
  same "run_recent and Model.localDue agree on what is recent, at a 300 s interval" \
    "$(for age in "${model_ages[@]}"; do
        if [[ $age == none ]]; then last=""; else last=$(( model_now - age )); fi
        if run_recent "$model_now" "$last" 300; then echo recent; else echo due; fi
      done)" \
    "$(for age in "${model_ages[@]}"; do
        if [[ $age == none ]]; then echo "[$(( model_now * 1000 )), 0, 300]"
        else echo "[$(( model_now * 1000 )), $(( (model_now - age) * 1000 )), 300]"; fi
      done | model_call localDue | sed 's/^true$/due/; s/^false$/recent/')"
fi

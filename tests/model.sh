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
fi

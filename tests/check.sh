# shellcheck shell=bash
# Tests for the background check: the agent wrapper parser and its
# warnings, mise answers of odd shapes, pins.json of the wrong shape, feed
# outputs that are not versions, recipe reads in a blob-less clone, and
# whole runs of bin/omabump-check against fake tools (runError, TERM,
# scratch files, the shell.json settings). Sourced by tests/run.sh, whose
# helpers, stubs and $scratch it uses.
# Variables set here are read by the functions under test, and those read
# here are set by tests/run.sh and omabump-common, which shellcheck does not
# see from this file; stubs are called by the functions under test:
# shellcheck disable=SC2034,SC2154,SC2329
# Single quotes below hold shell text for files and jq, never expanded here:
# shellcheck disable=SC2016

# --- discovery: the wrapper parser ----------------------------------------------

d2=$scratch/discover2
mkdir -p "$d2/bin"
printf '{"setup.default.agent.omp": {"label": "omp"}, "setup.default.agent.hermes": {"label": "Hermes"}}' >"$d2/stock.jsonc"
: >"$d2/user.jsonc"
disc2() { python3 "$root/bin/omabump-discover" --stock "$d2/stock.jsonc" --user "$d2/user.jsonc" --bin-dir "$d2/bin" "$@"; }
# The omp agent as "<key>/<source>", and its warning.
omp_of() { disc2 "$@" | jq -r '.agents[] | select(.command == "omp") | "\(.key)/\(.source)"'; }
omp_warning() { disc2 "$@" | jq -r '.agents[] | select(.command == "omp") | .warning // ""'; }
put() { printf '%s\n' "$@" >"$d2/bin/omp"; }
use_exec() { put '#!/bin/bash' "mise use -g --quiet \"$1\" || exit 1" "exec mise x \"$1\" -- \"omp\" \"\$@\""; }

put '#!/bin/bash' '# Written by omarchy-mise-install' '' 'export MISE_MINIMUM_RELEASE_AGE=0' 'export A_B="x y"' "export C='z'" \
  'mise use -g --quiet "github:can1357/oh-my-pi" || exit 1' '  exec mise x "github:can1357/oh-my-pi" -- "omp" "$@"' '# the end'
same "wrapper: comments, blank lines and exports around the two lines" 'github:can1357/oh-my-pi/wrapper' "$(omp_of)"
put '#!/usr/bin/env bash' 'mise use --yes -g "npm:@scope/omp"' 'exec mise exec "npm:@scope/omp" -- "omp" "$@"'
same "wrapper: env bash, flags in any order, no || exit, mise exec" 'npm:@scope/omp/wrapper' "$(omp_of)"
for pair in 'npm:@scope/omp@1.2.3|npm:@scope/omp' 'omp@latest|omp' '@scope/omp@2|@scope/omp' 'aqua:o/omp@prefix:1|aqua:o/omp' \
  'ubi:o/omp[exe=omp]@1.0|ubi:o/omp' 'http:omp[url=https://u@example.com/x]|http:omp'; do
  use_exec "${pair%%|*}"
  same "wrapper: the key of ${pair%%|*}" "${pair#*|}/wrapper" "$(omp_of)"
done
use_exec 'omp@'
same "wrapper: an empty @version is a warning" "wrapper $d2/bin/omp not recognised: malformed @version suffix" "$(HOME=/nonexistent omp_warning)"

# Files that run mise but are not a wrapper Omabump reads: the agent falls
# back to its command and the file is named.
rejected() {
  same "wrapper: $1" "omp/command|$2" "$(omp_of)|$(HOME=/nonexistent omp_warning | sed "s|^wrapper $d2/bin/omp not recognised: ||")"
}
put '#!/bin/bash' 'mise use -g "a"' 'mise use -g "b"' 'exec mise x "a" -- "omp" "$@"'
rejected "two mise use lines" '2 mise use and 1 exec mise lines, not one of each'
put '#!/bin/bash' 'mise use --quiet "a"' 'exec mise x "a" -- "omp" "$@"'
rejected "mise use without -g" 'line 2: mise use without -g, or with a flag Omabump does not know'
put '#!/bin/bash' 'mise use -g --path /tmp/x "a"' 'exec mise x "a" -- "omp" "$@"'
rejected "a mise use flag that takes a value" 'line 2 is not a line of an omarchy-mise-install wrapper'
put '#!/bin/bash' 'exec mise x "a" -- "omp" "$@"' 'mise use -g "a"'
rejected "exec before use" 'mise use comes after exec mise'
put '#!/bin/sh' 'mise use -g "a"' 'exec mise x "a" -- "omp" "$@"'
rejected "a shebang other than bash" 'no bash shebang on the first line'
put '#!/bin/bash' 'export X=$(id)' 'mise use -g "a"' 'exec mise x "a" -- "omp" "$@"'
rejected "an export of a command substitution" 'line 2 is not a line of an omarchy-mise-install wrapper'
use_exec a
same "wrapper: owned by another uid, with the uid" "omp/command|not owned by uid $(( $(id -u) + 1 ))" \
  "$(omp_of --uid "$(( $(id -u) + 1 ))")|$(omp_warning --uid "$(( $(id -u) + 1 ))" | sed 's/^.*not recognised: //')"

# Anything else in its place is silent.
put '#!/bin/bash' 'exec "$HOME/.hermes/hermes-agent/venv/bin/hermes" "$@"'
same "wrapper: a launcher that does not run mise (Hermes, OpenClaw) is silent" 'omp/command|' "$(omp_of)|$(omp_warning)"
put '#!/bin/bash' 'echo "run omarchy-mise-install, or install mise first" >&2' 'exit 1'
same "wrapper: the user's own script that mentions mise is silent" 'omp/command|' "$(omp_of)|$(omp_warning)"
put '#!/bin/bash' '# mise use -g "a"' 'exec /opt/omp/bin/omp "$@"'
same "wrapper: mise in a comment only is silent" 'omp/command|' "$(omp_of)|$(omp_warning)"
same "wrapper: a script that does not run mise, owned by another uid, is silent" '' "$(omp_warning --uid "$(( $(id -u) + 1 ))")"
rm -f "$d2/bin/omp"

# --- discovery: the menus ---------------------------------------------------------

python3 -c 'print("{\"a\": " + "[" * 100000 + "]" * 100000 + "}")' >"$d2/user.jsonc"
same "menu: one nested too deeply is that menu's error, the stock agents still count" '1|omp hermes' \
  "$(disc2 | jq -r '[(.errors | map(select(test("nested too deeply"))) | length), (.agents | map(.command) | join(" "))] | join("|")')"
: >"$d2/user.jsonc"
same "menu: a user menu without agents is no error" '' "$(disc2 | jq -r '.errors | join("|")')"
printf '{"setup.default.agents.claude": {"label": "Claude"}}' >"$d2/stock.jsonc"
same "menu: a stock menu without setup.default.agent ids is an error (Omarchy renamed them)" \
  "the menu $d2/stock.jsonc lists no setup.default.agent.<command> entries|0" "$(disc2 | jq -r '"\(.errors | join("|"))|\(.agents | length)"')"
printf '{"setup.default.agent.omp": {"label": "omp"}, "setup.default.agent.hermes": {"label": "Hermes"}}' >"$d2/stock.jsonc"

# --- discovery: warnings and disabled rows ----------------------------------------

discover_out='{"agents": [
  {"command": "omp", "key": "omp", "label": "omp", "source": "command", "warning": "wrapper ~/.local/bin/omp not recognised: x"},
  {"command": "grok", "key": "grok", "label": "Grok", "source": "command", "warning": "wrapper ~/.local/bin/grok not recognised: y"}],
  "errors": ["menu trouble"]}'
rm -f "$user_apps"
discover_agents
same "warnings: each rejected mise wrapper is named after the menu errors" \
  'menu trouble; wrapper ~/.local/bin/omp not recognised: x; wrapper ~/.local/bin/grok not recognised: y' "$discovery_error"
printf '[{"pkg": "mise:oh-my-pi", "disabled": true}, {"pkg": "mise:grok", "disabled": true}]' >"$user_apps"
discover_agents
same "warnings: none for a command whose row the user disabled, by the row or by mise:<command>" 'menu trouble' "$discovery_error"
printf '{"not": "an array"}' >"$user_apps"
discover_agents 2>/dev/null
same "warnings: a user file that is not an array disables nothing" \
  'menu trouble; wrapper ~/.local/bin/omp not recognised: x; wrapper ~/.local/bin/grok not recognised: y' "$discovery_error"
rm -f "$user_apps"
discover_out='{"agents":[],"errors":[]}'
discover_agents

# --- pins.json of the wrong shape ---------------------------------------------------

for v in '"x"' '[1]' '5' '{"commit": 5}' '{"ref": 7}' '{"follow": ["master"]}'; do
  echo "{\"omarchyPkgs\": $v}" >"$user_pins"
  same "pkgs_pin: omarchyPkgs $v is a pin error under set -e, not an exit" 'error||' \
    "$( (set -euo pipefail; pkgs_base="" pkgs_follow=0 pkgs_pin_ref="" pkgs_pin_error=""; pkgs_pin 2>/dev/null; echo "${pkgs_pin_error:+error}|$pkgs_base|$pkgs_pin_ref") )"
done
echo '{"omarchyPkgs": "x"}' >"$user_pins"
same "pkgs_pin: sourcing omabump-common under set -e survives it" 'omarchyPkgs in pins.json is not an object' \
  "$(bash -c 'set -euo pipefail; source "$1/bin/omabump-common"; echo "$pkgs_pin_error"' _ "$root" 2>/dev/null)"
rm -f "$user_pins"
pkgs_base="" pkgs_follow=0 pkgs_pin_ref="" pkgs_pin_error=""
pkgs_pin 2>/dev/null

# --- mise answers of odd shapes -------------------------------------------------------

same "mise_outdated_table: an entry that is no object is marked, odd fields dropped" \
  '{"a":{"odd":true},"b":{"odd":true},"c":{"bump":"1.0","latest":"2"}}' \
  "$(mise_outdated_table <<<'{"a": "oops", "b": [1], "c": {"bump": "1.0", "latest": 2, "requested": {"x": 1}, "current": "a\u0007b"}}')"
refuse "mise_outdated_table: an answer that is not an object fails" mise_outdated_table <<<'[1]'
same "mise_field: a string entry gives nothing, under set -e" '|ok' "$( (set -euo pipefail; v=$(mise_field '{"t": "oops"}' t latest); echo "$v|ok") )"
# mise_row on given tables, under set -e: "latest|installable|update|note|error".
mise_row_on() {
  ( set -euo pipefail
    mise_safe_json='{"t": true}' mise_error="" mise_bump_error="" mise_outdated_json=$1 mise_bump_json=$2
    mise_fetch_failed=()
    mise_row t "$3"
    echo "$latest|$installable|$mise_update|$note|$feed_error" )
}
same "mise_row: an outdated entry that is no object is a check error" '|true|false||mise outdated gave an entry for t that is not an object' \
  "$(mise_row_on "$(mise_outdated_table <<<'{"t": "oops"}')" '{}' 1.0)"
same "mise_row: a bump entry that is no object is a check error" '|true|false||mise outdated --bump gave an entry for t that is not an object' \
  "$(mise_row_on '{}' "$(mise_outdated_table <<<'{"t": [1, 2]}')" 1.0)"
same "mise_row: a pinned row shows the release, not the request-shaped bump" '0.97.1|false|false|Pinned to 0.97, 0.97.1 exists|' \
  "$(mise_row_on '{}' '{"t": {"bump": "0.97", "latest": "0.97.1", "requested": "0.97"}}' 0.96.0)"
same "mise_row: at that release, the row is current" '0.97.1|true|false||' \
  "$(mise_row_on '{}' '{"t": {"bump": "0.97", "latest": "0.97.1", "requested": "0.97"}}' 0.97.1)"
same "mise_row: without latest, the bump still shows" '0.98|false|false|Pinned to 0.97, 0.98 exists|' \
  "$(mise_row_on '{}' '{"t": {"bump": "0.98", "requested": "0.97"}}' 0.97.1)"

# An Update asks outdated about its own tool only.
mise_log=$scratch/mise-key.calls
mise_key_load() {
  : >"$mise_log"
  ( mise() { :; }
    mise_run() {
      printf '%s\n' "$*" >>"$mise_log"
      case $* in
        "ls --json") echo '{"a": [{"version": "1", "active": true}], "b": [{"version": "2", "active": true}]}' ;;
        "ls --json --backend"*) echo '{"a": [], "b": []}' ;;
        outdated*) echo '{}' ;;
        *) return 1 ;;
      esac
    }
    app_table='[{"pkg": "mise:a", "source": "mise", "tool": "a"}, {"pkg": "mise:b", "source": "mise", "tool": "b"}]'
    mise_load 1 "$@" )
  grep '^outdated' "$mise_log"
}
same "mise_load: every selected key for the check" $'outdated --json -- a b\noutdated --bump --json -- a b' "$(mise_key_load)"
same "mise_load: only the given key for an Update" $'outdated --json -- b\noutdated --bump --json -- b' "$(mise_key_load b)"
same "mise_load: a key no row selected asks nothing" '' "$(mise_key_load c)"
check "the installer's Update loads mise for its tool only" grep -q '^  mise_load 1 "$tool"$' "$root/bin/omabump-install"

# --- the backends mise is told to disable -------------------------------------------

same "mise_disabled_backends: your MISE_DISABLE_BACKENDS and mise's setting are added, once each" 'asdf,vfox,foo,bar,baz' \
  "$(MISE_DATA_DIR=$scratch/no-mise-data MISE_DISABLE_BACKENDS='foo, bar,asdf,../x' mise_user_backends='baz,foo' mise_disabled_backends)"
same "mise_backends_load: mise's setting as mise prints it" 'zed,asdf' \
  "$(mise_run() { [[ $* == 'settings get disable_backends' ]] && echo '["zed", "asdf"]'; }; mise_backends_load; echo "$mise_user_backends")"
same "mise_backends_load: a mise that cannot answer leaves it out" '' \
  "$(mise_run() { return 1; }; mise_user_backends=x; mise_backends_load; echo "$mise_user_backends")"
mkdir -p "$scratch/setbin"
printf '#!/bin/sh\necho "${MISE_DISABLE_BACKENDS-unset}|$*"\n' >"$scratch/setbin/mise"
chmod +x "$scratch/setbin/mise"
same "mise_run: mise settings runs without Omabump's list, which would replace the answer" 'unset|settings get disable_backends' \
  "$( unset MISE_DISABLE_BACKENDS; PATH=$scratch/setbin:$PATH real_mise_run settings get disable_backends)"
same "mise_run: every other call gets the list" 'asdf,vfox,mine|ls' \
  "$( unset MISE_DISABLE_BACKENDS; mise_user_backends=mine MISE_DATA_DIR=$scratch/no-mise-data PATH=$scratch/setbin:$PATH real_mise_run ls)"
mise_user_backends=""

# --- notify and showMise from shell.json ---------------------------------------------

settings_of() { printf '{"plugins": [{"id": "io.github.vladkarok.omabump"%s}]}' "$1" >"$shell_json"; load_quiet 2>/dev/null; echo "$setting_notify|$setting_show_mise"; }
same "load_quiet: booleans" 'true|false' "$(settings_of ', "notify": true, "showMise": false')"
same "load_quiet: the strings omarchy bar set stores, in any case" 'false|true' "$(settings_of ', "notify": " False ", "showMise": "TRUE"')"
same "load_quiet: anything else is unset" '|' "$(settings_of ', "notify": "maybe", "showMise": 1')"
same "load_quiet: no settings, unset" '|' "$(settings_of '')"
rm -f "$shell_json"
load_quiet

# --- feeds whose output is not one version ---------------------------------------------

regex_app='{"pkg": "x", "feed": {"type": "regex", "url": "https://example.com/rx", "pattern": "release: (?:v([0-9.]+)|unknown)"}}'
echo 'release: unknown' >"$scratch/served/rx"
same "feed_version: a regex group that took no part is no version, not None" 'feed returned no version' \
  "$(feed_version "$regex_app" 2>&1 >/dev/null)"
echo 'release: v1.2.3' >"$scratch/served/rx"
same "feed_version: the same pattern with its group" 1.2.3 "$(feed_version "$regex_app")"
json_app() { jq -cn --arg p "$1" '{pkg: "x", feed: {type: "json", url: "https://example.com/js", path: $p}}'; }
printf '%s\n' '{"versions": ["1.0", "2.0"], "n": 1.5, "o": {"a": 1}, "v": " 3.1 \n"}' >"$scratch/served/js"
same "feed_version: a json path with two values is an error, not 1.02.0" 'the feed path gives 2 values, not one' \
  "$(feed_version "$(json_app '.versions[]')" 2>&1 >/dev/null)"
same "feed_version: one value of several" 2.0 "$(feed_version "$(json_app '.versions[1]')")"
same "feed_version: a number" 1.5 "$(feed_version "$(json_app .n)")"
same "feed_version: an object is an odd version" "feed returned an odd version '{\"a\":1}'" "$(feed_version "$(json_app .o)" 2>&1 >/dev/null)"
same "feed_version: blanks around a version go" 3.1 "$(feed_version "$(json_app .v)")"
printf 'version: 1.2 3\n' >"$scratch/served/latest.yml"
same "feed_version: blanks inside a version are an odd version, not 1.23" "feed returned an odd version '1.2 3'" \
  "$(feed_version '{"pkg": "x", "feed": {"type": "latest-yml", "url": "https://example.com/latest.yml"}}' 2>&1 >/dev/null)"
rm -f "$scratch/served/rx" "$scratch/served/js" "$scratch/served/latest.yml"

# --- recipes in a blob-less clone -------------------------------------------------------

# A blob-less clone of a local repository. pgit allows https only, so every
# blob the clone lacks is a fetch that fails, as it does offline.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
src=$scratch/pkgs-src
tgit init -q "$src"
mkdir -p "$src/pkgbuilds/foo/.omarchy" "$src/pkgbuilds/bar"
printf 'pkgname=foo\npkgver=1.2.3\npkgrel=1\n' >"$src/pkgbuilds/foo/PKGBUILD"
echo '{"upstream": {"type": "github"}, "min_release_age": "24h"}' >"$src/pkgbuilds/foo/.omarchy/package.json"
printf 'pkgname=bar\npkgver=1\npkgrel=1\n' >"$src/pkgbuilds/bar/PKGBUILD"
tgit -C "$src" add -A
tgit -C "$src" commit -q -m one
tgit clone -q --bare "$src" "$scratch/pkgs.git"
tgit -C "$scratch/pkgs.git" config uploadpack.allowFilter true
real_pkgs_dir=$pkgs_dir
pkgs_dir=$scratch/pkgs-clone
tgit init -q "$pkgs_dir"
tgit -C "$pkgs_dir" remote add origin "file://$scratch/pkgs.git"
tgit -C "$pkgs_dir" -c protocol.file.allow=always fetch -q --filter=blob:none origin main
rev=$(git -C "$pkgs_dir" rev-parse FETCH_HEAD)
rc_of() { "$@" >/dev/null 2>&1; echo $?; }
same "recipe_has: a file in the tree, no blob needed" 0 "$(rc_of recipe_has "$rev" foo PKGBUILD)"
same "recipe_has: a file not in the tree" 1 "$(rc_of recipe_has "$rev" foo .omarchy/upstream.sh)"
same "recipe_has: no recipe" 1 "$(rc_of recipe_has "$rev" baz PKGBUILD)"
same "recipe_has: a commit the clone cannot read" 2 "$(rc_of recipe_has 0123456789abcdef0123456789abcdef01234567 foo PKGBUILD)"
same "recipe_file: a blob that cannot be fetched is a failed read, not a missing file" 2 \
  "$(rc_of recipe_file "$rev" foo .omarchy/package.json)"
same "recipe_blocker: then a failed check, not 'no upstream watch'" "1||could not read pkgbuilds/foo/.omarchy/package.json at ${rev:0:12}" \
  "$(out=$(recipe_blocker "$rev" foo 2>"$scratch/rb.err"); echo "$?|$out|$(grep -o "^could not read pkgbuilds/foo/.omarchy/package.json at ${rev:0:12}" "$scratch/rb.err")")"
same "recipe_release_age: an unreadable package.json fails" 1 "$(rc_of recipe_release_age "$rev" foo)"
same "recipe_blocker: a package without a recipe still says so" 'No baz recipe in omarchy-pkgs' "$(recipe_blocker "$rev" baz)"
same "recipe_blocker: a recipe without package.json needs no blob" 'Repo recipe has no upstream watch yet' "$(recipe_blocker "$rev" bar)"
same "recipe_source: a recipeCommit whose base recipe cannot be read fails" 1 \
  "$(rc_of recipe_source foo '{"recipeCommit": "0123456789abcdef0123456789abcdef01234567"}')"
# The blobs fetched as the real clone would, from its (here local) origin.
tgit -C "$pkgs_dir" -c protocol.file.allow=always cat-file -e "$rev:pkgbuilds/foo/.omarchy/package.json"
tgit -C "$pkgs_dir" -c protocol.file.allow=always cat-file -e "$rev:pkgbuilds/foo/PKGBUILD"
same "recipe_blocker: once the blob is here, the watch counts" '0|' "$(out=$(recipe_blocker "$rev" foo 2>&1); echo "$?|$out")"
same "recipe_release_age: and its window" 86400 "$(recipe_release_age "$rev" foo)"
same "recipe_file: and the file reads" 'pkgname=foo' "$(recipe_file "$rev" foo PKGBUILD | head -1)"
pkgs_dir=$real_pkgs_dir
unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM

# --- run_killable -------------------------------------------------------------------------

same "run_killable: the command's output and exit status" 'out|3' "$(run_killable timeout 10 sh -c 'printf out; exit 3'; echo "|$?")"
same "run_killable: the lock fds are closed for the command" 'closed' \
  "$( (exec 9>"$scratch/fd9"; run_killable timeout 10 sh -c '{ true >&9; } 2>/dev/null && echo open || echo closed') )"

# --- whole runs of omabump-check ----------------------------------------------------------

# Fake pacman (only claude-desktop installed), curl (every fetch fails), git
# (every call fails) and mise (logs its calls, knows no tool; with
# $OMABUMP_TEST_HANG set, `mise ls --json` hangs and notes its pid there).
# HOME, the XDG directories and Omarchy's menu all point into $run_dir, and
# every run passes --no-notify.
run_dir=$scratch/check-run
mkdir -p "$run_dir/bin" "$run_dir/home/.config/omarchy"
printf '#!/bin/sh\n[ "$1" = -Q ] && [ "$3" = claude-desktop ] && { echo "claude-desktop 1.0-1"; exit 0; }\nexit 1\n' >"$run_dir/bin/pacman"
printf '#!/bin/sh\nexit 7\n' >"$run_dir/bin/curl"
printf '#!/bin/sh\nexit 1\n' >"$run_dir/bin/git"
cat >"$run_dir/bin/mise" <<'EOF'
#!/bin/sh
echo "$*" >>"$OMABUMP_TEST_MISE"
if [ "$*" = "ls --json" ] && [ -n "${OMABUMP_TEST_HANG:-}" ]; then
  echo $$ >"$OMABUMP_TEST_HANG"
  exec sleep 60
fi
echo '{}'
EOF
chmod +x "$run_dir/bin/"*
run_state=$run_dir/state/omarchy/plugins/io.github.vladkarok.omabump
run_settings() { printf '{"plugins": [{"id": "io.github.vladkarok.omabump"%s}]}' "$1" >"$run_dir/home/.config/omarchy/shell.json"; }
# The check under `timeout -k 5 120`, as Main.qml runs it, in the background:
# $! is the timeout's pid.
check_bg() {
  : >"$run_dir/mise.log"
  HOME=$run_dir/home XDG_CONFIG_HOME=$run_dir/config XDG_STATE_HOME=$run_dir/state XDG_CACHE_HOME=$run_dir/cache \
    OMARCHY_PATH=$run_dir/omarchy PATH=$run_dir/bin:$PATH OMABUMP_TEST_MISE=$run_dir/mise.log \
    timeout -k 5 120 "$root/bin/omabump-check" --no-notify "$@" >/dev/null 2>&1 &
}
check_run() { check_bg "$@"; wait "$!"; }
run_status() { jq -r "$1" "$run_state/status.json" 2>&1; }
# Scratch files a run left: dot files in the state and cache directories
# but the two lock files.
leftovers() { find "$run_dir/state" "$run_dir/cache" -name '.*' ! -name .check.lock ! -name omarchy-pkgs.lock -printf '%f\n' 2>/dev/null; }

run_settings ', "showMise": "false"'
check_run; rc=$?
same "a run: exit 0, runError empty, nothing left checking" '0||false|0' \
  "$rc|$(run_status '"\(.runError)|\(.checking)|\([.apps[] | select(.checking == true)] | length)"')"
same "a run with no --no-mise flag honours showMise false in shell.json: mise never runs" '' "$(cat "$run_dir/mise.log")"
same "a run leaves no scratch files" '' "$(leftovers)"
run_settings ''
check_run
same "without the setting the mise rows are checked, mise's setting read first" 'settings get disable_backends|ls --json' \
  "$(head -2 "$run_dir/mise.log" | paste -sd'|')"
run_settings ', "showMise": true'
check_run --no-mise
same "--no-mise wins over showMise true" '' "$(cat "$run_dir/mise.log")"

# TERM while a command under its own timeout runs (mise here; git, curl
# feeds and discovery go the same way): the trap must not wait for it.
mkdir -p "$run_state/.check.stale" && : >"$run_state/.status.stale" && : >"$run_state/.state.stale"
rm -f "$run_dir/hang.pid"
OMABUMP_TEST_HANG=$run_dir/hang.pid check_bg
pid=$!
for _ in $(seq 100); do [[ -s $run_dir/hang.pid ]] && break; sleep 0.1; done
same "TERM: the check reached the hanging mise" yes "$([[ -s $run_dir/hang.pid ]] && echo yes)"
term_at=$(date +%s%N)
kill -TERM "$pid"
wait "$pid"; rc=$?
waited_ms=$(( ($(date +%s%N) - term_at) / 1000000 ))
same "TERM: the check ends with its trap's 143, not KILL's 137" 143 "$rc"
check "TERM: well inside the 5 s before the KILL ($waited_ms ms)" test "$waited_ms" -lt 4000
same "TERM: status.json says the run stopped early, no row left checking" 'The check stopped early (exit 143)|false|0' \
  "$(run_status '"\(.runError)|\(.checking)|\([.apps[] | select(.checking == true)] | length)"')"
hung=$(cat "$run_dir/hang.pid" 2>/dev/null)
refuse "TERM: the hanging mise is stopped too" kill -0 "${hung:-0}"
same "TERM: no scratch files are left, an earlier killed run's included" '' "$(leftovers)"
[[ -z $hung ]] || kill "$hung" 2>/dev/null

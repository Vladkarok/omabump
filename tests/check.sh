# shellcheck shell=bash
# Tests for the background check: the agent wrapper parser and its
# warnings, mise answers of odd shapes, pins.json of the wrong shape, feed
# outputs that are not versions, recipe reads in a blob-less clone, and
# whole runs of bin/omabump-check against fake tools (runError, TERM, INT
# and HUP, the lock, scratch files, the shell.json settings). Sourced by
# tests/run.sh, whose helpers, stubs and $scratch it uses.
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
# A colon after the first @ (but a leading one) is the version's, not a
# backend's.
for pair in 'npm:@scope/omp@1.2.3|npm:@scope/omp' 'omp@latest|omp' '@scope/omp@2|@scope/omp' 'aqua:o/omp@prefix:1|aqua:o/omp' \
  'ubi:o/omp[exe=omp]@1.0|ubi:o/omp' 'http:omp[url=https://u@example.com/x]|http:omp' \
  'omp@prefix:1|omp' '@s/x@ref:main|@s/x' 'npm:@s/x@ref:main|npm:@s/x' 'github:o/omp|github:o/omp'; do
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
put '#!/bin/bash' 'echo "run mise use -g omp first" >&2' 'exit 1'
same "wrapper: mise use in an echo string is silent" 'omp/command|' "$(omp_of)|$(omp_warning)"
put '#!/bin/bash' 'exec /opt/omp/bin/omp "$@"  # was: exec mise x "omp" -- "omp" "$@"'
same "wrapper: mise in a trailing comment is silent" 'omp/command|' "$(omp_of)|$(omp_warning)"

# A changed template that still runs mise is named: mise as the command,
# after exec, command or NAME=value, by path, with global flags first.
put '#!/bin/bash' 'exec mise -C "$HOME" x "a" -- "omp" "$@"'
rejected "a changed template: -C DIR before x" 'line 2 is not a line of an omarchy-mise-install wrapper'
put '#!/bin/bash' 'MISE_YES=1 command ~/.local/bin/mise --cd /tmp -q use -g "a"'
rejected "a changed template: NAME=value, command and a path to mise" 'line 2 is not a line of an omarchy-mise-install wrapper'
# Each global flag that takes a value, and mise as a command after env,
# sudo, if, &&, $( or a backslash-newline.
for line in 'exec mise -E dev x "a" -- "omp" "$@"' 'mise --jobs 4 use -g "a"' 'mise -j 4 --env dev use -g "a"' \
  'mise --log-level debug -P dev --profile=x use -g "a"' 'env MISE_YES=1 mise use -g "a"' 'sudo mise use -g "a"' \
  'if mise use -g "a"; then exit 1; fi' 'cd /tmp && exec mise x "a" -- "omp" "$@"' 'v=$(mise x "a" -- omp --version)' \
  $'mise use -g \\\n  "a"'; do
  put '#!/bin/bash' "$line"
  rejected "a changed template: ${line//$'\n'/ }" 'line 2 is not a line of an omarchy-mise-install wrapper'
done
# A script of the user's that only names mise, in a string with ; in it or
# one over two lines, stays silent.
put '#!/bin/bash' 'echo "not yet; mise use -g omp first" >&2' 'exit 1'
same "wrapper: mise after a ; inside a string is silent" 'omp/command|' "$(omp_of)|$(omp_warning)"
put '#!/bin/bash' 'echo "install it first:' 'mise use -g omp" >&2' 'exit 1'
same "wrapper: mise on the second line of a string is silent" 'omp/command|' "$(omp_of)|$(omp_warning)"

# Flags that could each be read two ways made the match backtrack
# exponentially: 40 of them took hours. Each now reads one way.
put '#!/bin/bash' "mise $(printf -- '--x %.0s' {1..40})y" "mise $(printf -- '-C %.0s' {1..40})y" \
  "$(printf 'A=1 exec %.0s' {1..40})mise $(printf -- '--cd -x %.0s' {1..40})y"
t0=$(date +%s%N)
out=$(timeout 10 python3 -I "$root/bin/omabump-discover" --stock "$d2/stock.jsonc" --user "$d2/user.jsonc" --bin-dir "$d2/bin" \
  | jq -r '.agents[] | select(.command == "omp") | "\(.key)|\(.warning // "")"')
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
same "wrapper: 40 flags that run nothing are silent" 'omp|' "$out"
check "wrapper: and are read within a second ($ms ms)" test "$ms" -lt 1000
rm -f "$d2/bin/omp"

# --- discovery: the menus ---------------------------------------------------------

python3 -c 'print("{\"a\": " + "[" * 100000 + "]" * 100000 + "}")' >"$d2/user.jsonc"
same "menu: one nested too deeply is that menu's error, the stock agents still count" '1|omp hermes' \
  "$(disc2 | jq -r '[(.errors | map(select(test("nested too deeply"))) | length), (.agents | map(.command) | join(" "))] | join("|")')"
# The limit is Omabump's own, the same on any stack: 64 levels pass, 65 do not,
# and brackets inside strings do not count.
python3 -c 'print("{\"a\": \"[[[[\", \"b\": " + "[" * 63 + "]" * 63 + "}")' >"$d2/user.jsonc"
same "menu: 64 levels are read" '0' "$(disc2 | jq -r '.errors | map(select(test("nested too deeply"))) | length')"
python3 -c 'print("{\"b\": " + "[" * 64 + "]" * 64 + "}")' >"$d2/user.jsonc"
same "menu: 65 levels are too deep" '1' "$(disc2 | jq -r '.errors | map(select(test("nested too deeply"))) | length')"
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
printf '%s\n' '"3.1"' >"$scratch/served/js"
same "feed_version: a path that fails on the document says so" 'the feed path fails on this feed' \
  "$(feed_version "$(json_app .version)" 2>&1 >/dev/null)"
printf '%s\n' '{"version": "1.0"}' '{"version": "2.0"}' >"$scratch/served/js"
same "feed_version: a json feed of two documents is a sentence, not a bash error" 'the feed holds 2 JSON documents, not one' \
  "$(feed_version "$(json_app .version)" 2>&1 >/dev/null)"
: >"$scratch/served/js"
same "feed_version: an empty json feed" 'the feed is empty' "$(feed_version "$(json_app .version)" 2>&1 >/dev/null)"
printf '%s\n' '{"version": "1.0"} trailing' >"$scratch/served/js"
same "feed_version: a json feed with more after the document is not JSON" 'feed is not JSON' \
  "$(feed_version "$(json_app .version)" 2>&1 >/dev/null)"
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

# Waits up to ten seconds for the file $1 to have something in it.
appears() { for _ in $(seq 100); do [[ -s $1 ]] && return 0; sleep 0.1; done; return 1; }
# Ctrl-C in a terminal: INT to the whole group of a job whose INT is not
# ignored (set -m), while the script runs a command directly, not in
# $(...). The command's own group is stopped, and the script stops too
# instead of going on to its next step as if one command had failed.
cat >"$scratch/int-step.sh" <<'EOF'
set -euo pipefail
source "$1/bin/omabump-common"
run_killable timeout 30 sh -c 'echo $$ >"$1"; exec sleep 30' _ "$2"
echo "the next step"
EOF
rm -f "$scratch/int.pid"
rc=$( set -m
  bash "$scratch/int-step.sh" "$root" "$scratch/int.pid" >"$scratch/int.out" 2>&1 &
  appears "$scratch/int.pid"
  kill -INT -- "-$!"
  wait "$!"; echo "$?" ) 2>/dev/null
same "run_killable: Ctrl-C stops the script, not only the command" '130|' "$rc|$(cat "$scratch/int.out")"
slept=$(cat "$scratch/int.pid" 2>/dev/null)
refuse "run_killable: and the command it ran is stopped" kill -0 "${slept:-0}"
[[ -z $slept ]] || kill "$slept" 2>/dev/null

# --- whole runs of omabump-check ----------------------------------------------------------

# Fake pacman (only claude-desktop and foo-old installed, or with
# $OMABUMP_TEST_PKGS set the "<name> <version>" lines of that file; with
# $OMABUMP_TEST_Q_HOOK set, each -Q runs that shell command first),
# pacman-conf (the database in $run_dir/pacman-db), curl (every fetch
# fails), sudo (only looked for, never run), git (every call fails) and mise
# (logs its calls, knows no tool; with $OMABUMP_TEST_HANG set, `mise ls
# --json` hangs and notes its pid there, with $OMABUMP_TEST_LS_FAIL set it
# fails, with $OMABUMP_TEST_LS_HOOK set it runs that shell command first,
# with $OMABUMP_TEST_MISE_LS set it prints that file). curl and git
# note each call in net.log, but the git config reads omabump-common makes
# when it is sourced. HOME, the XDG directories and Omarchy's menu all point
# into $run_dir, and every run passes --no-notify but ai_notify's, which
# puts a fake notify-send first on PATH.
run_dir=$scratch/check-run
mkdir -p "$run_dir/bin" "$run_dir/home/.config/omarchy" "$run_dir/pacman-db"
cat >"$run_dir/bin/pacman" <<'EOF'
#!/bin/sh
[ "$1" = -Q ] || exit 1
[ -z "${OMABUMP_TEST_Q_HOOK:-}" ] || sh -c "$OMABUMP_TEST_Q_HOOK"
if [ -n "${OMABUMP_TEST_PKGS:-}" ]; then
  awk -v n="$3" '$1 == n { print; found = 1 } END { exit !found }' "$OMABUMP_TEST_PKGS"
  exit
fi
case $3 in
  claude-desktop|foo-old) echo "$3 1.0-1" ;;
  *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\necho "%s/pacman-db/"\n' "$run_dir" >"$run_dir/bin/pacman-conf"
printf '#!/bin/sh\necho "curl $*" >>"$OMABUMP_TEST_NET"\nexit 7\n' >"$run_dir/bin/curl"
printf '#!/bin/sh\nexit 1\n' >"$run_dir/bin/sudo"
printf '#!/bin/sh\n[ "$1" = config ] || echo "git $*" >>"$OMABUMP_TEST_NET"\nexit 1\n' >"$run_dir/bin/git"
cat >"$run_dir/bin/mise" <<'EOF'
#!/bin/sh
echo "${MISE_OFFLINE:+MISE_OFFLINE=$MISE_OFFLINE }$*" >>"$OMABUMP_TEST_MISE"
if [ "$*" = "ls --json" ] && [ -n "${OMABUMP_TEST_HANG:-}" ]; then
  echo $$ >"$OMABUMP_TEST_HANG"
  exec sleep 60
fi
if [ "$*" = "ls --json" ] && [ -n "${OMABUMP_TEST_LS_FAIL:-}" ]; then
  echo "mise: no inventory" >&2
  exit 1
fi
if [ "$*" = "ls --json" ] && [ -n "${OMABUMP_TEST_LS_HOOK:-}" ]; then
  sh -c "$OMABUMP_TEST_LS_HOOK"
fi
if [ "$*" = "ls --json" ] && [ -n "${OMABUMP_TEST_MISE_LS:-}" ]; then
  cat "$OMABUMP_TEST_MISE_LS"
  exit
fi
echo '{}'
EOF
chmod +x "$run_dir/bin/"*
run_state=$run_dir/state/omarchy/plugins/io.github.vladkarok.omabump
run_settings() { printf '{"plugins": [{"id": "io.github.vladkarok.omabump"%s}]}' "$1" >"$run_dir/home/.config/omarchy/shell.json"; }
run_env=(HOME="$run_dir/home" XDG_CONFIG_HOME="$run_dir/config" XDG_STATE_HOME="$run_dir/state"
  XDG_CACHE_HOME="$run_dir/cache" OMARCHY_PATH="$run_dir/omarchy" PATH="$run_dir/bin:$PATH"
  OMABUMP_TEST_MISE="$run_dir/mise.log" OMABUMP_TEST_NET="$run_dir/net.log")
# The check under `timeout -k 5 120`, as Main.qml runs it, in the background:
# $! is the timeout's pid (env execs it).
check_bg() {
  : >"$run_dir/mise.log"
  : >"$run_dir/net.log"
  env "${run_env[@]}" timeout -k 5 120 "$root/bin/omabump-check" --no-notify "$@" >/dev/null 2>&1 &
}
check_run() { check_bg "$@"; wait "$!"; }
run_status() { jq -r "$1" "$run_state/status.json" 2>&1; }
# Scratch files a run left: dot files in the state and cache directories
# but the lock files.
leftovers() {
  find "$run_dir/state" "$run_dir/cache" -name '.*' ! -name .check.lock ! -name .local.lock ! -name omarchy-pkgs.lock \
    -printf '%f\n' 2>/dev/null
}

run_settings ', "showMise": "false"'
check_run; rc=$?
same "a run: exit 0, runError empty, nothing left checking" '0||false|0' \
  "$rc|$(run_status '"\(.runError)|\(.checking)|\([.apps[] | select(.checking == true)] | length)"')"
same "a run with no --no-mise flag honours showMise false in shell.json: mise never runs" '' "$(cat "$run_dir/mise.log")"
same "a run leaves no scratch files" '' "$(leftovers)"
check "a run keeps its lock file: the leftover sweep spares it" test -e "$run_state/.check.lock"
run_settings ''
check_run
same "without the setting the mise rows are checked, mise's setting read first" 'settings get disable_backends|ls --json' \
  "$(head -2 "$run_dir/mise.log" | paste -sd'|')"
run_settings ', "showMise": true'
check_run --no-mise
same "--no-mise wins over showMise true" '' "$(cat "$run_dir/mise.log")"

# TERM while a command under its own timeout runs (mise here; git, curl
# feeds and discovery go the same way): the trap must not wait for it.
# The .check.XXXXXX dir is an older release's scratch dir.
mkdir -p "$run_state/.run.stale" "$run_state/.check.Ab12Cd" && : >"$run_state/.status.stale" && : >"$run_state/.state.stale"
rm -f "$run_dir/hang.pid"
OMABUMP_TEST_HANG=$run_dir/hang.pid check_bg
pid=$!
appears "$run_dir/hang.pid"
same "TERM: the check reached the hanging mise" yes "$([[ -s $run_dir/hang.pid ]] && echo yes)"
# A second check while the first runs (a shell reload starts one per bar):
# the lock is still there and held, so it ends at once without a mise call,
# and its start leaves the first one's scratch dir alone. It exits 75, the
# exit Model.js reads as a run that left on the lock (no check ran, and
# none failed), and says why in one line.
lock_busy_exit=$(sed -n 's/^var lockBusyExit = \([0-9]*\)$/\1/p' "$root/Model.js")
: >"$run_dir/mise.log"
env "${run_env[@]}" timeout -k 5 120 "$root/bin/omabump-check" --no-notify >/dev/null 2>"$run_dir/busy.err"; rc=$?
same "a second check while one runs: exits Model.lockBusyExit, mise never called" "${lock_busy_exit:-none}|" \
  "$rc|$(cat "$run_dir/mise.log")"
same "a second check while one runs: one line on stderr says no check ran" '1|no check ran' \
  "$(wc -l <"$run_dir/busy.err")|$(grep -o 'no check ran' "$run_dir/busy.err")"
same "a second check while one runs: the first one's scratch dir is still there" 1 \
  "$(find "$run_state" -maxdepth 1 -name '.run.*' | wc -l)"
check "a second check while one runs: the first one still runs" kill -0 "$pid"
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

# Ctrl-C (INT) or a closed terminal (HUP) on a check run from a terminal:
# the signal reaches the check's whole process group, which is a job of its
# own whose INT is not ignored (set -m), as in an interactive shell.
# status.json says how the run ended, never "exit 0", and the hanging mise
# is stopped.
check_signalled() {
  rm -f "$run_dir/hang.pid"
  ( set -m
    env "${run_env[@]}" OMABUMP_TEST_HANG="$run_dir/hang.pid" "$root/bin/omabump-check" --no-notify >/dev/null 2>&1 &
    appears "$run_dir/hang.pid"
    kill "-$1" -- "-$!"
    wait "$!"; echo "$?" ) 2>/dev/null
}
for pair in INT:130 HUP:129; do
  rc=$(check_signalled "${pair%:*}")
  same "${pair%:*}: the check ends with ${pair#*:} and status.json says so" \
    "${pair#*:}|The check stopped early (exit ${pair#*:})|0" \
    "$rc|$(run_status '"\(.runError)|\([.apps[] | select(.checking == true)] | length)"')"
  hung=$(cat "$run_dir/hang.pid" 2>/dev/null)
  refuse "${pair%:*}: the hanging mise is stopped too" kill -0 "${hung:-0}"
  [[ -z $hung ]] || kill "$hung" 2>/dev/null
done

# --wait (the installer's refresh) waits for a held lock instead, says so,
# and runs once the lock is free. The holder lets go by itself within 10 s,
# so a test that breaks cannot hang the suite. Show mise tools turned off
# during the wait counts: the settings are read once the lock is held.
rm -f "$run_dir/held" "$run_dir/go"
( exec 8>"$run_state/.check.lock" && flock 8 && echo held >"$run_dir/held" && appears "$run_dir/go" ) &
holder=$!
appears "$run_dir/held"
run_settings ', "showMise": true'
: >"$run_dir/mise.log"
env "${run_env[@]}" timeout -k 5 120 "$root/bin/omabump-check" --no-notify --wait >/dev/null 2>"$run_dir/wait.err" &
waiter=$!
appears "$run_dir/wait.err"
check "--wait: still waiting while the lock is held" kill -0 "$waiter"
run_settings ', "showMise": false'
echo go >"$run_dir/go"
wait "$holder"
wait "$waiter"; rc=$?
same "--wait: says it waits, then runs once the lock is free" '0|Waiting for the running check to end...|false|' \
  "$rc|$(head -1 "$run_dir/wait.err")|$(run_status '"\(.checking)|\(.runError)"')"
same "--wait: reads showMise once it holds the lock, not before its wait" '' "$(cat "$run_dir/mise.log")"
# A wait that gives up (a flock that always fails stands in for 11 minutes
# of a held lock) exits 75 too, says so, and leaves status.json as it was.
mkdir -p "$run_dir/busy"
printf '#!/bin/sh\nexit 1\n' >"$run_dir/busy/flock"
chmod +x "$run_dir/busy/flock"
before=$(md5sum <"$run_state/status.json")
env "${run_env[@]}" PATH="$run_dir/busy:$run_dir/bin:$PATH" timeout -k 5 120 "$root/bin/omabump-check" --no-notify --wait \
  >/dev/null 2>"$run_dir/wait.err"; rc=$?
same "--wait: a wait that gives up exits Model.lockBusyExit, saying no check ran" "${lock_busy_exit:-none}|no check ran" \
  "$rc|$(tail -1 "$run_dir/wait.err" | grep -o 'no check ran')"
same "--wait: and leaves status.json as it was" "$before" "$(md5sum <"$run_state/status.json")"
rm -rf "$run_dir/busy" "$run_dir/held" "$run_dir/go" "$run_dir/wait.err" "$run_dir/busy.err"

# --- status.json's shape: schemaVersion, the switch, old scratch files ---------------------

# A vendor package installed under another name (foo-old for foo-bin), its
# version from a command feed in the user's apps.json. The row says that
# with installedName, switchable and updateAvailable; its note no longer
# carries the switch clause the panel now writes.
run_settings ', "showMise": "false"'
mkdir -p "$run_dir/config/omarchy/omabump"
foo_app() {
  jq -cn --arg v "$1" '[{pkg: "foo-bin", label: "Foo", source: "vendor-pkg", installed: ["foo-bin", "foo-old"],
    vendorPkg: "https://example.com/foo-{version}.pkg.tar.zst", checksum: "feed",
    feed: {type: "command", command: "echo \($v)"}}]' >"$run_dir/config/omarchy/omabump/apps.json"
}
foo_row='.apps[] | select(.pkg == "foo-bin") | "\(.installedName)|\(.installable)|\(.updateAvailable)|\(.switchable)|\(.note)"'
foo_app 1.0
check_run
same "status.json: schemaVersion 1" 1 "$(run_status .schemaVersion)"
same "switch: at the same version the row is switchable, the note has no switch clause" 'foo-old|true|false|true|' "$(run_status "$foo_row")"
foo_app 2.0
check_run
same "switch: with a newer version Update switches, the note has no switch clause" 'foo-old|true|true|false|' "$(run_status "$foo_row")"
same "status.json: every row has unchecked" 0 "$(run_status '[.apps[] | select(.unchecked | type != "boolean")] | length')"
# The same row with its Update turned off in apps.json: the update still
# shows, the route does not, and the row says why.
jq -c '.[0].updateBlocked = "a known problem, see x#1"' "$run_dir/config/omarchy/omabump/apps.json" >"$run_dir/blocked.json"
mv "$run_dir/blocked.json" "$run_dir/config/omarchy/omabump/apps.json"
check_run
same "updateBlocked: the update shows, Update and Switch are off, the note says why" \
  'true|false|false|true|Update off: a known problem, see x#1' \
  "$(run_status '.apps[] | select(.pkg == "foo-bin") | "\(.updateAvailable)|\(.installable)|\(.switchable)|\(.blocked)|\(.note)"')"
same "updateBlocked: rows without it say blocked false" 0 "$(run_status '[.apps[] | select(.pkg != "foo-bin" and .blocked != false)] | length')"
rm -f "$run_dir/config/omarchy/omabump/apps.json"

# status.json, read with the jq filter $1 while a check runs: the check
# hangs in mise until the file is read, then is stopped.
status_mid_run() {
  local pid hung
  rm -f "$run_dir/hang.pid"
  OMABUMP_TEST_HANG=$run_dir/hang.pid check_bg
  pid=$!
  appears "$run_dir/hang.pid"
  run_status "$1"
  kill -TERM "$pid"
  wait "$pid"
  hung=$(cat "$run_dir/hang.pid" 2>/dev/null)
  [[ -z $hung ]] || kill "$hung" 2>/dev/null
}

# A status.json an older release wrote (no schemaVersion) shows while the
# next run checks: its notes lose the switch clause, and a skipped mise row
# is marked unchecked.
run_settings ''
cat >"$run_state/status.json" <<'JSON'
{"checkedAt": "2026-01-01T00:00:00+00:00", "apps": [
  {"pkg": "foo-bin", "source": "vendor-pkg", "note": "Installed as foo-old, switch to foo-bin; Recipe from omarchy-pkgs 0123456789ab"},
  {"pkg": "bar-bin", "source": "omarchy", "note": "Installed as bar-old, Update switches to bar-bin"},
  {"pkg": "baz", "source": "omarchy", "note": "No baz recipe in omarchy-pkgs"},
  {"pkg": "mise:t", "source": "mise", "note": "Update check skipped: asdf backend"}]}
JSON
same "an older status.json: notes lose the switch clause, a skipped mise row is unchecked" \
  'bar-bin=/false baz=No baz recipe in omarchy-pkgs/false foo-bin=Recipe from omarchy-pkgs 0123456789ab/false mise:t=Update check skipped: asdf backend/true|1' \
  "$(status_mid_run '"\([.apps[] | "\(.pkg)=\(.note)/\(.unchecked)"] | sort | join(" "))|\(.schemaVersion)"')"
# When mise's inventory fails, the mise rows of that file stay, failed, to
# the end of the run, and keep the unchecked the migration gave them.
cat >"$run_state/status.json" <<'JSON'
{"checkedAt": "2026-01-01T00:00:00+00:00", "apps": [
  {"pkg": "mise:t", "source": "mise", "note": "Update check skipped: asdf backend"},
  {"pkg": "mise:u", "source": "mise", "note": ""}]}
JSON
OMABUMP_TEST_LS_FAIL=1 check_run
same "an older status.json and a failed mise ls: its mise rows stay, stale, with unchecked" \
  'mise:t=true/true/mise ls failed mise:u=false/true/mise ls failed|1' \
  "$(run_status '"\([.apps[] | select(.source == "mise") | "\(.pkg)=\(.unchecked)/\(.stale)/\(.error | .[:14])"] | sort | join(" "))|\(.schemaVersion)"')"
# A file of this release (schemaVersion 1) shows as it is: a note that
# happens to read like the old clause keeps it, unchecked stays false.
cat >"$run_state/status.json" <<'JSON'
{"schemaVersion": 1, "checkedAt": "2026-01-01T00:00:00+00:00", "apps": [
  {"pkg": "foo-bin", "source": "vendor-pkg", "note": "Installed as a, switch to b", "unchecked": false},
  {"pkg": "mise:t", "source": "mise", "note": "Update check skipped: asdf backend", "unchecked": false}]}
JSON
same "a status.json with schemaVersion 1 is not migrated" \
  'foo-bin=Installed as a, switch to b/false mise:t=Update check skipped: asdf backend/false' \
  "$(status_mid_run '[.apps[] | "\(.pkg)=\(.note)/\(.unchecked)"] | sort | join(" ")')"
rm -f "$run_state/status.json"

# Scratch files an Update makes while it runs, without the check's lock, and
# an older release's check made outside its run's dir: a check removes only
# the day-old ones. An older release's .notified file goes at once.
run_cache=$run_dir/cache/omabump
mkdir -p "$run_cache/.mise-select.Old123" "$run_cache/.mise-select.New123"
: >"$run_cache/.mise-select.Old123/ls.json"
for f in "$run_cache/.mise.Old123" "$run_cache/.feed.Old123" "$run_state/.discovered.Old123" \
  "$run_cache/.mise.New123" "$run_cache/.feed.New123" "$run_state/.discovered.New123" "$run_state/.notified.Ab12Cd"; do
  : >"$f"
done
touch -d '2 days ago' "$run_cache/.mise.Old123" "$run_cache/.feed.Old123" "$run_state/.discovered.Old123" "$run_cache/.mise-select.Old123"
# A killed Update's half downloads and sync-upstream's mktemp dirs: the
# day-old ones go. A whole package and a scratch file by another name stay,
# however old.
mkdir -p "$run_cache/packages" "$run_cache/scratch/tmp.Old1234567" "$run_cache/scratch/tmp.New1234567"
for f in "$run_cache/packages/foo-1.0.pkg.tar.zst.part" "$run_cache/packages/foo-1.1.pkg.tar.zst.part" \
  "$run_cache/packages/foo-0.9.pkg.tar" "$run_cache/scratch/tmp.Old1234567/x" "$run_cache/scratch/hook.tar"; do
  : >"$f"
done
touch -d '2 days ago' "$run_cache/packages/foo-1.0.pkg.tar.zst.part" "$run_cache/packages/foo-0.9.pkg.tar" \
  "$run_cache/scratch/tmp.Old1234567" "$run_cache/scratch/hook.tar"
run_settings ', "showMise": "false"'
check_run
same "a run removes day-old scratch files only, and an older release's .notified" \
  '.discovered.New123 .feed.New123 .mise-select.New123 .mise.New123' "$(leftovers | sort | paste -sd' ')"
same "a run removes day-old half downloads and sync-upstream dirs only" \
  'foo-0.9.pkg.tar foo-1.1.pkg.tar.zst.part hook.tar tmp.New1234567' \
  "$(find "$run_cache/packages" "$run_cache/scratch" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd' ')"
check "and keeps its lock" test -e "$run_state/.check.lock"
rm -rf "$run_cache/packages" "$run_cache/scratch"
rm -rf "$run_cache"/.mise.New123 "$run_cache"/.feed.New123 "$run_cache"/.mise-select.New123 "$run_state"/.discovered.New123

# --- a local refresh (--local) ------------------------------------------------------------

# Apps of the user's apps.json on each route --local reads again: omarchy
# rows (one with an update, one whose release omarchy-pkgs holds), a
# vendor package that may be installed under another name, indicators (one
# installed, one not yet) and mise tools, one with a second key. loc_status
# writes the status.json a check left for them: the fields that matter
# here over the rest of a row as a check writes it.
run_settings ''
cat >"$run_dir/config/omarchy/omabump/apps.json" <<'JSON'
[{"pkg": "loc-a", "label": "Loc A", "source": "omarchy", "feed": {"type": "github-release", "repo": "o/a"}},
 {"pkg": "loc-b", "label": "Loc B", "source": "vendor-pkg", "installed": ["loc-b", "loc-b-old"], "feed": {"type": "github-release", "repo": "o/b"}},
 {"pkg": "loc-held", "label": "Loc Held", "source": "omarchy", "feed": {"type": "github-release", "repo": "o/h"}},
 {"pkg": "loc-gone", "label": "Loc Gone", "source": "indicator", "feed": {"type": "github-release", "repo": "o/g"}},
 {"pkg": "loc-new", "label": "Loc New", "source": "indicator", "icon": "assets/new.svg", "feed": {"type": "github-release", "repo": "o/n"}},
 {"pkg": "mise:t", "label": "T", "source": "mise", "tool": "t"},
 {"pkg": "mise:u", "label": "U", "source": "mise", "tool": "u"},
 {"pkg": "mise:k", "label": "K", "source": "mise", "tool": ["k", "npm:k"]}]
JSON
# Omabump's own row, at the version of this copy, is in every check's file.
self_version=$(jq -r .version "$root/manifest.json")
loc_status() {
  jq -c --arg self "$self_version" '.apps += [{pkg: "self:omabump", label: "Omabump", source: "self", installedName: "omabump",
    installed: $self, latest: $self}]
    | .apps |= map({label: "", installedName: "", installed: "", latest: "", versionFrom: "feed", updateAvailable: false,
    installable: true, error: "", note: "", stale: false, switchable: false, recipe: "", recipeCommit: "", request: "",
    muted: false, skipped: false, unchecked: false, held: false, omarchyUpdate: false, blocked: false, selfUpdating: false,
    icon: "", iconLight: ""} + .)' \
    >"$run_dir/fixture.json" <<'JSON'
{"schemaVersion": 1, "checkedAt": "2026-01-01T00:10:00+00:00", "checking": false, "startedAt": "2026-01-01T00:09:00+00:00",
 "inventoryAt": "2026-01-01T00:09:00+00:00", "runError": "", "omarchyPkgs": {"commit": "", "following": false, "error": "", "note": ""},
 "discoveryError": "", "miseError": "", "apps": [
  {"pkg": "loc-a", "source": "omarchy", "installedName": "loc-a", "installed": "1.0-1", "latest": "1.2", "updateAvailable": true,
   "skipped": true, "note": "Recipe from omarchy-pkgs 0123456789ab"},
  {"pkg": "loc-b", "source": "vendor-pkg", "installedName": "loc-b", "installed": "2.0-1", "latest": "2.0"},
  {"pkg": "loc-held", "source": "omarchy", "installedName": "loc-held", "installed": "1.0-1", "latest": "1.1", "updateAvailable": true,
   "installable": false, "held": true,
   "note": "omarchy-pkgs holds new releases for 24 h, Update from Jan 2 00:09; Recipe from omarchy-pkgs 0123456789ab"},
  {"pkg": "loc-gone", "source": "indicator", "installedName": "loc-gone", "installed": "3.0-1", "latest": "3.0", "installable": false,
   "note": "No supported install path"},
  {"pkg": "mise:t", "source": "mise", "installedName": "t", "installed": "1.0", "latest": "1.1", "versionFrom": "mise", "updateAvailable": true},
  {"pkg": "mise:u", "source": "mise", "installedName": "u", "installed": "2.0", "latest": "2.0", "versionFrom": "mise"},
  {"pkg": "mise:k", "source": "mise", "installedName": "k", "installed": "1.0", "latest": "1.5", "versionFrom": "mise",
   "installable": false, "request": "1.0", "note": "Pinned to 1.0, 1.5 exists"}]}
JSON
  cp "$run_dir/fixture.json" "$run_state/status.json"
}
# What is installed: pacman's packages as "<name> <version>", mise's active
# tools as <key>=<version>. loc_same installs what loc_status says.
loc_pkgs() { printf '%s\n' "$@" >"$run_dir/pkgs"; }
loc_tools() { jq -n '[$ARGS.positional[] | split("=") | {(.[0]): [{version: .[1], active: true}]}] | add // {}' --args "$@" >"$run_dir/mise-ls.json"; }
loc_same() { loc_pkgs 'loc-a 1.0-1' 'loc-b 2.0-1' 'loc-held 1.0-1' 'loc-gone 3.0-1'; loc_tools t=1.0 u=2.0 k=1.0; }
# A local refresh as the widget runs it (with the options $@), then $? is
# its exit; loc_row reads the jq filter $2 of the row $1, loc_was the row
# loc_status wrote, and loc_md5 what is in status.json.
local_run() { OMABUMP_TEST_PKGS=$run_dir/pkgs OMABUMP_TEST_MISE_LS=$run_dir/mise-ls.json check_run --local "$@"; }
loc_row() { run_status ".apps[] | select(.pkg == \"$1\") | $2"; }
loc_was() { jq -c --arg p "$1" '.apps[] | select(.pkg == $p)' "$run_dir/fixture.json"; }
loc_md5() { md5sum <"$run_state/status.json"; }
read -r local_full local_nostatus local_busy < <(sed -n \
  's/^full_check_exit=\([0-9]*\) no_status_exit=\([0-9]*\) pacman_busy_exit=\([0-9]*\)$/\1 \2 \3/p' "$root/bin/omabump-check")

loc_status
loc_same
echo '{"loc-a": "1.2"}' >"$run_state/notified.json"
echo '{"loc-held": {"version": "1.1", "at": 1767225540}}' >"$run_state/seen.json"
notified_md5=$(md5sum <"$run_state/notified.json") seen_md5=$(md5sum <"$run_state/seen.json")
local_run; rc=$?
same "--local: nothing moved, exit 0 and every row as it was" "0|$(jq -c .apps "$run_dir/fixture.json")" "$rc|$(run_status '.apps | tojson')"
same "--local: checkedAt and startedAt stay the check's, inventoryAt is this run's" \
  '2026-01-01T00:10:00+00:00|2026-01-01T00:09:00+00:00|false|true' \
  "$(run_status '"\(.checkedAt)|\(.startedAt)|\(.inventoryAt == "2026-01-01T00:09:00+00:00")|\(.inventoryAt | test("^20[0-9-]+T[0-9:]+[+-][0-9:]+$"))"')"
same "--local: no feed and no git call" '' "$(cat "$run_dir/net.log")"
same "--local: mise is asked for its setting and its inventory, offline, never outdated" \
  'MISE_OFFLINE=1 settings get disable_backends|MISE_OFFLINE=1 ls --json' \
  "$(paste -sd'|' "$run_dir/mise.log")"

loc_status
loc_pkgs 'loc-a 1.2-1' 'loc-b 2.0-1' 'loc-held 1.1-1'
local_run; rc=$?
same "--local: installed at the newest known version: no update, no skip, and no check needed" \
  '0|1.2-1|false|false|Recipe from omarchy-pkgs 0123456789ab' "$rc|$(loc_row loc-a '"\(.installed)|\(.updateAvailable)|\(.skipped)|\(.note)"')"
same "--local: a held release once installed: no hold, Update back, the hold's clause gone" \
  'false|false|true|Recipe from omarchy-pkgs 0123456789ab' "$(loc_row loc-held '"\(.updateAvailable)|\(.held)|\(.installable)|\(.note)"')"
same "--local: an app no longer installed loses its row" '' "$(loc_row loc-gone .pkg)"
same "--local: a row that did not move stays as it was" "$(loc_was loc-b)" "$(loc_row loc-b 'tojson')"
same "--local: notified.json and seen.json are never written" "$notified_md5|$seen_md5" \
  "$(md5sum <"$run_state/notified.json")|$(md5sum <"$run_state/seen.json")"
rm -f "$run_state/notified.json" "$run_state/seen.json"

loc_status
loc_pkgs 'loc-a 1.3-1' 'loc-b 2.0-1' 'loc-held 1.0-1' 'loc-gone 3.0-1'
local_run; rc=$?
same "--local: installed past the newest known version: not checked yet, no update, the route kept, and a check asked for" \
  "$local_full|1.3-1|false|true|true|Not checked yet" \
  "$rc|$(loc_row loc-a '"\(.installed)|\(.updateAvailable)|\(.installable)|\(.unchecked)|\(.note)"')"
same "--local: and the newest known version stays for the check" 1.2 "$(loc_row loc-a .latest)"
local_run; rc=$?
same "--local: the next refresh, nothing moved: the row stays unread, no second check asked" "0|true|Not checked yet" \
  "$rc|$(loc_row loc-a '"\(.unchecked)|\(.note)"')"
same "--local: and makes no notified.json or seen.json" '' \
  "$(find "$run_state" -maxdepth 1 \( -name notified.json -o -name seen.json \) -printf '%f\n')"

# A newer version of a held release, still below the held one: the hold
# and its note stay, and so does the row's Update, still not installable.
loc_status
loc_pkgs 'loc-a 1.0-1' 'loc-b 2.0-1' 'loc-held 1.0.5-1' 'loc-gone 3.0-1'
local_run; rc=$?
same "--local: a held app moved, still below the held release: the hold stays, no check needed" \
  "0|1.0.5-1|true|true|false|$(loc_was loc-held | jq -r .note)" \
  "$rc|$(loc_row loc-held '"\(.installed)|\(.updateAvailable)|\(.held)|\(.installable)|\(.note)"')"

# A row that names another source than the app table (the user moved the
# app to another route): only a check can say what it is now.
loc_status
jq '.apps |= map(if .pkg == "loc-b" then .source = "indicator" else . end)' "$run_dir/fixture.json" >"$run_state/status.json"
loc_pkgs 'loc-a 1.0-1' 'loc-b 2.1-1' 'loc-held 1.0-1' 'loc-gone 3.0-1'
local_run; rc=$?
same "--local: a row of another source than the table's stays as it was and asks for a check" "$local_full|indicator|2.0-1" \
  "$rc|$(loc_row loc-b '"\(.source)|\(.installed)"')"
loc_status
loc_pkgs 'loc-a 1.0-1' 'loc-b-old 2.0-1' 'loc-held 1.0-1' 'loc-gone 3.0-1'
local_run; rc=$?
same "--local: installed under another name asks for a check, the switch shows meanwhile" "$local_full|loc-b-old|2.0-1|true|false" \
  "$rc|$(loc_row loc-b '"\(.installedName)|\(.installed)|\(.switchable)|\(.updateAvailable)"')"

loc_status
loc_pkgs 'loc-a 1.0-1' 'loc-b 2.0-1' 'loc-held 1.0-1' 'loc-gone 3.0-1' 'loc-new 5.0-1'
local_run; rc=$?
same "--local: an app installed since the check: an unchecked row, and a check asked for" \
  "$local_full|Loc New|indicator|loc-new|5.0-1||false|false|true|Not checked yet|assets/new.svg" \
  "$rc|$(loc_row loc-new '"\(.label)|\(.source)|\(.installedName)|\(.installed)|\(.latest)|\(.updateAvailable)|\(.installable)|\(.unchecked)|\(.note)|\(.icon)"')"
same "--local: the new row in table order" 'loc-a loc-b loc-held loc-gone loc-new mise:t mise:u mise:k self:omabump' \
  "$(run_status '[.apps[].pkg] | join(" ")')"
same "--local: the new row has every field a check writes" "$(jq -c '.apps[0] | keys' "$run_dir/fixture.json")" "$(loc_row loc-new 'keys | tojson')"

# Omabump updated outside its Update (omarchy plugin update, a git pull):
# its row follows manifest.json as the others follow pacman.
loc_status
jq '.apps |= map(if .pkg == "self:omabump" then .installed = "0.0.1" | .updateAvailable = true else . end)' \
  "$run_dir/fixture.json" >"$run_state/status.json"
loc_same
local_run; rc=$?
same "--local: Omabump at the release its row offered: no update, no check needed" "0|$self_version|false|false" \
  "$rc|$(loc_row self:omabump '"\(.installed)|\(.updateAvailable)|\(.unchecked)"')"
jq '.apps |= map(if .pkg == "self:omabump" then .installed = "0.0.1" | .latest = "0.0.1" else . end)' \
  "$run_dir/fixture.json" >"$run_state/status.json"
local_run; rc=$?
same "--local: Omabump past its newest known release: not checked yet, and a check asked for" \
  "$local_full|$self_version|false|true|Not checked yet" \
  "$rc|$(loc_row self:omabump '"\(.installed)|\(.updateAvailable)|\(.unchecked)|\(.note)"')"

loc_status
loc_pkgs 'loc-a 1.0-1' 'loc-b 2.0-1' 'loc-held 1.0-1' 'loc-gone 3.0-1'
loc_tools t=1.1 u=2.1 npm:k=1.6
local_run; rc=$?
same "--local: a mise tool at its newest known version: no update, and a check asked for" "$local_full|1.1|false|false|1.1" \
  "$rc|$(loc_row mise:t '"\(.installed)|\(.updateAvailable)|\(.unchecked)|\(.latest)"')"
same "--local: a mise tool at another version: unchecked, no Update, the newest known kept" '2.1|false|true|false|2.0|Not checked yet' \
  "$(loc_row mise:u '"\(.installed)|\(.updateAvailable)|\(.unchecked)|\(.installable)|\(.latest)|\(.note)"')"
same "--local: a mise tool under another key: the newest known and the request go" 'npm:k|1.6|||true|' \
  "$(loc_row mise:k '"\(.installedName)|\(.installed)|\(.latest)|\(.versionFrom)|\(.unchecked)|\(.request)"')"
loc_status
loc_tools u=2.0 k=1.0
local_run; rc=$?
same "--local: a mise tool no longer active loses its row" '0|' "$rc|$(loc_row mise:t .pkg)"
loc_status
loc_tools t=1.1 u=2.1 k=1.0
OMABUMP_TEST_LS_FAIL=1 local_run; rc=$?
same "--local: mise ls failed: the mise rows stay as they were, none read as uninstalled" \
  "0|$(jq -c '[.apps[] | select(.source == "mise")]' "$run_dir/fixture.json")" "$rc|$(run_status '[.apps[] | select(.source == "mise")] | tojson')"
loc_status
loc_tools u=2.1 npm:k=1.6
local_run --no-mise; rc=$?
same "--local --no-mise: the mise rows stay as they were, and mise is never asked" \
  "0|$(jq -c '[.apps[] | select(.source == "mise")]' "$run_dir/fixture.json")|" \
  "$rc|$(run_status '[.apps[] | select(.source == "mise")] | tojson')|$(cat "$run_dir/mise.log")"

# pacman's lock file while a transaction runs: pacman -Q could read its
# database half way and miss a package being replaced. Nothing is read or
# written then, not even the mise rows: a change of theirs would ask for a
# check, which reads pacman too. Once the transaction is over, the next try
# finds it all.
loc_status
loc_pkgs 'loc-a 1.2-1' 'loc-b 2.0-1' 'loc-held 1.0-1'
loc_tools t=1.0 u=2.1 k=1.0
: >"$run_dir/pacman-db/db.lck"
status_md5=$(loc_md5)
local_run; rc=$?
same "--local: pacman mid-transaction: try again later, status.json as it was, mise not asked" \
  "$local_busy|$status_md5|" "$rc|$(loc_md5)|$(cat "$run_dir/mise.log")"
mv "$run_state/status.json" "$run_dir/status.keep"
local_run; rc=$?
same "--local: pacman mid-transaction and no status.json: try again later all the same, no check now" "$local_busy" "$rc"
mv "$run_dir/status.keep" "$run_state/status.json"
rm -f "$run_dir/pacman-db/db.lck"
local_run; rc=$?
same "--local: once it is over, the rows move and the mise change asks for its check" "$local_full|1.2-1|2.1|" \
  "$rc|$(loc_row loc-a .installed)|$(loc_row mise:u .installed)|$(loc_row loc-gone .pkg)"
# A transaction that starts during the run: while mise ls runs (after
# discovery, before pacman's rows are read), or while they are read. It
# takes loc-a out of pacman's database, as replacing a package does.
for when in LS Q; do
  loc_status
  loc_same
  status_md5=$(loc_md5)
  export "OMABUMP_TEST_${when}_HOOK=: >'$run_dir/pacman-db/db.lck'; sed -i '/^loc-a /d' '$run_dir/pkgs'"
  local_run; rc=$?
  unset "OMABUMP_TEST_${when}_HOOK"
  same "--local: pacman starts a transaction during the run ($when hook): try again later, status.json as it was" \
    "$local_busy|$status_md5" "$rc|$(loc_md5)"
  rm -f "$run_dir/pacman-db/db.lck"
done

rm -f "$run_state/status.json"
local_run; rc=$?
same "--local: no status.json: a check asked for, nothing written" "$local_nostatus|no file" \
  "$rc|$([[ -e $run_state/status.json ]] && echo file || echo no file)"
for bad in '{"apps": []}' '{"schemaVersion": 1, "checking": true, "apps": []}' '{"schemaVersion": 1, "apps": [{"pkg": 1}]}' 'not json'; do
  printf '%s\n' "$bad" >"$run_state/status.json"
  local_run; rc=$?
  same "--local: from $bad: a check asked for, the file as it was" "$local_nostatus|$bad" "$rc|$(cat "$run_state/status.json")"
done
check_run --local --wait; rc=$?
same "--local with --wait is a usage error" 2 "$rc"

# Holds the lock files on the fds $@ (7 .local.lock, 8 .check.lock) in the
# background until loc_free, ten seconds at most, so a test that breaks
# cannot hang the suite. It lets go of the check's lock first, as a local
# refresh does.
loc_hold() {
  rm -f "$run_dir/held" "$run_dir/go"
  ( exec 7>"$run_state/.local.lock" 8>"$run_state/.check.lock"
    for fd in "$@"; do flock "$fd"; done
    echo held >"$run_dir/held"
    appears "$run_dir/go"
    exec 8>&- 7>&- ) &
  holder=$!
  appears "$run_dir/held"
}
loc_free() { echo go >"$run_dir/go"; wait "$holder"; }
loc_status
loc_hold 8
local_run; rc=$?
same "--local while a check runs: exits Model.lockBusyExit, mise never called" "${lock_busy_exit:-none}|" "$rc|$(cat "$run_dir/mise.log")"
loc_free
loc_hold 7
local_run; rc=$?
same "--local while another local refresh runs: the same" "${lock_busy_exit:-none}|" "$rc|$(cat "$run_dir/mise.log")"
loc_free
# A check that finds a local refresh holding the lock waits for it to end,
# then runs: leaving the answer to it would drop the check.
loc_hold 7 8
check_bg
pid=$!
waited=no
for _ in $(seq 100); do pgrep -f '^flock -w [0-9]* 6$' >/dev/null && { waited=yes; break; }; sleep 0.1; done
same "a check while a local refresh runs waits for it" yes "$waited"
loc_free
wait "$pid"; rc=$?
same "and then runs" '0|false' "$rc|$(run_status .checking)"
same "a check writes inventoryAt, its start" true "$(run_status '.inventoryAt == .startedAt and .inventoryAt != ""')"
loc_status
same "while a check runs, inventoryAt stays the last one's" '2026-01-01T00:09:00+00:00' "$(status_mid_run .inventoryAt)"
same "--local and the checks around it leave no scratch files" '' "$(leftovers)"
rm -f "$run_dir/config/omarchy/omabump/apps.json" "$run_state/status.json" "$run_dir/fixture.json" "$run_dir/pkgs" \
  "$run_dir/mise-ls.json" "$run_dir/held" "$run_dir/go"

# --- an app installed as its self-updating AppImage -----------------------------------------

# T3 Code as the shipped table has it, its feed a command feed of the
# user's (ai_feed: 0.1.1 unless given), its AppImage where Omarchy puts it
# (ai_put: the version its desktop entry names, none for ""). The AppImage
# is a script that leaves a mark if anything runs it. The fake 7z first on
# PATH "extracts" the entry from the file next to it, <AppImage>.desktop,
# when asked as appimage_version asks, and notes each call in 7z.log; the
# fake stat (statbin, put first by a test) answers $OMABUMP_TEST_STAT; no7z
# has every command on PATH but 7z, for a machine without 7zip. The fake
# notify-send (notifybin, first on PATH for ai_notify) notes each
# notification's title and body in notify.log, so none reaches the desktop.
ai_file=$run_dir/home/.local/share/t3code/T3-Code.AppImage
mkdir -p "${ai_file%/*}" "$run_dir/7zbin" "$run_dir/statbin" "$run_dir/no7z" "$run_dir/notifybin"
cat >"$run_dir/7zbin/7z" <<'EOF'
#!/bin/sh
echo "7z $*" >>"$OMABUMP_TEST_7Z"
[ "$1 $2 $3 $4 $5 $7" = "e -so -r- -x!*/* -- *.desktop" ] || exit 7
cat "$6.desktop" 2>/dev/null || exit 2
EOF
printf '#!/bin/sh\necho "$OMABUMP_TEST_STAT"\n' >"$run_dir/statbin/stat"
cat >"$run_dir/notifybin/notify-send" <<'EOF'
#!/bin/sh
[ "$1 $2" = "-a Omabump" ] || exit 7
printf '%s|%s\n' "$3" "$4" >>"$OMABUMP_TEST_NOTIFY"
EOF
chmod +x "$run_dir/7zbin/7z" "$run_dir/statbin/stat" "$run_dir/notifybin/notify-send"
IFS=: read -ra ai_dirs <<<"$PATH"
for d in "${ai_dirs[@]}"; do
  [[ -d $d ]] || continue
  find "$d" -maxdepth 1 \( -type f -o -type l \) ! -name 7z ! -name 7za ! -name 7zz ! -name 7zr \
    -exec ln -s -t "$run_dir/no7z" -- {} + 2>/dev/null
done
ai_feed() {
  jq -cn --arg v "${1:-0.1.1}" '[{pkg: "t3code-bin", feed: {type: "command", command: "echo \($v)"}}]' \
    >"$run_dir/config/omarchy/omabump/apps.json"
}
ai_put() {
  rm -rf "$ai_file"
  printf '#!/bin/sh\n: >"%s/appimage-ran"\n' "$run_dir" >"$ai_file"
  chmod +x "$ai_file"
  if [[ -n $1 ]]; then printf '[Desktop Entry]\nName=T3 Code\nX-AppImage-Version=%s\n' "$1"
  else printf '[Desktop Entry]\nName=T3 Code\n'; fi >"$ai_file.desktop"
}
# A check (or with --local a local refresh) with what loc_pkgs installed;
# PATH is $ai_bins when set. $? is its exit.
ai_run() {
  : >"$run_dir/7z.log"
  : >"$run_dir/net.log"
  env "${run_env[@]}" PATH="${ai_bins:-$run_dir/7zbin:$run_dir/bin:$PATH}" OMABUMP_TEST_PKGS="$run_dir/pkgs" \
    OMABUMP_TEST_7Z="$run_dir/7z.log" timeout -k 5 120 "$root/bin/omabump-check" --no-notify "$@" >/dev/null 2>"$run_dir/ai.err"
}
# A check as ai_run's that notifies: no --no-notify, and the fake
# notify-send first on PATH.
ai_notify() {
  : >"$run_dir/notify.log"
  env "${run_env[@]}" PATH="$run_dir/notifybin:$run_dir/7zbin:$run_dir/bin:$PATH" OMABUMP_TEST_PKGS="$run_dir/pkgs" \
    OMABUMP_TEST_7Z="$run_dir/7z.log" OMABUMP_TEST_NOTIFY="$run_dir/notify.log" \
    timeout -k 5 120 "$root/bin/omabump-check" >/dev/null 2>"$run_dir/ai.err"
}
ai_row() { run_status ".apps[] | select(.pkg == \"t3code-bin\") | $1"; }
ai_fields='"\(.installedName)|\(.installed)|\(.selfUpdating)|\(.installable)|\(.switchable)|\(.updateAvailable)|\(.unchecked)|\(.latest)|\(.versionFrom)|\(.error)|\(.note)"'
ai_note="Updates itself: open T3 Code to update"

run_settings ', "showMise": "false"'
rm -f "$run_state/status.json" "$run_state/notified.json"
loc_pkgs ''
ai_feed
ai_put 0.1.0
ai_run; rc=$?
same "AppImage: no package, the AppImage's row: its version, no route, the feed's update" \
  "0|~/.local/share/t3code/T3-Code.AppImage|0.1.0|true|false|false|true|false|0.1.1|feed||$ai_note" "$rc|$(ai_row "$ai_fields")"
same "AppImage: no omarchy-pkgs read for it, 7z asked once" '|1' "$(grep '^git' "$run_dir/net.log")|$(wc -l <"$run_dir/7z.log")"
same "AppImage: every row says selfUpdating" 0 "$(run_status '[.apps[] | select(.selfUpdating | type != "boolean")] | length')"
ai_put 0.1.1
ai_run
same "AppImage: at the feed's version, current" "false|false|$ai_note" "$(ai_row '"\(.updateAvailable)|\(.unchecked)|\(.note)"')"
ai_feed 0.2.0
ai_put 0.1.1-nightly.20261019.1
ai_run
same "AppImage: a nightly is compared with no stable release: no update, unchecked, the note says why" \
  "0.1.1-nightly.20261019.1|false|true|0.2.0|Pre-release build, not compared with the feed's stable releases; $ai_note" \
  "$(ai_row '"\(.installed)|\(.updateAvailable)|\(.unchecked)|\(.latest)|\(.note)"')"
ai_feed
ai_put v0.1.1
ai_run
same "AppImage: a v before the version goes, as the feed drops it from the tag: current at the feed's" \
  "0.1.1|false|false|$ai_note" "$(ai_row '"\(.installed)|\(.updateAvailable)|\(.unchecked)|\(.note)"')"
ai_put continuous
ai_run
same "AppImage: a version with a letter first is compared with nothing: no update, unchecked, the note says why" \
  "continuous|false|true|Not a release number, not compared with the feed's; $ai_note" \
  "$(ai_row '"\(.installed)|\(.updateAvailable)|\(.unchecked)|\(.note)"')"
ai_put ''
ai_run
# shellcheck disable=SC2088 # the path as apps.json writes it
same "AppImage: no version in it: unknown, unchecked, the note says so" \
  "~/.local/share/t3code/T3-Code.AppImage||false|true|Version unknown: 7z could not read it from the AppImage; $ai_note" \
  "$(ai_row '"\(.installedName)|\(.installed)|\(.updateAvailable)|\(.unchecked)|\(.note)"')"
ai_put 0.1.0
ai_bins=$run_dir/bin:$run_dir/no7z ai_run; rc=$?
same "AppImage: without 7z the row still shows, its version unknown, the note says how to get it" \
  "0|true||false|true|Version unknown: install 7zip to read it (sudo pacman -S --needed 7zip); $ai_note" \
  "$rc|$(ai_row '"\(.selfUpdating)|\(.installed)|\(.updateAvailable)|\(.unchecked)|\(.note)"')"
loc_pkgs 't3code-bin 0.1.0-1'
ai_run
same "AppImage: the package wins when pacman has it, and 7z is not asked" 't3code-bin|0.1.0-1|false|' \
  "$(ai_row '"\(.installedName)|\(.installed)|\(.selfUpdating)"')|$(cat "$run_dir/7z.log")"
loc_pkgs ''

# Files Omabump does not read: the row is gone, as with no AppImage at all.
ai_put 0.1.0
mv "$ai_file" "$run_dir/elsewhere.AppImage"
cp "$ai_file.desktop" "$run_dir/elsewhere.AppImage.desktop"
ln -s "$run_dir/elsewhere.AppImage" "$ai_file"
ai_run
same "AppImage: a symlink is not read: no row, 7z not asked" '|' "$(ai_row .pkg)|$(cat "$run_dir/7z.log")"
rm -f "$ai_file"
mkdir "$ai_file"
ai_run
same "AppImage: nor a directory" '' "$(ai_row .pkg)"
ai_put 0.1.0
OMABUMP_TEST_STAT="regular file/$(( $(id -u) + 1 ))/1000" ai_bins=$run_dir/statbin:$run_dir/7zbin:$run_dir/bin:$PATH ai_run
same "AppImage: nor a file of another user" '' "$(ai_row .pkg)"
OMABUMP_TEST_STAT="regular file/$(id -u)/3000000000" ai_bins=$run_dir/statbin:$run_dir/7zbin:$run_dir/bin:$PATH ai_run
same "AppImage: nor one over 2 GiB" '' "$(ai_row .pkg)"
OMABUMP_TEST_STAT="regular file/$(id -u)/1000" ai_bins=$run_dir/statbin:$run_dir/7zbin:$run_dir/bin:$PATH ai_run
same "AppImage: a file of yours within the bound is" t3code-bin "$(ai_row .pkg)"
jq -cn '[{pkg: "t3code-bin", appImage: "~/../t3code/T3-Code.AppImage", feed: {type: "command", command: "echo 0.1.1"}}]' \
  >"$run_dir/config/omarchy/omabump/apps.json"
ai_run
same "AppImage: an appImage path the rules refuse drops the entry, and says so" '|1' \
  "$(ai_row .pkg)|$(grep -c '^ignoring app "t3code-bin"' "$run_dir/ai.err")"
ai_feed

# --local: the AppImage's own updater moves it between checks.
ai_put 0.1.0
ai_run
ai_put 0.1.1
ai_run --local; rc=$?
same "--local: the AppImage updated itself to the newest known: no update, no check needed, no network" \
  "0|0.1.1|false|false|$ai_note|" "$rc|$(ai_row '"\(.installed)|\(.updateAvailable)|\(.unchecked)|\(.note)"')|$(cat "$run_dir/net.log")"
ai_put 0.1.0
ai_run --local; rc=$?
same "--local: back below the newest known: the update again" "0|0.1.0|true" "$rc|$(ai_row '"\(.installed)|\(.updateAvailable)"')"
ai_put 0.1.2
ai_run --local; rc=$?
same "--local: past the newest known: not checked yet, no update, and a check asked for" \
  "$local_full|0.1.2|false|true|Not checked yet|0.1.1" \
  "$rc|$(ai_row '"\(.installed)|\(.updateAvailable)|\(.unchecked)|\(.note)|\(.latest)"')"
ai_put 0.1.0
ai_run
ai_put 0.1.1-nightly.20261019.1
ai_run --local; rc=$?
same "--local: a nightly now: unchecked, no update, the note says why" \
  "0|false|true|Pre-release build, not compared with the feed's stable releases; $ai_note" \
  "$rc|$(ai_row '"\(.updateAvailable)|\(.unchecked)|\(.note)"')"
rm -f "$ai_file"
ai_run --local; rc=$?
same "--local: the AppImage removed: its row goes" '0|' "$rc|$(ai_row .pkg)"
ai_put 0.1.0
ai_run --local; rc=$?
same "--local: an AppImage since the last check: an unchecked row, and a check asked for" \
  "$local_full|~/.local/share/t3code/T3-Code.AppImage|0.1.0|true|false|true|Not checked yet" \
  "$rc|$(ai_row '"\(.installedName)|\(.installed)|\(.selfUpdating)|\(.updateAvailable)|\(.unchecked)|\(.note)"')"
# The check it asked for never came (stopped early, say), and the app then
# updated itself: no check has read its newest version, so the row is no
# more current than before.
ai_put 0.1.1
ai_run --local; rc=$?
same "--local: a row no check has read, at another version: still unchecked, and a check asked for" \
  "$local_full|0.1.1||false|true|Not checked yet" \
  "$rc|$(ai_row '"\(.installed)|\(.latest)|\(.updateAvailable)|\(.unchecked)|\(.note)"')"
ai_put ''
ai_run --local; rc=$?
same "--local: and with its version unknown now, the same" "$local_full||true|Not checked yet" \
  "$rc|$(ai_row '"\(.installed)|\(.unchecked)|\(.note)"')"
ai_put 0.1.0
ai_run
same "--local: once a check has read it, the row is the check's" "0.1.0|0.1.1|true|false|$ai_note" \
  "$(ai_row '"\(.installed)|\(.latest)|\(.updateAvailable)|\(.unchecked)|\(.note)"')"
loc_pkgs 't3code-bin 0.1.1-1'
ai_run --local; rc=$?
same "--local: the package installed over the AppImage: a check asked for, no route meanwhile" \
  "$local_full|t3code-bin|0.1.1-1|false|false|false|true|Not checked yet" \
  "$rc|$(ai_row '"\(.installedName)|\(.installed)|\(.selfUpdating)|\(.installable)|\(.updateAvailable)|\(.unchecked)|\(.note)"')"
ai_run
loc_pkgs ''
ai_run --local; rc=$?
same "--local: the package removed, the AppImage left: a check asked for" \
  "$local_full|~/.local/share/t3code/T3-Code.AppImage|0.1.0|true|false" \
  "$rc|$(ai_row '"\(.installedName)|\(.installed)|\(.selfUpdating)|\(.installable)"')"
# What only one form has goes with it: updateBlocked marks the package row
# alone, and a recipe is the package's.
jq -cn '[{pkg: "t3code-bin", updateBlocked: "a known problem", feed: {type: "command", command: "echo 0.1.1"}}]' \
  >"$run_dir/config/omarchy/omabump/apps.json"
ai_run
same "AppImage: updateBlocked does not mark a self-updating row" "false|$ai_note" "$(ai_row '"\(.blocked)|\(.note)"')"
loc_pkgs 't3code-bin 0.1.1-1'
ai_run
same "AppImage: it marks the package's" true "$(ai_row .blocked)"
jq '.apps |= map(if .pkg == "t3code-bin" then .recipe = "t3code-bin 0.1.1-1" | .recipeCommit = "0123456" else . end)' \
  "$run_state/status.json" >"$run_dir/edited.json" && mv "$run_dir/edited.json" "$run_state/status.json"
loc_pkgs ''
ai_run --local; rc=$?
same "--local: to the AppImage: no updateBlocked mark, no recipe" "$local_full|true|false||" \
  "$rc|$(ai_row '"\(.selfUpdating)|\(.blocked)|\(.recipe)|\(.recipeCommit)"')"
loc_pkgs 't3code-bin 0.1.1-1'
ai_run --local; rc=$?
same "--local: back to the package: the updateBlocked mark again" "$local_full|false|true" \
  "$rc|$(ai_row '"\(.selfUpdating)|\(.blocked)"')"
loc_pkgs ''
ai_feed
ai_run

# Notifications: once per version, as for any row (announce_action), and
# saying the app updates itself.
rm -f "$run_state/notified.json"
ai_put 0.1.0
ai_notify
same "AppImage: an update notifies, saying the app updates itself" \
  "T3 Code 0.1.1 available|Installed: 0.1.0. T3 Code updates itself: open it to update.|0.1.1" \
  "$(cat "$run_dir/notify.log")|$(jq -r '."t3code-bin"' "$run_state/notified.json")"
ai_notify
same "AppImage: not twice for one version" '' "$(cat "$run_dir/notify.log")"
ai_feed 0.1.2
ai_notify
same "AppImage: again for a newer one" "T3 Code 0.1.2 available|Installed: 0.1.0. T3 Code updates itself: open it to update." \
  "$(cat "$run_dir/notify.log")"
ai_feed 0.1.3
ai_put 0.1.2-nightly.20261019.1
ai_notify
same "AppImage: a pre-release claims no update, so none is announced" "|false" "$(cat "$run_dir/notify.log")|$(ai_row .updateAvailable)"
ai_put ''
ai_notify
same "AppImage: nor with its version unknown" "|false" "$(cat "$run_dir/notify.log")|$(ai_row .updateAvailable)"
ai_feed
check "AppImage: nothing ever ran it" test ! -e "$run_dir/appimage-ran"
same "AppImage: the runs leave no scratch files" '' "$(leftovers)"
rm -rf "$run_dir/home/.local/share/t3code" "$run_dir/elsewhere.AppImage" "$run_dir/elsewhere.AppImage.desktop" "$run_dir/no7z" \
  "$run_dir/7zbin" "$run_dir/statbin" "$run_dir/notifybin" "$run_dir/7z.log" "$run_dir/notify.log" "$run_dir/ai.err" "$run_dir/pkgs" \
  "$run_state/notified.json"
rm -f "$run_dir/config/omarchy/omabump/apps.json" "$run_state/status.json"

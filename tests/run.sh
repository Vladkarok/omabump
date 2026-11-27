#!/bin/bash
# Omabump's tests. Plain bash: one line per test, every test runs, and any
# failure makes the exit non-zero. Nothing touches the network: fetch,
# mise_run and the git network wrapper are stubbed below, and every XDG
# directory points into a scratch directory.
#
#   tests/run.sh               every part, in order
#   tests/run.sh <part>...     only those parts
#   tests/run.sh --list        the parts
#
# unit is this file's tests of bin/omabump-common; model is Model.js under
# node (tests/model.sh); qml, check, install, pin-watch and apps-watch are
# tests/<part>.sh.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
parts=(unit model qml check install pin-watch apps-watch)

# Each part runs in a bash of its own, from the setup below and nothing an
# earlier part left, so one part can run alone. The counts file carries the
# test number on from part to part.
if [[ ${1:-} != --part ]]; then
  if [[ ${1:-} == --list ]]; then printf '%s\n' "${parts[@]}"; exit 0; fi
  (( $# )) || set -- "${parts[@]}"
  for p; do
    [[ " ${parts[*]} " == *" $p "* ]] || { echo "tests/run.sh: no part '$p'; --list names them" >&2; exit 2; }
  done
  mkdir -p "$root/.tests"
  counts=$(mktemp -p "$root/.tests")
  trap 'rm -f "$counts"; rmdir "$root/.tests" 2>/dev/null' EXIT
  # secs <start>: the seconds since $EPOCHREALTIME was <start>.
  secs() { local us=$(( ${EPOCHREALTIME//[!0-9]/} - ${1//[!0-9]/} )); printf '%d.%d' $(( us / 1000000 )) $(( us % 1000000 / 100000 )); }
  n=0 failed=0 run_start=$EPOCHREALTIME
  for p; do
    echo "# $p"
    part_start=$EPOCHREALTIME
    echo "$n" >"$counts"
    OMABUMP_TEST_COUNTS=$counts bash "$root/tests/run.sh" --part "$p"
    rc=$?
    # A part that stopped half way never marked its count as the end: that
    # is a failure too, after the tests it ran.
    part_n="" part_failed="" part_end=""
    read -r part_n part_failed part_end <"$counts"
    if [[ $part_end == end ]]; then
      n=$part_n failed=$(( failed + part_failed ))
    else
      n=$(( ${part_n:-$n} + 1 )) failed=$(( failed + ${part_failed:-0} + 1 ))
      echo "FAIL $n - $p ran to the end: exit $rc"
    fi
    echo "# $p: $(secs "$part_start") s"
  done
  if (( failed )); then
    echo "$failed of $n tests failed ($(secs "$run_start") s)"
    exit 1
  fi
  echo "all $n tests passed ($(secs "$run_start") s)"
  exit 0
fi
part=$2

# Scratch space inside the checkout, never the system temp directory.
mkdir -p "$root/.tests"
scratch=$(mktemp -d -p "$root/.tests")
trap 'rm -rf "$scratch"; rmdir "$root/.tests" 2>/dev/null' EXIT
export XDG_CONFIG_HOME=$scratch/config XDG_STATE_HOME=$scratch/state XDG_CACHE_HOME=$scratch/cache
mkdir -p "$XDG_CONFIG_HOME/omarchy/omabump" "$scratch/served"

# shellcheck source=../bin/omabump-common
source "$root/bin/omabump-common"
# Never the shell.json under the real HOME: the tests write and remove it.
shell_json=$scratch/shell.json
# The real mise_run, kept under another name before the stub replaces it.
eval "$(declare -f mise_run | sed '1s/^mise_run/real_mise_run/')"

# Stubs. fetch serves $scratch/served/<basename of the last argument>, or
# api-<basename> for a URL on api.github.com, and leaves its arguments in
# $scratch/fetched and adds them to $scratch/fetch.log.
fetch() {
  local url=${*: -1} name
  printf '%s\n' "$*" >"$scratch/fetched"
  printf '%s\n' "$*" >>"$scratch/fetch.log"
  name=${url##*/}
  [[ $url != https://api.github.com/* ]] || name=api-$name
  [[ -f $scratch/served/$name ]] || return 22
  cat "$scratch/served/$name"
}
# shellcheck disable=SC2329 # stubs, called from omabump-common
mise_run() { echo "mise_run called in a test" >&2; return 1; }
# shellcheck disable=SC2329 # called from omabump-common
pgit_net() { echo "pgit_net called in a test" >&2; return 1; }

counts=${OMABUMP_TEST_COUNTS:-/dev/null}
n=$(<"$counts") failed=0
n=${n:-0}
# Each test writes the count, so a part that stops half way still hands on
# the number and the failures it reached.
pass() { n=$((n + 1)); echo "ok $n - $1"; echo "$n $failed" >"$counts"; }
fail() { n=$((n + 1)) failed=$((failed + 1)); echo "FAIL $n - $1${2:+: $2}"; echo "$n $failed" >"$counts"; }
# check <name> <command...>: the command must succeed.
check() { local name=$1; shift; if "$@" >/dev/null; then pass "$name"; else fail "$name"; fi; }
# refuse <name> <command...>: the command must fail.
refuse() { local name=$1; shift; if "$@" >/dev/null 2>&1; then fail "$name" "expected a failure"; else pass "$name"; fi; }
# same <name> <expected> <actual>
same() { if [[ $3 == "$2" ]]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }

# git, quiet and with a test author, for the repositories the tests make.
tgit() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main -c advice.detachedHead=false "$@" >/dev/null 2>&1; }
hexsum() { printf '%s' "$2" | "${1}sum" | cut -d' ' -f1; }
b64sum() { printf '%s' "$1" | python3 -c 'import base64, hashlib, sys; print(base64.b64encode(hashlib.sha512(sys.stdin.buffer.read()).digest()).decode())'; }

# repo_db <file> <entries...>: a database as Omarchy's repo serves it, a
# zstd tar of <name>-<version>/desc, from entries "<name> <version> [<file
# name> [<sha256>|twice]]": the file this machine's architecture names by
# default, its sha256 the file name's own unless given; "twice" gives the
# desc a second %NAME%.
repo_sum() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
repo_db() {
  local out=$1 d name version file extra
  shift
  d=$(mktemp -d -p "$scratch")
  for e in "$@"; do
    read -r name version file extra <<<"$e"
    file=${file:-$name-$version-$(uname -m).pkg.tar.zst}
    mkdir -p "$d/$name-$version"
    { printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n' "$file" "$name"
      [[ $extra != twice ]] || printf '%%NAME%%\n%s-other\n\n' "$name"
      [[ $extra =~ ^[0-9a-f]{64}$ ]] || extra=$(repo_sum "$file")
      printf '%%VERSION%%\n%s\n\n%%SHA256SUM%%\n%s\n\n%%CSIZE%%\n100\n\n' "$version" "$extra"; } >"$d/$name-$version/desc"
  done
  (cd "$d" && bsdtar --zstd -cf "$out" -- *)
  rm -rf "$d"
}

# The part's last test number and its failures, for the run that started it.
finish() { echo "$n $failed end" >"$counts"; exit $(( failed > 0 )); }
# unit is the rest of this file.
case $part in
  unit) ;;
  model) source "$root/tests/model.sh"; finish ;;
  qml) source "$root/tests/qml.sh"; finish ;;
  check) source "$root/tests/check.sh"; finish ;;
  install) source "$root/tests/install.sh"; finish ;;
  pin-watch) source "$root/tests/pin-watch.sh"; finish ;;
  apps-watch) source "$root/tests/apps-watch.sh"; finish ;;
  *) echo "tests/run.sh: no part '$part'" >&2; exit 2 ;;
esac

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
# One entry reaches jq as one argv string, which the kernel caps at 128 KiB.
jq -n '[{pkg: "big", source: "indicator", icon: ("x" * 140000)}, {pkg: "edge", source: "indicator", icon: ("x" * 60000)}]' >"$user_apps"
same "apps_table: an entry over app_entry_max is dropped, one under it stays" \
  'no yes' "$(apps_table 2>/dev/null | jq -r '[(any(.[]; .pkg == "big")), (any(.[]; .pkg == "edge"))] | map(if . then "yes" else "no" end) | join(" ")')"
same "apps_table: the oversized entry is named on stderr" 1 \
  "$(apps_table 2>&1 >/dev/null | grep -c '^ignoring app "big": its entry is larger than 65536 bytes')"
printf '[{"pkg": "a", "source": "indicator", "updateBlocked": true}, {"pkg": "b", "source": "indicator", "updateBlocked": "fine"}]\n' >"$user_apps"
same "apps_table: updateBlocked must be a short string" 'b:fine' "$(apps_table 2>/dev/null | jq -r 'map(select(.pkg == "a" or .pkg == "b")) | map("\(.pkg):\(.updateBlocked // "")") | join(" ")')"
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
echo '{"pkg": "x"}' >"$user_apps"
same "apps_table: a user file that is not an array is ignored" 'a b c' "$(apps_table 2>/dev/null | jq -r 'map(.pkg) | join(" ")')"
cat >"$user_apps" <<'EOF'
[
  {"pkg": "a", "appImage": ""},
  {"pkg": "ai-ok", "source": "omarchy", "appImage": "~/.local/share/x/X-1_2+3.AppImage"},
  {"pkg": "ai-none", "source": "indicator", "appImage": null},
  {"pkg": "ai-empty", "source": "omarchy", "appImage": ""},
  {"pkg": "ai-false", "source": "omarchy", "appImage": false},
  {"pkg": "mise:ai-empty", "source": "mise", "tool": "ai-empty", "appImage": ""},
  {"pkg": "ai-up", "source": "omarchy", "appImage": "~/../x/X.AppImage"},
  {"pkg": "ai-abs", "source": "omarchy", "appImage": "/home/u/X.AppImage"},
  {"pkg": "ai-user", "source": "omarchy", "appImage": "~root/X.AppImage"},
  {"pkg": "ai-blank", "source": "omarchy", "appImage": "~/a b/X.AppImage"},
  {"pkg": "ai-dot", "source": "omarchy", "appImage": "~/./X.AppImage"},
  {"pkg": "ai-num", "source": "vendor-pkg", "appImage": 5},
  {"pkg": "mise:ai", "source": "mise", "tool": "ai", "appImage": "~/X.AppImage"}
]
EOF
same "apps_table: an appImage is a ~/ path Omabump accepts, and never on a mise row" \
  'a b c ai-ok ai-none ai-empty ai-false mise:ai-empty' "$(apps_table 2>/dev/null | jq -r 'map(.pkg) | join(" ")')"
same "apps_table: \"\" (or false) is none, as with updateBlocked: a user's file turns a shipped appImage off with it" \
  '"a":""' "$(apps_table 2>/dev/null | jq -r '.[] | select(.pkg == "a") | "\(.pkg | tojson):\(.appImage | tojson)"')"
same "apps_table: each entry with another appImage is named on stderr, and says why" 7 \
  "$(apps_table 2>&1 >/dev/null | grep -c '^ignoring app .*an appImage or npmPackage that is not a ~/ path Omabump accepts')"
# npmPackage takes the same paths, never on a mise row either; selfUpdate
# is text of at most 100 characters.
jq -n --arg long "$(printf 'a%.0s' {1..101})" --arg most "$(printf 'a%.0s' {1..100})" '[
  {pkg: "a", npmPackage: ""},
  {pkg: "np-ok", source: "omarchy", npmPackage: "~/.openclaw/tools/node/lib/node_modules/openclaw", selfUpdate: "run openclaw update"},
  {pkg: "np-null", source: "indicator", npmPackage: null},
  {pkg: "np-up", source: "omarchy", npmPackage: "~/../x"},
  {pkg: "np-abs", source: "omarchy", npmPackage: "/home/u/x"},
  {pkg: "np-num", source: "omarchy", npmPackage: 5},
  {pkg: "mise:np", source: "mise", tool: "np", npmPackage: "~/x"},
  {pkg: "su-most", source: "omarchy", selfUpdate: $most},
  {pkg: "su-long", source: "omarchy", selfUpdate: $long},
  {pkg: "su-num", source: "omarchy", selfUpdate: 5}
]' >"$user_apps"
same "apps_table: an npmPackage is a ~/ path as an appImage is, and a selfUpdate is short text" \
  'a b c np-ok np-null su-most' "$(apps_table 2>/dev/null | jq -r 'map(.pkg) | join(" ")')"
same "apps_table: each such entry is named on stderr" 6 \
  "$(apps_table 2>&1 >/dev/null | grep -c '^ignoring app .*an appImage or npmPackage that is not a ~/ path Omabump accepts, an updateBlocked or selfUpdate too long')"
same "apps_table: and the ones with another selfUpdate too" 2 \
  "$(apps_table 2>&1 >/dev/null | grep -c '^ignoring app "su-')"
rm -f "$user_apps"
# home_path_ok and apps_table's home_path_ok take the same paths.
# shellcheck disable=SC2088 # paths as apps.json writes them, ~ and all
ai_paths=('~/x' '~/.local/share/t3code/T3-Code.AppImage' '~/a/b+c_d-e.f' '~/.x' '~' '~/' '~/a/' '~//a' '~/.' '~/..'
  '~/a/./b' '~/a/.' '~/a..b' '/x' 'x' '~root/x' '~/a b' '~/é' $'~/a\n' "~/$(printf 'a%.0s' {1..198})"
  "~/$(printf 'a%.0s' {1..199})")
same "home_path_ok and apps_table agree on every path" \
  "$(for p in "${ai_paths[@]}"; do if home_path_ok "$p"; then echo true; else echo false; fi; done)" \
  "$(jq -rn "$jq_name_rules"' $ARGS.positional[] | home_path_ok' --args "${ai_paths[@]}")"
same "home_path_ok: the paths it takes" 'true true true true false false false false false false false false false false false false false false false true false' \
  "$(for p in "${ai_paths[@]}"; do if home_path_ok "$p"; then echo true; else echo false; fi; done | paste -sd' ')"

# --- apps that update themselves --------------------------------------------------

# An app whose appImage is ~/apps/X.AppImage under $ai_home. The AppImage is
# a script that leaves a mark if anything runs it.
ai_home=$scratch/ai-home ai_bin=$scratch/ai-bin
mkdir -p "$ai_home/apps" "$ai_bin"
ai_app='{"pkg": "x", "source": "omarchy", "appImage": "~/apps/X.AppImage"}'
printf '#!/bin/sh\n: >"%s/ai-ran"\n' "$scratch" >"$ai_home/apps/X.AppImage"
chmod +x "$ai_home/apps/X.AppImage"
same "appimage_file: a regular file of yours, under HOME" "$ai_home/apps/X.AppImage" "$(HOME=$ai_home appimage_file "$ai_app")"
refuse "appimage_file: an app without appImage" appimage_file '{"pkg": "x", "source": "omarchy"}'
refuse "appimage_file: nor with appImage \"\"" appimage_file '{"pkg": "x", "source": "omarchy", "appImage": ""}'
refuse "appimage_file: nor with appImage false" appimage_file '{"pkg": "x", "source": "omarchy", "appImage": false}'
same "appimage_file: a path the rules refuse" '' "$(HOME=$ai_home appimage_file '{"appImage": "~/apps/../apps/X.AppImage"}')"
mv "$ai_home/apps/X.AppImage" "$ai_home/apps/real"
ln -s real "$ai_home/apps/X.AppImage"
same "appimage_file: a symlink is not read, even to a file of yours" '' "$(HOME=$ai_home appimage_file "$ai_app")"
rm "$ai_home/apps/X.AppImage"
mkdir "$ai_home/apps/X.AppImage"
same "appimage_file: nor a directory" '' "$(HOME=$ai_home appimage_file "$ai_app")"
rmdir "$ai_home/apps/X.AppImage"
same "appimage_file: nor a file that is not there" '' "$(HOME=$ai_home appimage_file "$ai_app")"
mv "$ai_home/apps/real" "$ai_home/apps/X.AppImage"
# Another owner and a size past the bound, as stat would describe them.
same "appimage_file: a file of another user is not read" '' \
  "$(stat() { echo "regular file/$(( UID + 1 ))/1000"; }; HOME=$ai_home appimage_file "$ai_app")"
same "appimage_file: nor one larger than appimage_max_bytes" '' \
  "$(stat() { echo "regular file/$UID/$(( appimage_max_bytes + 1 ))"; }; HOME=$ai_home appimage_file "$ai_app")"
same "appimage_file: at the bound it is" "$ai_home/apps/X.AppImage" \
  "$(stat() { echo "regular file/$UID/$appimage_max_bytes"; }; HOME=$ai_home appimage_file "$ai_app")"

# A fake 7z that "extracts" the desktop entry from the file next to the
# AppImage, <AppImage>.desktop, when asked as appimage_version asks.
cat >"$ai_bin/7z" <<'EOF'
#!/bin/sh
[ "$1 $2 $3 $4 $5 $7" = "e -so -r- -x!*/* -- *.desktop" ] || exit 7
cat "$6.desktop" 2>/dev/null || exit 2
EOF
chmod +x "$ai_bin/7z"
# ai_version <desktop entry text>: what appimage_version reads from it.
ai_version() { printf '%s' "$1" >"$ai_home/apps/X.AppImage.desktop"; (PATH=$ai_bin:$PATH appimage_version "$ai_home/apps/X.AppImage"); }
same "appimage_version: X-AppImage-Version of the desktop entry" 0.1.0 \
  "$(ai_version $'[Desktop Entry]\nName=T3 Code\nX-AppImage-Version=0.1.0\nComment=x\n')"
same "appimage_version: blanks around =, a CRLF line, a pre-release" 0.1.1-nightly.20261019.1 \
  "$(ai_version $'[Desktop Entry]\r\nX-AppImage-Version = 0.1.1-nightly.20261019.1 \r\n')"
same "appimage_version: a leading v before a digit goes, as the github-release feed drops it" '0.1.1|1.0|1.2.0-beta.1' \
  "$(ai_version $'[Desktop Entry]\nX-AppImage-Version=v0.1.1\n')|$(ai_version $'[Desktop Entry]\nX-AppImage-Version=V1.0\n')|$(ai_version $'[Desktop Entry]\nX-AppImage-Version=v1.2.0-beta.1\n')"
same "appimage_version: no v goes before a letter" 'vv0.1|vnext|continuous' \
  "$(ai_version $'[Desktop Entry]\nX-AppImage-Version=vv0.1\n')|$(ai_version $'[Desktop Entry]\nX-AppImage-Version=vnext\n')|$(ai_version $'[Desktop Entry]\nX-AppImage-Version=continuous\n')"
same "appimage_version: only the [Desktop Entry] group counts" 2.0 \
  "$(ai_version $'[Desktop Action x]\nX-AppImage-Version=9.9\n[Desktop Entry]\nX-AppImage-Version[de]=8.8\nX-AppImage-Version=2.0\n')"
for entry in $'[Desktop Entry]\nName=T3 Code\n' $'X-AppImage-Version=1.0\n' $'[Desktop Entry]\nX-AppImage-Version=1.0\nX-AppImage-Version=1.1\n' \
  $'[Desktop Entry]\nX-AppImage-Version=1.0\n[Desktop Entry]\nX-AppImage-Version=1.0\n' $'[Desktop Entry]\nX-AppImage-Version=1 0\n' \
  $'[Desktop Entry]\nX-AppImage-Version=../1\n' $'[Desktop Entry]\nX-AppImage-Version=\n' ''; do
  same "appimage_version: no version from $(jq -Rsc . <<<"$entry")" '' "$(ai_version "$entry")"
done
same "appimage_version: an entry of 64 KiB is read" 1.0 \
  "$(ai_version "$(printf '[Desktop Entry]\nX-AppImage-Version=1.0\n%065400d\n' 0)")"
same "appimage_version: a larger one is no version" '' \
  "$(ai_version "$(printf '[Desktop Entry]\nX-AppImage-Version=1.0\n%065600d\n' 0)")"
ai_version $'[Desktop Entry]\nX-AppImage-Version=0.1.0\n' >/dev/null
same "appimage_version: without 7z, no version" '' "$(PATH=$scratch/no-such-dir appimage_version "$ai_home/apps/X.AppImage")"
# shellcheck disable=SC2088 # the path as apps.json writes it
same "appimage_installed: the appImage as apps.json writes it, and the version" '~/apps/X.AppImage 0.1.0' \
  "$(PATH=$ai_bin:$PATH HOME=$ai_home appimage_installed "$ai_app")"
# shellcheck disable=SC2088 # the path as apps.json writes it
check "self_updating_name: the path installed_app gives" self_updating_name '~/apps/X.AppImage'
refuse "self_updating_name: never a package or mise name" self_updating_name x-bin
same "installed_app: an app installed as its AppImage" 'omarchy ~/apps/X.AppImage 0.1.0' \
  "$(pacman() { return 1; }; PATH=$ai_bin:$PATH HOME=$ai_home installed_app "$ai_app")"
same "installed_app: its package wins" 'omarchy x 1.0-1' \
  "$(pacman() { [[ $3 == x ]] && echo 'x 1.0-1'; }; PATH=$ai_bin:$PATH HOME=$ai_home installed_app "$ai_app")"
same "installed_app: no package and no AppImage, not installed" 'not installed' \
  "$(pacman() { return 1; }; HOME=$scratch/no-such-home installed_app "$ai_app" || echo 'not installed')"
same "installed_app: an appImage of \"\" names no file" 'not installed' \
  "$(pacman() { return 1; }; PATH=$ai_bin:$PATH HOME=$ai_home installed_app '{"pkg": "x", "source": "omarchy", "appImage": ""}' || echo 'not installed')"
ai_version $'[Desktop Entry]\n' >/dev/null
# shellcheck disable=SC2088 # the path as apps.json writes it
same "appimage_installed: a version it cannot read is empty" '~/apps/X.AppImage |' \
  "$(PATH=$ai_bin:$PATH HOME=$ai_home appimage_installed "$ai_app" | sed 's/$/|/')"

# The real 7z, when it is here, on a zip named like an AppImage: only the
# .desktop file at the top is read, not one further down, nor what a
# directory named *.desktop holds; two at the top are no version.
if command -v 7z >/dev/null; then
  ai_zip() {
    python3 -I - "$ai_home/apps/X.AppImage" "$@" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for spec in sys.argv[2:]:
        name, _, version = spec.partition("=")
        z.writestr(name, "[Desktop Entry]\nX-AppImage-Version=%s\n" % version if version else "x\n")
EOF
    appimage_version "$ai_home/apps/X.AppImage"
  }
  same "appimage_version (real 7z): the top-level entry, not a nested one or a directory's" 1.0 \
    "$(ai_zip usr/share/applications/a.desktop=9.9 top.desktop=1.0 dir.desktop/inner=8.8)"
  same "appimage_version (real 7z): two top-level entries are no version" '' "$(ai_zip a.desktop=1.0 b.desktop=1.0)"
  same "appimage_version (real 7z): a file that is no archive is no version" '' \
    "$(printf 'not an archive\n' >"$ai_home/apps/X.AppImage"; appimage_version "$ai_home/apps/X.AppImage")"
else
  pass "appimage_version (real 7z) (skipped: 7z is not installed)"
fi
check "appimage_version: nothing ran the AppImage" test ! -e "$scratch/ai-ran"

# An app whose npmPackage is ~/claw/tools/node/lib/node_modules/claw under
# $ai_home, tools/node a link to tools/node-v24 as upstream's installer
# makes it, and the same app's AppImage. The package's entry point is a
# script that leaves a mark if anything runs it.
np_dir=$ai_home/claw/tools/node-v24/lib/node_modules/claw
mkdir -p "$np_dir"
ln -s node-v24 "$ai_home/claw/tools/node"
printf '#!/bin/sh\n: >"%s/np-ran"\n' "$scratch" >"$np_dir/claw.mjs"
chmod +x "$np_dir/claw.mjs"
np_app='{"pkg": "x", "source": "omarchy", "npmPackage": "~/claw/tools/node/lib/node_modules/claw", "appImage": "~/apps/X.AppImage"}'
# np_put <package.json text>: the package.json the app's copy has.
np_put() { printf '%s' "$1" >"$np_dir/package.json"; }
np_put '{"name": "claw", "version": "2026.10.9", "bin": {"claw": "claw.mjs"}}'
same "npm_package_version: the version of its package.json" 2026.10.9 "$(npm_package_version "$np_dir/package.json")"
np_put '{"name": "claw", "version": "2026.10.9-beta.1"}'
same "npm_package_version: a pre-release stays as it is" 2026.10.9-beta.1 "$(npm_package_version "$np_dir/package.json")"
for doc in '{"name": "claw"}' '{"version": 5}' '{"version": "1 0"}' '{"version": "../1"}' '{"version": ""}' \
  '["1.0"]' '"1.0"' '{"version": "1.0"} {"version": "1.1"}' 'not json' ''; do
  np_put "$doc"
  same "npm_package_version: no version from $(jq -Rsc . <<<"$doc")" '' "$(npm_package_version "$np_dir/package.json")"
done
np_put '{"version": "2026.10.9"}'
# shellcheck disable=SC2088 # the path as apps.json writes it
same "npm_package_installed: the npmPackage as apps.json writes it, and the version" \
  '~/claw/tools/node/lib/node_modules/claw 2026.10.9' "$(HOME=$ai_home npm_package_installed "$np_app")"
refuse "npm_package_installed: an app without npmPackage" npm_package_installed '{"pkg": "x", "source": "omarchy"}'
same "npm_package_installed: nor with npmPackage \"\"" '' \
  "$(HOME=$ai_home npm_package_installed '{"pkg": "x", "source": "omarchy", "npmPackage": ""}')"
same "npm_package_installed: a path the rules refuse" '' \
  "$(HOME=$ai_home npm_package_installed '{"npmPackage": "~/claw/../claw/tools/node/lib/node_modules/claw"}')"
same "npm_package_installed: the text test is no rule: a mention elsewhere is read as JSON" '' \
  "$(HOME=$ai_home npm_package_installed '{"pkg": "x", "label": "\"npmPackage\""}')"
mv "$np_dir/package.json" "$np_dir/real.json"
ln -s real.json "$np_dir/package.json"
same "npm_package_installed: a package.json that is a symlink is not read" '' "$(HOME=$ai_home npm_package_installed "$np_app")"
rm "$np_dir/package.json"
same "npm_package_installed: nor a package without one" '' "$(HOME=$ai_home npm_package_installed "$np_app")"
mv "$np_dir/real.json" "$np_dir/package.json"
# shellcheck disable=SC2329 # stat is what home_file calls
same "npm_package_installed: nor one of another user" '' \
  "$(stat() { echo "regular file/$(( UID + 1 ))/1000"; }; HOME=$ai_home npm_package_installed "$np_app")"
# shellcheck disable=SC2329 # stat is what home_file calls
same "npm_package_installed: nor one larger than npm_package_max_bytes" '' \
  "$(stat() { echo "regular file/$UID/$(( npm_package_max_bytes + 1 ))"; }; HOME=$ai_home npm_package_installed "$np_app")"
np_put '{"name": "claw"}'
# shellcheck disable=SC2088 # the path as apps.json writes it
same "npm_package_installed: a version it cannot read is empty" '~/claw/tools/node/lib/node_modules/claw |' \
  "$(HOME=$ai_home npm_package_installed "$np_app" | sed 's/$/|/')"
np_put '{"version": "2026.10.9"}'
# shellcheck disable=SC2088 # the path as apps.json writes it
check "self_updating_name: the npmPackage path installed_app gives" self_updating_name '~/claw/tools/node/lib/node_modules/claw'
same "installed_app: an app installed as its npm package" 'omarchy ~/claw/tools/node/lib/node_modules/claw 2026.10.9' \
  "$(pacman() { return 1; }; PATH=$ai_bin:$PATH HOME=$ai_home installed_app "$np_app")"
same "installed_app: the npm package wins over the package, its seed, and over the AppImage" \
  'omarchy ~/claw/tools/node/lib/node_modules/claw 2026.10.9' \
  "$(pacman() { [[ $3 == x ]] && echo 'x 1.0-1'; }; PATH=$ai_bin:$PATH HOME=$ai_home installed_app "$np_app")"
rm "$np_dir/package.json"
same "installed_app: without its package.json, the package again" 'omarchy x 1.0-1' \
  "$(pacman() { [[ $3 == x ]] && echo 'x 1.0-1'; }; PATH=$ai_bin:$PATH HOME=$ai_home installed_app "$np_app")"
same "self_update_text: the app's selfUpdate" 'run claw update' \
  "$(self_update_text '{"pkg": "x", "selfUpdate": "run claw update"}' X)"
same "self_update_text: else open the app" 'open X to update|open X to update' \
  "$(self_update_text '{"pkg": "x"}' X)|$(self_update_text '{"pkg": "x", "selfUpdate": ""}' X)"
check "npm_package_version: nothing ran the package" test ! -e "$scratch/np-ran"
rm -rf "$ai_home" "$ai_bin"

# --- the app table's sources -----------------------------------------------------

rm -f "$user_apps"
app_table=""
shipped_apps=$real_shipped

# A source outside the four routes is dropped; "self" is Omabump's own.
printf '[{"pkg": "x1", "source": "self"}, {"pkg": "x2", "source": "shell"}, {"pkg": "x3"}, {"pkg": "x4", "source": "indicator"}]' >"$user_apps"
same "apps_table: a user entry with source self, an unknown or no source is dropped" 'x4' \
  "$(apps_table 2>/dev/null | jq -r '[.[] | select(.pkg | startswith("x")) | .pkg] | join(" ")')"
# The sources apps.json may name are route_table's routes but Omabump's
# own: entry_ok lists them itself, so a route added to the table and not
# to it is refused from apps.json, not let through.
jq -nc --arg routes "${route_names[*]}" '$routes | split(" ") | map({pkg: "r-\(.)", source: .})' >"$user_apps"
same "apps_table: every route of route_table but self comes from apps.json" "repo vendor-pkg indicator mise" \
  "$(apps_table 2>/dev/null | jq -r '[.[] | select(.pkg | startswith("r-")) | .source] | join(" ")')"
# The omarchy source of 0.1.19 reads as repo with build true, silently; a
# build the entry gives itself stays. A build that is no boolean is refused.
printf '%s' '[{"pkg": "o1", "source": "omarchy"}, {"pkg": "o2", "source": "omarchy", "build": false},
  {"pkg": "o3", "source": "repo", "build": "yes"}, {"pkg": "o4", "source": "repo", "build": true}]' >"$user_apps"
same "apps_table: source omarchy reads as repo with build true, a build of its own kept, a non-boolean build refused" \
  'o1 repo true|o2 repo false|o4 repo true|1' \
  "$(apps_table 2>"$scratch/at.err" | jq -r '[.[] | select(.pkg | test("^o[0-9]$")) | "\(.pkg) \(.source) \(.build)"] | join("|")')|$(grep -c '"o3"' "$scratch/at.err")"
same "apps_table: the omarchy source says nothing on stderr" '' "$(grep -E '"o[124]"' "$scratch/at.err")"
load_table 2>/dev/null
check "build_allowed: a repo entry with build true" build_allowed "$(app_json o4)"
refuse "build_allowed: not with build false" build_allowed "$(app_json o2)"
refuse "build_allowed: not on a route that does not build, whatever the entry says" build_allowed '{"source": "vendor-pkg", "build": true}'
refuse "build_allowed: not without build" build_allowed '{"source": "repo"}'
app_table=""
rm -f "$user_apps" "$scratch/at.err"

# --- route ----------------------------------------------------------------------

same "route: the facts of each route, as route_table lists them" \
  'repo vercmp repo pacman yes desktop yes
vendor-pkg vercmp feed pacman yes desktop no
indicator vercmp feed pacman no desktop no
mise exact mise mise no cli no
self exact feed manifest no plugin no' \
  "$(for r in "${route_names[@]}"; do
      echo "$r ${route_facts[$r.versions]} ${route_facts[$r.newest]} ${route_facts[$r.installed]} ${route_facts[$r.switch]} ${route_facts[$r.section]} ${route_facts[$r.build]}"
    done)"
refuse "route: a source no route names has no fact" route shell switch yes
refuse "route: nor an empty one" route "" versions vercmp
same "route_section: by source, desktop for none or another" 'desktop desktop desktop desktop cli plugin desktop desktop desktop' \
  "$(jq -r "$jq_routes"' map(route_section) | join(" ")' <<<'[{"source": "shell"}, {"source": "repo"}, {"source": "vendor-pkg"},
    {"source": "indicator"}, {"source": "mise"}, {"source": "self"}, {"source": "shell"}, {"source": 1}, {}]')"
same "row_order: desktop apps in table order, then mise tools, then Omabump" 'a b x mise:m self:omabump' \
  "$(jq -r "$jq_status"' .apps | row_order(["a", "b", "mise:m"]) | map(.pkg) | join(" ")' <<<'{"apps": [
    {"pkg": "self:omabump", "source": "self"}, {"pkg": "mise:m", "source": "mise"}, {"pkg": "x", "source": "indicator"},
    {"pkg": "a", "source": "repo"}, {"pkg": "b", "source": "vendor-pkg"}]}')"

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

# --- a recipe's signing keys: a keyring of their own ---------------------------------

same "pgp_fingerprints: one line, quoted, upper case" 'ABCDEF0123456789ABCDEF0123456789ABCDEF01' \
  "$(printf "pkgname=x\nvalidpgpkeys=('abcdef0123456789abcdef0123456789abcdef01')\n" | pgp_fingerprints)"
same "pgp_fingerprints: several lines, comments, unquoted" "$(printf '%s\n' "$(printf 'A%.0s' {1..40})" "$(printf 'B%.0s' {1..40})")" \
  "$(printf 'validpgpkeys=(\n  "%s" # someone\n  %s\n)\nsource=(x)\n' "$(printf 'A%.0s' {1..40})" "$(printf 'b%.0s' {1..40})" | pgp_fingerprints)"
same "pgp_fingerprints: none" '' "$(printf 'pkgname=x\n' | pgp_fingerprints)"
refuse "pgp_fingerprints: a short key ID is refused" pgp_fingerprints <<<"validpgpkeys=('F0134EE680CAC571')"
# A throwaway key pair made here, its public key shipped as omarchy-pkgs
# ships one: pkgbuilds/<pkg>/keys/pgp/<FPR>.asc, in a git repo the clone's
# functions read at a commit.
if command -v gpg >/dev/null; then
  pgp_gen=$scratch/pgp-gen
  mkdir -m 700 "$pgp_gen"
  pgp_key() {
    gpg --homedir "$pgp_gen" --batch --passphrase '' --quick-gen-key "$1 <$1@example.invalid>" ed25519 sign never </dev/null >/dev/null 2>&1
    gpg --homedir "$pgp_gen" --batch --with-colons --list-keys "$1@example.invalid" 2>/dev/null </dev/null | awk -F: '$1 == "fpr" { print $10; exit }'
  }
  pgp_good=$(pgp_key good) pgp_other=$(pgp_key other)
  real_pkgs_dir=$pkgs_dir
  pkgs_dir=$scratch/pgp-pkgs
  mkdir -p "$pkgs_dir/pkgbuilds/signed/keys/pgp"
  gpg --homedir "$pgp_gen" --batch --armor --export "$pgp_good" >"$pkgs_dir/pkgbuilds/signed/keys/pgp/$pgp_good.asc" 2>/dev/null </dev/null
  # Under the good key's name: the other key, then both together.
  gpg --homedir "$pgp_gen" --batch --armor --export "$pgp_other" >"$pkgs_dir/pkgbuilds/signed/keys/pgp/WRONG.asc" 2>/dev/null </dev/null
  gpg --homedir "$pgp_gen" --batch --armor --export "$pgp_good" "$pgp_other" >"$pkgs_dir/pkgbuilds/signed/keys/pgp/BOTH.asc" 2>/dev/null </dev/null
  tgit init -q "$pkgs_dir" && tgit -C "$pkgs_dir" add -A && tgit -C "$pkgs_dir" commit -qm keys
  pgp_rev=$(git -C "$pkgs_dir" rev-parse HEAD)
  # keyring_of <file to ship as the good key's> <fingerprints...>: status, the
  # keyring's primary keys, the reason.
  keyring_of() {
    local f=$1 kr=$scratch/pgp-keyring rc=0 err
    shift
    if [[ $f != "$pgp_good.asc" ]]; then
      cp "$pkgs_dir/pkgbuilds/signed/keys/pgp/$f" "$pkgs_dir/pkgbuilds/signed/keys/pgp/$pgp_good.asc"
      tgit -C "$pkgs_dir" commit -qam "swap"
    fi
    err=$(pgp_keyring "$(git -C "$pkgs_dir" rev-parse HEAD)" signed "$kr" "$@" 2>&1) || rc=$?
    echo "$rc|$(gpg --homedir "$kr" --batch --with-colons --list-keys 2>/dev/null </dev/null | awk -F: '$1 == "fpr" { print $10 }' | sort -u | tr '\n' ' ')|$err|$(stat -c %a "$kr" 2>/dev/null)"
    pgp_keyring_drop "$kr"
    tgit -C "$pkgs_dir" reset -q --hard "$pgp_rev"
  }
  same "pgp_keyring: the recipe's key, exactly its fingerprint: a keyring of it alone, mode 700" \
    "0|$pgp_good ||700" "$(keyring_of "$pgp_good.asc" "$pgp_good")"
  out=$(keyring_of WRONG.asc "$pgp_good")
  same "pgp_keyring: a file whose key has another fingerprint: refused" "1|$pgp_other" "$(cut -d'|' -f1 <<<"$out")|$(grep -o "primary key(s) [0-9A-F]*" <<<"$out" | cut -d' ' -f3)"
  out=$(keyring_of BOTH.asc "$pgp_good")
  same "pgp_keyring: a file with a second primary key: refused" '1|not exactly' "$(cut -d'|' -f1 <<<"$out")|$(grep -o 'not exactly' <<<"$out")"
  out=$(keyring_of "$pgp_good.asc" "$pgp_other")
  same "pgp_keyring: a listed fingerprint without its key file: refused, saying which" \
    "1|ships no keys/pgp/$pgp_other.asc" "$(cut -d'|' -f1 <<<"$out")|$(grep -o "ships no keys/pgp/$pgp_other.asc" <<<"$out")"
  same "pgp_keyring: no fingerprints: an empty keyring" '0|||700' "$(keyring_of "$pgp_good.asc")"
  # The file at the commit, not the work tree: a work tree the sync or a
  # hook changed is not read.
  cp "$pkgs_dir/pkgbuilds/signed/keys/pgp/WRONG.asc" "$pkgs_dir/pkgbuilds/signed/keys/pgp/$pgp_good.asc"
  out=$(pgp_keyring "$pgp_rev" signed "$scratch/pgp-keyring" "$pgp_good" 2>&1); rc=$?
  same "pgp_keyring: the key file at the commit, whatever the work tree holds" 0 "$rc"
  pgp_keyring_drop "$scratch/pgp-keyring"
  check "pgp_keyring_drop: the keyring goes" test ! -e "$scratch/pgp-keyring"
  pkgs_dir=$real_pkgs_dir
  gpgconf --homedir "$pgp_gen" --kill all >/dev/null 2>&1 </dev/null || true
  rm -rf "$pgp_gen" "$scratch/pgp-pkgs"
else
  if [[ -n ${CI:-} ]]; then fail "pgp_keyring tests run on CI" "gpg is not installed"; else echo "SKIP - pgp_keyring: gpg is not installed"; fi
fi

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
    "ls --json --backend aqua --backend github --backend ubi") echo '{"a":[],"b":[]}' ;;
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
# GitHub's API with all its calls left, so that mise_github_reserve keeps a
# (the github-release tests below set their own).
printf '{"resources": {"core": {"limit": 60, "remaining": 60}}}\n200' >"$scratch/served/api-rate_limit"
reset_mise() { : >"$mise_calls"; mise_ls_json='{}' mise_safe_json='{}' mise_outdated_json='{}' mise_bump_json='{}' mise_error="" mise_bump_error="" mise_backend_error=""; }
load_table; reset_mise
mise_load 1
same "mise: outdated and bump name only the selected keys on safe backends, after --" \
  $'outdated --json -- a e\noutdated --bump --json -- a e' "$(grep '^outdated' "$mise_calls")"
same "mise: one ls for all allowed backends, one for GitHub's, plus the inventory" 3 "$(grep -c '^ls' "$mise_calls")"
# In a check's run, what mise may spend is counted against the run's
# /rate_limit answer: one key on GitHub's backends (a) of the two asked.
run_tmp=$scratch/mise-run
mkdir -p "$run_tmp"
reset_mise
mise_load 1
same "mise: a check counts its GitHub-backed keys against the calls left" '59 60' "$(cat "$run_tmp/github-api-left")"
rm -rf "$run_tmp"
run_tmp=""
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
# A pinned request whose version list failed: mise names the backend's
# tool, which its install record maps to the key.
mkdir -p "$scratch/mise-rec/installs/e"
printf 'version = 1\nfull = "aqua:org/e-cli"\n' >"$scratch/mise-rec/installs/e/.mise.backend.toml"
echo "mise WARN  Remote versions cannot be fetched for org/e-cli: HTTP status server error (504 Gateway Timeout)" >"$scratch/mise.err"
mise_fetch_failed=() mise_query=(e aqua:org/f other)
echo "mise WARN  Remote versions cannot be fetched for org/f: 403 rate limit exceeded" >>"$scratch/mise.err"
MISE_DATA_DIR=$scratch/mise-rec mise_note_fetch_failures "$scratch/mise.err"
same "mise_note_fetch_failures: a version list that failed, by the install record and by a backend key" \
  'HTTP status server error (504 Gateway Timeout)|403 rate limit exceeded|' \
  "${mise_fetch_failed[e]:-}|${mise_fetch_failed[aqua:org/f]:-}|${mise_fetch_failed[other]:-}"
same "mise_backend_name: none without a record, nor for a key with a path" '|' \
  "$(MISE_DATA_DIR=$scratch/mise-rec mise_backend_name other)|$(MISE_DATA_DIR=$scratch/mise-rec mise_backend_name ../e)"
mise_fetch_failed=() mise_query=()
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
load_table 2>/dev/null
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
# A guard for calls a test does not expect; tests below stub it in turn.
# shellcheck disable=SC2329
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
# shellcheck disable=SC2016 # expanded by the fake mise, not here
printf '#!/bin/sh\necho "${MISE_USE_VERSIONS_HOST-unset} ${MISE_USE_VERSIONS_HOST_TRACK-unset} ${MISE_DISABLE_TOOLS-unset}"\n' >"$scratch/agebin/mise"
same "mise_run: finding versions skips mise's versions host, which lags releases; no install counter" 'false false ' \
  "$(unset MISE_DISABLE_TOOLS; PATH=$scratch/agebin:$PATH MISE_USE_VERSIONS_HOST=true real_mise_run outdated)"
same "mise_run: an install of a version found goes through the host" 'true false ' \
  "$(unset MISE_DISABLE_TOOLS; PATH=$scratch/agebin:$PATH mise_versions_host=1 real_mise_run install -- x@1)"
same "mise_run: not when you turned the host off" 'false false ' \
  "$(unset MISE_DISABLE_TOOLS; PATH=$scratch/agebin:$PATH mise_user_host=false mise_versions_host=1 real_mise_run install -- x@1)"
same "mise_run: mise settings get as it is" 'unset false unset' "$(unset MISE_DISABLE_TOOLS; PATH=$scratch/agebin:$PATH real_mise_run settings get x)"
same "mise_disabled_tools: yours, mise's setting and the unused ones, once each, odd names left out" 'a,npm:@s/b,c,d' \
  "$(MISE_DISABLE_TOOLS='a, npm:@s/b,../x' mise_user_tools='c,a' mise_unused_tools='d,c,x y' mise_disabled_tools)"
same "mise_run: every other call is told them" 'false false mine,u' \
  "$(unset MISE_DISABLE_TOOLS; mise_user_tools=mine mise_unused_tools=u PATH=$scratch/agebin:$PATH real_mise_run ls)"
same "mise_run: mise install and up are told only yours: they rewrite every other tool's shims" $'true false mine\nfalse false mine' \
  "$(unset MISE_DISABLE_TOOLS
     PATH=$scratch/agebin:$PATH mise_user_tools=mine mise_unused_tools=u mise_versions_host=1 real_mise_run install -- x@1
     PATH=$scratch/agebin:$PATH mise_user_tools=mine mise_unused_tools=u real_mise_run up -- x)"
# The tools the config names that mise has nothing installed of.
mise_unused_tools=x mise_ls_json='{"a": [], "npm:@s/b": []}'
mise_run() { [[ $* == 'config ls --json' ]] && echo '[{"tools": ["a", "c", "npm:@s/b"]}, {"tools": ["d", "c", 5]}, "x"]'; }
mise_unused_load
same "mise_unused_load: what the config names, less the inventory's keys" 'c,d' "$mise_unused_tools"
mise_run() { return 1; }
mise_unused_tools=x
mise_unused_load
same "mise_unused_load: none when mise cannot list its config" '' "$mise_unused_tools"
# shellcheck disable=SC2329 # called from omabump-common
mise_run() { echo "mise_run called in a test" >&2; return 1; }
mise_ls_json='{}'
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
check "skip_over: pacman, a newer release than the skipped one" skip_over omarchy true 0.68.0 0.67.0 0.65.0-1
check "skip_over: pacman, the skipped version installed" skip_over omarchy false 0.67.0 0.67.0 1:0.67.0-2
refuse "skip_over: pacman, a skip vercmp calls equal to the newest" skip_over omarchy true 0.66 0.66.0 0.65-1
refuse "skip_over: pacman, a rollback below the skipped version" skip_over omarchy true 0.66.0 0.67.0 0.65.0-1
refuse "skip_over: pacman, a skip of a version still to come" skip_over omarchy false 1.9 2.0 1.9-1
check "skip_over: mise, another newest version" skip_over mise true 1.0.99 1.0.98 1.0.0
check "skip_over: mise, at the skipped version" skip_over mise false 1.0.99 1.0.99 1.0.99
refuse "skip_over: mise, the skipped version is the update" skip_over mise true 1.0.99 1.0.99 1.0.0
refuse "skip_over: no newest version, no answer" skip_over omarchy false '' 0.67.0 0.68.0-1
# A repo row's newest version can be the repo's full one, a pkgrel or an
# epoch in it: such a skip holds against the full version installed, and
# can be stored at all.
check "skip_version_ok: a full version with an epoch" skip_version_ok 1:2.0-1
check "skip_version_ok: a full version with a pkgrel" skip_version_ok 1.2-2
refuse "skip_version_ok: an epoch with no pkgrel is none" skip_version_ok 1:2.0
check "row_skipped: repo, the skipped pkgrel is the newest" row_skipped repo true 1.2-2 1.2-2
refuse "skip_over: repo, a skipped pkgrel does not end at once with the release before it installed" skip_over repo true 1.2-2 1.2-2 1.2-1
check "skip_over: repo, ends once that pkgrel is installed" skip_over repo false 1.2-2 1.2-2 1.2-2
refuse "skip_over: repo, a skipped epoch version does not end at once" skip_over repo true 1:2.0-1 1:2.0-1 1:1.9-1
check "skip_over: repo, a newer full version ends it" skip_over repo true 1:2.0-2 1:2.0-1 1:1.9-1
skipped_json='{"grok-bot": "0.66.0"}'
same "skip_ended: the skip's version once it is over" '0.66.0|' \
  "$(skip_ended '{"pkg": "grok-bot", "source": "omarchy", "updateAvailable": true, "latest": "0.67", "installed": "0.65-1"}')|$(
    skip_ended '{"pkg": "grok-bot", "source": "omarchy", "updateAvailable": true, "latest": "0.66", "installed": "0.65-1"}')"
skipped_json='{}'
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

# --- rows: what is known about an app, made a row ---------------------------------------

# A feed knows only upstream's version: the installed one is compared less
# epoch and pkgrel. A version from mise (or none) is compared as it is.
check "row_newer: a feed's version against the installed one less epoch and pkgrel" row_newer 1.2 1:1.0-1 feed
refuse "row_newer: the same versions, not from a feed, compare whole" row_newer 1.2 1:1.0-1 mise
refuse "row_newer: a feed at the installed upstream version" row_newer 1.2 1.2-5 feed
check "row_past: installed past what the feed knows" row_past 1.3-1 1.2 feed
refuse "row_past: at it, by its upstream part" row_past 2:1.2-7 1.2 feed
check "row_past: whole versions when not from a feed" row_past 2:1.2-7 1.2 mise

# update_blocked's three answers, as "<status>|<stdout>": 0 off with the
# reason, 1 not off, 2 and up the entry could not be read (jq's status, 2
# for its 1), which no caller may take for "not off".
blocked_of() { local out rc=0; out=$(update_blocked "$@" 2>/dev/null) || rc=$?; echo "$rc|$out"; }
same "update_blocked: the reason apps.json gives" '0|a known problem' \
  "$(blocked_of '{"pkg": "a", "source": "repo", "updateBlocked": "a known problem"}' false)"
same "update_blocked: none for an app that updates itself" '1|' \
  "$(blocked_of '{"pkg": "a", "source": "repo", "updateBlocked": "x"}' true)"
same "update_blocked: none for Omabump's own row" '1|' "$(blocked_of "$self_app" false)"
same "update_blocked: none without one" '1|' \
  "$(blocked_of '{"pkg": "a", "source": "repo", "updateBlocked": ""}' false)"
same "update_blocked: an entry jq cannot parse is unread, not not off" '5|' "$(blocked_of 'not json' false)"
same "update_blocked: unread when jq is killed, its status kept" '137|' \
  "$( jq() { return 137; }; blocked_of '{"pkg": "a", "updateBlocked": "x"}' false )"
same "update_blocked: a jq that fails with 1 is unread too (2)" '2|' \
  "$( jq() { return 1; }; blocked_of '{"pkg": "a"}' false )"
same "update_blocked: unread for an app that updates itself as well" '137|' \
  "$( jq() { return 137; }; blocked_of '{"pkg": "a"}' true )"

# derived <source> <installed name> <installed> <latest> <from> [<app>]:
# a row as a check's route would leave it (installable, the route's note),
# through row_derive and row_json. Prints the row.
derived() {
  local pkg source installed_name installed latest from app label installable note
  local mise_update self_updating held unchecked error stale omarchy_update blocked
  local muted_json='[]' skipped_json='{}' update switchable muted skipped skip_end quiet
  local hold_clause unread=false
  pkg=r-app source=$1 installed_name=$2 installed=$3 latest=$4 from=$5
  app=${6:-'{"pkg": "r-app", "label": "R <App>", "icon": "assets/r.svg"}'}
  label=$(jq -r '.label // .pkg' <<<"$app") installable=true note="A note of the route"
  mise_update=false self_updating=false held=false unchecked=false
  error="" stale=false omarchy_update=false blocked=""
  # A copy that updates itself has no route: nothing installable, no note.
  if self_updating_name "$installed_name"; then self_updating=true installable=false note=""; fi
  row_derive
  row_json
}
mkdir -p "$state_dir"
row_fields='"\(.updateAvailable)|\(.installable)|\(.held)|\(.switchable)|\(.unchecked)|\(.note)"'
same "row: a vendor row with an update, the whole row" \
  '{"pkg":"r-app","label":"R ‹App›","source":"vendor-pkg","installedName":"r-app","installed":"1.0-1","latest":"1.2","versionFrom":"feed","updateAvailable":true,"installable":true,"error":"","note":"A note of the route","stale":false,"switchable":false,"skipped":false,"skipEnded":"","unchecked":false,"held":false,"omarchyUpdate":false,"blocked":false,"selfUpdating":false,"icon":"assets/r.svg","iconLight":"","holdClause":"","unread":false,"section":"desktop","switchRoute":true,"repoVersion":"","vendorVersion":"","ahead":false,"buildable":false,"buildNote":""}' \
  "$(derived vendor-pkg r-app 1.0-1 1.2 feed)"
same "row: no field nothing reads (muted, request, recipe)" 'false|false|false' \
  "$(derived vendor-pkg r-app 1.0-1 1.2 feed | jq -r '"\(has("muted"))|\(has("request"))|\(has("recipe"))"')"
same "row: the feed's version is the installed one's upstream part: no update" \
  'false|true|false|false|false|A note of the route' \
  "$(derived vendor-pkg r-app 2:1.2-3 1.2 feed | jq -r "$row_fields")"
same "row: installed under another name at the newest version: Switch" \
  'false|true|false|true|false|A note of the route' \
  "$(derived vendor-pkg r-app-bin 1.2-1 1.2 feed | jq -r "$row_fields")"
same "row: under another name and behind: Update replaces it, no Switch" \
  'true|true|false|false|false|A note of the route' \
  "$(derived vendor-pkg r-app-bin 1.1-1 1.2 feed | jq -r "$row_fields")"
same "row: under another name, past the newest version: no Switch" \
  'false|true|false|false|false|A note of the route' \
  "$(derived vendor-pkg r-app-bin 1.3-1 1.2 feed | jq -r "$row_fields")"
# shellcheck disable=SC2088 # the path as apps.json writes it
same "row: a copy that updates itself, compared as it is, its note says how" \
  'true|false|false|false|false|Updates itself: run r update' \
  "$(derived repo '~/.r/app' 1.1 1.2 feed '{"pkg": "r-app", "selfUpdate": "run r update"}' | jq -r "$row_fields")"
# shellcheck disable=SC2088 # the path as apps.json writes it
same "row: a copy at a pre-release: unchecked, and why" \
  'false|false|false|false|true|Pre-release build, not compared with the feed'"'"'s stable releases; Updates itself: open r-app to update' \
  "$(derived repo '~/.r/app' 1.3-nightly.1 1.2 feed '{"pkg": "r-app"}' | jq -r "$row_fields")"
# shellcheck disable=SC2088 # the path as apps.json writes it
same "row: a copy is never ahead nor buildable" 'false|false' \
  "$(derived repo '~/.r/app' 1.1 1.2 feed '{"pkg": "r-app"}' | jq -r '"\(.ahead)|\(.buildable)"')"

# switch_target_ok: the one rule the check and the installer share for
# whether Switch may install a version over what is installed.
check "switch_target_ok: at the same upstream version, a pkgrel apart" switch_target_ok 1.2-3 1.2
check "switch_target_ok: the repo's full version at the installed one" switch_target_ok 1:1.2-1 1:1.2-1
refuse "switch_target_ok: the installed full version newer than the repo's" switch_target_ok 1.2-2 1.2-1
refuse "switch_target_ok: no target" switch_target_ok 1.2-1 ""

# build_hold_clause: a recipe's release-age window, from the first check
# that saw the version, at 2026-01-01 00:00 UTC.
hold_of() {
  local TZ=UTC seen_file=$scratch/derived-seen.json now=1767225600
  export TZ
  jq -n --arg v 1.2 --argjson at $(( now - $2 )) '{"r-app": {version: $v, at: $at}}' >"$seen_file"
  build_hold_clause r-app 1.2 "$1" "$now"
}
same "build_hold_clause: the recipe holds the release: until when Build now waits" \
  'omarchy-pkgs holds new releases for 24 h, Build now from Jan 2 00:00' "$(hold_of 86400 0)"
same "build_hold_clause: counted from when a check first saw it" \
  'omarchy-pkgs holds new releases for 2 h, Build now from Jan 1 01:00' "$(hold_of 5400 1800)"
same "build_hold_clause: a window that has passed: nothing" '' "$(hold_of 86400 86400)"
same "build_hold_clause: no window: nothing" '' "$(hold_of 0 0)"
same "build_why: in order: no build, Update off, tools, the recipe" \
  "Not in Omarchy's repo yet|Update off: x|m|held|" \
  "$(build_why false x m held)|$(build_why true x m held)|$(build_why true '' m held)|$(build_why true '' '' held)|$(build_why true '' '' '')"
# The settings' mute and skip, for a row with an update.
# quiet_of <muted> <skipped>: row_quiet's answer for r-app at 1.0-1 with
# 1.2 out, under those settings, as "muted|skipped|skip_end|quiet".
quiet_of() {
  local muted_json=$1 skipped_json=$2 muted skipped skip_end quiet
  row_quiet r-app repo true 1.2 1.0-1
  # shellcheck disable=SC2031 # row_quiet set them in this shell, as locals here
  echo "$muted|$skipped|$skip_end|$quiet"
}
same "row_quiet: muted, a skip of the newest version, nothing over" 'true|true||true' \
  "$(quiet_of '["r-app"]' '{"r-app": "1.2"}')"
same "row_quiet: a skip of an older version is over" 'false|false|1.1|false' "$(quiet_of '[]' '{"r-app": "1.1"}')"

# The mise ladder: mise_row's answer, which the check shows and Update acts
# on, from given tables. Prints "state|latest|installable|update|request|note|error".
mise_state_on() {
  local latest from note installable mise_update request feed_error unchecked mise_state
  local mise_safe_json=${4:-'{"t": true}'} mise_error=${5:-} mise_bump_error="" mise_outdated_json=$1 mise_bump_json=$2
  local mise_backend_error="" fetch_failed_t=${6:-}
  local -A mise_fetch_failed=() mise_held=()
  [[ -z $fetch_failed_t ]] || mise_fetch_failed[t]=$fetch_failed_t
  mise_row t "$3"
  echo "$mise_state|$latest|$installable|$mise_update|$request|$note|$feed_error"
}
same "mise_row: a key on no allowed backend is unchecked" \
  'unchecked||false|false||Update check skipped: not on a backend Omabump queries|' "$(mise_state_on '{}' '{}' 1.0 '{}')"
same "mise_row: mise outdated failed: an error, no version" \
  'error||true|false|||mise outdated failed: x' "$(mise_state_on '{}' '{}' 1.0 '' 'mise outdated failed: x')"
same "mise_row: versions mise could not fetch: an error" \
  'error||true|false|||mise could not fetch the versions of t: rate limited' "$(mise_state_on '{}' '{}' 1.0 '' '' 'rate limited')"
same "mise_row: what mise up reaches is the update" \
  'update|1.1|true|true|||' "$(mise_state_on '{"t": {"latest": "1.1"}}' '{}' 1.0)"
same "mise_row: a pin below the newest release" \
  'pinned|0.97.1|false|false|0.96|Pinned to 0.96, 0.97.1 exists|' \
  "$(mise_state_on '{}' '{"t": {"bump": "0.97", "latest": "0.97.1", "requested": "0.96"}}' 0.96.0)"
same "mise_row: a latest request your settings hold back" \
  'pinned|2.0|false|false|latest|Held back by your mise settings, 2.0 exists|' \
  "$(mise_state_on '{}' '{"t": {"latest": "2.0", "requested": "latest"}}' 1.0)"
same "mise_row: nothing newer: current, at the installed version" \
  'current|1.0|true|false|||' "$(mise_state_on '{}' '{}' 1.0)"

# --- Omarchy's repo: its database, and what it makes of a row -------------------------

# pacman-conf as Omarchy's pacman.conf answers it: the lines of
# $OMABUMP_TEST_SERVERS for `--repo omarchy Server`, and exit 1 (repo not
# configured) when that is empty.
mkdir -p "$scratch/confbin"
cat >"$scratch/confbin/pacman-conf" <<'EOF'
#!/bin/sh
[ "$*" = "--repo omarchy Server" ] || exit 2
[ -n "${OMABUMP_TEST_SERVERS:-}" ] || { echo "error: repo 'omarchy' not configured" >&2; exit 1; }
printf '%s\n' "$OMABUMP_TEST_SERVERS"
EOF
chmod +x "$scratch/confbin/pacman-conf"
# The environment of servers_of and repo_of is their own: locals, exported
# for the pacman-conf stub, not a subshell's.
servers_of() {
  local OMABUMP_TEST_SERVERS=$1 PATH=$scratch/confbin:$PATH repo_error="" repo_server=""
  export OMABUMP_TEST_SERVERS PATH
  if repo_server_find; then echo "$repo_server"; else echo "$repo_error"; fi
}
same "repo_server_find: the first https Server, less its trailing slash" 'https://pkgs.omarchy.org/edge/x86_64' \
  "$(servers_of $'http://mirror.example/x86_64\nhttps://pkgs.omarchy.org/edge/x86_64/\nhttps://other.example/x86_64')"
same "repo_server_find: a server with odd characters is passed over" 'https://b.example/x86_64' \
  "$(servers_of $'https://a.example/x 86\nhttps://a.example/../x\nhttps://a.example/"x"\nhttps://b.example/x86_64')"
same "repo_server_find: no such repo, said so" 'No [omarchy] repo in pacman.conf' "$(servers_of '')"
same "repo_server_find: no https Server, said so" 'No https Server for [omarchy] in pacman.conf' "$(servers_of 'http://mirror.example/x86_64')"

sum64=$(printf 'a%.0s' {1..64})
repo_ok_of() { if repo_entry_ok "$@"; then echo ok; else echo no; fi; }
same "repo_entry_ok: the package file of that name, version and architecture, or any" 'ok ok ok' \
  "$(repo_ok_of crush-bin 0.20.0-1 "crush-bin-0.20.0-1-$(uname -m).pkg.tar.zst" "$sum64") $(repo_ok_of x 1.0-1 x-1.0-1-any.pkg.tar.xz "$sum64") $(
     repo_ok_of cursor-cli 1:2026.11.22.1.e9042b2-2 "cursor-cli-1:2026.11.22.1.e9042b2-2-$(uname -m).pkg.tar.zst" "$sum64")"
same "repo_entry_ok: another name's, version's or architecture's file, a path, an odd extension or sum" 'no no no no no no no no no' \
  "$(for a in "crush-bin 0.20.0-1 crush-bin-debug-0.20.0-1-any.pkg.tar.zst $sum64" "x 1.0-1 x-1.0-2-any.pkg.tar.zst $sum64" \
       "x 1.0-1 x-1.0-1-otherarch.pkg.tar.zst $sum64" "x 1.0-1 ../x-1.0-1-any.pkg.tar.zst $sum64" "x 1.0-1 a/x-1.0-1-any.pkg.tar.zst $sum64" \
       "x 1.0-1 x-1.0-1-any.pkg.tar.sh $sum64" "x 1.0-1 x-1.0-1-any.pkg.tar.zst ${sum64^^}" "x 1.0 x-1.0-any.pkg.tar.zst $sum64" \
       "-x 1.0-1 -x-1.0-1-any.pkg.tar.zst $sum64"; do
       # shellcheck disable=SC2086 # the four fields, split on purpose
       repo_ok_of $a; done | paste -sd' ')"
# Name and full version bounded, and so the file name: a pkgrel of 140 KB
# would pass full_version_ok and reach jq as one argument.
n128=$(head -c 128 /dev/zero | tr '\0' a) v128=1.0-$(head -c 124 /dev/zero | tr '\0' 1) long_rel=$(head -c 140000 /dev/zero | tr '\0' 1)
same "repo_entry_ok: a name and a full version of 128 characters each" ok "$(repo_ok_of "$n128" "$v128" "$n128-$v128-any.pkg.tar.zst" "$sum64")"
same "repo_entry_ok: one character more of either, or a pkgrel of 140 KB, is refused" 'no no no' \
  "$(repo_ok_of "${n128}b" 1.0-1 "${n128}b-1.0-1-any.pkg.tar.zst" "$sum64") $(repo_ok_of x "${v128}1" "x-${v128}1-any.pkg.tar.zst" "$sum64") $(
     repo_ok_of x "1.0-$long_rel" "x-1.0-$long_rel-any.pkg.tar.zst" "$sum64")"

repo_db "$scratch/served/omarchy.db" 'crush-bin 0.20.0-1' 'crush-bin-debug 0.21.0-1' 'cursor-cli 1:2026.11.22.1.e9042b2-2' 'dup 1.0-1 dup-1.0-1-any.pkg.tar.zst twice' \
  'evil 1.0-1 ../evil-1.0-1-any.pkg.tar.zst'
same "repo_db_entries: each package taken by its exact name; a field twice or an odd file name drops it" \
  "crush-bin 0.20.0-1|crush-bin-debug 0.21.0-1|cursor-cli 1:2026.11.22.1.e9042b2-2" \
  "$(repo_db_entries "$scratch/served/omarchy.db" | cut -f1,2 | tr '\t' ' ' | sort | paste -sd'|')"
printf 'not an archive' >"$scratch/repo-junk.db"
refuse "repo_db_entries: a file bsdtar cannot read fails" repo_db_entries "$scratch/repo-junk.db"
(cd "$scratch" && rm -rf repo-none && mkdir -p repo-none/x-1 && echo '%CSIZE%' >repo-none/x-1/desc && bsdtar --zstd -cf repo-none.db -C repo-none x-1)
refuse "repo_db_entries: a database with no package Omabump takes fails" repo_db_entries "$scratch/repo-none.db"
# repo_load and repo_lookup through the fetch stub: "<state>|<version>
# <file>|<error>|<size bound> <URL fetched>" for the package $1, with the
# servers $servers (one by default).
repo_of() {
  local OMABUMP_TEST_SERVERS=${servers-https://pkgs.example/edge/x86_64} PATH=$scratch/confbin:$PATH
  export OMABUMP_TEST_SERVERS PATH
  ( eval "$(declare -f fetch | sed '1s/^fetch/stub_fetch/')"
    fetch() { echo "${max_size:-} ${*: -1}" >>"$scratch/repo-fetch.log"; stub_fetch "$@"; }
    : >"$scratch/repo-fetch.log"
    repo_load || true
    repo_lookup "$1" || true
    echo "$repo_state|$repo_version $repo_file|$repo_error|$(paste -sd' ' "$scratch/repo-fetch.log")" )
}
same "repo_load: one fetch of the database, bounded; crush-bin is not crush-bin-debug" \
  "ready|0.20.0-1 crush-bin-0.20.0-1-$(uname -m).pkg.tar.zst||8M https://pkgs.example/edge/x86_64/omarchy.db" "$(repo_of crush-bin)"
same "repo_lookup: the epoch's version and file as the database names them" \
  "ready|1:2026.11.22.1.e9042b2-2 cursor-cli-1:2026.11.22.1.e9042b2-2-$(uname -m).pkg.tar.zst||8M https://pkgs.example/edge/x86_64/omarchy.db" "$(repo_of cursor-cli)"
same "repo_lookup: a package the repo does not have" 'ready| ||8M https://pkgs.example/edge/x86_64/omarchy.db' "$(repo_of crush)"
same "repo_load: no such repo: none, and nothing fetched" 'none| |No [omarchy] repo in pacman.conf|' "$(servers='' repo_of crush-bin)"
mv "$scratch/served/omarchy.db" "$scratch/omarchy.db.away"
same "repo_load: a database that cannot be fetched: failed, and why" \
  'failed| |could not fetch Omarchy'"'"'s repo database from https://pkgs.example/edge/x86_64 (curl exit 22)|8M https://pkgs.example/edge/x86_64/omarchy.db' \
  "$(repo_of crush-bin)"
cp "$scratch/repo-junk.db" "$scratch/served/omarchy.db"
same "repo_load: one that cannot be read: failed, and why" \
  'failed| |Omarchy'"'"'s repo database from https://pkgs.example/edge/x86_64 could not be read|8M https://pkgs.example/edge/x86_64/omarchy.db' \
  "$(repo_of crush-bin)"
mv "$scratch/omarchy.db.away" "$scratch/served/omarchy.db"
same "repo_file_url: an epoch's colon is percent-encoded" 'https://pkgs.example/x/cursor-cli-1%3A2.0-1-any.pkg.tar.zst' \
  "$(repo_server=https://pkgs.example/x repo_file_url cursor-cli-1:2.0-1-any.pkg.tar.zst)"
rm -f "$scratch/served/omarchy.db" "$scratch/repo-junk.db" "$scratch/repo-none.db"

# package_signature_ok against a gpg stub that prints $T_GPG_STATUS as its
# status lines and exits $T_GPG_RC, and a pacman-conf whose GPGDir is
# $T_GPGDIR: "<status>|<signer>|<error>|<gpg's arguments>".
mkdir -p "$scratch/gpgbin"
cat >"$scratch/gpgbin/gpg" <<'EOF'
#!/bin/sh
echo "$*" >"$T_GPG_ARGS"
printf '%s\n' "$T_GPG_STATUS"
echo "gpg: its own words" >&2
exit "$T_GPG_RC"
EOF
cat >"$scratch/gpgbin/pacman-conf" <<'EOF'
#!/bin/sh
[ "$*" = GPGDir ] || exit 2
printf '%s\n' "$T_GPGDIR"
EOF
chmod +x "$scratch/gpgbin/gpg" "$scratch/gpgbin/pacman-conf"
printf 'binary signature' >"$scratch/sig.sig"
printf 'package' >"$scratch/sig.pkg"
sig_of() {
  # shellcheck disable=SC2034 # read by the stubs
  local PATH=$scratch/gpgbin:$PATH T_GPG_STATUS=$1 T_GPG_RC=${2:-0} T_GPGDIR=${3-/k/} T_GPG_ARGS=$scratch/gpg-args
  local sig_signer sig_error rc=0
  export PATH T_GPG_STATUS T_GPG_RC T_GPGDIR T_GPG_ARGS
  rm -f "$scratch/gpg-args"
  package_signature_ok "$scratch/sig.sig" "$scratch/sig.pkg" 2>/dev/null || rc=$?
  echo "$rc|$sig_signer|$sig_error|$(cat "$scratch/gpg-args" 2>/dev/null)"
}
gpg_good=$'[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG F0134EE680CAC571 Omarchy <pkgs@omarchy.org>\n[GNUPG:] VALIDSIG 40DFB630FF42BCFFB047046CF0134EE680CAC571 2026-09-07 1788804152 0 4 0 22 10 00 40DFB630FF42BCFFB047046CF0134EE680CAC571'
gpg_args="--homedir /k/ --no-permission-warning --status-fd 1 --verify $scratch/sig.sig $scratch/sig.pkg"
same "package_signature_ok: a good signature by a fully trusted key, gpg run as pacman-key runs it, in GPGDir" \
  "0|Omarchy <pkgs@omarchy.org>, key 40DFB630FF42BCFFB047046CF0134EE680CAC571||$gpg_args" "$(sig_of "$gpg_good"$'\n[GNUPG:] TRUST_FULLY 0 pgp')"
same "package_signature_ok: an ultimately trusted key" 0 "$(sig_of "$gpg_good"$'\n[GNUPG:] TRUST_ULTIMATE 0 pgp' | cut -d'|' -f1)"
same "package_signature_ok: a good signature by a key the keyring does not trust, gpg exiting 0: refused" \
  "1||the signature is good, but its key is not one pacman's keyring trusts|$gpg_args" "$(sig_of "$gpg_good"$'\n[GNUPG:] TRUST_UNDEFINED 0 pgp')"
same "package_signature_ok: trust words that are no status line do not count" \
  "1||the signature is good, but its key is not one pacman's keyring trusts" \
  "$(sig_of "$gpg_good"$'\ngpg: [GNUPG:] TRUST_FULLY 0 pgp\n[GNUPG:] TRUST_FULLYX' | cut -d'|' -f1-3)"
same "package_signature_ok: a bad signature" "1||gpg exited 1: it is not a good signature from a key in pacman's keyring" \
  "$(sig_of $'[GNUPG:] BADSIG F0134EE680CAC571 Omarchy\n[GNUPG:] TRUST_FULLY 0 pgp' 1 | cut -d'|' -f1-3)"
same "package_signature_ok: an expired or revoked key, or an expired signature, gpg exiting 0: refused" \
  "1||gpg found a signature that has expired, or is by an expired or revoked key|1||gpg found a signature that has expired, or is by an expired or revoked key" \
  "$(sig_of "${gpg_good/GOODSIG/REVKEYSIG}"$'\n[GNUPG:] TRUST_FULLY 0 pgp' | cut -d'|' -f1-3)|$(
     sig_of "$gpg_good"$'\n[GNUPG:] EXPSIG F0134EE680CAC571 Omarchy\n[GNUPG:] TRUST_FULLY 0 pgp' | cut -d'|' -f1-3)"
same "package_signature_ok: the primary key's fingerprint, VALIDSIG's last field" '0|Omarchy <pkgs@omarchy.org>, key 1111' \
  "$(sig_of "${gpg_good% *} 1111"$'\n[GNUPG:] TRUST_FULLY 0 pgp' | cut -d'|' -f1,2)"
same "package_signature_ok: gpg exiting 0 with no VALIDSIG" "1||gpg found no valid signature" \
  "$(sig_of $'[GNUPG:] NEWSIG\n[GNUPG:] TRUST_FULLY 0 pgp' | cut -d'|' -f1-3)"
same "package_signature_ok: no GPGDir from pacman-conf: pacman's own default" '0|--homedir /etc/pacman.d/gnupg' \
  "$(sig_of "$gpg_good"$'\n[GNUPG:] TRUST_FULLY 0 pgp' 0 '' | cut -d'|' -f1,4 | cut -d' ' -f1-2)"
same "package_signature_ok: a GPGDir that is no absolute path: refused, gpg not run" \
  "1||pacman-conf names GPGDir 'k/', not an absolute path|" "$(sig_of "$gpg_good"$'\n[GNUPG:] TRUST_FULLY 0 pgp' 0 k/)"
same "package_signature_ok: the signer's words are terminal-safe" '0|Om^[[2Jarchy, key 40DF' \
  "$(sig_of $'[GNUPG:] GOODSIG F0 Om\e[2Jarchy\n[GNUPG:] VALIDSIG 40DF 2026\n[GNUPG:] TRUST_FULLY 0 pgp' | cut -d'|' -f1,2)"
printf -- '-----BEGIN PGP SIGNATURE-----\n' >"$scratch/sig.sig"
same "package_signature_ok: an armored signature: refused, as pacman-key refuses one, gpg not run" \
  "1||the signature is armored; pacman takes only a binary one|" "$(sig_of "$gpg_good"$'\n[GNUPG:] TRUST_FULLY 0 pgp')"
rm -rf "$scratch/gpgbin" "$scratch/sig.sig" "$scratch/sig.pkg" "$scratch/gpg-args"

# repo_derived <installed> <vendor's latest> <feed error> <repo state> <repo's version> [<installable>] [<installed name>] [<build reason>]:
# a check's repo row, the route's installable as given (true by default),
# installed as r-app unless <installed name> says otherwise, the vendor's
# version as the feed gave it (or, with a feed error, the last check's),
# through row_derive (repo_derive) and row_json, and its fields
# "update|installable|held|latest|versionFrom|stale|error|note|holdClause|repoVersion|ahead|buildable|buildNote|switchable".
repo_derived() {
  local pkg=r-app source=repo installed_name=${7:-r-app} installed=$1 latest="" from="" vendor_version=$2 feed_error=$3 route_error=""
  # shellcheck disable=SC2034 # repo_sha256 is repo_lookup's, set for it
  local repo_state=$4 repo_error="" repo_version="" repo_file="" repo_sha256="" stale=false installable=${6:-true} note=""
  local app='{"pkg": "r-app", "label": "R"}' label=R mise_update=false self_updating=false repo_why="" repo_failed=false
  local held=false unchecked=false omarchy_update=false blocked="" error line build_reason=${8:-}
  local muted_json='[]' skipped_json='{}' update switchable muted skipped skip_end quiet hold_clause="" unread=false
  local repo_new ahead buildable build_note route_ok
  local -A repo_entries=()
  [[ -z $5 ]] || repo_entries[r-app]="$5 r-app-$5-any.pkg.tar.zst $sum64"
  repo_lookup r-app || true
  case $4 in
    none) repo_error="No [omarchy] repo in pacman.conf" repo_why=$repo_error ;;
    failed) repo_error="could not fetch Omarchy's repo database from https://pkgs.example (curl exit 6)" repo_failed=true ;;
    ready) [[ -n $repo_version ]] || repo_why="Omarchy's repo has no r-app" ;;
  esac
  # A feed that failed leaves the last check's version, as the check does.
  [[ -z $feed_error ]] || stale=true
  row_derive
  error=""
  while IFS= read -r line; do [[ -z $line ]] || error+=${error:+; }$line; done <<<"$route_error"$'\n'"$feed_error"
  row_json | jq -r '"\(.updateAvailable)|\(.installable)|\(.held)|\(.latest)|\(.versionFrom)|\(.stale)|\(.error)|\(.note)|\(.holdClause)|\(.repoVersion)|\(.ahead)|\(.buildable)|\(.buildNote)|\(.switchable)"'
}
same "repo row: the repo has the vendor's newest: Update" 'true|true|false|1.2|feed|false||||1.2-1|false|false||false' \
  "$(repo_derived 1.0-1 1.2 '' ready 1.2-1)"
same "repo row: the vendor ahead of the repo: the update shows, held, no Update, ahead and buildable" \
  "true|false|true|1.2|feed|false||Not in Omarchy's repo yet|Not in Omarchy's repo yet|1.0-1|true|true||false" "$(repo_derived 1.0-1 1.2 '' ready 1.0-1)"
same "repo row: ahead, Build now cannot run: not buildable, and why" \
  "true|false|true|1.2|feed|false||Not in Omarchy's repo yet|Not in Omarchy's repo yet|1.0-1|true|false|Missing: makepkg|false" \
  "$(repo_derived 1.0-1 1.2 '' ready 1.0-1 true r-app 'Missing: makepkg')"
same "repo row: a pkgrel the repo has, the feed's version installed: Update, to the repo's full version" \
  'true|true|false|1.2-2|repo|false||||1.2-2|false|false||false' "$(repo_derived 1.2-1 1.2 '' ready 1.2-2)"
same "repo row: the repo ahead of the feed: the repo's version is the newest" 'true|true|false|1.3-1|repo|false||||1.3-1|false|false||false' \
  "$(repo_derived 1.2-1 1.2 '' ready 1.3-1)"
same "repo row: the repo ahead of what is installed, the vendor ahead of the repo: Update to the repo's, and ahead: the vendor's shows" \
  'true|true|false|1.3|feed|false||||1.2-1|true|true||false' "$(repo_derived 1.0-1 1.3 '' ready 1.2-1)"
same "repo row: current in both: no Update, nothing ahead" 'false|false|false|1.2|feed|false||||1.2-1|false|false||false' \
  "$(repo_derived 1.2-1 1.2 '' ready 1.2-1)"
same "repo row: the feed failed, the repo answered: its version, no error, not stale" 'true|true|false|1.2-1|repo|false||||1.2-1|false|false||false' \
  "$(repo_derived 1.0-1 1.1 'could not fetch the feed' ready 1.2-1)"
same "repo row: the feed failed, its last version ahead of the repo: ahead still, stale, no error" \
  "true|false|true|1.3|feed|true||Not in Omarchy's repo yet|Not in Omarchy's repo yet|1.2-1|true|true||false" \
  "$(repo_derived 1.2-1 1.3 'could not fetch the feed' ready 1.2-1)"
same "repo row: the repo unreadable with a newer release: an error, no Update, ahead by the feed" \
  "true|false|false|1.2|feed|false|could not fetch Omarchy's repo database from https://pkgs.example (curl exit 6)||||true|true||false" \
  "$(repo_derived 1.0-1 1.2 '' failed '')"
same "repo row: the repo unreadable, no update: no error, nothing claimed" 'false|false|false|1.2|feed|false|||||false|false||false' \
  "$(repo_derived 1.2-1 1.2 '' failed '')"
same "repo row: both unreadable: both errors, the last known version" \
  "false|false|false|1.0|feed|true|could not fetch Omarchy's repo database from https://pkgs.example (curl exit 6); feed down||||false|false||false" \
  "$(repo_derived 1.2-1 1.0 'feed down' failed '')"
same "repo row: no such repo here: no Update, the note says so, no error, ahead" \
  'true|false|false|1.2|feed|false||No [omarchy] repo in pacman.conf|||true|true||false' "$(repo_derived 1.0-1 1.2 '' none '')"
same "repo row: a repo without the package: no Update, the note says so" \
  "true|false|false|1.2|feed|false||Omarchy's repo has no r-app|||true|true||false" "$(repo_derived 1.0-1 1.2 '' ready '')"
same "repo row: Update off (the route's installable false) and the vendor ahead: no hold, Update is off, not waiting" \
  'true|false|false|1.2|feed|false||||1.0-1|true|true||false' "$(repo_derived 1.0-1 1.2 '' ready 1.0-1 false)"
same "repo row: installed under another name, the repo newer: Update replaces it" \
  'true|true|false|2.0-1|repo|false||||2.0-1|false|false||false' "$(repo_derived 1.0-1 1.2 '' ready 2.0-1 true r-app-bin)"
same "repo row: installed under another name at the repo's version: Switch" \
  'false|false|false|2.0|feed|false||||2.0-1|false|false||true' "$(repo_derived 2.0-1 2.0 '' ready 2.0-1 true r-app-bin)"
same "repo row: installed under another name past the repo's full version: no Switch" \
  'false|false|false|2.0|feed|false||||2.0-1|false|false||false' "$(repo_derived 2.0-2 2.0 '' ready 2.0-1 true r-app-bin)"
same "repo row: Switch needs the route: not with Update off" \
  'false|false|false|2.0|feed|false||||2.0-1|false|false||false' "$(repo_derived 2.0-1 2.0 '' ready 2.0-1 false r-app-bin)"
same "repo row: no feed: the repo's version alone, never ahead" 'true|true|false|1.2-1|repo|false||||1.2-1|false|false||false' \
  "$(repo_derived 1.0-1 '' '' ready 1.2-1)"
same "repo row: no feed, current: the repo's version" 'false|false|false|1.2-1|repo|false||||1.2-1|false|false||false' \
  "$(repo_derived 1.2-1 '' '' ready 1.2-1)"
# vendor_ahead: the vendor's release newer than what is installed and than
# the repo's package (by its upstream part), or the repo has none.
check "vendor_ahead: newer than both" vendor_ahead 1.0-1 1.1-1 1.2
refuse "vendor_ahead: the repo has it" vendor_ahead 1.0-1 1.2-1 1.2
refuse "vendor_ahead: installed already" vendor_ahead 1.2-1 1.0-1 1.2
check "vendor_ahead: the repo has none" vendor_ahead 1.0-1 '' 1.2
refuse "vendor_ahead: no vendor version" vendor_ahead 1.0-1 '' ''
check "vendor_ahead: upstream parts compared, as a feed has no epoch" vendor_ahead 1:1.0-1 1:1.0-1 1.2

# --- status.json: written, read and checked in one place -------------------------------

# status_load takes only a file of this shape, and with "finished" only one
# no check is writing; status_row reads a row of it.
st_file=$scratch/status-unit.json
st_load() {
  local status_file=$st_file
  printf '%s' "$1" >"$status_file"
  if status_load "${2:-}"; then echo "ok $(jq -c .apps <<<"$status_json")"; else echo "no${status_json:+ $status_json}"; fi
}
st_ok='{"schemaVersion": 1, "apps": [{"pkg": "a", "latest": "1"}, {"pkg": "b"}]}'
same "status_load: a file of schemaVersion 1" 'ok [{"pkg":"a","latest":"1"},{"pkg":"b"}]' "$(st_load "$st_ok")"
same "status_load: another schemaVersion is no status.json" no "$(st_load '{"schemaVersion": 2, "apps": []}')"
same "status_load: nor is one without it" no "$(st_load '{"apps": []}')"
same "status_load: nor a row without a pkg string" no "$(st_load '{"schemaVersion": 1, "apps": [{"pkg": 1}]}')"
same "status_load: nor apps that are not a list" no "$(st_load '{"schemaVersion": 1, "apps": {}}')"
same "status_load: nor text that is not JSON, nor an empty file" 'no|no' "$(st_load 'not json')|$(st_load '')"
same "status_load: a running check's file reads" 'ok []' "$(st_load '{"schemaVersion": 1, "checking": true, "apps": []}')"
same "status_load finished: but is no finished check" no "$(st_load '{"schemaVersion": 1, "checking": true, "apps": []}' finished)"
same "status_row: the row of a pkg" '{"pkg":"a","latest":"1"}' "$(status_row a "$st_ok")"
same "status_row: none is {}" '{}' "$(status_row c "$st_ok")"
same "status_row: through a filter" '1|' "$(status_row a "$st_ok" '.latest')|$(status_row b "$st_ok" '.latest // ""')"
# A row's unread, from its field, or for a row from before it (0.1.17)
# from its note.
st_row_state() { jq -r "$jq_status"' "\(row_unread)"' <<<"$1"; }
same "row_unread: the field" "true" "$(st_row_state '{"unread": true, "note": "y"}')"
same "row_unread: a row from before it, by its note" "true" "$(st_row_state '{"unchecked": true, "note": "Not checked yet"}')"
same "row_unread: the field wins over the note" "false" \
  "$(st_row_state "{\"unread\": false, \"unchecked\": true, \"note\": \"Not checked yet\"}")"
st_field() { local status_file=$st_file; printf '%s' "$1" >"$status_file"; status_field "$2" "$3"; }
same "status_field: a string field, a flag as text" '1|true' \
  "$(st_field '{"schemaVersion": 1, "apps": [{"pkg": "a", "latest": "1", "updateAvailable": true}]}' a latest)|$(
    st_field '{"schemaVersion": 1, "apps": [{"pkg": "a", "latest": "1", "updateAvailable": true}]}' a updateAvailable)"
same "status_field: nothing from another schemaVersion, a missing row or a number" '||' \
  "$(st_field '{"schemaVersion": 2, "apps": [{"pkg": "a", "latest": "1"}]}' a latest)|$(
    st_field "$st_ok" c latest)|$(st_field '{"schemaVersion": 1, "apps": [{"pkg": "a", "n": 5}]}' a n)"

# status_write_check: the rows on stdin in row order, and while a check
# runs, the last run's rows it has not read yet, marked checking.
st_write() {
  local status_file=$st_file run_tmp=$scratch
  echo '{"schemaVersion": 1, "inventoryAt": "then", "apps": [{"pkg": "mise:m", "source": "mise"}, {"pkg": "x", "source": "omarchy"}]}' \
    >"$scratch/status-prev.json"
  printf '%s\n' '{"pkg": "self:omabump", "source": "self"}' '{"pkg": "y", "source": "omarchy"}' \
    | status_write_check "$1" at started 1 "" commit "" "" "" "$scratch/status-prev.json" '["x", "y", "mise:m"]'
  jq -c '[.schemaVersion, .checking, .inventoryAt, .retry, .omarchyPkgs.commit, [.apps[] | "\(.pkg)\(if .checking then "*" else "" end)"]]' "$status_file"
}
same "status_write_check: while checking, the last rows not read yet stay, marked" \
  '[1,true,"then",true,"commit",["x*","y","mise:m*","self:omabump"]]' "$(st_write 0)"
same "status_write_check: the final write has the run's rows alone, read now" \
  '[1,false,"started",true,"commit",["y","self:omabump"]]' "$(st_write 1)"
same "status_write_check: and its file reads back as a finished check's" ok \
  "$(st_load "$(cat "$st_file")" finished | cut -d' ' -f1)"
# status_write_local: changed rows put in place, dropped ones gone, a new
# one added in table order, icons from the table, the rest as it was.
st_local() {
  local status_file=$st_file run_tmp=$scratch
  echo '{"schemaVersion": 1, "checkedAt": "c", "inventoryAt": "then", "apps": [{"pkg": "x", "v": 1, "icon": "old"}, {"pkg": "z", "v": 1}]}' \
    >"$scratch/status-prev.json"
  echo '[{"pkg": "x", "icon": "new"}, {"pkg": "w"}, {"pkg": "z"}]' >"$scratch/status-table.json"
  printf '%s\n' '{"pkg": "w", "v": 3}' '{"pkg": "z", "_drop": true}' \
    | status_write_local "$scratch/status-prev.json" "$scratch/status-table.json" now
  jq -c '[.checkedAt, .inventoryAt, .apps]' "$status_file"
}
same "status_write_local: rows changed, dropped and added, icons from the table" \
  '["c","now",[{"pkg":"x","v":1,"icon":"new","iconLight":""},{"pkg":"w","v":3,"icon":"","iconLight":""}]]' "$(st_local)"

# --- Omabump's own row ---------------------------------------------------------------

check "app_id_ok: self:omabump" app_id_ok self:omabump
refuse "app_id_ok: another self: id" app_id_ok self:other
same "apps_table: a self: row from the user's file is dropped" '' \
  "$(printf '[{"pkg": "self:omabump", "source": "indicator"}]' >"$user_apps"; apps_table 2>/dev/null | jq -r '.[] | select(.pkg == "self:omabump") | .pkg')"
rm -f "$user_apps"
same "installed_app: the self row reads manifest.json" "self omabump $(jq -r .version "$root/manifest.json")" "$(installed_app "$self_app")"
echo '302 https://github.com/vladkarok/omabump/releases/tag/v0.2.0' >"$scratch/served/latest"
same "the self row's newest version from the release redirect" 0.2.0 "$(feed_version "$self_app")"
# What the API would answer if it were asked, with 47 of its 60 calls an
# hour left: a 404 or a 302 elsewhere on github.com means no release, and
# the API is not asked.
api_left() { printf '{"resources": {"core": {"limit": 60, "remaining": %s, "used": 0}}}\n200' "$1" >"$scratch/served/api-rate_limit"; }
api_left 47
printf '{"tag_name": "v0.3.0"}\n200' >"$scratch/served/api-latest"
echo '404 ' >"$scratch/served/latest"
refuse "the self row: no release is a feed error" feed_version "$self_app"
same "the self row: no release, and says so; the API is not asked" 'github.com/vladkarok/omabump has no latest release' \
  "$(feed_version "$self_app" 2>&1 >/dev/null)"
echo '302 https://github.com/vladkarok/omabump/releases' >"$scratch/served/latest"
same "the self row: a redirect to the releases page is no release either" 'github.com/vladkarok/omabump has no latest release' \
  "$(feed_version "$self_app" 2>&1 >/dev/null)"
# github.com's pages failing (a 5xx, a rate limit, a move, no answer): the
# API's latest release.
for web in '504 ' '500 ' '403 ' '429 ' ''; do
  if [[ -n $web ]]; then echo "$web" >"$scratch/served/latest"; else rm -f "$scratch/served/latest"; fi
  same "github-release: github.com's answer ${web:-(none)}, the API's tag" 0.3.0 "$(feed_version "$self_app")"
done
# The API's answer is read whatever its status: no -f, and its status after
# the body.
feed_version "$self_app" >/dev/null
same "github-release: the API is asked for its JSON, without -f" \
  "-sS -H Accept: application/vnd.github+json -w \n%{http_code} https://api.github.com/repos/vladkarok/omabump/releases/latest" \
  "$(cat "$scratch/fetched")"
# The fallback leaves the API's last github_api_reserve calls alone, and
# does not call when it cannot tell how many are left.
echo '504 ' >"$scratch/served/latest"
api_left "$github_api_reserve"
same "github-release: with $github_api_reserve calls left, the API is asked" 0.3.0 "$(feed_version "$self_app")"
api_left $(( github_api_reserve - 1 ))
same "github-release: with fewer, it is not, and the error says why" \
  "github.com answered 504 for vladkarok/omabump's latest release; api.github.com has $(( github_api_reserve - 1 )) of its 60 calls an hour left here, which Omabump leaves to you|https://api.github.com/rate_limit" \
  "$(feed_version "$self_app" 2>&1 >/dev/null)|$(awk '{print $NF}' "$scratch/fetched")"
for doc in '{"resources": {"core": {"limit": 60}}}\n200' '{"resources": {"core": {"limit": 60, "remaining": "47"}}}\n200' \
  '{"resources": {"core": {"limit": 60, "remaining": -1}}}\n200' '{"resources": null}\n200' '[]\n200' 'not json\n200' \
  '{"resources": {"core": {"limit": 60, "remaining": 47}}}\n403' ''; do
  if [[ -n $doc ]]; then printf %b "$doc" >"$scratch/served/api-rate_limit"; else rm -f "$scratch/served/api-rate_limit"; fi
  same "github-release: no count from /rate_limit's $(jq -Rsc . <<<"$doc"), the API is not asked" \
    "github.com answered 504 for vladkarok/omabump's latest release, and api.github.com did not say how many calls it has left, so Omabump did not ask it|https://api.github.com/rate_limit" \
    "$(feed_version "$self_app" 2>&1 >/dev/null)|$(awk '{print $NF}' "$scratch/fetched")"
done
api_left 47
# Any other answer from github.com is an error that names it, without the
# API: a repo that moved, a page that no longer redirects.
for web in '301 https://github.com/other/omabump/releases/latest' '200 ' '400 '; do
  echo "$web" >"$scratch/served/latest"
  same "github-release: github.com's answer ${web%% *} is an error, the API not asked" \
    "github.com answered ${web%% *} for vladkarok/omabump's latest release" "$(feed_version "$self_app" 2>&1 >/dev/null)"
done
echo '504 ' >"$scratch/served/latest"
printf '{"message": "API rate limit exceeded"}\n403' >"$scratch/served/api-latest"
same "github-release: both failing, the error names both answers" \
  "github.com answered 504 and api.github.com answered 403 for vladkarok/omabump's latest release" \
  "$(feed_version "$self_app" 2>&1 >/dev/null)"
printf '{"message": "Not Found"}\n404' >"$scratch/served/api-latest"
same "github-release: the API's 404 is no release" 'github.com/vladkarok/omabump has no latest release' \
  "$(feed_version "$self_app" 2>&1 >/dev/null)"
for doc in '{"name": "v0.3.0"}' '{"tag_name": 3}' '["v0.3.0"]' 'not json' ''; do
  printf '%s\n200' "$doc" >"$scratch/served/api-latest"
  same "github-release: no tag from the API's $(jq -Rsc . <<<"$doc")" \
    "github.com answered 504 and api.github.com named no tag for vladkarok/omabump's latest release" \
    "$(feed_version "$self_app" 2>&1 >/dev/null)"
done
printf '{"tag_name": "v0.3.0\\nv0.4.0"}\n200' >"$scratch/served/api-latest"
same "github-release: a tag on two lines is no version" "feed returned an odd version '0.3.0 v0.4.0'" \
  "$(feed_version "$self_app" 2>&1 >/dev/null)"
rm -f "$scratch/served/api-latest"
same "github-release: no answer from the API either" \
  "github.com answered 504 and api.github.com could not be reached (curl exit 22) for vladkarok/omabump's latest release" \
  "$(feed_version "$self_app" 2>&1 >/dev/null)"
# One check reads /rate_limit once (github_api_left keeps the answer in the
# run's scratch directory, whose feeds run in subshells) and counts each
# fallback against it.
run_tmp=$scratch/feed-run
mkdir -p "$run_tmp"
echo '504 ' >"$scratch/served/latest"
api_left 47
printf '{"tag_name": "v0.3.0"}\n200' >"$scratch/served/api-latest"
: >"$scratch/fetch.log"
same "github-release: one check reads /rate_limit once and counts each fallback" '0.3.0|0.3.0|1|45 60' \
  "$(feed_version "$self_app")|$(feed_version "$self_app")|$(grep -c 'rate_limit$' "$scratch/fetch.log")|$(cat "$run_tmp/github-api-left")"
api_left 20
rm -f "$run_tmp/github-api-left"
same "github-release: with 20 left, one fallback, then the reserve" \
  "0.3.0|github.com answered 504 for vladkarok/omabump's latest release; api.github.com has 19 of its 60 calls an hour left here, which Omabump leaves to you" \
  "$(feed_version "$self_app")|$(feed_version "$self_app" 2>&1 >/dev/null)"
rm -f "$run_tmp/github-api-left" "$scratch/served/api-rate_limit"
: >"$scratch/fetch.log"
same "github-release: no answer from /rate_limit is kept too: asked once" 1 \
  "$(feed_version "$self_app" 2>/dev/null; feed_version "$self_app" 2>/dev/null; grep -c 'rate_limit$' "$scratch/fetch.log")"
rm -rf "$run_tmp"
run_tmp=""
rm -f "$scratch/served/latest" "$scratch/served/api-rate_limit" "$scratch/fetch.log"
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
# The rollback's git clean -fd would delete an untracked file, so one counts
# even where status.showUntrackedFiles hides it.
tgit -C "$plugin_dir" config status.showUntrackedFiles no
echo mine >"$plugin_dir/mine"
same "self_plan: an untracked file refuses, though git status hides it" 'local changes' "$(self_plan 0.2.0 2>&1 | grep -o 'local changes')"
rm "$plugin_dir/mine"
tgit -C "$plugin_dir" config --unset status.showUntrackedFiles
refuse "self_plan: a tag that does not exist" self_plan 0.9.0
tgit -C "$plugin_dir" reset -q --hard main
tgit -C "$plugin_dir" merge -q --ff-only origin/main
same "self_plan: a tag behind the installed commit is not a fast-forward" 'not a fast-forward' "$(self_plan 0.2.0 2>&1 | grep -o 'not a fast-forward')"
refuse "self_plan: an odd version never reaches git" self_plan '0.2.0:refs/heads/x'
# shellcheck disable=SC2329 # called from omabump-common
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

# --- the shipped apps.json and pins.json --------------------------------------

check "apps.json is a JSON array" jq -e 'type == "array"' "$root/apps.json"
same "apps.json has no command feeds" 0 "$(jq '[.[] | select(.feed.type == "command")] | length' "$root/apps.json")"
same "apps.json sets no _userFeed" 0 "$(jq '[.[] | select(has("_userFeed"))] | length' "$root/apps.json")"
same "every pkg in apps.json is unique" '[]' "$(jq -c 'map(.pkg) | group_by(.) | map(select(length > 1) | .[0])' "$root/apps.json")"
vendor_ok=1
while IFS= read -r app; do vendor_checksum_declared "$app" || vendor_ok=0; done < <(jq -c '.[] | select(.source == "vendor-pkg")' "$root/apps.json")
check "every vendor-pkg in apps.json names a checksum source" test "$vendor_ok" = 1
same "every app in apps.json names an icon" '[]' "$(jq -c '[.[] | select((.icon // "") == "") | .pkg]' "$root/apps.json")"
icons_missing=()
while IFS= read -r icon_path; do
  [[ $icon_path == assets/*.svg && $icon_path != *..* && -f $root/$icon_path && ! -L $root/$icon_path ]] || icons_missing+=("$icon_path")
done < <(jq -r '.[] | (.icon // empty), (.iconLight // empty)' "$root/apps.json" | sort -u)
same "every icon in apps.json is a regular SVG under assets/" "" "${icons_missing[*]}"
check "pins.json pins a 40-hex commit" jq -e '.omarchyPkgs.commit | test("^[0-9a-f]{40}$")' "$root/pins.json"
# Since Omarchy's migration 1795441383 each agent is a package of the
# [omarchy] repo (omarchy-install-ai-cli names them), Pi among them: each
# has its entry, in the CLI section, on a route that reads pacman.
for p in claude-code openai-codex grok-cli opencode github-copilot-cli crush-bin cursor-cli antigravity-cli muse-code \
  oh-my-pi openrouter-ori kimi-code qwen-code deepseek-dsh minimax-code freebuff kilocode-cli devin-cli amp-cli \
  pi-coding-agent; do
  # $p inside the single quotes is jq's variable, not the shell's.
  # shellcheck disable=SC2016
  check "apps.json tracks Omarchy's agent package $p in the CLI section, on the repo route" jq -e --arg p "$p" \
    'any(.[]; .pkg == $p and .section == "cli" and .source == "repo")' "$root/apps.json"
done
same "apps.json names a section only for the CLI packages" '[]' \
  "$(jq -c '[.[] | select(has("section") and (.section != "cli" or .source == "mise")) | .pkg]' "$root/apps.json")"
# Update installs each of them from Omarchy's repo, signed, never from a
# local build: the CLI packages and the desktop apps Omarchy packages are
# all on the repo route. Build now may build only the recipes listed here:
# not opencode (one recipe builds two packages), minimax-code and
# deepseek-dsh (npm install over the network in package()), kilocode-cli
# (its version from git ls-remote), cursor-cli and muse-code (composed
# versions). Those last three, and deepseek-dsh, have no feed: they read
# omarchy-pkgs' master, which says nothing the repo does not.
same "every CLI package of apps.json is on the repo route, with the 8 desktop apps Omarchy packages" '20|28' \
  "$(jq -r '"\([.[] | select(.section == "cli" and .source == "repo")] | length)|\([.[] | select(.source == "repo")] | length)"' "$root/apps.json")"
same "apps.json: the entries Build now may build" \
  'amp-cli antigravity-cli claude-code claude-desktop crush-bin devin-cli freebuff github-copilot-cli grok-bot grok-cli hermes-desktop kimi-code lmstudio-bin oh-my-pi openai-codex openai-codex-desktop openclaw openrouter-ori perplexity pi-coding-agent qwen-code t3code-bin' \
  "$(jq -r '[.[] | select(.build == true) | .pkg] | sort | join(" ")' "$root/apps.json")"
same "apps.json: no entry still on the omarchy route, no build on another route" '[]' \
  "$(jq -c '[.[] | select(.source == "omarchy" or (.build == true and .source != "repo")) | .pkg]' "$root/apps.json")"
same "apps.json: the feeds read from omarchy-pkgs' master are gone" '[]' \
  "$(jq -c '[.[] | select(.pkg | IN("cursor-cli", "muse-code", "deepseek-dsh")) | select(has("feed")) | .pkg]' "$root/apps.json")"
same "apps.json: no feed reads omarchy-pkgs" '[]' \
  "$(jq -c '[.[] | select((.feed.url // "" | tostring) | test("omarchy-pkgs")) | .pkg]' "$root/apps.json")"
# Before it, Omarchy named each agent's mise tool in /etc/mise/conf.d/omarchy-tools.toml;
# the key mise ls reports is that name, so the table must carry it.
for t in claude codex crush opencode grok copilot cursor-agent pi amp antigravity-cli qwen muse \
  github:can1357/oh-my-pi npm:@kilocode/cli http:kiro-cli http:devin npm:@deepseek-ai/dsh npm:@minimax-ai/code \
  npm:command-code npm:freebuff npm:@moonshot-ai/kimi-code; do
  # $t inside the single quotes is jq's variable, not the shell's.
  # shellcheck disable=SC2016
  check "apps.json tracks Omarchy's mise tool $t" jq -e --arg t "$t" 'any(.[]; .source == "mise" and ([.tool] | flatten | index($t)))' "$root/apps.json"
done
mise_ls_json='{"grok":[{"version":"1.0.46","installed":true,"active":true}]}'
same "the Grok CLI row finds mise's first-party grok" "grok 1.0.46" "$(mise_active "$(app_json mise:grok-cli)")"
mise_ls_json='{}'
finish

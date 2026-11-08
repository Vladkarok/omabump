# shellcheck shell=bash disable=SC2154,SC2016 # root, scratch and the helpers come from tests/run.sh; single quotes hold the fixture's own code and the report's Markdown
# Sourced by tests/run.sh: .github/scripts/pin-watch against a small omarchy-pkgs of
# its own, built here, so nothing reaches the network.

# --- .github/scripts/pin-watch -----------------------------------------------------

pw=$scratch/pin-watch
mkdir -p "$pw/plugin"
pw_git() { git -C "$pw/up" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" >/dev/null; }
# A commit dated $1 days ago, with the files written before it.
pw_commit() {
  local days=$1 msg=$2 when
  when=$(date -d "$days days ago" -Iseconds)
  pw_git add -A
  GIT_AUTHOR_DATE=$when GIT_COMMITTER_DATE=$when pw_git commit -q -m "$msg"
}
git init -q -b master "$pw/up"
# As GitHub does: a blob-less clone, and a fetch of a commit by its id.
git -C "$pw/up" config uploadpack.allowFilter true
git -C "$pw/up" config uploadpack.allowAnySHA1InWant true
mkdir -p "$pw/up/bin" "$pw/up/helpers" "$pw/up/pkgbuilds/app/.omarchy" "$pw/up/pkgbuilds/pinned/.omarchy" "$pw/up/pkgbuilds/other" \
  "$pw/up/pkgbuilds/hooked/.omarchy"
# sync-upstream sources a.sh, which runs watch.py, which imports util.py;
# a comment names ci.sh, which only omarchy-pkgs' own tooling runs, as does
# bin/auto-release. The hooked app's hook writes its _commit and runs hook.sh.
cat >"$pw/up/bin/sync-upstream" <<'EOF'
#!/bin/bash
BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$BUILD_ROOT/helpers/a.sh"
# helpers/ci.sh publishes what bin/auto-release tags.
echo sync
EOF
printf 'echo release\n' >"$pw/up/bin/auto-release"
printf 'helper() { python3 "${BASH_SOURCE[0]%%/*}/watch.py"; }\n' >"$pw/up/helpers/a.sh"
printf 'import util\n' >"$pw/up/helpers/watch.py"
printf 'X = 1\n' >"$pw/up/helpers/util.py"
printf 'publish() { :; }\n' >"$pw/up/helpers/ci.sh"
printf 'hookhelp() { :; }\n' >"$pw/up/helpers/hook.sh"
printf 'source "$BUILD_ROOT/helpers/hook.sh"\nsed -i "s/^_commit=.*/_commit=$c/" PKGBUILD\n' >"$pw/up/pkgbuilds/hooked/.omarchy/upstream.sh"
printf 'pkgname=hooked\npkgver=1\n_commit=aaaa\nsource=("https://example.invalid/$_commit/x.deb")\n' >"$pw/up/pkgbuilds/hooked/PKGBUILD"
cat >"$pw/up/pkgbuilds/app/PKGBUILD" <<'EOF'
pkgname=app
pkgver=1.0
pkgrel=1
depends=('glibc')
sha256sums=('aaaa'
            'bbbb')
sha256sums_x86_64=('cccc')
EOF
printf '{"upstream": {"github": "o/app"}}\n' >"$pw/up/pkgbuilds/app/.omarchy/package.json"
printf 'pkgname=pinned\npkgver=1\n' >"$pw/up/pkgbuilds/pinned/PKGBUILD"
printf '{"sync": false}\n' >"$pw/up/pkgbuilds/pinned/.omarchy/package.json"
printf 'pkgname=other\n' >"$pw/up/pkgbuilds/other/PKGBUILD"
pw_commit 10 base
pw_pin=$(git -C "$pw/up" rev-parse HEAD)
printf '{"omarchyPkgs": {"commit": "%s", "ref": "refs/heads/master"}}\n' "$pw_pin" >"$pw/plugin/pins.json"
cat >"$pw/plugin/apps.json" <<'EOF'
[
  {"pkg": "app", "source": "omarchy"},
  {"pkg": "pinned", "source": "omarchy", "recipeCommit": "0000000000000000000000000000000000000000"},
  {"pkg": "hooked", "source": "omarchy"},
  {"pkg": "mise:x", "source": "mise", "tool": "x"}
]
EOF
# A copy of the script, its hook_writes naming the hooked app's _commit.
pw_run() { pw_out=$(cd "$pw" && timeout 60 "$pw/pin-watch" --repo "file://$pw/up" --plugin-dir "$pw/plugin" 2>&1); pw_rc=$?; }
pw_hook_writes() { sed -i "s/^hook_writes=.*/hook_writes=($1)/" "$pw/pin-watch"; }
cp "$root/.github/scripts/pin-watch" "$pw/pin-watch"
pw_hook_writes '"hooked _commit"'
check "pin-watch: the test's copy has its own hook_writes" grep -qx 'hook_writes=("hooked _commit")' "$pw/pin-watch"

pw_run
same "pin-watch: master at the pin is no news" '0|' "$pw_rc|$pw_out"

# A routine sync, as omarchy-pkgs' bot makes it (the hooked recipe's
# _commit too), plus changes to code and a recipe Update never runs.
sed -i 's/^pkgver=1.0/pkgver=1.1/; s/aaaa/dddd/; s/bbbb/eeee/; s/cccc/ffff/' "$pw/up/pkgbuilds/app/PKGBUILD"
sed -i 's/^pkgver=1$/pkgver=2/; s/^_commit=aaaa/_commit=bbbb/' "$pw/up/pkgbuilds/hooked/PKGBUILD"
printf 'echo release v2\n' >"$pw/up/bin/auto-release"
printf 'publish() { echo v2; }\n' >"$pw/up/helpers/ci.sh"
printf 'pkgname=other\ndepends=(x)\n' >"$pw/up/pkgbuilds/other/PKGBUILD"
pw_commit 8 "chore: sync upstream releases"
pw_run
same "pin-watch: a routine sync, a hook's own rewrite and code nothing Update runs names are no news" '0|' "$pw_rc|$pw_out"

sed -i "s/^depends=('glibc')/depends=('glibc' 'gtk3')/" "$pw/up/pkgbuilds/app/PKGBUILD"
pw_commit 6 "app: needs gtk3"
pw_run
same "pin-watch: a recipe change beyond the sync is news" 3 "$pw_rc"
check "pin-watch: the report names the recipe and shows the change" grep -q "^+depends=('glibc' 'gtk3')" <<<"$pw_out"
refuse "pin-watch: the report leaves out the routine lines" grep -q '^+pkgver=1.1' <<<"$pw_out"
refuse "pin-watch: and the code Update never runs" grep -q 'auto-release' <<<"$pw_out"
check "pin-watch: and names what a hook rewrites" grep -qF 'what the recipe'"'"'s own hook rewrites (`_commit` of hooked)' <<<"$pw_out"
check "pin-watch: and the helpers left out" grep -qF "that nothing Update runs names, omarchy-pkgs' own build and publish tooling: \`helpers/ci.sh\`." <<<"$pw_out"
refuse "pin-watch: without their diff" grep -q '^+publish' <<<"$pw_out"
check "pin-watch: the report suggests a commit at least 3 days old" grep -q "\"commit\": \"$(git -C "$pw/up" rev-parse HEAD)\"" <<<"$pw_out"

# The hooked recipe beyond its hook's rewrite: news, shown without the line
# the hook writes. A hook_writes entry the pinned hook does not write (it
# names no "_build=") changes nothing.
sed -i 's/^_commit=bbbb/_commit=cccc/; s|/x.deb|/y.deb|' "$pw/up/pkgbuilds/hooked/PKGBUILD"
pw_commit 5 "hooked: another file"
pw_hook_writes '"hooked _commit _build"'
pw_run
same "pin-watch: a hooked recipe changed beyond its hook's rewrite is news" 3 "$pw_rc"
check "pin-watch: the change is shown" grep -q '^+source=("https://example.invalid/$_commit/y.deb")' <<<"$pw_out"
refuse "pin-watch: the line the hook writes is not" grep -q '^[-+]_commit=' <<<"$pw_out"
# Without the entry the hook's rewrite is news, line and all.
pw_hook_writes ''
pw_run
check "pin-watch: without a hook_writes entry the line shows" grep -q '^+_commit=cccc' <<<"$pw_out"
refuse "pin-watch: and no hook is named as rewriting it" grep -qF 'own hook rewrites' <<<"$pw_out"
pw_hook_writes '"hooked _commit"'

# Code Update runs: what sync-upstream names, through the files named (a.sh,
# then watch.py, then the util.py it imports), and what a hook names.
pw_code() {  # <file> <text>: news, and the file's diff in the report
  printf '%s\n' "$2" >"$pw/up/$1"
  pw_commit 4 "change $1"
  pw_run
  same "pin-watch: a change to $1 is news" 3 "$pw_rc"
  check "pin-watch: a change to $1 is shown under Code Update runs" \
    grep -qF "diff --git a/$1 b/$1" <<<"$(sed -n '/^### Code Update runs/,/^### /p' <<<"$pw_out")"
  refuse "pin-watch: $1 is not among the helpers left out" grep -qF "that nothing Update runs names" <<<"$pw_out"
}
printf '{"omarchyPkgs": {"commit": "%s", "ref": "refs/heads/master"}}\n' "$(git -C "$pw/up" rev-parse HEAD)" >"$pw/plugin/pins.json"
pw_code helpers/util.py 'X = 2'
printf '{"omarchyPkgs": {"commit": "%s", "ref": "refs/heads/master"}}\n' "$(git -C "$pw/up" rev-parse HEAD)" >"$pw/plugin/pins.json"
pw_code helpers/hook.sh 'hookhelp() { echo 2; }'
printf '{"omarchyPkgs": {"commit": "%s", "ref": "refs/heads/master"}}\n' "$(git -C "$pw/up" rev-parse HEAD)" >"$pw/plugin/pins.json"
# A helper master's sync-upstream starts to source is news, though the
# pinned one names nothing of it.
printf 'newhelp() { :; }\n' >"$pw/up/helpers/new.sh"
printf 'source "$BUILD_ROOT/helpers/new.sh"\n' >>"$pw/up/bin/sync-upstream"
pw_commit 4 "sync-upstream: new helper"
pw_run
check "pin-watch: a helper master's sync-upstream starts to source is shown" grep -qF 'diff --git a/helpers/new.sh b/helpers/new.sh' <<<"$pw_out"
same "pin-watch: a helper master's sync-upstream starts to source is news" 3 "$pw_rc"
pw_pin=$(git -C "$pw/up" rev-parse HEAD)
printf '{"omarchyPkgs": {"commit": "%s", "ref": "refs/heads/master"}}\n' "$pw_pin" >"$pw/plugin/pins.json"

pw_bump() { pw_pin=$(git -C "$pw/up" rev-parse HEAD); printf '{"omarchyPkgs": {"commit": "%s", "ref": "refs/heads/master"}}\n' "$pw_pin" >"$pw/plugin/pins.json"; }

# A bin/ file sync-upstream runs is Update code; one only a comment names,
# however it names it, is not.
mkdir -p "$pw/up/bin"
printf 'echo lib\n' >"$pw/up/bin/sync-lib"
printf 'echo notes\n' >"$pw/up/bin/notes"
printf '"$BUILD_ROOT/bin/sync-lib"\n# "$BUILD_ROOT/bin/notes" writes the notes\n' >>"$pw/up/bin/sync-upstream"
pw_commit 4 "sync-upstream runs bin/sync-lib"
pw_bump
pw_code bin/sync-lib 'echo lib v2'
pw_bump
printf 'echo notes v2\n' >"$pw/up/bin/notes"
pw_commit 4 "notes v2"
pw_run
same "pin-watch: a bin/ file only a comment names is no news" '0|' "$pw_rc|$pw_out"
pw_bump

# A Python package helpers/ holds, imported by a helper Update runs: all of
# its files count.
mkdir -p "$pw/up/helpers/providers"
printf '' >"$pw/up/helpers/providers/__init__.py"
printf 'URL = 1\n' >"$pw/up/helpers/providers/github.py"
printf 'import util\nfrom providers import github\n' >"$pw/up/helpers/watch.py"
pw_commit 4 "watch.py: providers package"
pw_bump
pw_code helpers/providers/github.py 'URL = 2'
pw_bump

# A helper name computed in code makes every file in helpers/ count, and the
# report says which file computes one.
printf 'helper() { python3 "${BASH_SOURCE[0]%%/*}/watch.py"; for p in x; do source "${BASH_SOURCE[0]%%/*}/prov-$p.sh"; done; }\n' >"$pw/up/helpers/a.sh"
pw_commit 4 "a.sh: providers by name"
pw_bump
printf 'publish() { echo v3; }\n' >"$pw/up/helpers/ci.sh"
pw_commit 4 "ci.sh v3"
pw_run
same "pin-watch: with a computed helper name, a change to any helper is news" 3 "$pw_rc"
check "pin-watch: the report names the file that computes one" grep -qF 'Every file in `helpers/` counts, as `helpers/a.sh` finds files by a name computed in code.' <<<"$pw_out"
printf 'helper() { python3 "${BASH_SOURCE[0]%%/*}/watch.py"; }\n' >"$pw/up/helpers/a.sh"
pw_commit 4 "a.sh: back to named helpers"
pw_bump

# hook_names counts a name only while the pinned hook assigns it in code:
# a hook that reads _commit (current_commit=, a comment) no longer writes
# it, so its changes are news again; master's hook writing it does not count.
printf 'source "$BUILD_ROOT/helpers/hook.sh"\ncurrent_commit=$(grep _commit PKGBUILD)\n# sed rewrote _commit= here\n' >"$pw/up/pkgbuilds/hooked/.omarchy/upstream.sh"
pw_commit 4 "hooked: the hook only reads _commit"
pw_bump
printf 'source "$BUILD_ROOT/helpers/hook.sh"\nsed -i "s/^_commit=.*/_commit=$c/" PKGBUILD\n' >"$pw/up/pkgbuilds/hooked/.omarchy/upstream.sh"
sed -i 's/^_commit=cccc/_commit=dddd/' "$pw/up/pkgbuilds/hooked/PKGBUILD"
pw_commit 4 "hooked: _commit by hand, and a hook that writes it again"
pw_run
same "pin-watch: a _commit change the pinned hook does not write is news" 3 "$pw_rc"
check "pin-watch: and is shown" grep -q '^+_commit=dddd' <<<"$pw_out"
refuse "pin-watch: and no hook is named as rewriting it" grep -qF 'own hook rewrites' <<<"$pw_out"
pw_bump
sed -i 's/^_commit=dddd/_commit=eeee/' "$pw/up/pkgbuilds/hooked/PKGBUILD"
pw_commit 4 "hooked: a routine _commit"
pw_run
same "pin-watch: once the pinned hook writes _commit again, its change is no news" '0|' "$pw_rc|$pw_out"
pw_bump

# A blob the blob-less clone cannot fetch is an error, never a file that is
# not there (a change that would then go unseen, and the issue closed).
printf 'helper() { python3 "${BASH_SOURCE[0]%%/*}/watch.py"; echo unreadable; }\n' >"$pw/up/helpers/a.sh"
pw_commit 4 "a.sh: unreadable"
GIT_NO_LAZY_FETCH=1 pw_run
same "pin-watch: a blob it cannot fetch is an error" 1 "$pw_rc"
check "pin-watch: and says which" grep -q '^pin-watch: cannot read ' <<<"$pw_out"
pw_bump

printf 'helper() { python3 "${BASH_SOURCE[0]%%/*}/watch.py"; echo changed; }\n' >"$pw/up/helpers/a.sh"
printf '{"upstream": {"github": "o/pinned"}}\n' >"$pw/up/pkgbuilds/pinned/.omarchy/package.json"
pw_commit 1 "helpers and a watch for pinned"
pw_run
check "pin-watch: a change to a helper sync-upstream sources is news" grep -q '^### Code Update runs' <<<"$pw_out"
check "pin-watch: the report lists what Update runs" grep -qF 'name there or on master: `bin/sync-lib`, `helpers/a.sh`, `helpers/hook.sh`, `helpers/new.sh`, `helpers/providers/__init__.py`, `helpers/providers/github.py`, `helpers/util.py`, `helpers/watch.py`.' <<<"$pw_out"
check "pin-watch: a recipeCommit app whose recipe now has a watch is named" grep -q '`pinned`: the recipe on master now has an upstream watch' <<<"$pw_out"
refuse "pin-watch: the suggestion skips a commit younger than 3 days" grep -q "\"commit\": \"$(git -C "$pw/up" rev-parse HEAD)\"" <<<"$pw_out"

printf '{"omarchyPkgs": {"commit": "%s", "ref": "refs/heads/master"}}\n' "$(git -C "$pw/up" rev-parse HEAD)" >"$pw/plugin/pins.json"
pw_run
same "pin-watch: after a bump to master, no news" '0|' "$pw_rc|$pw_out"
printf '{"omarchyPkgs": {"commit": "%s"}}\n' "$(printf '1%.0s' {1..40})" >"$pw/plugin/pins.json"
pw_run
same "pin-watch: a pin that is not on master is an error" 1 "$pw_rc"

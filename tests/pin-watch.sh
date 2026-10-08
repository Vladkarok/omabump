# shellcheck shell=bash disable=SC2154 # root, scratch and the helpers come from tests/run.sh
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
mkdir -p "$pw/up/bin" "$pw/up/helpers" "$pw/up/pkgbuilds/app/.omarchy" "$pw/up/pkgbuilds/pinned/.omarchy" "$pw/up/pkgbuilds/other"
printf '#!/bin/bash\necho sync\n' >"$pw/up/bin/sync-upstream"
printf 'echo release\n' >"$pw/up/bin/auto-release"
printf 'helper() { :; }\n' >"$pw/up/helpers/a.sh"
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
  {"pkg": "mise:x", "source": "mise", "tool": "x"}
]
EOF
pw_run() { pw_out=$(cd "$pw" && timeout 60 "$root/.github/scripts/pin-watch" --repo "file://$pw/up" --plugin-dir "$pw/plugin" 2>&1); pw_rc=$?; }

pw_run
same "pin-watch: master at the pin is no news" '0|' "$pw_rc|$pw_out"

# A routine sync, as omarchy-pkgs' bot makes it, plus changes to code and a
# recipe Update never runs.
sed -i 's/^pkgver=1.0/pkgver=1.1/; s/aaaa/dddd/; s/bbbb/eeee/; s/cccc/ffff/' "$pw/up/pkgbuilds/app/PKGBUILD"
printf 'echo release v2\n' >"$pw/up/bin/auto-release"
printf 'pkgname=other\ndepends=(x)\n' >"$pw/up/pkgbuilds/other/PKGBUILD"
pw_commit 8 "chore: sync upstream releases"
pw_run
same "pin-watch: a routine sync and unrelated changes are no news" '0|' "$pw_rc|$pw_out"

sed -i "s/^depends=('glibc')/depends=('glibc' 'gtk3')/" "$pw/up/pkgbuilds/app/PKGBUILD"
pw_commit 6 "app: needs gtk3"
pw_run
same "pin-watch: a recipe change beyond the sync is news" 3 "$pw_rc"
check "pin-watch: the report names the recipe and shows the change" grep -q "^+depends=('glibc' 'gtk3')" <<<"$pw_out"
refuse "pin-watch: the report leaves out the routine lines" grep -q '^+pkgver=1.1' <<<"$pw_out"
refuse "pin-watch: and the code Update never runs" grep -q 'auto-release' <<<"$pw_out"
check "pin-watch: the report suggests a commit at least 3 days old" grep -q "\"commit\": \"$(git -C "$pw/up" rev-parse HEAD)\"" <<<"$pw_out"

printf 'helper() { echo changed; }\n' >"$pw/up/helpers/a.sh"
printf '{"upstream": {"github": "o/pinned"}}\n' >"$pw/up/pkgbuilds/pinned/.omarchy/package.json"
pw_commit 1 "helpers and a watch for pinned"
pw_run
check "pin-watch: a change to helpers/ is news" grep -q '^### Code Update runs' <<<"$pw_out"
# shellcheck disable=SC2016 # backticks of the Markdown, not a command
check "pin-watch: a recipeCommit app whose recipe now has a watch is named" grep -q '`pinned`: the recipe on master now has an upstream watch' <<<"$pw_out"
refuse "pin-watch: the suggestion skips a commit younger than 3 days" grep -q "\"commit\": \"$(git -C "$pw/up" rev-parse HEAD)\"" <<<"$pw_out"

printf '{"omarchyPkgs": {"commit": "%s", "ref": "refs/heads/master"}}\n' "$(git -C "$pw/up" rev-parse HEAD)" >"$pw/plugin/pins.json"
pw_run
same "pin-watch: after a bump to master, no news" '0|' "$pw_rc|$pw_out"
printf '{"omarchyPkgs": {"commit": "%s"}}\n' "$(printf '1%.0s' {1..40})" >"$pw/plugin/pins.json"
pw_run
same "pin-watch: a pin that is not on master is an error" 1 "$pw_rc"

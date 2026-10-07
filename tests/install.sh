# shellcheck shell=bash
# bin/omabump-install against stub commands, sourced by tests/run.sh (its
# helpers, $root and $scratch). The installer runs as a child process from a
# copy of the plugin whose bin/omabump-check is a stub, with these first on
# PATH:
#   pacman    -Q and -Qi from a fixture database, -Qp and -Qip from the
#             package's .PKGINFO, -U as $STUB_PACMAN_U says (ok, no, hookfail)
#   sudo      records its arguments and runs only the installer's three
#             commands, as you, on files in the test staging directory;
#             anything else fails loudly
#   curl      serves files from a local directory
#   makepkg   reads the test recipe's PKGBUILD and "builds" a plain tar
#   omarchy-plugin-validate, omarchy-shell, omarchy   record, and change nothing
# The omarchy route reads a local omarchy-pkgs clone at the commit the test
# pins.json names, so nothing reaches the network or needs root.

: "${root:?}" "${scratch:?}"
it=$scratch/install
ihome=$it/home
iplugin=$ihome/.config/omarchy/plugins/io.github.vladkarok.omabump
istubs=$it/stubs idb=$it/db ilog=$it/log iserved=$it/served istaging=$it/staging
mkdir -p "$iplugin/bin" "$istubs" "$idb/qi" "$ilog" "$iserved" "$ihome/.config/omarchy/omabump"
for f in bin/omabump-install bin/omabump-common bin/omabump-discover apps.json pins.json manifest.json; do
  cp "$root/$f" "$iplugin/$f"
done
cat >"$iplugin/bin/omabump-check" <<'EOF'
#!/bin/bash
echo "omabump-check $*" >>"$STUB_LOG/calls"
EOF
chmod +x "$iplugin/bin/omabump-check"

cat >"$istubs/pacman" <<'EOF'
#!/bin/bash
echo "pacman $*" >>"$STUB_LOG/calls"
last=${*: -1}
pkginfo() { bsdtar -xOf "$1" .PKGINFO 2>/dev/null; }
field() { sed -n "s/^$1 = //p" <<<"$2"; }
case $1 in
  -Q) awk -v n="$last" '$1 == n { print; found = 1; exit } END { exit !found }' "$STUB_DB/installed" ;;
  -Qi) cat "$STUB_DB/qi/$last" 2>/dev/null ;;
  -Qp) info=$(pkginfo "$last") || exit 1
    echo "$(field pkgname "$info") $(field pkgver "$info")" ;;
  -Qip) info=$(pkginfo "$last") || exit 1
    p=$(field provides "$info" | paste -sd' ') c=$(field conflict "$info" | paste -sd' ')
    printf 'Name            : %s\nProvides        : %s\nConflicts With  : %s\n' "$(field pkgname "$info")" "${p:-None}" "${c:-None}" ;;
  -U) info=$(pkginfo "$last") || exit 1
    case ${STUB_PACMAN_U:-no} in
      ok|hookfail)
        name=$(field pkgname "$info")
        { echo "$name"; field conflict "$info"; } >"$STUB_DB/drop"
        awk 'NR == FNR { d[$1]; next } !($1 in d)' "$STUB_DB/drop" "$STUB_DB/installed" >"$STUB_DB/installed.new"
        echo "$name $(field pkgver "$info")" >>"$STUB_DB/installed.new"
        mv "$STUB_DB/installed.new" "$STUB_DB/installed"
        [[ $STUB_PACMAN_U == ok ]] || { echo "error: command failed to execute correctly" >&2; exit 1; } ;;
      *) echo ":: Proceed with installation? [Y/n] n"; exit 1 ;;
    esac ;;
  *) echo "pacman stub: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat >"$istubs/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >>"$STUB_LOG/calls"
dest=${*: -1}
[[ $dest == "$STUB_STAGING"/* && $dest != *..* ]] || { echo "sudo stub: refusing $*" >&2; exit 97; }
case "$*" in
  "install -o root -g root -m 0644 -D /dev/stdin $dest")
    mkdir -p "${dest%/*}" && cat >"$dest" || exit 1
    [[ -z ${STUB_TAMPER:-} ]] || printf 'x' >>"$dest" ;;
  "pacman -U -- $dest") exec pacman -U -- "$dest" ;;
  "rm -f -- $dest") exec rm -f -- "$dest" ;;
  *) echo "sudo stub: refusing $*" >&2; exit 97 ;;
esac
EOF
cat >"$istubs/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >>"$STUB_LOG/calls"
url=${*: -1} out=""
while (( $# )); do
  [[ $1 == -o ]] && { out=$2; shift; }
  shift
done
[[ -f $STUB_SERVED/${url##*/} ]] || exit 22
if [[ -n $out ]]; then cp "$STUB_SERVED/${url##*/}" "$out"; else cat "$STUB_SERVED/${url##*/}"; fi
EOF
cat >"$istubs/makepkg" <<'EOF'
#!/bin/bash
echo "makepkg $*" >>"$STUB_LOG/calls"
source ./PKGBUILD
full=$pkgver-$pkgrel file=$PKGDEST/$pkgname-$pkgver-$pkgrel-x86_64$PKGEXT
case " $* " in
  *" --packagelist "*) echo "$file" ;;
  *" --printsrcinfo "*)
    printf 'pkgbase = %s\n\tpkgver = %s\n\tpkgrel = %s\n' "$pkgname" "$pkgver" "$pkgrel"
    [[ -z $install ]] || printf '\tinstall = %s\n' "$install"
    for v in "${conflicts[@]}"; do printf '\tconflicts = %s\n' "$v"; done
    for v in "${provides[@]}"; do printf '\tprovides = %s\n' "$v"; done
    for v in "${source[@]}"; do printf '\tsource = %s\n' "$v"; done
    printf '\npkgname = %s\n' "$pkgname" ;;
  *" -sfC "*)
    d=$BUILDDIR/$pkgname/pkg files=(.PKGINFO)
    mkdir -p "$d" "$PKGDEST"
    { echo "pkgname = $pkgname"; echo "pkgver = $full"
      for v in "${conflicts[@]}"; do echo "conflict = $v"; done
      for v in "${provides[@]}"; do echo "provides = $v"; done; } >"$d/.PKGINFO"
    [[ -z $install ]] || { cp "$install" "$d/.INSTALL"; files+=(.INSTALL); }
    bsdtar -cf "$file" -C "$d" "${files[@]}" ;;
  *) echo "makepkg stub: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat >"$istubs/omarchy-plugin-validate" <<'EOF'
#!/bin/bash
echo "validate $*" >>"$STUB_LOG/calls"
case ${STUB_VALIDATE:-ok} in
  fail) exit 1 ;;
  # As Ctrl-C would: the installer running this stops while it waits.
  term) kill -TERM "$PPID"; sleep 1 ;;
esac
EOF
# shellcheck disable=SC2016 # expanded by the stub, not here
for f in omarchy-shell omarchy; do printf '#!/bin/bash\necho "%s $*" >>"$STUB_LOG/calls"\n' "$f" >"$istubs/$f"; done
chmod +x "$istubs"/*

inst_env=(env HOME="$ihome" PATH="$istubs:$PATH" XDG_CONFIG_HOME="$ihome/.config" XDG_STATE_HOME="$it/state"
  XDG_CACHE_HOME="$it/cache" GIT_CONFIG_NOSYSTEM=1 OMABUMP_TEST_STAGING_DIR="$istaging"
  STUB_DB="$idb" STUB_LOG="$ilog" STUB_SERVED="$iserved" STUB_STAGING="$istaging")
# inst <args...>: a run of the installer copy; its output in $iout, status in $irc.
inst() { iout=$("${inst_env[@]}" timeout 120 "$iplugin/bin/omabump-install" "$@" </dev/null 2>&1); irc=$?; }
# inst_src <code> <args...>: the installer sourced with <args> in a child
# bash, so its setup runs as in a real run, then <code> there, under the
# installer's set -euo pipefail.
inst_src() {
  local code=$1
  shift
  # shellcheck disable=SC2016 # expanded by the child bash
  iout=$("${inst_env[@]}" timeout 120 bash -c 'source "$1" "${@:2}" >/dev/null 2>&1 || exit 99; '"$code" \
    omabump-test "$iplugin/bin/omabump-install" "$@" </dev/null 2>&1)
  irc=$?
}
# says <name> <text>: the last run printed <text>. calls <name> <text>: a
# stub was called with a line holding it.
says() { if grep -qF -- "$2" <<<"$iout"; then pass "$1"; else fail "$1" "no '$2' in: $iout"; fi; }
calls() { if grep -qF -- "$2" "$ilog/calls"; then pass "$1"; else fail "$1" "no '$2' in: $(<"$ilog/calls")"; fi; }
no_call() { if grep -qF -- "$2" "$ilog/calls"; then fail "$1" "'$2' in: $(<"$ilog/calls")"; else pass "$1"; fi; }
# fresh <installed lines...>: an empty call log and staging directory, and
# pacman's database holding these "<name> <version>" lines.
fresh() { : >"$ilog/calls"; rm -rf "$istaging"; printf '%s\n' "$@" >"$idb/installed"; }

# A package file as the pacman stub reads it: a tar with these .PKGINFO
# lines and, with $install_text set, an .INSTALL.
make_pkg() {
  local file=$1 d=$it/pkgtmp parts=(.PKGINFO)
  shift
  rm -rf "$d" && mkdir -p "$d"
  printf '%s\n' "$@" >"$d/.PKGINFO"
  if [[ -n ${install_text:-} ]]; then printf '%s\n' "$install_text" >"$d/.INSTALL"; parts+=(.INSTALL); fi
  bsdtar -cf "$file" -C "$d" "${parts[@]}"
  rm -rf "$d"
}
sha512_b64() { python3 -I -c 'import base64, hashlib, sys; print(base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "$1"; }

cat >"$ihome/.config/omarchy/omabump/apps.json" <<'EOF'
[
  {"pkg": "testapp", "label": "Test App", "source": "vendor-pkg", "installed": ["testapp", "testapp-bin"],
   "feed": {"type": "latest-yml", "url": "https://example.invalid/latest.yml"},
   "vendorPkg": "https://example.invalid/testapp-{version}-1-x86_64.pkg.tar", "checksum": "feed", "configDir": "~/.config/TestApp"},
  {"pkg": "testpkg", "label": "Test Pkg", "source": "omarchy", "installed": ["testpkg", "testpkg-bin"]},
  {"pkg": "nocon", "label": "No Conflict", "source": "omarchy", "installed": ["nocon", "nocon-bin"]}
]
EOF

# --- the vendor route ------------------------------------------------------------

vpkg=testapp-2.0.0-1-x86_64.pkg.tar
vstaged=$istaging/$vpkg vcached=$it/cache/omabump/packages/$vpkg
install_text='post_install() { echo hello; }' make_pkg "$iserved/$vpkg" 'pkgname = testapp' 'pkgver = 2.0.0-1' 'conflict = testapp-bin'
printf 'version: 2.0.0\nfiles:\n  - url: https://example.invalid/%s\n    sha512: %s\n' "$vpkg" "$(sha512_b64 "$iserved/$vpkg")" >"$iserved/latest.yml"

fresh 'testapp 1.0.0-1'
inst --prepare testapp
same "install --prepare (vendor): succeeds" 0 "$irc"
says "install --prepare (vendor): checks the download" 'sha512 matches.'
says "install --prepare (vendor): the staged copy goes whether pacman installed it or not" \
  "Would run: sudo rm -f -- $vstaged (whether pacman installed it or not)"
no_call "install --prepare (vendor): never calls sudo" 'sudo '

fresh 'testapp 1.0.0-1'
STUB_PACMAN_U=no inst testapp
same "install, n at pacman's prompt: a failure" 1 "$irc"
says "install, n at pacman's prompt: says pacman installed nothing, and why it may be" \
  'pacman did not install testapp 2.0.0-1 (you answered no, or it failed above)'
says "install, n at pacman's prompt: points to the verified file for a retry" "The verified package stays in $vcached for a retry"
calls "install, n at pacman's prompt: removes the staged copy with sudo rm" "sudo rm -f -- $vstaged"
check "install, n at pacman's prompt: no staged copy left" test ! -e "$vstaged"
check "install, n at pacman's prompt: the verified file stays in the user cache" test -f "$vcached"
same "install, n at pacman's prompt: nothing installed" 'testapp 1.0.0-1' "$(<"$idb/installed")"
no_call "install, n at pacman's prompt: no panel refresh" 'omabump-check'

fresh 'testapp 1.0.0-1'
STUB_PACMAN_U=hookfail inst testapp
same "install, a hook fails after pacman installed: a success" 0 "$irc"
says "install, a hook fails after pacman installed: with a warning" 'warning: pacman reported an error, but testapp 2.0.0-1 is installed'
says "install, a hook fails after pacman installed: the install is checked" 'Installed testapp 2.0.0-1.'
check "install, a hook fails after pacman installed: no staged copy left" test ! -e "$vstaged"
calls "install, a hook fails after pacman installed: the panel is refreshed" 'omabump-check --no-notify --wait'

fresh 'testapp 1.0.0-1'
STUB_PACMAN_U=ok inst testapp
same "install (vendor): a success" 0 "$irc"
says "install (vendor): the staged copy is checked" "Staged copy checked: $vstaged"
same "install (vendor): pacman has the new version" 'testapp 2.0.0-1' "$(<"$idb/installed")"
check "install (vendor): no staged copy left" test ! -e "$vstaged"
check "install (vendor): the package file is cleaned up" test ! -e "$vcached"
says "install (vendor): restart to use it" 'Restart Test App to use 2.0.0-1.'

fresh 'testapp 1.0.0-1'
STUB_PACMAN_U=ok STUB_TAMPER=1 inst testapp
same "install (vendor): a staged copy that differs is a failure" 1 "$irc"
says "install (vendor): its digest is checked" 'sha512 of the staged copy is'
no_call "install (vendor): and pacman -U never runs" 'pacman -U'

# The feed knows no epoch; the file's full version must still be newer.
fresh 'testapp 1:1.0.0-1'
STUB_PACMAN_U=ok inst testapp
says "install (vendor): guard_version refuses a file older than an installed epoch" \
  'vendor package: 2.0.0-1 is not newer than the installed testapp 1:1.0.0-1; not installing'
no_call "install (vendor): before anything is staged" 'sudo '

fresh 'testapp-bin 2.0.0-1'
printf 'Name            : testapp-bin\nProvides        : None\nConflicts With  : None\n' >"$idb/qi/testapp-bin"
inst --prepare --switch testapp
same "install --prepare --switch (vendor): at the same version" 0 "$irc"
says "install --prepare --switch (vendor): the declared conflict" 'pacman will ask to remove testapp-bin for testapp (declared conflict)'
says "install --prepare --switch (vendor): the package's install script" '--- testapp install script (.INSTALL), run as root:'
says "install --prepare --switch (vendor): the app's settings directory" 'Test App keeps its settings in ~/.config/TestApp.'
rm -f "$vcached"

# --- functions, sourced ---------------------------------------------------------------

fresh 'testapp 1.0.0-1'
inst_src 'switch=0; guard_version 2.0.0-1 && echo newer; guard_version 1.0.0-1 || true' testapp
same "guard_version: Update needs a newer full version" $'newer\n1.0.0-1 is not newer than the installed testapp 1.0.0-1' "$iout"
inst_src 'switch=1; guard_version 1.0.0-1 && echo same; guard_version 1:0.9-1 && echo epoch; guard_version 0.9-1 || true' testapp
same "guard_version: Switch takes the same or newer, epochs counted" \
  $'same\nepoch\n0.9-1 is older than the installed testapp 1.0.0-1' "$iout"

printf 'Name            : x\nProvides        : a=1  b>=2 c<3\nConflicts With  : None\n' >"$it/qi.txt"
# shellcheck disable=SC2016 # expanded by the child bash
T_QI=$it/qi.txt inst_src 'qi_names Provides <"$T_QI"; echo "[$(qi_names "Conflicts With" <"$T_QI")]"' testapp
same "qi_names: names without version constraints, nothing for None" $'a\nb\nc\n[]' "$iout"

# switch_conflicts with testapp-bin installed: one of the two must name the
# other, or something the other provides.
fresh 'testapp-bin 1.0.0-1'
conflicts_with() {  # <the installed package's Provides> <its Conflicts With> <.PKGINFO lines...>
  printf 'Name            : testapp-bin\nProvides        : %s\nConflicts With  : %s\n' "$1" "$2" >"$idb/qi/testapp-bin"
  shift 2
  make_pkg "$it/new.pkg.tar" 'pkgname = testapp' 'pkgver = 2.0.0-1' "$@"
  # shellcheck disable=SC2016 # expanded by the child bash
  T_PKG=$it/new.pkg.tar inst_src 'rc=0; switch_conflicts "$T_PKG" || rc=$?; echo "$rc"' testapp
  echo "$iout"
}
same "switch_conflicts: the new package conflicts with the old name" 0 "$(conflicts_with None None 'conflict = testapp-bin')"
same "switch_conflicts: with something the old one provides" 0 "$(conflicts_with 'oldapi=1' None 'conflict = oldapi')"
same "switch_conflicts: the old package conflicts with the new name" 0 "$(conflicts_with None 'testapp<3' 'provides = x')"
same "switch_conflicts: with something the new one provides" 0 "$(conflicts_with None newapi 'provides = newapi=2')"
same "switch_conflicts: no conflict either way" 1 "$(conflicts_with 'testapp-bin' 'other' 'conflict = other' 'provides = more')"
printf 'not a package' >"$it/new.pkg.tar"
# shellcheck disable=SC2016 # expanded by the child bash
T_PKG=$it/new.pkg.tar inst_src 'rc=0; switch_conflicts "$T_PKG" || rc=$?; echo "$rc"' testapp
same "switch_conflicts: a package pacman cannot read is not 'no conflict'" 2 "$iout"
rm -f "$it/new.pkg.tar" "$idb/qi/testapp-bin"

# --- the omarchy route, on a local omarchy-pkgs clone ----------------------------

pk=$it/cache/omabump/omarchy-pkgs
igit() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@example.com \
  -c init.defaultBranch=main -c advice.detachedHead=false "$@" >/dev/null 2>&1; }
igit init -q "$pk"
igit -C "$pk" remote add origin https://github.com/omacom/omarchy-pkgs.git
mkdir -p "$pk/bin"
cat >"$pk/bin/sync-upstream" <<'EOF'
#!/bin/bash
# Moves the recipe to the release 2.0.0.
sed -i "s/^pkgver=.*/pkgver=2.0.0/" "pkgbuilds/$1/PKGBUILD"
EOF
chmod +x "$pk/bin/sync-upstream"
for p in testpkg nocon; do
  mkdir -p "$pk/pkgbuilds/$p/.omarchy"
  echo '{"upstream": {"type": "github"}}' >"$pk/pkgbuilds/$p/.omarchy/package.json"
done
# The install= form openclaw's recipe uses: the name only makepkg expands.
# shellcheck disable=SC2016 # PKGBUILD text
printf '%s\n' 'pkgname=testpkg' 'pkgver=1.0.0' 'pkgrel=1' 'arch=(x86_64)' 'install=$pkgname.install' 'conflicts=(testpkg-bin)' \
  'provides=(testpkg)' 'source=("testpkg-$pkgver.tar.gz::https://example.invalid/testpkg-$pkgver.tar.gz")' >"$pk/pkgbuilds/testpkg/PKGBUILD"
echo 'post_install() { echo "testpkg recipe hook"; }' >"$pk/pkgbuilds/testpkg/testpkg.install"
printf '%s\n' 'pkgname=nocon' 'pkgver=1.0.0' 'pkgrel=1' 'arch=(x86_64)' >"$pk/pkgbuilds/nocon/PKGBUILD"
igit -C "$pk" add -A
igit -C "$pk" commit -q -m recipes
printf '{"omarchyPkgs": {"commit": "%s"}}\n' "$(git -C "$pk" rev-parse HEAD)" >"$ihome/.config/omarchy/omabump/pins.json"
opkg=testpkg-2.0.0-1-x86_64.pkg.tar
ostaged=$istaging/$opkg

fresh 'testpkg-bin 1.5.0-1'
printf 'Name            : testpkg-bin\nProvides        : None\nConflicts With  : None\n' >"$idb/qi/testpkg-bin"
inst --prepare --switch testpkg
same "install --prepare --switch (omarchy): succeeds" 0 "$irc"
says "install --prepare --switch (omarchy): the recipe moved to the release" 'Recipe builds testpkg 2.0.0-1'
says "install --prepare --switch (omarchy): the conflict, read from the recipe" 'pacman will ask to remove testpkg-bin for testpkg (declared conflict)'
says "install --prepare --switch (omarchy): an install=\$pkgname.install script is found and shown" \
  '--- testpkg install script (testpkg.install in the recipe), run as root:'
says "install --prepare --switch (omarchy): with its text" 'testpkg recipe hook'
says "install --prepare (omarchy): the staged copy is checked against the build's sha256" \
  "Would check: sha256sum of $ostaged is the one taken of $it/cache/omabump/packages/$opkg right after the build"
says "install --prepare (omarchy): the staged copy goes whether pacman installed it or not" \
  "Would run: sudo rm -f -- $ostaged (whether pacman installed it or not)"
no_call "install --prepare (omarchy): no build" ' -sfC'
no_call "install --prepare (omarchy): no sudo" 'sudo '
same "install --prepare (omarchy): the clone is left at the pinned recipe" 'pkgver=1.0.0' "$(grep '^pkgver=' "$pk/pkgbuilds/testpkg/PKGBUILD")"

fresh 'nocon-bin 1.0.0-1'
printf 'Name            : nocon-bin\nProvides        : None\nConflicts With  : None\n' >"$idb/qi/nocon-bin"
inst nocon
same "install (omarchy): a switch without a declared conflict is refused" 1 "$irc"
says "install (omarchy): and says why" 'neither nocon nor nocon-bin declares a conflict with the other'
no_call "install (omarchy): before makepkg builds" ' -sfC'

fresh 'testpkg-bin 1.5.0-1'
STUB_PACMAN_U=ok STUB_TAMPER=1 inst testpkg
same "install (omarchy): a staged copy that is not the built file is refused" 1 "$irc"
says "install (omarchy): by the sha256 taken after the build" 'sha256 of the staged copy is'
no_call "install (omarchy): pacman -U never runs then" 'pacman -U'

fresh 'testpkg-bin 1.5.0-1'
STUB_PACMAN_U=ok inst testpkg
same "install (omarchy): a switch with a declared conflict installs" 0 "$irc"
calls "install (omarchy): after the build" ' -sfC'
says "install (omarchy): the built package's own install script is shown" '--- testpkg install script (.INSTALL), run as root:'
same "install (omarchy): pacman replaced the old package" 'testpkg 2.0.0-1' "$(<"$idb/installed")"
check "install (omarchy): no staged copy left" test ! -e "$ostaged"
check "install (omarchy): the package file is cleaned up" test ! -e "$it/cache/omabump/packages/$opkg"
check "install (omarchy): the build tree is cleaned up" test ! -e "$it/cache/omabump/build/testpkg"
says "install (omarchy): restart to use it" 'Restart Test Pkg to use 2.0.0-1.'

# --- Omabump's own update: the fast-forward and its rollback ---------------------------

igit init -q "$iplugin"
mkdir -p "$iplugin/d"
echo one >"$iplugin/a.txt"
echo keep >"$iplugin/d/keep"
igit -C "$iplugin" add -A
igit -C "$iplugin" commit -q -m installed
before=$(git -C "$iplugin" rev-parse HEAD)
echo two >"$iplugin/a.txt"
echo new >"$iplugin/c.txt"
echo new >"$iplugin/d/new"
igit -C "$iplugin" add -A
igit -C "$iplugin" commit -q -m release
target=$(git -C "$iplugin" rev-parse HEAD)
at_before() {
  [[ $(git -C "$iplugin" rev-parse HEAD) == "$before" && -z $(git -C "$iplugin" status --porcelain) && $(<"$iplugin/a.txt") == one ]]
}
self_reset() { igit -C "$iplugin" reset -q --hard "$before"; igit -C "$iplugin" clean -qfd; : >"$ilog/calls"; }
export T_BEFORE=$before T_TARGET=$target

self_reset
# shellcheck disable=SC2016 # expanded by the child bash
inst_src 'self_target=$T_TARGET; self_apply "$T_BEFORE" omarchy-plugin-validate; echo applied' self:omabump
same "self_apply: a validated release stays" "0|applied|$target" "$irc|$iout|$(git -C "$iplugin" rev-parse HEAD)"

self_reset
# shellcheck disable=SC2016 # expanded by the child bash
STUB_VALIDATE=fail inst_src 'self_target=$T_TARGET; self_apply "$T_BEFORE" omarchy-plugin-validate' self:omabump
says "self_apply: a failed validation rolls back" "the new version failed validation; rolled back to ${before:0:12}"
check "self_apply: back at the installed commit, the release's files gone" at_before

# A merge that moved HEAD and then failed.
self_reset
# shellcheck disable=SC2016 # expanded by the child bash
inst_src 'eval "$(declare -f self_git | sed "1s/^self_git/real_self_git/")"
  self_git() { real_self_git "$@" || return; [[ $1 != merge ]]; }
  self_target=$T_TARGET; self_apply "$T_BEFORE" omarchy-plugin-validate' self:omabump
says "self_apply: a merge that fails after moving HEAD rolls back" "git merge --ff-only $target failed; rolled back to ${before:0:12}"
check "self_apply: back at the installed commit" at_before
no_call "self_apply: nothing validated after a failed merge" 'validate'

# A merge that stops part way: a.txt rewritten and c.txt written, d/new not
# (d is read-only), HEAD and the index not moved. Root writes anyway.
self_reset
if (( $(id -u) == 0 )); then
  pass "self_apply: a merge that stops part way rolls back (skipped as root)"
  pass "self_apply: the files it wrote are gone (skipped as root)"
else
  chmod 555 "$iplugin/d"
  # shellcheck disable=SC2016 # expanded by the child bash
  inst_src 'self_target=$T_TARGET; self_apply "$T_BEFORE" omarchy-plugin-validate' self:omabump
  chmod 755 "$iplugin/d"
  says "self_apply: a merge that stops part way rolls back" "git merge --ff-only $target failed; rolled back to ${before:0:12}"
  check "self_apply: the files it wrote are gone" at_before
fi

# Stopped by a signal (Ctrl-C) while validating: the exit trap rolls back.
self_reset
# shellcheck disable=SC2016 # expanded by the child bash
STUB_VALIDATE=term inst_src 'self_target=$T_TARGET; self_apply "$T_BEFORE" omarchy-plugin-validate; echo applied' self:omabump
says "self_apply: a run stopped while validating rolls back on exit" "the update stopped part way; rolled back to ${before:0:12}"
check "self_apply: back at the installed commit after the signal" at_before
refuse "self_apply: and the run is a failure" test "$irc" = 0
self_reset
unset T_BEFORE T_TARGET

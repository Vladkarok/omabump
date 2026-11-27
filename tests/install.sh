# shellcheck shell=bash
# bin/omabump-install against stub commands, sourced by tests/run.sh (its
# helpers, $root and $scratch). The installer runs in a child bash from a
# copy of the plugin whose bin/omabump-check is a stub, staging in a test
# directory instead of /var/cache/omabump, with these first on PATH:
#   pacman    -Q and -Qi from a fixture database, -Qqo from its file
#             owners, -Qp and -Qip from the package's .PKGINFO (-Qp fails on a staged copy with
#             $STUB_QP_FAIL set, and says $STUB_QP_STAGED of one when that
#             is set), -U as $STUB_PACMAN_U says (ok, no, with
#             $STUB_PACMAN_KEEP set leaving the packages it conflicts with,
#             hookfail, or HUP or TERM: that signal to the installer at
#             the prompt, after which pacman goes on until the installer
#             has ended and records whether the package was still there)
#   sudo      records its arguments and runs only the installer's four
#             commands, as you, on files in the test staging directory,
#             and rm -f on one in the test bin directory; anything else
#             fails loudly. With $STUB_SUDO_INSTALL set (HUP
#             or TERM), install sends that signal to the installer once
#             the copy is written, and waits until the installer has
#             ended; with $STUB_SUDO_ASKS set, it sends it before (as
#             while sudo asks for a password) and writes the copy once
#             the installer has ended. rm -f does the same with
#             $STUB_SUDO_RM set: the signal, then rm once the installer
#             has ended. It keeps no password per terminal as the real
#             one does: sudo -n succeeds unless $STUB_SUDO_N=fail, which
#             is what a run whose terminal was closed gets (or one whose
#             password timed out)
#   curl      serves files from a local directory, by the URL's last part
#             (an epoch's %3A read as ":")
#   pacman-conf  $STUB_REPO_SERVER as the [omarchy] repo's Server, or no
#             such repo when that is unset; GPGDir as $STUB_DB/gnupg/
#   gpg       --verify <sig> <file> as pacman-key runs it, in pacman's
#             GPGDir: when <sig> holds "signed:" and the file's sha256, a
#             good signature by a trusted key (TRUST_FULLY); "untrusted:"
#             and the sha256, a good one by a key the keyring does not
#             trust (TRUST_UNDEFINED, and exit 0, as gpg does); anything
#             else a bad one (exit 1). With $STUB_GPG_CACHE_GOOD set, every
#             file outside the staging directory reads as signed, as one
#             swapped for the signed file while it was checked would
#   makepkg   reads the test recipe's PKGBUILD and "builds" a plain tar,
#             its files owned by root as under fakeroot, or by
#             $STUB_MAKEPKG_OWNER ("<uid>:<gid>");
#             with $STUB_MAKEPKG_INSTALLS ("<name> <version>") set, that is
#             what pacman has installed once the build is done, as when
#             omarchy update installs it meanwhile
#   mise      answers for one tool, testtool 1.0.0 on a safe backend, with
#             $STUB_MISE_OUTDATED and $STUB_MISE_BUMP as its outdated tables
#   omarchy-plugin-validate, omarchy-shell, omarchy   record, and change nothing
# The omarchy route reads a local omarchy-pkgs clone at the commit the test
# pins.json names, so nothing reaches the network or needs root.

: "${root:?}" "${scratch:?}"
it=$scratch/install
ihome=$it/home
iplugin=$ihome/.config/omarchy/plugins/io.github.vladkarok.omabump
istubs=$it/stubs idb=$it/db ilog=$it/log iserved=$it/served istaging=$it/staging ibin=$it/bin
mkdir -p "$iplugin/bin" "$istubs" "$idb/qi" "$ilog" "$iserved" "$ibin" "$ihome/.config/omarchy/omabump"
: >"$idb/files"
for f in bin/omabump-install bin/omabump-common apps.json pins.json manifest.json; do
  cp "$root/$f" "$iplugin/$f"
done
# The panel's refresh, recorded, and whether the installer still held the
# omarchy-pkgs clone's lock then.
cat >"$iplugin/bin/omabump-check" <<'EOF'
#!/bin/bash
echo "omabump-check $*" >>"$STUB_LOG/calls"
[[ ! -e $STUB_PKGS_LOCK ]] || flock -n "$STUB_PKGS_LOCK" true || echo "omabump-check: the clone is locked" >>"$STUB_LOG/calls"
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
  -Qqo) awk -F'\t' -v p="$last" '$1 == p { print $2; found = 1 } END { exit !found }' "$STUB_DB/files" \
    || { echo "error: No package owns $last" >&2; exit 1; } ;;
  -Qp) [[ -z ${STUB_QP_FAIL:-} || $last != "$STUB_STAGING"/* ]] || { echo "error: cannot read $last" >&2; exit 1; }
    [[ -z ${STUB_QP_STAGED:-} || $last != "$STUB_STAGING"/* ]] || { echo "$STUB_QP_STAGED"; exit 0; }
    info=$(pkginfo "$last") || exit 1
    echo "$(field pkgname "$info") $(field pkgver "$info")" ;;
  -Qip) info=$(pkginfo "$last") || exit 1
    p=$(field provides "$info" | paste -sd' ') c=$(field conflict "$info" | paste -sd' ')
    printf 'Name            : %s\nProvides        : %s\nConflicts With  : %s\n' "$(field pkgname "$info")" "${p:-None}" "${c:-None}" ;;
  -U) info=$(pkginfo "$last") || exit 1
    case ${STUB_PACMAN_U:-no} in
      ok|hookfail)
        name=$(field pkgname "$info")
        { echo "$name"; [[ -n ${STUB_PACMAN_KEEP:-} ]] || field conflict "$info"; } >"$STUB_DB/drop"
        awk 'NR == FNR { d[$1]; next } !($1 in d)' "$STUB_DB/drop" "$STUB_DB/installed" >"$STUB_DB/installed.new"
        echo "$name $(field pkgver "$info")" >>"$STUB_DB/installed.new"
        mv "$STUB_DB/installed.new" "$STUB_DB/installed"
        [[ $STUB_PACMAN_U == ok ]] || { echo "error: command failed to execute correctly" >&2; exit 1; } ;;
      # The terminal closing or kill while pacman asks. The sudo stub
      # exec'd this, so the parent is the installer. pacman is a process
      # of its own: it goes on while the installer ends (on_exit runs
      # then), and only afterwards would it read the package.
      HUP|TERM) echo ":: Proceed with installation? [Y/n]"; i=$PPID
        kill "-$STUB_PACMAN_U" "$i"
        for _ in {1..100}; do kill -0 "$i" 2>/dev/null || break; sleep 0.05; done
        [[ ! -e $last ]] || echo "pacman -U: $last still there after the installer ended" >>"$STUB_LOG/calls"
        exit 1 ;;
      *) echo ":: Proceed with installation? [Y/n] n"; exit 1 ;;
    esac ;;
  *) echo "pacman stub: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat >"$istubs/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >>"$STUB_LOG/calls"
dest=${*: -1}
[[ ($dest == "$STUB_STAGING"/* || $* == "rm -f -- $STUB_BIN/"*) && $dest != *..* ]] || { echo "sudo stub: refusing $*" >&2; exit 97; }
# The signal $1 to the installer, then nothing until it has ended.
signal_installer() {
  kill "-$1" "$PPID"
  for _ in {1..100}; do kill -0 "$PPID" 2>/dev/null || break; sleep 0.05; done
}
case "$*" in
  "install -o root -g root -m 0644 -D /dev/stdin $dest")
    # kill while sudo asks for the password: sudo is not signalled, and
    # copies the package once you answer, after the installer has ended.
    [[ -z ${STUB_SUDO_ASKS:-} ]] || signal_installer "$STUB_SUDO_ASKS"
    mkdir -p "${dest%/*}" && cat >"$dest" || exit 1
    # Another pacman installing this meanwhile, while sudo had the prompt.
    [[ -z ${STUB_SUDO_MEANWHILE:-} ]] || echo "$STUB_SUDO_MEANWHILE" >>"$STUB_DB/installed"
    [[ -z ${STUB_TAMPER:-} ]] || printf 'x' >>"$dest"
    # The terminal closing or kill once the copy is there, before pacman.
    if [[ -n ${STUB_SUDO_INSTALL:-} ]]; then
      signal_installer "$STUB_SUDO_INSTALL"
      exit 1
    fi ;;
  "pacman -U -- $dest") exec pacman -U -- "$dest" ;;
  # kill as the copy is removed, once pacman has ended.
  "rm -f -- $dest")
    [[ -z ${STUB_SUDO_RM:-} ]] || signal_installer "$STUB_SUDO_RM"
    exec rm -f -- "$dest" ;;
  "-n rm -f -- $dest")
    [[ ${STUB_SUDO_N:-} != fail ]] || { echo "sudo: a password is required" >&2; exit 1; }
    exec rm -f -- "$dest" ;;
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
name=${url##*/} name=${name//%3A/:}
[[ -f $STUB_SERVED/$name ]] || exit 22
if [[ -n $out ]]; then cp "$STUB_SERVED/$name" "$out"; else cat "$STUB_SERVED/$name"; fi
EOF
cat >"$istubs/pacman-conf" <<'EOF'
#!/bin/bash
echo "pacman-conf $*" >>"$STUB_LOG/calls"
[[ $* != GPGDir ]] || { echo "$STUB_DB/gnupg/"; exit 0; }
[[ $* == "--repo omarchy Server" ]] || { echo "pacman-conf stub: unexpected $*" >&2; exit 99; }
[[ -n ${STUB_REPO_SERVER:-} ]] || { echo "error: repo 'omarchy' not configured" >&2; exit 1; }
echo "$STUB_REPO_SERVER"
EOF
cat >"$istubs/gpg" <<'EOF'
#!/bin/bash
echo "gpg $*" >>"$STUB_LOG/calls"
[[ $# == 8 && "${*:1:6}" == "--homedir $STUB_DB/gnupg/ --no-permission-warning --status-fd 1 --verify" ]] \
  || { echo "gpg stub: unexpected $*" >&2; exit 99; }
sig=$7 file=$8 sum="" kind=bad
[[ -f $file ]] && sum=$(sha256sum <"$file" | cut -d' ' -f1)
[[ -f $sig && -n $sum && $(<"$sig") == "signed:$sum" ]] && kind=good
[[ -f $sig && -n $sum && $(<"$sig") == "untrusted:$sum" ]] && kind=untrusted
[[ -z ${STUB_GPG_CACHE_GOOD:-} || $file == "$STUB_STAGING"/* ]] || kind=good
fpr=40DFB630FF42BCFFB047046CF0134EE680CAC571
echo '[GNUPG:] NEWSIG'
if [[ $kind == bad ]]; then
  echo '[GNUPG:] BADSIG F0134EE680CAC571 Omarchy <pkgs@omarchy.org>'
  echo 'gpg: BAD signature from "Omarchy <pkgs@omarchy.org>" [full]' >&2
  exit 1
fi
echo '[GNUPG:] GOODSIG F0134EE680CAC571 Omarchy <pkgs@omarchy.org>'
echo "[GNUPG:] VALIDSIG $fpr 2026-09-07 1788804152 0 4 0 22 10 00 $fpr"
if [[ $kind == untrusted ]]; then
  echo 'gpg: Good signature from "Omarchy <pkgs@omarchy.org>" [unknown]' >&2
  echo 'gpg: WARNING: This key is not certified with a trusted signature!' >&2
  echo '[GNUPG:] TRUST_UNDEFINED 0 pgp'
else
  echo 'gpg: Good signature from "Omarchy <pkgs@omarchy.org>" [full]' >&2
  echo '[GNUPG:] TRUST_FULLY 0 pgp'
fi
EOF
cat >"$istubs/makepkg" <<'EOF'
#!/bin/bash
echo "makepkg $*" >>"$STUB_LOG/calls"
echo "${GNUPGHOME:-none}" >>"$STUB_LOG/gnupg"
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
    owner=${STUB_MAKEPKG_OWNER:-0:0}
    bsdtar -cf "$file" --uid "${owner%:*}" --gid "${owner#*:}" -C "$d" "${files[@]}"
    [[ -z ${STUB_MAKEPKG_INSTALLS:-} ]] || printf '%s\n' "$STUB_MAKEPKG_INSTALLS" >"$STUB_DB/installed" ;;
  *) echo "makepkg stub: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat >"$istubs/mise" <<'EOF'
#!/bin/bash
echo "mise $*" >>"$STUB_LOG/calls"
none='{}'
case "$*" in
  "settings ls --all --json") echo "{\"disable_backends\": [], \"disable_tools\": [\"mine\"], \"use_versions_host\": ${STUB_MISE_HOST:-true}}" ;;
  "config ls --json") echo '[{"path": "/etc/mise/x.toml", "tools": ["testtool", "unused-tool"]}]' ;;
  "ls --json"|"ls --json --backend "*)
    echo "{\"testtool\": [{\"version\": \"$(cat "$STUB_LOG/mise-version" 2>/dev/null || echo 1.0.0)\", \"active\": true, \"installed\": true}]}" ;;
  "install -- testtool@"*)
    echo "env $MISE_USE_VERSIONS_HOST $MISE_USE_VERSIONS_HOST_TRACK $MISE_DISABLE_TOOLS" >>"$STUB_LOG/calls"
    all="$*"
    [ -n "${STUB_MISE_LOCKED:-}" ] || echo "${all#install -- testtool@}" >"$STUB_LOG/mise-version" ;;
  "up -- testtool")
    echo "env $MISE_USE_VERSIONS_HOST $MISE_USE_VERSIONS_HOST_TRACK $MISE_DISABLE_TOOLS" >>"$STUB_LOG/calls"
    echo "${STUB_MISE_UP:-1.0.0}" >"$STUB_LOG/mise-version" ;;
  "outdated --json -- testtool") printf '%s\n' "${STUB_MISE_OUTDATED:-$none}" ;;
  "outdated --bump --json -- testtool") printf '%s\n' "${STUB_MISE_BUMP:-$none}" ;;
  *) echo "mise stub: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat >"$istubs/omarchy-plugin-validate" <<'EOF'
#!/bin/bash
echo "validate $*" >>"$STUB_LOG/calls"
case ${STUB_VALIDATE:-ok} in
  fail) exit 1 ;;
  # As Ctrl-C would: the installer running this stops while it waits.
  term) kill -TERM "$PPID"; sleep 0.2 ;;
esac
EOF
# shellcheck disable=SC2016 # expanded by the stub, not here
for f in omarchy-shell omarchy; do printf '#!/bin/bash\necho "%s $*" >>"$STUB_LOG/calls"\n' "$f" >"$istubs/$f"; done
chmod +x "$istubs"/*

inst_env=(env HOME="$ihome" PATH="$istubs:$PATH" XDG_CONFIG_HOME="$ihome/.config" XDG_STATE_HOME="$it/state"
  XDG_CACHE_HOME="$it/cache" GIT_CONFIG_NOSYSTEM=1
  STUB_DB="$idb" STUB_LOG="$ilog" STUB_SERVED="$iserved" STUB_STAGING="$istaging" STUB_BIN="$ibin"
  STUB_PKGS_LOCK="$it/cache/omabump/omarchy-pkgs.lock")
# The child bash sources the installer copy, which runs nothing, then stages
# in $istaging, with $idb/db.lck as pacman's lock file and $ibin as
# /usr/bin.
# shellcheck disable=SC2016 # expanded by the child bash
inst_load='source "$1" || exit 99; staging_dir=$STUB_STAGING pacman_lock=$STUB_DB/db.lck bin_dir=$STUB_BIN; '
# inst <args...>: a run of the installer copy; its output in $iout, status
# in $irc.
inst() {
  # shellcheck disable=SC2016 # expanded by the child bash
  iout=$("${inst_env[@]}" timeout 120 bash -c "$inst_load"'omabump_install "${@:2}"' \
    omabump-test "$iplugin/bin/omabump-install" "$@" </dev/null 2>&1)
  irc=$?
}
# inst_src <code> [<args...>]: <code> in a child bash that sourced the
# installer copy, under its set -euo pipefail, with <args> as "$@". Nothing
# of a run has happened: <code> sets the globals the functions it calls
# read, or calls install_setup "$@" for a run's own.
inst_src() {
  local code=$1
  shift
  # shellcheck disable=SC2016 # expanded by the child bash
  iout=$("${inst_env[@]}" timeout 120 bash -c "$inst_load"'shift; '"$code" \
    omabump-test "$iplugin/bin/omabump-install" "$@" </dev/null 2>&1)
  irc=$?
}
# inst_src's code for a run's setup with <args>, under set -e and with its
# output dropped, before the rest of the code. It sets on_exit as the trap
# on EXIT; code without it runs with none.
# shellcheck disable=SC2016 # expanded by the child bash
isetup='install_setup "$@" >/dev/null 2>&1; '
# says <name> <text>: the last run printed <text>. calls <name> <text>: a
# stub was called with a line holding it.
says() { if grep -qF -- "$2" <<<"$iout"; then pass "$1"; else fail "$1" "no '$2' in: $iout"; fi; }
calls() { if grep -qF -- "$2" "$ilog/calls"; then pass "$1"; else fail "$1" "no '$2' in: $(<"$ilog/calls")"; fi; }
no_call() { if grep -qF -- "$2" "$ilog/calls"; then fail "$1" "'$2' in: $(<"$ilog/calls")"; else pass "$1"; fi; }
# fresh <installed lines...>: an empty call log and staging directory, no
# staged copy recorded as left, no pacman running (its lock file), no check
# run yet (status.json), and pacman's database holding these "<name>
# <version>" lines.
ileft=$it/cache/omabump/staged-left
istatus=$it/state/omarchy/plugins/io.github.vladkarok.omabump/status.json
fresh() { : >"$ilog/calls"; rm -rf "$istaging" "$ileft" "$idb/db.lck" "$istatus"; printf '%s\n' "$@" >"$idb/installed"; }
# shown <pkg> <latest> <installed> [<update>]: status.json from a check that
# saw <pkg> at <installed> and showed <latest>, as the panel does until the
# next one, offering an update when the two differ unless <update> says
# otherwise (true or false).
shown() {
  mkdir -p "${istatus%/*}"
  jq -n --arg pkg "$1" --arg latest "$2" --arg installed "$3" --arg update "${4:-}" '{schemaVersion: 1, apps: [{pkg: $pkg,
    installed: $installed, latest: $latest, installable: true,
    updateAvailable: (if $update == "" then $latest != $installed else $update == "true" end)}]}' >"$istatus"
}

# A package file as the pacman stub reads it: a tar with these .PKGINFO
# lines and, with $install_text set, an .INSTALL, owned by root as makepkg
# packs them, or by $pkg_owner ("<uid>:<gid>").
make_pkg() {
  local file=$1 d=$it/pkgtmp parts=(.PKGINFO) owner=${pkg_owner:-0:0}
  shift
  rm -rf "$d" && mkdir -p "$d"
  printf '%s\n' "$@" >"$d/.PKGINFO"
  if [[ -n ${install_text:-} ]]; then printf '%s\n' "$install_text" >"$d/.INSTALL"; parts+=(.INSTALL); fi
  bsdtar -cf "$file" --uid "${owner%:*}" --gid "${owner#*:}" -C "$d" "${parts[@]}"
  rm -rf "$d"
}
sha512_b64() { python3 -I -c 'import base64, hashlib, sys; print(base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "$1"; }

cat >"$ihome/.config/omarchy/omabump/apps.json" <<'EOF'
[
  {"pkg": "testapp", "label": "Test App", "source": "vendor-pkg", "installed": ["testapp", "testapp-bin"],
   "feed": {"type": "latest-yml", "url": "https://example.invalid/latest.yml"},
   "vendorPkg": "https://example.invalid/testapp-{version}-1-x86_64.pkg.tar", "checksum": "feed", "configDir": "~/.config/TestApp"},
  {"pkg": "testpkg", "label": "Test Pkg", "source": "omarchy", "installed": ["testpkg", "testpkg-bin"]},
  {"pkg": "nocon", "label": "No Conflict", "source": "omarchy", "installed": ["nocon", "nocon-bin"]},
  {"pkg": "mise:testtool", "label": "Test Tool", "source": "mise", "tool": "testtool"},
  {"pkg": "blockedapp", "label": "Blocked App", "source": "omarchy", "updateBlocked": "a known problem in its install script, see x#1"},
  {"pkg": "selfapp", "label": "Self App", "source": "omarchy", "appImage": "~/.local/share/selfapp/Self.AppImage"},
  {"pkg": "npmapp", "label": "Npm App", "source": "omarchy", "npmPackage": "~/.npmapp/lib/node_modules/npmapp",
   "selfUpdate": "run npmapp update", "updateBlocked": "its package is the seed"},
  {"pkg": "npmesc", "label": "Npm Esc", "source": "omarchy", "npmPackage": "~/.npmesc/lib/node_modules/npmesc",
   "selfUpdate": "run \u001b]0;x\u0007npmesc update"},
  {"pkg": "indapp", "label": "Ind App", "source": "indicator"},
  {"pkg": "rpapp", "label": "Rp App", "source": "repo", "installed": ["rpapp", "rpapp-bin"]},
  {"pkg": "rpepoch", "label": "Rp Epoch", "source": "repo"}
]
EOF

# --- an app whose Update apps.json turned off ---------------------------------------

fresh 'blockedapp 1.0-1'
inst blockedapp
same "install, updateBlocked: refuses" 1 "$irc"
says "install, updateBlocked: says why" 'omabump: Update of Blocked App is off in Omabump: a known problem in its install script, see x#1'
no_call "install, updateBlocked: nothing staged" 'sudo'
no_call "install, updateBlocked: nothing built" 'makepkg'
inst --prepare blockedapp
same "install --prepare, updateBlocked: says it would refuse, and why" \
  '0|Would refuse: Update of Blocked App is off in Omabump: a known problem in its install script, see x#1' "$irc|$iout"

# --- an app installed as its self-updating AppImage ---------------------------------

# Its package is not installed; the AppImage is a script that leaves a mark
# if anything runs it. A staged copy an earlier Update recorded as left
# stays: removing it would call sudo. No Update of the app comes to remove
# it later, so the refusal names it, with the command that does; a line of
# the record that is no staged copy is not named.
mkdir -p "$ihome/.local/share/selfapp"
printf '#!/bin/sh\n: >"%s/selfapp-ran"\n' "$it" >"$ihome/.local/share/selfapp/Self.AppImage"
chmod +x "$ihome/.local/share/selfapp/Self.AppImage"
for args in selfapp '--prepare selfapp' '--switch selfapp'; do
  fresh
  mkdir -p "$istaging" "$ileft"
  : >"$istaging/selfapp-old.pkg.tar"
  printf '%s\n' "$istaging/selfapp-old.pkg.tar" "$it/elsewhere.pkg.tar" "$istaging/gone.pkg.tar" >"$ileft/selfapp"
  : >"$it/elsewhere.pkg.tar"
  # shellcheck disable=SC2086 # the arguments, split on purpose
  inst $args
  # --prepare says what a run would refuse, as for any other refusal.
  refusal='omabump: ' rc=1
  [[ $args != --prepare* ]] || refusal='Would refuse: ' rc=0
  same "install $args, a self-updating app: refuses as other refusals do" "$rc" "$irc"
  says "install $args, a self-updating app: says it updates itself, and which file it is" \
    "${refusal}Self App updates itself: open Self App to update (it is installed as ~/.local/share/selfapp/Self.AppImage, which Omabump does not replace)"
  no_call "install $args, a self-updating app: never calls sudo" 'sudo'
  no_call "install $args, a self-updating app: nothing built" 'makepkg'
  check "install $args, a self-updating app: the staged copy left stays" test -e "$istaging/selfapp-old.pkg.tar"
  says "install $args, a self-updating app: names the staged copy left, and how to remove it" \
    "omabump: a stopped Update of the selfapp package left its staged copy in $istaging/selfapp-old.pkg.tar, and no Update of Self App will remove it now; remove it with: sudo rm -f -- $istaging/selfapp-old.pkg.tar"
  same "install $args, a self-updating app: names nothing else of the record" 1 "$(grep -c 'left its staged copy' <<<"$iout")"
  same "install $args, a self-updating app: the record stays as it was" 3 "$(wc -l <"$ileft/selfapp")"
done
rm -f "$it/elsewhere.pkg.tar"
fresh
inst selfapp
same "install, a self-updating app with no staged copy left: the refusal alone" \
  '1|omabump: Self App updates itself: open Self App to update (it is installed as ~/.local/share/selfapp/Self.AppImage, which Omabump does not replace)' \
  "$irc|$iout"
check "install, a self-updating app: nothing ran the AppImage" test ! -e "$it/selfapp-ran"
# With its package installed, the package is what Update works on: the
# installer's setup goes past the refusal (the route itself is not run here).
fresh 'selfapp 1.0-1'
# shellcheck disable=SC2016 # expanded by the child bash
inst_src "$isetup"'echo "$installed_name $installed"' selfapp
same "install, an app with an appImage whose package is installed: the package, no refusal" '0|selfapp 1.0-1' "$irc|$iout"
rm -rf "$ihome/.local/share/selfapp"

# An app installed as its self-updating npm package, beside the package
# that seeded it: the copy is what runs, so the refusal is the copy's,
# whatever the package's updateBlocked says.
mkdir -p "$ihome/.npmapp/lib/node_modules/npmapp"
echo '{"name": "npmapp", "version": "2.0.0"}' >"$ihome/.npmapp/lib/node_modules/npmapp/package.json"
for args in npmapp '--prepare npmapp'; do
  fresh 'npmapp 1.0-1'
  # shellcheck disable=SC2086 # the arguments, split on purpose
  inst $args
  refusal='omabump: ' rc=1
  [[ $args != --prepare* ]] || refusal='Would refuse: ' rc=0
  same "install $args, a self-updating npm package: refuses, saying how it updates and which copy it is" \
    "$rc|${refusal}Npm App updates itself: run npmapp update (it is installed as ~/.npmapp/lib/node_modules/npmapp, which Omabump does not replace)" \
    "$irc|$iout"
  no_call "install $args, a self-updating npm package: never calls sudo" 'sudo'
  no_call "install $args, a self-updating npm package: nothing built" 'makepkg'
done
rm -rf "$ihome/.npmapp"
# The selfUpdate text reaches the terminal as the label does, through
# term_safe.
mkdir -p "$ihome/.npmesc/lib/node_modules/npmesc"
echo '{"name": "npmesc", "version": "2.0.0"}' >"$ihome/.npmesc/lib/node_modules/npmesc/package.json"
fresh
inst npmesc
same "install, a self-updating npm package: its selfUpdate text has no control characters on the terminal" 0 \
  "$(LC_ALL=C grep -c $'[\x01-\x08\x0b-\x1f\x7f]' <<<"$iout")"
says "install, a self-updating npm package: the rest of its selfUpdate text stays" 'npmesc update (it is installed as'
rm -rf "$ihome/.npmesc"
fresh 'npmapp 1.0-1'
inst npmapp
same "install, the npm package's seed alone: its updateBlocked refuses" \
  '1|omabump: Update of Npm App is off in Omabump: its package is the seed' "$irc|$iout"

# --- the rule refusals, asked directly ------------------------------------------------

# rule <name> <phase> <reason> <args...>: rule_refusal, asked at each point
# of a run in turn with the facts of a run with <args>, gives <reason> at
# <phase> (none: at no point) and changes nothing; a run refuses with that
# reason, and --prepare says it would, both as their last line.
rule() {
  local name=$1 phase=$2 reason=$3
  shift 3
  # shellcheck disable=SC2016 # expanded by the child bash
  inst_src 'install_args "$@"; install_app; installed_facts >/dev/null 2>&1
    for p in copy entry route; do if why=$(rule_refusal "$p"); then echo "$p|$why"; exit 0; fi; done; echo none' "$@"
  if [[ $phase == none ]]; then
    same "rule_refusal, $name: none applies" '0|none' "$irc|$iout"
    return
  fi
  same "rule_refusal, $name: asked directly, at $phase" "0|$phase|$reason" "$irc|$iout"
  no_call "rule_refusal, $name: asked directly, calls no sudo" 'sudo'
  inst "$@"
  same "rule_refusal, $name: a run refuses with it" "1|omabump: $reason" "$irc|$(tail -n1 <<<"$iout")"
  inst --prepare "$@"
  same "rule_refusal, $name: --prepare says the run would" "0|Would refuse: $reason" "$irc|$(tail -n1 <<<"$iout")"
}
fresh 'blockedapp 1.0-1'
rule "updateBlocked" entry 'Update of Blocked App is off in Omabump: a known problem in its install script, see x#1' blockedapp
mkdir -p "$ihome/.local/share/selfapp" "$ihome/.npmapp/lib/node_modules/npmapp"
printf '#!/bin/sh\n: >"%s/selfapp-ran"\n' "$it" >"$ihome/.local/share/selfapp/Self.AppImage"
chmod +x "$ihome/.local/share/selfapp/Self.AppImage"
echo '{"name": "npmapp", "version": "2.0.0"}' >"$ihome/.npmapp/lib/node_modules/npmapp/package.json"
fresh 'npmapp 1.0-1'
rule "a self-updating AppImage" copy \
  'Self App updates itself: open Self App to update (it is installed as ~/.local/share/selfapp/Self.AppImage, which Omabump does not replace)' selfapp
rule "a self-updating npm package, over its updateBlocked" copy \
  'Npm App updates itself: run npmapp update (it is installed as ~/.npmapp/lib/node_modules/npmapp, which Omabump does not replace)' npmapp
fresh 'selfapp 1.0-1'
rule "an AppImage whose package is installed" none '' selfapp
check "rule_refusal: nothing ran the AppImage" test ! -e "$it/selfapp-ran"
rm -rf "$ihome/.local/share/selfapp" "$ihome/.npmapp"
fresh 'testapp 1.0.0-1'
rule "--switch with nothing to switch" route 'Test App is not installed under another name; nothing to switch' --switch testapp
rule "an Update of a vendor row" none '' testapp
fresh 'testapp-bin 1.0.0-1'
rule "--switch from another name" none '' --switch testapp
fresh
rule "--switch on a mise row" route "--switch works for rows from Omarchy's repo and vendor rows only" --switch mise:testtool
rule "an indicator row" route \
  'Ind App has no Update here: omarchy update updates it when pacman or the AUR has its package, else update it the way you installed it' indapp
rule "--switch on a repo row with nothing to switch" route 'Rp App is not installed under another name; nothing to switch' --switch rpapp
rule "--build on a vendor row" route "Build now is not available for Test App: Omabump does not build its recipe (its apps.json entry has no \"build\": true). Update installs it once Omarchy's repo has it" --build testapp
rule "--build while buildAhead is off" route "Build now is off. It builds Test Pkg on this machine from Omarchy's own recipe, before Omarchy's repo has the release: it takes minutes, runs Omarchy's build recipe as you, and the package is not signed by Omarchy. Turn it on with: omarchy bar set io.github.vladkarok.omabump buildAhead true --json (or in the Omabump panel's settings)" --build testpkg
rule "Omabump from a local checkout" route "Omabump runs from a local checkout ($iplugin); update it with git" self:omabump

# --- the vendor route ------------------------------------------------------------

vpkg=testapp-2.0.0-1-x86_64.pkg.tar
vstaged=$istaging/$vpkg vcached=$it/cache/omabump/packages/$vpkg
install_text='post_install() { echo hello; }' make_pkg "$iserved/$vpkg" 'pkgname = testapp' 'pkgver = 2.0.0-1' 'conflict = testapp-bin'
printf 'version: 2.0.0\nfiles:\n  - url: https://example.invalid/%s\n    sha512: %s\n' "$vpkg" "$(sha512_b64 "$iserved/$vpkg")" >"$iserved/latest.yml"

# A jq that fails, as a killed one does, on the read of updateBlocked alone
# (update_blocked's filter): that is no answer, so a run ends there, failed,
# before any sudo, and --prepare too, never as "Would refuse" nor as an
# Update that is not off. testapp's feed has a newer release by now, so a
# run that took the failure for "not off" would reach sudo pacman -U.
ijq=$it/jq-killed
mkdir -p "$ijq"
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/bin/bash\nfor a; do [[ $a == %q ]] && exit 137; done\nexec %q "$@"\n' '.updateBlocked // ""' "$(command -v jq)" >"$ijq/jq"
chmod +x "$ijq/jq"
inst_env_was=("${inst_env[@]}")
inst_env+=(PATH="$ijq:$istubs:$PATH")
unread_line='omabump: could not read the entry of %s in the app table; nothing was installed'
for case in 'blockedapp:Blocked App:blockedapp 1.0-1' 'testapp:Test App:testapp 1.0.0-1'; do
  IFS=: read -r upkg ulabel uinstalled <<<"$case"
  # shellcheck disable=SC2059 # the line's format
  uline=$(printf "$unread_line" "$ulabel")
  for uargs in '' --prepare; do
    fresh "$uinstalled"
    inst ${uargs:+"$uargs"} "$upkg"
    same "updateBlocked unread, $upkg${uargs:+ $uargs}: the run fails there" "1|$uline" "$irc|$(tail -n1 <<<"$iout")"
    no_call "updateBlocked unread, $upkg${uargs:+ $uargs}: no sudo" 'sudo'
    refuse "updateBlocked unread, $upkg${uargs:+ $uargs}: no refusal, no route" grep -qe 'Would refuse\|is off in Omabump\|installed 1' <<<"$iout"
  done
done
inst_env=("${inst_env_was[@]}")

fresh 'testapp 1.0.0-1'
inst --prepare testapp
same "install --prepare (vendor): succeeds" 0 "$irc"
says "install --prepare (vendor): checks the download" 'sha512 matches.'
says "install --prepare (vendor): the staged copy goes whether pacman installed it or not" \
  "Would run: sudo rm -f -- $vstaged (whether pacman installed it or not)"
says "install --prepare (vendor): who owns the staged copy's files is checked" \
  "Would check: every file in $vstaged is owned by root, in group root, tty, ftp or games"
no_call "install --prepare (vendor): never calls sudo" 'sudo '
same "install --prepare (vendor): the download is for the real run, not a stopped one" '' "$(grep -F 'the build and download files stay' <<<"$iout")"

# Run as a command, the installer stages in /var/cache/omabump and reads
# pacman's own lock file whatever the environment says.
fresh 'testapp 1.0.0-1'
: >"$idb/db.lck"
iout=$("${inst_env[@]}" OMABUMP_TEST_STAGING_DIR="$istaging" staging_dir="$istaging" pacman_lock="$idb/db.lck" \
  timeout 120 "$iplugin/bin/omabump-install" --prepare testapp </dev/null 2>&1)
same "install --prepare, run as a command: succeeds" 0 "$?"
says "install, run as a command: no environment variable moves the staging directory" \
  "Would run: sudo pacman -U -- /var/cache/omabump/$vpkg ("
refuse "install, run as a command: nor pacman's lock file" grep -qF "$idb/db.lck" <<<"$iout"
rm -f "$idb/db.lck"

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

# kill once pacman has ended (n at its prompt), as the copy is removed:
# nothing reads it any more, so on_exit removes it with sudo -n.
fresh 'testapp 1.0.0-1'
STUB_PACMAN_U=no STUB_SUDO_RM=TERM inst testapp
same "install, TERM once pacman has ended: the run ends" 143 "$irc"
calls "install, TERM once pacman has ended: removes the staged copy with sudo -n" "sudo -n rm -f -- $vstaged"
check "install, TERM once pacman has ended: no staged copy left" test ! -e "$vstaged"
check "install, TERM once pacman has ended: nothing recorded as left" test ! -e "$ileft/testapp"

# kill once the copy is staged, the terminal still open: the run ends there
# and then, and the staged copy goes all the same, through sudo -n.
fresh 'testapp 1.0.0-1'
STUB_SUDO_INSTALL=TERM inst testapp
same "install, TERM once the copy is staged: the run ends" 143 "$irc"
calls "install, TERM once the copy is staged: removes the staged copy with sudo -n" "sudo -n rm -f -- $vstaged"
check "install, TERM once the copy is staged: no staged copy left" test ! -e "$vstaged"
check "install, TERM once the copy is staged: nothing recorded as left" test ! -e "$ileft/testapp"
no_call "install, TERM once the copy is staged: pacman -U never runs" 'pacman -U'

# The terminal closing there: sudo -n finds no password then, and the
# message goes nowhere, so the copy is recorded for the next Update.
fresh 'testapp 1.0.0-1'
STUB_SUDO_INSTALL=HUP STUB_SUDO_N=fail inst testapp
same "install, the terminal closed once the copy is staged: the run ends" 129 "$irc"
calls "install, the terminal closed once the copy is staged: tries sudo -n" "sudo -n rm -f -- $vstaged"
check "install, the terminal closed once the copy is staged, sudo -n refused: the copy is there" test -e "$vstaged"
same "install, the terminal closed once the copy is staged, sudo -n refused: and recorded" "$vstaged" "$(cat "$ileft/testapp" 2>&1)"
says "install, the terminal closed once the copy is staged, sudo -n refused: the message names the copy and how to remove it" \
  "omabump: the staged copy stays in $vstaged; remove it with: sudo rm -f -- $vstaged (the next Update of Test App removes it too)"

# kill while sudo asks for its password, before the copy is there: sudo,
# not signalled, writes it once you answer, after the run has ended. There
# is nothing for sudo -n to remove yet, so the copy is recorded.
fresh 'testapp 1.0.0-1'
STUB_SUDO_ASKS=TERM inst testapp
same "install, TERM while sudo asks: the run ends" 143 "$irc"
no_call "install, TERM while sudo asks: no sudo -n rm on a copy not there yet" 'sudo -n'
check "install, TERM while sudo asks: sudo writes the copy after the run" test -e "$vstaged"
same "install, TERM while sudo asks: the copy is recorded" "$vstaged" "$(cat "$ileft/testapp" 2>&1)"
says "install, TERM while sudo asks: the message names the copy and how to remove it once sudo has ended" \
  "omabump: sudo was still copying the package to $vstaged, so the copy may appear there; once sudo has ended, remove it with: sudo rm -f -- $vstaged (the next Update of Test App removes it too)"

# kill at pacman's prompt: the run ends there and then, but pacman, a
# process of its own under sudo, goes on and may still install the copy.
# It is left to pacman, and recorded for the next Update.
fresh 'testapp 1.0.0-1'
STUB_PACMAN_U=TERM inst testapp
same "install, TERM at pacman's prompt: the run ends" 143 "$irc"
no_call "install, TERM at pacman's prompt: no sudo -n rm under pacman" 'sudo -n'
calls "install, TERM at pacman's prompt: pacman still has the copy once the installer has ended" \
  "pacman -U: $vstaged still there after the installer ended"
same "install, TERM at pacman's prompt: the copy is recorded" "$vstaged" "$(cat "$ileft/testapp" 2>&1)"
says "install, TERM at pacman's prompt: the message names the copy and how to remove it once pacman has ended" \
  "omabump: pacman may still be reading the staged copy, so it stays in $vstaged; once pacman has ended, remove it with: sudo rm -f -- $vstaged (the next Update of Test App removes it too)"
same "install, TERM at pacman's prompt: nothing installed" 'testapp 1.0.0-1' "$(<"$idb/installed")"
says "install, TERM at pacman's prompt: the download stays, and the message says so" \
  "omabump: the build and download files stay in $it/cache/omabump/{build,packages,sources}"

# The terminal closing at the prompt: the same, sudo -n or not.
fresh 'testapp 1.0.0-1'
STUB_PACMAN_U=HUP inst testapp
same "install, the terminal closed at pacman's prompt: the run ends" 129 "$irc"
no_call "install, the terminal closed at pacman's prompt: no sudo -n rm under pacman" 'sudo -n'
calls "install, the terminal closed at pacman's prompt: pacman still has the copy once the installer has ended" \
  "pacman -U: $vstaged still there after the installer ended"
same "install, the terminal closed at pacman's prompt: the copy is recorded" "$vstaged" "$(cat "$ileft/testapp" 2>&1)"

# The next Update while a pacman runs (its lock file is there), here one
# with nothing newer to install: the copy stays, recorded.
: >"$idb/db.lck"
: >"$ilog/calls"
printf '%s\n' 'testapp 2.0.0-1' >"$idb/installed"
inst testapp
says "install, while pacman runs: a recorded copy stays, and the message says why" \
  "omabump: pacman's lock file $idb/db.lck is there, so a pacman may be reading the staged copy a stopped run left; it stays in $vstaged. Once pacman has ended, remove it with: sudo rm -f -- $vstaged (the next Update of Test App removes it too)"
no_call "install, while pacman runs: no sudo" 'sudo '
check "install, while pacman runs: the copy is there" test -e "$vstaged"
same "install, while pacman runs: and still recorded" "$vstaged" "$(cat "$ileft/testapp" 2>&1)"

# Nor does one with a newer version to install stage over that copy (and
# then remove it): nothing is staged while pacman's lock file is there.
printf '%s\n' 'testapp 1.0.0-1' >"$idb/installed"
cp "$vstaged" "$it/held"
: >"$ilog/calls"
STUB_PACMAN_U=ok inst testapp
same "install, while pacman runs, a newer version: a failure" 1 "$irc"
says "install, while pacman runs, a newer version: says why" \
  "omabump: pacman's lock file $idb/db.lck is there: a pacman is running, or one ended without removing it. Not staging $vstaged; run Update again once no pacman runs (if none does, the lock file is stale: sudo rm $idb/db.lck)"
no_call "install, while pacman runs, a newer version: nothing staged" 'sudo install'
no_call "install, while pacman runs, a newer version: nothing removed" 'rm -f --'
same "install, while pacman runs, a newer version: the copy pacman may read is untouched" \
  "$(sha256sum <"$it/held")" "$(sha256sum <"$vstaged" 2>&1)"
same "install, while pacman runs, a newer version: and still recorded" "$vstaged" "$(cat "$ileft/testapp" 2>&1)"
same "install, while pacman runs, a newer version: nothing installed" 'testapp 1.0.0-1' "$(<"$idb/installed")"
inst --prepare testapp
says "install --prepare, while pacman runs: says it would refuse" \
  "Would refuse while pacman's lock file $idb/db.lck is there: a pacman is running, or one ended without removing it"
rm -f "$idb/db.lck" "$it/held"

# The next Update, in a terminal, pacman gone: the copy goes first.
inst --prepare testapp
same "install --prepare: names the recorded copy it would remove, once" 1 \
  "$(grep -cF "Would run: sudo rm -f -- $vstaged (the staged copy a stopped run left)" <<<"$iout")"
no_call "install --prepare: without sudo" 'sudo rm'
check "install --prepare: the record stays" test -f "$ileft/testapp"
: >"$ilog/calls"
STUB_PACMAN_U=no inst testapp
same "install, after a stopped run: its copy is removed first" "sudo rm -f -- $vstaged" "$(grep -m1 '^sudo ' "$ilog/calls")"
says "install, after a stopped run: and says so" "Removed the staged copy a stopped run left: $vstaged"
check "install, after a stopped run: the record goes" test ! -e "$ileft/testapp"
check "install, after a stopped run: no staged copy left" test ! -e "$vstaged"

# Before anything else the route does: an Update that finds nothing newer
# to install, so stages nothing, removes the copy all the same, before it
# reads the feed.
fresh 'testapp 2.0.0-1'
mkdir -p "$ileft" "$istaging"
: >"$vstaged"
printf '%s\n' "$vstaged" >"$ileft/testapp"
inst testapp
says "install, nothing newer: says so" 'Test App 2.0.0-1 is already installed; nothing to do.'
same "install, nothing newer: a recorded copy is removed before the feed is read" "sudo rm -f -- $vstaged" \
  "$(grep -m1 -e '^sudo ' -e '^curl ' "$ilog/calls")"
check "install, nothing newer: the copy is gone" test ! -e "$vstaged"
check "install, nothing newer: and so is the record" test ! -e "$ileft/testapp"

# Nothing newer in the feed, after a check that saw 1.0.0-1 and showed
# 2.0.0, which something else installed since (omarchy update, here): Update
# has nothing left to do, a success, and the panel's refresh clears the row.
fresh 'testapp 2.0.0-1'
shown testapp 2.0.0 1.0.0-1
inst testapp
same "install (vendor), the version the panel showed installed since: a success" 0 "$irc"
says "install (vendor), the version the panel showed installed since: says so" 'Test App 2.0.0-1 is already installed; nothing to do.'
calls "install (vendor), the version the panel showed installed since: refreshes the panel" 'omabump-check --no-notify --wait'
no_call "install (vendor), the version the panel showed installed since: downloads nothing" "$vpkg"
no_call "install (vendor), the version the panel showed installed since: stages nothing" 'sudo '
: >"$ilog/calls"
inst --prepare testapp
same "install --prepare (vendor), the version the panel showed installed: succeeds" 0 "$irc"
says "install --prepare (vendor), the version the panel showed installed: says what a run would say" \
  'Would say: Test App 2.0.0-1 is already installed; nothing to do.'
says "install --prepare (vendor), the version the panel showed installed: and that it would refresh the panel" \
  "/omabump-check --no-notify --wait (the panel's refresh)"
no_call "install --prepare (vendor), the version the panel showed installed: without refreshing it" 'omabump-check'
# The feed lists no checksum for the package now: nothing is downloaded,
# so that cannot fail the Update either.
cp "$iserved/latest.yml" "$it/latest.yml"
printf 'version: 2.0.0\nfiles:\n  - url: https://example.invalid/%s\n' "$vpkg" >"$iserved/latest.yml"
fresh 'testapp 2.0.0-1'
shown testapp 2.0.0 1.0.0-1
inst testapp
same "install (vendor), the version the panel showed installed, no checksum published: a success" 0 "$irc"
says "install (vendor), the version the panel showed installed, no checksum published: says so" \
  'Test App 2.0.0-1 is already installed; nothing to do.'
calls "install (vendor), the version the panel showed installed, no checksum published: refreshes the panel" \
  'omabump-check --no-notify --wait'
no_call "install (vendor), the version the panel showed installed, no checksum published: downloads nothing" "$vpkg"
mv "$it/latest.yml" "$iserved/latest.yml"

# Past the version the panel showed, by a newer release or a pkgrel: done
# too, and never a downgrade to the feed's.
fresh 'testapp 2.0.1-1'
shown testapp 2.0.0 1.0.0-1
inst testapp
same "install (vendor), past the version the panel showed: a success" 0 "$irc"
says "install (vendor), past the version the panel showed: says so" 'Test App 2.0.1-1 is already installed; nothing to do.'
no_call "install (vendor), past the version the panel showed: downloads nothing" "$vpkg"
fresh 'testapp 2.0.0-2'
shown testapp 2.0.0 1.0.0-1
inst testapp
same "install (vendor), the version the panel showed at a newer pkgrel: a success" 0 "$irc"

# No check to go by: a status.json that is not JSON, or one without this
# app's row. The feed's newest is installed, so there is nothing to do.
fresh 'testapp 2.0.0-1'
mkdir -p "${istatus%/*}" && printf 'not json' >"$istatus"
inst testapp
same "install (vendor), nothing newer, status.json unreadable: a success" 0 "$irc"
says "install (vendor), nothing newer, status.json unreadable: says so" 'Test App 2.0.0-1 is already installed; nothing to do.'
shown testpkg 3.0.0 1.0.0-1
inst testapp
same "install (vendor), nothing newer, no row in status.json: a success" 0 "$irc"
# A status.json of another schemaVersion is none either, whatever its row
# says (here: a newer version than the feed's).
shown testapp 2.1.0 2.0.0-1
jq '.schemaVersion = 2' "$istatus" >"$istatus.new" && mv "$istatus.new" "$istatus"
inst testapp
same "install (vendor), nothing newer, status.json of another schemaVersion: a success" 0 "$irc"

# The feed gives less than the panel showed (the vendor pulled 2.1.0):
# Update cannot install it, and says which two versions it found.
fresh 'testapp 2.0.0-1'
shown testapp 2.1.0 2.0.0-1
inst testapp
same "install (vendor), the feed behind the panel: a failure" 1 "$irc"
says "install (vendor), the feed behind the panel: names both versions" \
  "omabump: the vendor's feed gives 2.0.0 now, not the 2.1.0 it gave at the last check; Update cannot install it yet."
no_call "install (vendor), the feed behind the panel: no panel refresh" 'omabump-check'
no_call "install (vendor), the feed behind the panel: downloads nothing" "$vpkg"
inst --prepare testapp
same "install --prepare (vendor), the feed behind the panel: succeeds" 0 "$irc"
says "install --prepare (vendor), the feed behind the panel: says it would refuse" \
  "Would refuse: the vendor's feed gives 2.0.0 now, not the 2.1.0 it gave at the last check; Update cannot install it yet."

# Right after the app's lock is taken: an Update that stops before its
# route (here a --switch with nothing to switch) removes the copy too.
fresh 'testapp 1.0.0-1'
mkdir -p "$ileft" "$istaging"
: >"$vstaged"
printf '%s\n' "$vstaged" >"$ileft/testapp"
inst --switch testapp
says "install, a refused --switch: says why" 'Test App is not installed under another name; nothing to switch'
calls "install, a refused --switch: a recorded copy is removed all the same" "sudo rm -f -- $vstaged"
check "install, a refused --switch: the copy is gone" test ! -e "$vstaged"
check "install, a refused --switch: and so is the record" test ! -e "$ileft/testapp"
inst --prepare --switch testapp
same "install --prepare, a refused --switch: says it would refuse" \
  '0|Would refuse: Test App is not installed under another name; nothing to switch' "$irc|$(grep -F 'Would refuse' <<<"$iout")"

# The record is a file of yours: only a file name in the staging directory
# reaches sudo rm.
fresh 'testapp 1.0.0-1'
mkdir -p "$ileft" "$istaging"
: >"$it/victim"
printf '%s\n' "$it/victim" "$istaging/../victim" "$istaging/.." >"$ileft/testapp"
STUB_PACMAN_U=no inst testapp
no_call "install, a record naming files outside the staging directory: never passed to sudo" 'victim'
no_call "install, a record naming the staging directory's parent: never passed to sudo" "rm -f -- $istaging/.."
check "install, a record naming files outside the staging directory: they stay" test -e "$it/victim"
check "install, a record naming files outside the staging directory: the record goes" test ! -e "$ileft/testapp"
rm -f "$it/victim"

fresh 'testapp 1.0.0-1'
STUB_PACMAN_U=hookfail inst testapp
same "install, a hook fails after pacman installed: a success" 0 "$irc"
says "install, a hook fails after pacman installed: with a warning" 'warning: pacman reported an error, but testapp 2.0.0-1 is installed'
says "install, a hook fails after pacman installed: the install is checked" 'Installed testapp 2.0.0-1.'
check "install, a hook fails after pacman installed: no staged copy left" test ! -e "$vstaged"
calls "install, a hook fails after pacman installed: the panel is refreshed" 'omabump-check --no-notify --wait'

# Files that keep the IDs of the machine that packed them: on this one those
# can be another account. The download is refused before sudo, and by
# --prepare; root's group and the fixed groups Arch uses pass.
vowned() {
  pkg_owner=$1 install_text='post_install() { echo hello; }' make_pkg "$iserved/$vpkg" 'pkgname = testapp' 'pkgver = 2.0.0-1' 'conflict = testapp-bin'
  printf 'version: 2.0.0\nfiles:\n  - url: https://example.invalid/%s\n    sha512: %s\n' "$vpkg" "$(sha512_b64 "$iserved/$vpkg")" >"$iserved/latest.yml"
  rm -f "$vcached"
  fresh 'testapp 1.0.0-1'
}
vowned 1001:1001
STUB_PACMAN_U=ok inst testapp
same "install (vendor), files owned by uid 1001: refused" 1 "$irc"
says "install (vendor), files owned by uid 1001: names the package" \
  'omabump: testapp 2.0.0-1 has files that pacman would install with an owner other than root:'
says "install (vendor), files owned by uid 1001: and the files, with their owner" '  1001:1001 .PKGINFO'
says "install (vendor), files owned by uid 1001: says why" 'On this machine those IDs can belong to another account'
says "install (vendor), files owned by uid 1001: names where the download stays" "the download stays in $vcached"
no_call "install (vendor), files owned by uid 1001: before sudo" 'sudo '
check "install (vendor), files owned by uid 1001: no staged copy" test ! -e "$vstaged"
check "install (vendor), files owned by uid 1001: the download stays" test -f "$vcached"
same "install (vendor), files owned by uid 1001: nothing installed" 'testapp 1.0.0-1' "$(<"$idb/installed")"
inst --prepare testapp
same "install --prepare (vendor), files owned by uid 1001: succeeds" 0 "$irc"
says "install --prepare (vendor), files owned by uid 1001: says it would refuse" \
  'Would refuse: testapp 2.0.0-1 has files that pacman would install with an owner other than root:'
refuse "install --prepare (vendor), files owned by uid 1001: and stops there, as the run would" grep -qF 'Would run: sudo' <<<"$iout"
vowned 0:1001
STUB_PACMAN_U=ok inst testapp
same "install (vendor), root's files in group 1001: refused" 1 "$irc"
says "install (vendor), root's files in group 1001: names them" '  0:1001 .PKGINFO'
vowned 0:50
STUB_PACMAN_U=ok inst testapp
same "install (vendor), root's files in group games (50): installed" 0 "$irc"
vowned 0:0

fresh 'testapp 1.0.0-1'
STUB_PACMAN_U=ok inst testapp
same "install (vendor): a success" 0 "$irc"
says "install (vendor): the staged copy is checked" "Staged copy checked: $vstaged"
same "install (vendor): pacman has the new version" 'testapp 2.0.0-1' "$(<"$idb/installed")"
check "install (vendor): no staged copy left" test ! -e "$vstaged"
check "install (vendor): the package file is cleaned up" test ! -e "$vcached"
says "install (vendor): restart to use it" 'Restart Test App to use 2.0.0-1.'
same "install (vendor): no word of files that stay" '' "$(grep -F 'the build and download files stay' <<<"$iout")"

# A link the vendor's install script made in /usr/bin, owned by no package,
# to a file of the package: it goes, or pacman refuses the same-named AUR
# package that ships that path. A link a package owns, or one to another
# package's file, stays.
itarget=$it/opt/testapp/testapp
mkdir -p "${itarget%/*}" && : >"$itarget" && itarget=$(readlink -f "$itarget")
orphan() { fresh 'testapp 1.0.0-1'; ln -sfn "$itarget" "$ibin/testapp"; printf '%s\n' "$@" >"$idb/files"; }
orphan "$itarget"$'\t'testapp
inst --prepare testapp
says "install --prepare (vendor): names the orphan link it would remove" \
  "Would run: sudo rm -f -- $ibin/testapp (a link to $itarget that no package owns)"
no_call "install --prepare (vendor), an orphan link: never calls sudo" 'sudo '
orphan "$itarget"$'\t'testapp
STUB_PACMAN_U=ok inst testapp
same "install (vendor), an orphan link: a success" 0 "$irc"
calls "install (vendor), an orphan link: removed with sudo rm" "sudo rm -f -- $ibin/testapp"
says "install (vendor), an orphan link: and says so" "Removed $ibin/testapp, a link to $itarget that no package owns"
check "install (vendor), an orphan link: gone" test ! -L "$ibin/testapp"
check "install (vendor), an orphan link: its target stays" test -f "$itarget"
orphan "$itarget"$'\t'testapp "$ibin/testapp"$'\t'testapp
STUB_PACMAN_U=ok inst testapp
no_call "install (vendor): a link a package owns stays" "rm -f -- $ibin/testapp"
orphan "$itarget"$'\t'other
STUB_PACMAN_U=ok inst testapp
no_call "install (vendor): a link to another package's file stays" "rm -f -- $ibin/testapp"
check "install (vendor): the links that stay are there" test -L "$ibin/testapp"
rm -rf "${ibin:?}/testapp" "$it/opt"
: >"$idb/files"

fresh 'testapp 1.0.0-1'
STUB_PACMAN_U=ok STUB_TAMPER=1 inst testapp
same "install (vendor): a staged copy that differs is a failure" 1 "$irc"
says "install (vendor): its digest is checked" 'sha512 of the staged copy is'
no_call "install (vendor): and pacman -U never runs" 'pacman -U'
check "install (vendor): the copy that failed its check stays, as the message says" test -f "$vstaged"
no_call "install (vendor): the exit does not remove it" 'rm -f --'

fresh 'testapp 1.0.0-1'
STUB_PACMAN_U=ok STUB_QP_FAIL=1 inst testapp
same "install (vendor): a staged copy pacman -Qp cannot read is a failure" 1 "$irc"
says "install (vendor): it is named as kept" "cannot read $vstaged; not installing (the copy stays there)"
no_call "install (vendor): pacman -U never runs on it" 'pacman -U'
check "install (vendor): the copy stays, as the message says" test -f "$vstaged"
no_call "install (vendor): the exit does not remove it either" 'rm -f --'
check "install (vendor): nor record it for the next Update" test ! -e "$ileft/testapp"
# A staged copy whose digest matches, but which pacman -Qp reads as another
# package or version, is not installed either.
for qp in 'testapp 2.0.0-2' 'other 2.0.0-1'; do
  fresh 'testapp 1.0.0-1'
  STUB_PACMAN_U=ok STUB_QP_STAGED=$qp inst testapp
  same "install (vendor): a staged copy with the right digest that pacman -Qp reads as '$qp': refused, kept" \
    "1|omabump: the staged copy is '$qp', expected 'testapp 2.0.0-1'; not installing (the copy stays in $vstaged)" \
    "$irc|$(grep -vF 'the build and download files stay' <<<"$iout" | tail -n1)"
  no_call "install (vendor), '$qp' staged: pacman -U never runs" 'pacman -U'
done

# The feed knows no epoch; the file's full version must still be newer.
fresh 'testapp 1:1.0.0-1'
STUB_PACMAN_U=ok inst testapp
says "install (vendor): guard_version refuses a file older than an installed epoch" \
  'vendor package: 2.0.0-1 is not newer than the installed testapp 1:1.0.0-1; not installing'
no_call "install (vendor): before anything is staged" 'sudo '
inst --prepare testapp
same "install --prepare (vendor): says it would refuse a file older than an installed epoch" \
  '0|Would refuse: vendor package: 2.0.0-1 is not newer than the installed testapp 1:1.0.0-1; not installing' \
  "$irc|$(grep -F 'Would refuse' <<<"$iout")"

fresh 'testapp-bin 2.0.0-1'
printf 'Name            : testapp-bin\nProvides        : None\nConflicts With  : None\n' >"$idb/qi/testapp-bin"
inst --prepare --switch testapp
same "install --prepare --switch (vendor): at the same version" 0 "$irc"
says "install --prepare --switch (vendor): the declared conflict" 'pacman will ask to remove testapp-bin for testapp (declared conflict)'
says "install --prepare --switch (vendor): the package's install script" '--- testapp install script (.INSTALL), run as root:'
says "install --prepare --switch (vendor): the app's settings directory" 'Test App keeps its settings in ~/.config/TestApp.'
rm -f "$vcached"
# Switch installs the version installed under the other name, whatever the
# panel showed: the version is the same, the package is not.
shown testapp 2.0.0 2.0.0-1
STUB_PACMAN_U=ok inst --switch testapp
same "install --switch (vendor): at the same version, a success" 0 "$irc"
same "install --switch (vendor): at the same version, pacman replaced the old package" 'testapp 2.0.0-1' "$(<"$idb/installed")"
refuse "install --switch (vendor): at the same version, not taken for 'already installed'" grep -qF 'already installed' <<<"$iout"
rm -f "$idb/qi/testapp-bin"

# --- the mise route --------------------------------------------------------------

# An outdated entry that is not an object, which mise_outdated_table keeps
# as {"odd": true}, is the error the check shows, not "newest" or "held".
fresh
STUB_MISE_OUTDATED='{"testtool": "1.1.0"}' inst mise:testtool
same "install (mise): an outdated entry that is not an object is a failure" 1 "$irc"
says "install (mise): worded as the check words it" 'mise outdated gave an entry for testtool that is not an object'
STUB_MISE_BUMP='{"testtool": ["1.1.0"]}' inst mise:testtool
same "install (mise): so is a --bump entry that is not an object" 1 "$irc"
says "install (mise): also worded as the check words it" 'mise outdated --bump gave an entry for testtool that is not an object'
no_call "install (mise): mise install never runs then" 'mise install'
STUB_MISE_OUTDATED='{"testtool": {"latest": "1.1.0"}}' STUB_MISE_BUMP='{"testtool": 5}' inst --prepare mise:testtool
says "install --prepare (mise): an update mise reaches does not read the --bump table" 'Would run: mise install -- testtool@1.1.0 (in '
no_call "install --prepare (mise): mise install never runs" 'mise install'

# The update itself: the version mise outdated found, installed as it is,
# through mise's versions host, never with its install counter, and with
# the tools you disabled left alone. Not the unused ones: mise install
# rewrites the shims of every tool not disabled, and an unused tool's shim
# is how Omarchy installs it on first use.
fresh
rm -f "$ilog/mise-version"
STUB_MISE_OUTDATED='{"testtool": {"latest": "1.1.0"}}' inst mise:testtool
same "install (mise): a success" 0 "$irc"
calls "install (mise): installs the version mise found" 'mise install -- testtool@1.1.0'
calls "install (mise): through the versions host, no install counter, your disabled tools left alone" 'env true false mine'
refuse "install (mise): the unused tools keep their shims" grep -qF 'unused-tool' <(grep '^env ' "$ilog/calls")
calls "install (mise): while the check's mise outdated leaves them alone" 'mise outdated --json -- testtool'
says "install (mise): and says the tool is at it" 'Test Tool is now 1.1.0.'
refuse "install (mise): mise up never runs" grep -qF 'mise up' "$ilog/calls"
# You turned mise's versions host off: Update does not turn it on.
fresh
rm -f "$ilog/mise-version"
STUB_MISE_HOST=false STUB_MISE_OUTDATED='{"testtool": {"latest": "1.1.0"}}' inst mise:testtool
calls "install (mise): with the versions host off in your settings, without it" 'env false false mine'
# A lockfile keeps the request on the old version: mise up, which rewrites
# it, then runs as before.
fresh
rm -f "$ilog/mise-version"
STUB_MISE_LOCKED=1 STUB_MISE_UP=1.1.0 STUB_MISE_OUTDATED='{"testtool": {"latest": "1.1.0"}}' inst mise:testtool
same "install (mise): installed but not active: mise up after it, and then a success" '0|mise up -- testtool' \
  "$irc|$(grep -o 'mise up -- testtool' "$ilog/calls")"
says "install (mise): says why it runs mise up" 'Test Tool is 1.0.0 after mise install; running mise up -- testtool, which also updates a lockfile.'
says "install (mise): and that the tool is then at it" 'Test Tool is now 1.1.0.'
rm -f "$ilog/mise-version"
STUB_MISE_LOCKED=1 STUB_MISE_OUTDATED='{"testtool": {"latest": "1.1.0"}}' inst mise:testtool
same "install (mise): still not active after mise up: fails" 1 "$irc"
rm -f "$ilog/mise-version"
STUB_MISE_LOCKED=1 STUB_MISE_UP=1.2.0 STUB_MISE_OUTDATED='{"testtool": {"latest": "1.1.0"}}' inst mise:testtool
same "install (mise): mise up reaches a release past the one outdated named: a success" 0 "$irc"
says "install (mise): and says which" 'Test Tool is now 1.2.0: mise up found a release past 1.1.0.'
rm -f "$ilog/mise-version"
STUB_MISE_LOCKED=1 STUB_MISE_OUTDATED='{"testtool": {"latest": "1.1.0"}}' inst mise:testtool
says "install (mise): still not active after mise up: says so" 'Test Tool is 1.0.0 after mise up, expected 1.1.0. See mise ls testtool.'
rm -f "$ilog/mise-version"
fresh
rm -f "$ilog/mise-version"
STUB_MISE_OUTDATED='{"testtool": {"latest": "1.1.0 --force"}}' inst mise:testtool
same "install (mise): an odd version from mise is not installed" "1|" "$irc|$(grep -F 'mise install' "$ilog/calls")"

# Nothing newer for mise up, nothing held back: what is installed is the
# newest mise knows. Compared with the panel's row as strings.
fresh
inst mise:testtool
same "install (mise), nothing newer, no check yet: a success" 0 "$irc"
says "install (mise), nothing newer, no check yet: says so" 'Test Tool 1.0.0 is already installed; nothing to do.'
calls "install (mise), nothing newer, no check yet: refreshes the panel" 'omabump-check --no-notify --wait'
no_call "install (mise), nothing newer, no check yet: mise install never runs" 'mise install'
# Omarchy's wrapper updated the tool on launch, after a check that saw
# 0.9.0: to the version the panel showed, or past it.
fresh
shown mise:testtool 1.0.0 0.9.0
inst mise:testtool
same "install (mise), the version the panel showed installed since: a success" 0 "$irc"
says "install (mise), the version the panel showed installed since: says so" 'Test Tool 1.0.0 is already installed; nothing to do.'
calls "install (mise), the version the panel showed installed since: refreshes the panel" 'omabump-check --no-notify --wait'
fresh
shown mise:testtool 0.9.5 0.9.0
inst mise:testtool
same "install (mise), moved past the version the panel showed: a success" 0 "$irc"
# A check whose mise fetch failed keeps the last latest next to the version
# installed then, and offers no update: the panel promised nothing.
fresh
shown mise:testtool 0.9.5 1.0.0 false
inst mise:testtool
same "install (mise), a row that offered no update: a success" 0 "$irc"
says "install (mise), a row that offered no update: says so" 'Test Tool 1.0.0 is already installed; nothing to do.'
# The check saw 1.0.0 and mise offered 1.1.0, which mise up no longer
# reaches: Update cannot install it.
fresh
shown mise:testtool 1.1.0 1.0.0
inst mise:testtool
same "install (mise), mise up behind the panel: a failure" 1 "$irc"
says "install (mise), mise up behind the panel: names both versions" \
  'omabump: mise keeps Test Tool at 1.0.0, not the 1.1.0 mise showed at the last check; Update cannot install it yet.'
no_call "install (mise), mise up behind the panel: no panel refresh" 'omabump-check'
inst --prepare mise:testtool
same "install --prepare (mise), mise up behind the panel: succeeds" 0 "$irc"
says "install --prepare (mise), mise up behind the panel: says it would refuse" \
  'Would refuse: mise keeps Test Tool at 1.0.0, not the 1.1.0 mise showed at the last check'
no_call "install --prepare (mise), mise behind the panel: mise install never runs" 'mise install'

# --- functions, sourced ---------------------------------------------------------------

fresh 'testapp 1.0.0-1'
inst_src 'installed_name=testapp switch=0; guard_version 2.0.0-1 && echo newer; guard_version 1.0.0-1 || true'
same "guard_version: Update needs a newer full version" $'newer\n1.0.0-1 is not newer than the installed testapp 1.0.0-1' "$iout"
inst_src 'installed_name=testapp switch=1; guard_version 1.0.0-1 && echo same; guard_version 1:0.9-1 && echo epoch; guard_version 0.9-1 || true'
same "guard_version: Switch takes the same or newer, epochs counted" \
  $'same\nepoch\n0.9-1 is older than the installed testapp 1.0.0-1' "$iout"

printf 'Name            : x\nProvides        : a=1  b>=2 c<3\nConflicts With  : None\n' >"$it/qi.txt"
# shellcheck disable=SC2016 # expanded by the child bash
T_QI=$it/qi.txt inst_src 'qi_names Provides <"$T_QI"; echo "[$(qi_names "Conflicts With" <"$T_QI")]"'
same "qi_names: names without version constraints, nothing for None" $'a\nb\nc\n[]' "$iout"

# switch_conflicts with testapp-bin installed: one of the two must name the
# other, or something the other provides.
fresh 'testapp-bin 1.0.0-1'
conflicts_with() {  # <the installed package's Provides> <its Conflicts With> <.PKGINFO lines...>
  printf 'Name            : testapp-bin\nProvides        : %s\nConflicts With  : %s\n' "$1" "$2" >"$idb/qi/testapp-bin"
  shift 2
  make_pkg "$it/new.pkg.tar" 'pkgname = testapp' 'pkgver = 2.0.0-1' "$@"
  # shellcheck disable=SC2016 # expanded by the child bash
  T_PKG=$it/new.pkg.tar inst_src 'pkg=testapp installed_name=testapp-bin rc=0; switch_conflicts "$T_PKG" || rc=$?; echo "$rc"'
  echo "$iout"
}
same "switch_conflicts: the new package conflicts with the old name" 0 "$(conflicts_with None None 'conflict = testapp-bin')"
same "switch_conflicts: with something the old one provides" 0 "$(conflicts_with 'oldapi=1' None 'conflict = oldapi')"
same "switch_conflicts: the old package conflicts with the new name" 0 "$(conflicts_with None 'testapp<3' 'provides = x')"
same "switch_conflicts: with something the new one provides" 0 "$(conflicts_with None newapi 'provides = newapi=2')"
same "switch_conflicts: no conflict either way" 1 "$(conflicts_with 'testapp-bin' 'other' 'conflict = other' 'provides = more')"
printf 'not a package' >"$it/new.pkg.tar"
# shellcheck disable=SC2016 # expanded by the child bash
T_PKG=$it/new.pkg.tar inst_src 'pkg=testapp installed_name=testapp-bin rc=0; switch_conflicts "$T_PKG" || rc=$?; echo "$rc"'
same "switch_conflicts: a package pacman cannot read is not 'no conflict'" 2 "$iout"
rm -f "$it/new.pkg.tar" "$idb/qi/testapp-bin"

# foreign_owners: the entries a uid or gid other than root's breaks, the
# first 3 as "<uid>:<gid> <path>", then a count; 2 for a file bsdtar cannot list.
fo=$it/owners
rm -rf "$fo" && mkdir -p "$fo/d/opt/a b"
for fo_i in 1 2 3 4; do : >"$fo/d/opt/a b/f$fo_i"; done
: >"$fo/d/.PKGINFO" && : >"$fo/d/tty" && : >"$fo/d/ftp" && : >"$fo/d/games" && : >"$fo/d/x"$'\e'"[31m"
bsdtar -cf "$fo/ok.tar" --uid 0 --gid 0 -C "$fo/d" .PKGINFO
bsdtar -rf "$fo/ok.tar" --uid 0 --gid 5 -C "$fo/d" tty
bsdtar -rf "$fo/ok.tar" --uid 0 --gid 11 -C "$fo/d" ftp
bsdtar -rf "$fo/ok.tar" --uid 0 --gid 50 -C "$fo/d" games
cp "$fo/ok.tar" "$fo/bad.tar"
bsdtar -rf "$fo/bad.tar" -n --uid 1001 --gid 1001 -C "$fo/d" opt "opt/a b" "opt/a b/f1" "opt/a b/f2" "opt/a b/f3" "opt/a b/f4"
cp "$fo/ok.tar" "$fo/esc.tar"
bsdtar -rf "$fo/esc.tar" --uid 1000 --gid 0 -C "$fo/d" "x"$'\e'"[31m"
printf 'not a package' >"$fo/junk.tar"
# shellcheck disable=SC2016 # expanded by the child bash
T_FO=$fo inst_src 'for f in ok bad esc junk; do rc=0; out=$(foreign_owners "$T_FO/$f.tar") || rc=$?; echo "$f $rc"; [[ -z $out ]] || printf "%s\n" "$out"; done'
same "foreign_owners: root, and groups root, tty, ftp and games pass; 3 others shown, then a count; escapes; junk" \
  $'ok 0\nbad 1\n1001:1001 opt/\n1001:1001 opt/a b/\n1001:1001 opt/a b/f1\nand 3 more\nesc 1\n1000:0 x\\033[31m\njunk 2' "$iout"
# A listing past what a pipe holds at once (bash sends a here-string that
# big through a temporary file) still reaches awk when no file can be
# written: the check fails closed, never open.
mkdir -p "$fo/big"
for fo_i in $(seq 3000); do : >"$fo/big/file-with-a-long-name-$fo_i"; done
bsdtar -cf "$fo/big.tar" --uid 1001 --gid 1001 -C "$fo" big
# shellcheck disable=SC2016 # expanded by the child bash
T_FO=$fo inst_src 'ulimit -S -f 8; rc=0; out=$(foreign_owners "$T_FO/big.tar") || rc=$?; echo "$rc"; tail -1 <<<"$out"'
same "foreign_owners: a listing of 3000 entries, with no file writable: still refused" $'1\nand 2998 more' "$iout"
rm -rf "$fo"

# Before a build, from the recipe: per-architecture fields count for this
# machine's architecture only, as in the package makepkg would build here.
fresh 'testpkg-bin 1.5.0-1'
recipe_conflicts() {  # <the installed package's Conflicts With> <one .SRCINFO line>
  printf 'Name            : testpkg-bin\nProvides        : None\nConflicts With  : %s\n' "$1" >"$idb/qi/testpkg-bin"
  # shellcheck disable=SC2016 # expanded by the child bash
  T_LINE=$2 inst_src 'pkg=testpkg installed_name=testpkg-bin; mkpkg() { printf "pkgbase = testpkg\n\t%s\n\npkgname = testpkg\n" "$T_LINE"; }
    rc=0; switch_conflicts "$HOME" || rc=$?; echo "$rc"'
  echo "$iout"
}
iarch=$(uname -m) iother=armv7h
[[ $iarch != "$iother" ]] || iother=x86_64
same "switch_conflicts: a recipe's plain conflicts" 0 "$(recipe_conflicts None 'conflicts = testpkg-bin')"
same "switch_conflicts: a recipe's conflicts_<this architecture>" 0 "$(recipe_conflicts None "conflicts_$iarch = testpkg-bin")"
same "switch_conflicts: not another architecture's" 1 "$(recipe_conflicts None "conflicts_$iother = testpkg-bin")"
same "switch_conflicts: a recipe's provides_<this architecture>, which the old package conflicts with" 0 \
  "$(recipe_conflicts newapi "provides_$iarch = newapi=2")"
rm -f "$idb/qi/testpkg-bin"

# --- Build now, on a local omarchy-pkgs clone --------------------------------------

# Build now runs only with buildAhead on: the section turns it on in the
# widget's settings and off again at its end.
ishell=$ihome/.config/omarchy/shell.json
printf '{"plugins": [{"id": "io.github.vladkarok.omabump", "buildAhead": true}]}\n' >"$ishell"

pk=$it/cache/omabump/omarchy-pkgs
igit() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@example.com \
  -c init.defaultBranch=main -c advice.detachedHead=false "$@" >/dev/null 2>&1; }
igit init -q "$pk"
igit -C "$pk" remote add origin https://github.com/omacom/omarchy-pkgs.git
mkdir -p "$pk/bin"
cat >"$pk/bin/sync-upstream" <<'EOF'
#!/bin/bash
# Moves the recipe to the release 2.0.0, and notes the token it was given.
sed -i "s/^pkgver=.*/pkgver=2.0.0/" "pkgbuilds/$1/PKGBUILD"
echo "${UPSTREAM_GITHUB_TOKEN-none}" >.git/test-sync-token
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
inst --prepare --build testpkg
same "install --prepare --switch (build): succeeds" 0 "$irc"
says "install --prepare --switch (build): the recipe moved to the release" 'Recipe builds testpkg 2.0.0-1'
says "install --prepare --switch (build): the conflict, read from the recipe" 'pacman will ask to remove testpkg-bin for testpkg (declared conflict)'
says "install --prepare --switch (build): an install=\$pkgname.install script is found and shown" \
  '--- testpkg install script (testpkg.install in the recipe), run as root:'
says "install --prepare --switch (build): with its text" 'testpkg recipe hook'
says "install --prepare (build): the staged copy is checked against the build's sha256" \
  "Would check: sha256sum of $ostaged is the one taken of $it/cache/omabump/packages/$opkg right after the build"
says "install --prepare (build): the staged copy goes whether pacman installed it or not" \
  "Would run: sudo rm -f -- $ostaged (whether pacman installed it or not)"
no_call "install --prepare (build): no build" ' -sfC'
no_call "install --prepare (build): no sudo" 'sudo '
same "install --prepare (build): the clone is left at the pinned recipe" 'pkgver=1.0.0' "$(grep '^pkgver=' "$pk/pkgbuilds/testpkg/PKGBUILD")"
# With a token omarchy-pkgs' sync tool swaps in a .curlrc of its own, without
# the HTTPS-only rule and the limits Update holds its downloads to.
fresh 'testpkg-bin 1.5.0-1'
UPSTREAM_GITHUB_TOKEN=ghp_test inst --prepare --build testpkg
same "install (build): UPSTREAM_GITHUB_TOKEN does not reach bin/sync-upstream" '0|none' "$irc|$(cat "$pk/.git/test-sync-token")"

fresh 'nocon-bin 1.0.0-1'
printf 'Name            : nocon-bin\nProvides        : None\nConflicts With  : None\n' >"$idb/qi/nocon-bin"
inst --build nocon
same "install (build): a switch without a declared conflict is refused" 1 "$irc"
says "install (build): and says why" 'neither nocon nor nocon-bin declares a conflict with the other'
no_call "install (build): before makepkg builds" ' -sfC'

fresh 'testpkg-bin 1.5.0-1'
STUB_PACMAN_U=ok STUB_TAMPER=1 inst --build testpkg
same "install (build): a staged copy that is not the built file is refused" 1 "$irc"
says "install (build): by the sha256 taken after the build" 'sha256 of the staged copy is'
no_call "install (build): pacman -U never runs then" 'pacman -U'

fresh 'testpkg-bin 1.5.0-1'
STUB_PACMAN_U=ok STUB_MAKEPKG_OWNER=1001:1001 inst --build testpkg
same "install (build), a build with files owned by uid 1001: refused" 1 "$irc"
says "install (build), a build with files owned by uid 1001: names the files" '  1001:1001 .PKGINFO'
says "install (build), a build with files owned by uid 1001: names where the package stays" \
  "the package stays in $it/cache/omabump/packages/$opkg"
no_call "install (build), a build with files owned by uid 1001: pacman -U never runs" 'pacman -U'
calls "install (build), a build with files owned by uid 1001: the staged copy is checked, then removed" "sudo rm -f -- $ostaged"
check "install (build), a build with files owned by uid 1001: no staged copy left" test ! -e "$ostaged"
rm -rf "$it/cache/omabump/packages/$opkg" "$it/cache/omabump/build/testpkg"

fresh 'testpkg-bin 1.5.0-1'
STUB_PACMAN_U=ok inst --build testpkg
same "install (build): a switch with a declared conflict installs" 0 "$irc"
calls "install (build): after the build" ' -sfC'
says "install (build): the built package's own install script is shown" '--- testpkg install script (.INSTALL), run as root:'
same "install (build): pacman replaced the old package" 'testpkg 2.0.0-1' "$(<"$idb/installed")"
check "install (build): no staged copy left" test ! -e "$ostaged"
check "install (build): the package file is cleaned up" test ! -e "$it/cache/omabump/packages/$opkg"
check "install (build): the build tree is cleaned up" test ! -e "$it/cache/omabump/build/testpkg"
says "install (build): restart to use it" 'Restart Test Pkg to use 2.0.0-1.'
same "install (build): no word of files that stay" '' "$(grep -F 'the build and download files stay' <<<"$iout")"

# The synced recipe reaches 2.0.0-1, which omarchy update installed after a
# check that saw 1.0.0-1 and showed 2.0.0: nothing left to do, a success.
# The panel's refresh runs once the clone is back at the pin and unlocked.
fresh 'testpkg 2.0.0-1'
shown testpkg 2.0.0 1.0.0-1
inst --build testpkg
same "install (build), the version the panel showed installed since: a success" 0 "$irc"
says "install (build), the version the panel showed installed since: says so" 'Test Pkg 2.0.0-1 is already installed; nothing to do.'
calls "install (build), the version the panel showed installed since: refreshes the panel" 'omabump-check --no-notify --wait'
no_call "install (build), the version the panel showed installed since: not under the clone's lock" 'omabump-check: the clone is locked'
no_call "install (build), the version the panel showed installed since: builds nothing" ' -sfC'
same "install (build), the version the panel showed installed since: the clone is back at the pinned recipe" \
  'pkgver=1.0.0' "$(grep '^pkgver=' "$pk/pkgbuilds/testpkg/PKGBUILD")"
: >"$ilog/calls"
inst --prepare --build testpkg
same "install --prepare (build), the version the panel showed installed: succeeds" 0 "$irc"
says "install --prepare (build), the version the panel showed installed: says what a run would say" \
  'Would say: Test Pkg 2.0.0-1 is already installed; nothing to do.'
no_call "install --prepare (build), the version the panel showed installed: without refreshing the panel" 'omabump-check'
refuse "install --prepare (build), the version the panel showed installed: and stops there, as the run would" \
  grep -qF -e 'Package file:' -e 'Would run: sudo pacman -U' <<<"$iout"
same "install --prepare (build), the version the panel showed installed: the clone is back at the pinned recipe" \
  'pkgver=1.0.0' "$(grep '^pkgver=' "$pk/pkgbuilds/testpkg/PKGBUILD")"

# Installed past the recipe: done, and guard_version still never builds the
# older recipe.
fresh 'testpkg 2.1.0-1'
shown testpkg 2.1.0 2.0.0-1
inst --build testpkg
same "install (build), installed past the recipe: a success" 0 "$irc"
says "install (build), installed past the recipe: says so" 'Test Pkg 2.1.0-1 is already installed; nothing to do.'
no_call "install (build), installed past the recipe: no downgrade built" ' -sfC'
same "install (build), installed past the recipe: nothing installed" 'testpkg 2.1.0-1' "$(<"$idb/installed")"

# The panel showed 2.1.0 from the vendor's feed, and omarchy-pkgs' recipe
# syncs only to 2.0.0, which is installed: Update cannot reach 2.1.0 yet.
fresh 'testpkg 2.0.0-1'
shown testpkg 2.1.0 2.0.0-1
inst --build testpkg
same "install (build), the recipe behind the panel: a failure" 1 "$irc"
says "install (build), the recipe behind the panel: names both versions" \
  "omabump: omarchy-pkgs' recipe reaches 2.0.0-1, not the 2.1.0 the vendor's feed shows; Build now cannot install it yet."
no_call "install (build), the recipe behind the panel: no panel refresh" 'omabump-check'
no_call "install (build), the recipe behind the panel: builds nothing" ' -sfC'
same "install (build), the recipe behind the panel: the clone is back at the pinned recipe" \
  'pkgver=1.0.0' "$(grep '^pkgver=' "$pk/pkgbuilds/testpkg/PKGBUILD")"
inst --prepare --build testpkg
same "install --prepare (build), the recipe behind the panel: succeeds" 0 "$irc"
says "install --prepare (build), the recipe behind the panel: says it would refuse" \
  "Would refuse: omarchy-pkgs' recipe reaches 2.0.0-1, not the 2.1.0 the vendor's feed shows; Build now cannot install it yet."
refuse "install --prepare (build), the recipe behind the panel: and stops there, as the run would" \
  grep -qF -e 'Package file:' -e 'Would run: sudo pacman -U' <<<"$iout"

# An epoch installed keeps the recipe, which reaches the version the panel
# showed, from being newer: Update says that, not that the recipe is behind.
fresh 'testpkg 1:1.0.0-1'
shown testpkg 2.0.0 1:1.0.0-1
inst --build testpkg
same "install (build), an epoch installed: a failure" 1 "$irc"
says "install (build), an epoch installed: names the epoch's version" \
  'omabump: 2.0.0-1 is not newer than the installed testpkg 1:1.0.0-1; nothing to do'
refuse "install (build), an epoch installed: not as a recipe behind the panel" grep -qF 'not the 2.0.0' <<<"$iout"
no_call "install (build), an epoch installed: builds nothing" ' -sfC'
inst --prepare --build testpkg
says "install --prepare (build), an epoch installed: says it would refuse" \
  'Would refuse: 2.0.0-1 is not newer than the installed testpkg 1:1.0.0-1; nothing to do'

# omarchy update installed the version while makepkg built it: the build
# has nothing left to install, and goes with its files.
fresh 'testpkg 1.0.0-1'
shown testpkg 2.0.0 1.0.0-1
STUB_MAKEPKG_INSTALLS='testpkg 2.0.0-1' inst --build testpkg
same "install (build), the version installed during the build: a success" 0 "$irc"
calls "install (build), the version installed during the build: after the build" ' -sfC'
says "install (build), the version installed during the build: says so" 'Test Pkg 2.0.0-1 is already installed; nothing to do.'
no_call "install (build), the version installed during the build: stages nothing" 'sudo '
calls "install (build), the version installed during the build: refreshes the panel" 'omabump-check --no-notify --wait'
no_call "install (build), the version installed during the build: not under the clone's lock" 'omabump-check: the clone is locked'
check "install (build), the version installed during the build: the package file goes" test ! -e "$it/cache/omabump/packages/$opkg"
check "install (build), the version installed during the build: and the build tree" test ! -e "$it/cache/omabump/build/testpkg"
same "install (build), the version installed during the build: no word of files that stay" '' \
  "$(grep -F 'the build and download files stay' <<<"$iout")"
same "install (build), the version installed during the build: the clone is back at the pinned recipe" \
  'pkgver=1.0.0' "$(grep '^pkgver=' "$pk/pkgbuilds/testpkg/PKGBUILD")"
# Short of the version the panel showed, the run still stops before pacman,
# and keeps the build for a look.
fresh 'testpkg 1.0.0-1'
shown testpkg 2.1.0 1.0.0-1
STUB_MAKEPKG_INSTALLS='testpkg 2.0.0-1' inst --build testpkg
same "install (build), installed during the build, short of the panel: a failure" 1 "$irc"
says "install (build), installed during the build, short of the panel: says why" \
  'omabump: 2.0.0-1 is not newer than the installed testpkg 2.0.0-1; not installing'
says "install (build), installed during the build, short of the panel: the build files stay" \
  "omabump: the build and download files stay in $it/cache/omabump/{build,packages,sources}"
no_call "install (build), installed during the build, short of the panel: no panel refresh" 'omabump-check'
rm -rf "$it/cache/omabump/packages/$opkg" "$it/cache/omabump/build/testpkg"

# Build now never switches at the same version: Switch is the repo's
# package's.
fresh 'testpkg-bin 2.0.0-1'
STUB_PACMAN_U=ok inst --switch --build testpkg
same "install --switch --build: refused, nothing built" "1|omabump: --switch and --build do not go together: Build now replaces a package installed under another name itself, as Update does" \
  "$irc|$(tail -1 <<<"$iout")"
no_call "install --switch --build: no sync, no build" 'makepkg'
rm -f "$idb/qi/testpkg-bin"

# Build now while buildAhead is off: refused, saying how to turn it on, and
# nothing of omarchy-pkgs runs.
printf '{"plugins": [{"id": "io.github.vladkarok.omabump", "buildAhead": "false"}]}\n' >"$ishell"
for args in '--build testpkg' '--prepare --build testpkg'; do
  fresh 'testpkg 1.0.0-1'
  rm -f "$pk/.git/test-sync-token"
  # shellcheck disable=SC2086 # the arguments, split on purpose
  inst $args
  rc=1 refusal='omabump: '
  [[ $args != --prepare* ]] || rc=0 refusal='Would refuse: '
  same "install $args, buildAhead off: refused" "$rc" "$irc"
  says "install $args, buildAhead off: says what Build now does and how to turn it on" \
    "${refusal}Build now is off. It builds Test Pkg on this machine from Omarchy's own recipe, before Omarchy's repo has the release: it takes minutes, runs Omarchy's build recipe as you, and the package is not signed by Omarchy. Turn it on with: omarchy bar set io.github.vladkarok.omabump buildAhead true --json (or in the Omabump panel's settings)"
  no_call "install $args, buildAhead off: nothing built" 'makepkg'
  check "install $args, buildAhead off: bin/sync-upstream never ran" test ! -e "$pk/.git/test-sync-token"
done
printf '{"plugins": [{"id": "io.github.vladkarok.omabump", "buildAhead": true}]}\n' >"$ishell"
# An entry Build now may not build: refused before anything runs.
fresh 'rpapp 1.0.0-1'
inst --build rpapp
same "install --build, an entry without build: refused" \
  "1|omabump: Build now is not available for Rp App: Omabump does not build its recipe (its apps.json entry has no \"build\": true). Update installs it once Omarchy's repo has it" \
  "$irc|$(tail -1 <<<"$iout")"
# The repo has the release: Build now sends you to Update.
mkdir -p "$iserved"
make_pkg "$iserved/testpkg-2.0.0-1-$(uname -m).pkg.tar.zst" "pkgname = testpkg" "pkgver = 2.0.0-1"
repo_db "$iserved/omarchy.db" "testpkg 2.0.0-1 testpkg-2.0.0-1-$(uname -m).pkg.tar.zst"
fresh 'testpkg 1.0.0-1'
inst_env+=(STUB_REPO_SERVER=https://pkgs.example/edge/x86_64)
inst --build testpkg
inst_env=("${inst_env[@]:0:${#inst_env[@]}-1}")
same "install --build, the repo has a newer package: refused, use Update" \
  "1|omabump: Omarchy's repo has testpkg 2.0.0-1, newer than the installed 1.0.0-1, and the vendor's newest release is not known; use Update instead, which installs its signed package" \
  "$irc|$(tail -1 <<<"$iout")"
no_call "install --build, the repo has it: nothing built" 'makepkg'
rm -f "$iserved/omarchy.db" "$iserved/testpkg-2.0.0-1-$(uname -m).pkg.tar.zst"
rm -f "$ishell"

# --- the repo route: Omarchy's signed package -----------------------------------------

# Omarchy's repo at rp_server (the pacman-conf stub's, with
# STUB_REPO_SERVER set: rp_inst), its database and packages served by the
# curl stub. rp_pkg <name> <full version> [<.PKGINFO version>] makes the
# package file the database will name and its good signature; rp_db
# <entries...> the database, each "<name> <version> [<sha256>]" for a file
# rp_pkg made, its sha256 the file's own unless given.
rp_server=https://pkgs.example/edge/x86_64 rp_arch=$(uname -m)
rp_file() { echo "$1-$2-$rp_arch.pkg.tar.zst"; }
rp_pkg() {
  local file
  file=$(rp_file "$1" "$2")
  make_pkg "$iserved/$file" "pkgname = $1" "pkgver = ${3:-$2}"
  echo "signed:$(sha256sum <"$iserved/$file" | cut -d' ' -f1)" >"$iserved/$file.sig"
}
rp_db() {
  local e name version sum entries=()
  for e in "$@"; do
    read -r name version sum <<<"$e"
    entries+=("$name $version $(rp_file "$name" "$version") ${sum:-$(sha256sum <"$iserved/$(rp_file "$name" "$version")" | cut -d' ' -f1)}")
  done
  repo_db "$iserved/omarchy.db" "${entries[@]}"
}
rp_inst() { inst_env+=(STUB_REPO_SERVER="$rp_server"); inst "$@"; inst_env=("${inst_env[@]:0:${#inst_env[@]}-1}"); }
rp_cache=$it/cache/omabump/packages
rpf=$(rp_file rpapp 2.0.0-1)
# The omarchy-pkgs clone as the omarchy route tests left it: the repo path
# must not touch it.
pk_head=$(git -C "$pk" rev-parse HEAD) pk_status=$(git -C "$pk" status --porcelain)
rm -f "$pk/.git/test-sync-token"

rp_pkg rpapp 2.0.0-1
rp_db 'rpapp 2.0.0-1' 'rpapp-debug 9.0.0-1 0000000000000000000000000000000000000000000000000000000000000000'
fresh 'rpapp 1.0.0-1'
shown rpapp 2.0.0 1.0.0-1
inst rpapp
same "install (repo), no [omarchy] repo here: refused, saying so" \
  '1|omabump: No [omarchy] repo in pacman.conf, so there is no package to install Rp App from' "$irc|$(tail -n1 <<<"$iout")"
inst --prepare rpapp
same "install --prepare (repo), no [omarchy] repo here: says it would refuse" \
  '0|Would refuse: No [omarchy] repo in pacman.conf, so there is no package to install Rp App from' "$irc|$(tail -n1 <<<"$iout")"

fresh 'rpapp 1.0.0-1'
shown rpapp 2.0.0 1.0.0-1
rp_inst --prepare rpapp
same "install --prepare (repo): succeeds, stopping before the download" '0|Prepared: stopping before the download.' "$irc|$(tail -n1 <<<"$iout")"
says "install --prepare (repo): the package the database names, not rpapp-debug" "Omarchy's repo ($rp_server) has rpapp 2.0.0-1"
says "install --prepare (repo): would download the package and its signature" \
  "Would download: $rp_server/$rpf to $rp_cache/$rpf, and its signature $rp_server/$rpf.sig to $rp_cache/$rpf.sig"
says "install --prepare (repo): would check the sha256 the database lists" "Would check: sha256sum of $rp_cache/$rpf is $(sha256sum <"$iserved/$rpf" | cut -d' ' -f1)"
says "install --prepare (repo): would verify the signature" \
  "Would check: gpg --verify $rp_cache/$rpf.sig $rp_cache/$rpf (pacman's keyring) finds a good signature by a key pacman trusts"
says "install --prepare (repo): and again on the staged copy" \
  "Would check: gpg --verify $rp_cache/$rpf.sig $istaging/$rpf (pacman's keyring) finds a good signature by a key pacman trusts"
says "install --prepare (repo): would check the name and version" "Would check: pacman -Qp $rp_cache/$rpf is rpapp 2.0.0-1, newer than the installed 1.0.0-1"
says "install --prepare (repo): then the staging the other routes use" "Would run: sudo pacman -U -- $istaging/$rpf (pacman asks before it installs)"
calls "install --prepare (repo): reads the database" "curl --proto =https --proto-redir =https --connect-timeout 15 --max-time 30 --max-filesize 8M -fsSL $rp_server/omarchy.db"
no_call "install --prepare (repo): downloads no package" "$rpf"
no_call "install --prepare (repo): never calls sudo" 'sudo '
check "install --prepare (repo): nothing in the packages cache" test ! -e "$rp_cache/$rpf"

fresh 'rpapp 1.0.0-1'
shown rpapp 2.0.0 1.0.0-1
STUB_PACMAN_U=ok rp_inst rpapp
same "install (repo): a success" 0 "$irc"
says "install (repo): the sha256 is checked" 'sha256 matches.'
says "install (repo): the signature is verified, and its signer named" \
  'Signature: good, by Omarchy <pkgs@omarchy.org>, key 40DFB630FF42BCFFB047046CF0134EE680CAC571'
calls "install (repo): by gpg in pacman's keyring, as pacman-key runs it, on the downloaded file" \
  "gpg --homedir $idb/gnupg/ --no-permission-warning --status-fd 1 --verify $rp_cache/$rpf.sig $rp_cache/$rpf"
calls "install (repo): and on the staged copy" "gpg --homedir $idb/gnupg/ --no-permission-warning --status-fd 1 --verify $rp_cache/$rpf.sig $istaging/$rpf"
same "install (repo): the staged copy's signature is checked before pacman -U" 'gpg|pacman -U' \
  "$(grep -E "^(sudo pacman -U|gpg .*$istaging/)" "$ilog/calls" | sed 's/^gpg .*/gpg/; s/^sudo //; s/ --.*//' | paste -sd'|')"
says "install (repo): the staged copy is checked" "Staged copy checked: $istaging/$rpf"
calls "install (repo): installed with sudo pacman -U from the staging directory" "sudo pacman -U -- $istaging/$rpf"
same "install (repo): pacman has the new version" 'rpapp 2.0.0-1' "$(<"$idb/installed")"
check "install (repo): no staged copy left" test ! -e "$istaging/$rpf"
check "install (repo): the package and its signature are cleaned up" test ! -e "$rp_cache/$rpf" -a ! -e "$rp_cache/$rpf.sig"
says "install (repo): restart to use it" 'Restart Rp App to use 2.0.0-1.'
calls "install (repo): refreshes the panel" 'omabump-check --no-notify --wait'
no_call "install (repo): builds nothing" 'makepkg'
same "install (repo): the omarchy-pkgs clone is not touched, nor its code run" "$pk_head|$pk_status|no" \
  "$(git -C "$pk" rev-parse HEAD)|$(git -C "$pk" status --porcelain)|$([[ -e $pk/.git/test-sync-token ]] && echo ran || echo no)"

# Installed under another name: Update replaces it as the vendor route's
# does, by a conflict the downloaded, verified package declares; this one
# declares none, so pacman would keep both, and nothing is staged.
fresh 'rpapp-bin 1.0.0-1'
printf 'Name            : rpapp-bin\nProvides        : None\nConflicts With  : None\n' >"$idb/qi/rpapp-bin"
STUB_PACMAN_U=ok rp_inst rpapp
same "install (repo), installed under another name, no conflict declared: refused before sudo" \
  "1|omabump: neither rpapp nor rpapp-bin declares a conflict with the other, so pacman would keep both; not switching" \
  "$irc|$(grep -vF 'the build and download files stay' <<<"$iout" | tail -n1)"
no_call "install (repo), no conflict declared: nothing staged" 'sudo '
# With a conflict: Update replaces it, and Switch does at the same version.
make_pkg "$iserved/$rpf" "pkgname = rpapp" "pkgver = 2.0.0-1" "conflict = rpapp-bin"
echo "signed:$(sha256sum <"$iserved/$rpf" | cut -d' ' -f1)" >"$iserved/$rpf.sig"
rp_db 'rpapp 2.0.0-1'
fresh 'rpapp-bin 1.0.0-1'
STUB_PACMAN_U=ok rp_inst rpapp
same "install (repo), installed under another name, a conflict declared: Update replaces it" '0|rpapp 2.0.0-1' "$irc|$(<"$idb/installed")"
says "install (repo): pacman asks to remove the old package" 'pacman will ask to remove rpapp-bin for rpapp (declared conflict)'
fresh 'rpapp-bin 2.0.0-1'
STUB_PACMAN_U=ok rp_inst --switch rpapp
same "install --switch (repo): at the same version, the repo's package replaces it" '0|rpapp 2.0.0-1' "$irc|$(<"$idb/installed")"
fresh 'rpapp-bin 2.0.0-2'
STUB_PACMAN_U=ok rp_inst --switch rpapp
same "install --switch (repo): never to an older full version" \
  "1|omabump: 2.0.0-1 is older than the installed rpapp-bin 2.0.0-2; nothing to do" "$irc|$(tail -n1 <<<"$iout")"
no_call "install --switch (repo), older: nothing downloaded" "$rpf"
# A conflict pacman does not apply to this version (rpapp-bin<2): both stay
# installed, which is no switch: the run says so and fails.
fresh 'rpapp-bin 2.0.0-1'
STUB_PACMAN_U=ok STUB_PACMAN_KEEP=1 rp_inst --switch rpapp
same "install --switch (repo): the old package still there after pacman: a failure that says so" \
  "1|omabump: pacman installed rpapp 2.0.0-1, but rpapp-bin 2.0.0-1 is still installed beside it (its conflict does not cover this version); remove it with: sudo pacman -R rpapp-bin" \
  "$irc|$(grep -vF 'the build and download files stay' <<<"$iout" | tail -n1)"
# The canonical package came in meanwhile, at the target: the re-check of
# both names right before the staging refuses, so nothing goes down.
fresh 'rpapp-bin 1.0.0-1' 'rpapp 2.0.0-1'
# shellcheck disable=SC2016 # expanded by the child bash
inst_src 'pkg=rpapp installed_name=rpapp-bin installed=1.0.0-1 switch=1; stage_and_install "$STUB_SERVED/'"$rpf"'" "rpapp 2.0.0-1"'
same "stage_and_install, a switch: the canonical package installed meanwhile at the target: refused before the staging" \
  '1|omabump: rpapp is installed now, at 2.0.0-1, which 2.0.0-1 is not newer than; not installing' "$irc|$(tail -n1 <<<"$iout")"
no_call "stage_and_install, the canonical package installed meanwhile: nothing staged" 'sudo '
# The same while sudo waited for the password, after that re-check: asked
# once more with the copy staged, right before pacman.
fresh 'rpapp-bin 1.0.0-1'
inst_env+=(STUB_SUDO_MEANWHILE='rpapp 2.0.0-1')
# shellcheck disable=SC2016 # expanded by the child bash
inst_src 'pkg=rpapp installed_name=rpapp-bin installed=1.0.0-1 switch=1; stage_and_install "$STUB_SERVED/'"$rpf"'" "rpapp 2.0.0-1"'
inst_env=("${inst_env[@]:0:${#inst_env[@]}-1}")
same "stage_and_install, a switch: the canonical package installed while sudo waited: refused before pacman" \
  "1|omabump: rpapp is installed now, at 2.0.0-1, which 2.0.0-1 is not newer than; removed $istaging/$rpf, not installing" \
  "$irc|$(tail -n1 <<<"$iout")"
no_call "stage_and_install, installed while sudo waited: pacman -U not run" 'sudo pacman -U'
calls "stage_and_install, installed while sudo waited: the staged copy removed" "sudo rm -f -- $istaging/$rpf"
# The target installed meanwhile by something else, at what the panel
# showed: the re-check before the staging ends the run as done.
fresh 'rpapp 2.0.0-1'
shown rpapp 2.0.0 1.0.0-1
# shellcheck disable=SC2016 # expanded by the child bash
inst_src 'pkg=rpapp installed_name=rpapp installed=1.0.0-1 label="Rp App"; stage_and_install "$STUB_SERVED/'"$rpf"'" "rpapp 2.0.0-1"'
same "stage_and_install: the target installed meanwhile, as the panel showed: already installed, a success" \
  '0|Rp App 2.0.0-1 is already installed; nothing to do.' "$irc|$(grep -F 'already installed' <<<"$iout")"
no_call "stage_and_install: installed meanwhile: nothing staged" 'sudo '
fresh 'rpapp-bin 1.0.0-1' 'rpapp 1.5.0-1'
# shellcheck disable=SC2016 # expanded by the child bash
inst_src 'pkg=rpapp installed_name=rpapp-bin installed=1.0.0-1; guard_version 2.0.0-1 && echo ok'
same "guard_version: the canonical package older than the target: no word against it" '0|ok' "$irc|$(tail -n1 <<<"$iout")"
rm -f "$idb/qi/rpapp-bin"
rp_pkg rpapp 2.0.0-1
rp_db 'rpapp 2.0.0-1' 'rpapp-debug 9.0.0-1 0000000000000000000000000000000000000000000000000000000000000000'

# The repo's staged copy: its digest and signature match, pacman -Qp reads
# another version: refused before pacman.
fresh 'rpapp 1.0.0-1'
STUB_PACMAN_U=ok STUB_QP_STAGED='rpapp 2.0.0-2' rp_inst rpapp
same "install (repo): a staged copy pacman -Qp reads as another version: refused" \
  "1|omabump: the staged copy is 'rpapp 2.0.0-2', expected 'rpapp 2.0.0-1'; not installing (the copy stays in $istaging/$rpf)" \
  "$irc|$(grep -vF 'the build and download files stay' <<<"$iout" | tail -n1)"
no_call "install (repo), another version staged: pacman -U never runs" 'pacman -U'
rm -f "$rp_cache/$rpf" "$rp_cache/$rpf.sig"
# A signature that does not verify: refused, both files removed, no sudo.
echo 'signed:0000' >"$iserved/$rpf.sig"
fresh 'rpapp 1.0.0-1'
STUB_PACMAN_U=ok rp_inst rpapp
same "install (repo), a bad signature: refused, saying the signature did not verify" \
  "1|omabump: the signature of $rpf did not verify (gpg exited 1: it is not a good signature from a key in pacman's keyring). Removed the download, not installing" \
  "$irc|$(tail -n1 <<<"$iout")"
says "install (repo), a bad signature: gpg's own words are shown" 'gpg: BAD signature from'
check "install (repo), a bad signature: the package and its signature are deleted" test ! -e "$rp_cache/$rpf" -a ! -e "$rp_cache/$rpf.sig"
no_call "install (repo), a bad signature: no sudo" 'sudo '
same "install (repo), a bad signature: nothing installed" 'rpapp 1.0.0-1' "$(<"$idb/installed")"

# A good signature by a key that is in pacman's keyring but not trusted:
# gpg exits 0 and pacman-key --verify passes it, but pacman would not
# install it from the repo. Refused, both files removed, no sudo.
echo "untrusted:$(sha256sum <"$iserved/$rpf" | cut -d' ' -f1)" >"$iserved/$rpf.sig"
fresh 'rpapp 1.0.0-1'
STUB_PACMAN_U=ok rp_inst rpapp
same "install (repo), a good signature by an untrusted key: refused" \
  "1|omabump: the signature of $rpf did not verify (the signature is good, but its key is not one pacman's keyring trusts). Removed the download, not installing" \
  "$irc|$(tail -n1 <<<"$iout")"
says "install (repo), an untrusted key: gpg's warning is shown" 'This key is not certified with a trusted signature'
check "install (repo), an untrusted key: the package and its signature are deleted" test ! -e "$rp_cache/$rpf" -a ! -e "$rp_cache/$rpf.sig"
no_call "install (repo), an untrusted key: no sudo" 'sudo '
same "install (repo), an untrusted key: nothing installed" 'rpapp 1.0.0-1' "$(<"$idb/installed")"

# An armored signature is refused before gpg, as pacman-key refuses one.
printf '%s\n' '-----BEGIN PGP SIGNATURE-----' "signed:$(sha256sum <"$iserved/$rpf" | cut -d' ' -f1)" >"$iserved/$rpf.sig"
fresh 'rpapp 1.0.0-1'
STUB_PACMAN_U=ok rp_inst rpapp
same "install (repo), an armored signature: refused, gpg not asked" \
  "1|omabump: the signature of $rpf did not verify (the signature is armored; pacman takes only a binary one). Removed the download, not installing|" \
  "$irc|$(tail -n1 <<<"$iout")|$(grep '^gpg ' "$ilog/calls")"
rp_pkg rpapp 2.0.0-1

# The file in your cache swapped between its checks: the database is not
# signed, so its sha256 can be the other file's, and here the signature
# check of the cache's file is answered as for the signed one. The staged
# copy, root's, is the other file, and its own signature check refuses it:
# the copy goes, and pacman -U never runs.
make_pkg "$iserved/$rpf" 'pkgname = rpapp' 'pkgver = 2.0.0-1' 'url = swapped'
rp_db 'rpapp 2.0.0-1'
fresh 'rpapp 1.0.0-1'
STUB_GPG_CACHE_GOOD=1 STUB_PACMAN_U=ok rp_inst rpapp
same "install (repo), the cache's file swapped after its signature check: refused on the staged copy" \
  "1|omabump: the staged copy's signature did not verify (gpg exited 1: it is not a good signature from a key in pacman's keyring); removed $istaging/$rpf, not installing" \
  "$irc|$(grep -F "omabump: the staged copy" <<<"$iout")"
says "install (repo), swapped: the cache's file had passed" 'Signature: good, by Omarchy'
no_call "install (repo), swapped: pacman -U never runs" 'pacman -U'
check "install (repo), swapped: the staged copy is removed" test ! -e "$istaging/$rpf"
same "install (repo), swapped: nothing installed" 'rpapp 1.0.0-1' "$(<"$idb/installed")"
rm -f "$rp_cache/$rpf" "$rp_cache/$rpf.sig"
rp_pkg rpapp 2.0.0-1
rp_db 'rpapp 2.0.0-1'

# A file whose sha256 is not the database's: refused before the signature.
rp_db "rpapp 2.0.0-1 $(printf 'b%.0s' {1..64})"
fresh 'rpapp 1.0.0-1'
STUB_PACMAN_U=ok rp_inst rpapp
same "install (repo), a sha256 the database does not list: refused" \
  "1|omabump: sha256 of the download is $(sha256sum <"$iserved/$rpf" | cut -d' ' -f1), Omarchy's repo database lists $(printf 'b%.0s' {1..64}); removed the file, not installing" \
  "$irc|$(tail -n1 <<<"$iout")"
check "install (repo), a sha256 mismatch: the files are deleted" test ! -e "$rp_cache/$rpf" -a ! -e "$rp_cache/$rpf.sig"
no_call "install (repo), a sha256 mismatch: no sudo" 'sudo '

# A signed file that is not the package and version the database names.
rp_pkg rpapp 2.0.0-1 2.0.0-2
rp_db 'rpapp 2.0.0-1'
fresh 'rpapp 1.0.0-1'
STUB_PACMAN_U=ok rp_inst rpapp
same "install (repo), pacman -Qp gives another version: refused" \
  "1|omabump: the package is 'rpapp 2.0.0-2', and Omarchy's repo database names 'rpapp 2.0.0-1'; not installing" \
  "$irc|$(grep -F 'omabump: the package is' <<<"$iout")"
no_call "install (repo), another version: no sudo" 'sudo '
make_pkg "$iserved/$rpf" 'pkgname = other' 'pkgver = 2.0.0-1'
echo "signed:$(sha256sum <"$iserved/$rpf" | cut -d' ' -f1)" >"$iserved/$rpf.sig"
rp_db 'rpapp 2.0.0-1'
rm -f "$rp_cache/$rpf"
fresh 'rpapp 1.0.0-1'
STUB_PACMAN_U=ok rp_inst rpapp
same "install (repo), pacman -Qp gives another name: refused" \
  "1|omabump: the package is 'other 2.0.0-1', and Omarchy's repo database names 'rpapp 2.0.0-1'; not installing" \
  "$irc|$(grep -F 'omabump: the package is' <<<"$iout")"
no_call "install (repo), another name: no sudo" 'sudo '
rm -f "$rp_cache/$rpf" "$rp_cache/$rpf.sig"
rp_pkg rpapp 2.0.0-1
rp_db 'rpapp 2.0.0-1'

# pacman stops (n, or a dependency): the line on omarchy update.
fresh 'rpapp 1.0.0-1'
STUB_PACMAN_U=no rp_inst rpapp
same "install (repo), pacman installs nothing: a failure" 1 "$irc"
says "install (repo), pacman installs nothing: suggests omarchy update for a dependency" \
  "omabump: if pacman stopped on a dependency, run omarchy update: it updates the rest of the system with Omarchy's repo"
rm -f "$rp_cache/$rpf" "$rp_cache/$rpf.sig"

# The repo not newer than what is installed: as for any route with nothing
# newer. Behind the panel's version, it names both and says when.
rp_pkg rpapp 1.0.0-1
rp_db 'rpapp 1.0.0-1'
fresh 'rpapp 1.0.0-1'
shown rpapp 2.0.0 1.0.0-1
rp_inst rpapp
same "install (repo), the vendor ahead of the repo: a failure naming both versions" \
  "1|omabump: Omarchy's repo has 1.0.0-1, not the 2.0.0 the vendor's feed shows; Update cannot install it yet. It usually follows within the hour." \
  "$irc|$(tail -n1 <<<"$iout")"
no_call "install (repo), the vendor ahead of the repo: downloads no package" "$(rp_file rpapp 1.0.0-1)"
rp_inst --prepare rpapp
same "install --prepare (repo), the vendor ahead of the repo: says it would refuse" \
  "0|Would refuse: Omarchy's repo has 1.0.0-1, not the 2.0.0 the vendor's feed shows; Update cannot install it yet. It usually follows within the hour." \
  "$irc|$(tail -n1 <<<"$iout")"
fresh 'rpapp 1.0.0-1'
shown rpapp 1.0.0 0.9.0-1
rp_inst rpapp
same "install (repo), the panel's version installed since: already installed, a success" \
  '0|Rp App 1.0.0-1 is already installed; nothing to do.' "$irc|$(grep -F 'already installed' <<<"$iout")"
calls "install (repo), already installed: refreshes the panel" 'omabump-check --no-notify --wait'

# An epoch in the file name: its colon goes percent-encoded into the URL.
rpe=$(rp_file rpepoch 1:2.0-1)
rp_pkg rpepoch 1:2.0-1
rp_db 'rpepoch 1:2.0-1'
fresh 'rpepoch 1:1.0-1'
# A package an earlier run kept for a retry nobody made, and a recent one.
touch -d '9 days ago' "$rp_cache/old-1.0-1-x86_64.pkg.tar.zst"
touch -d '2 days ago' "$rp_cache/kept-1.0-1-x86_64.pkg.tar.zst"
STUB_PACMAN_U=ok rp_inst rpepoch
same "install (repo): a kept package older than a week goes after a success, a recent one stays" 'kept-1.0-1-x86_64.pkg.tar.zst' \
  "$(find "$rp_cache" -maxdepth 1 -type f \( -name 'old-*' -o -name 'kept-*' \) -printf '%f\n')"
says "install (repo): and says so" "Removed 1 package file(s) older than a week from"
rm -f "$rp_cache/kept-1.0-1-x86_64.pkg.tar.zst"
same "install (repo), an epoch's file: a success" '0|rpepoch 1:2.0-1' "$irc|$(<"$idb/installed")"
calls "install (repo), an epoch's file: fetched with the colon percent-encoded" "$rp_server/rpepoch-1%3A2.0-1-$rp_arch.pkg.tar.zst"
calls "install (repo), an epoch's file: and its signature" "$rp_server/rpepoch-1%3A2.0-1-$rp_arch.pkg.tar.zst.sig"
calls "install (repo), an epoch's file: staged by its name" "sudo pacman -U -- $istaging/$rpe"

# A row Build now may build (testpkg, build true): Update takes the repo's
# package, and never builds, whatever the vendor has. The repo behind the
# vendor: Update refuses, and says Build now can build it meanwhile.
rp_pkg testpkg 1.0.0-1
rp_db 'testpkg 1.0.0-1'
fresh 'testpkg 1.0.0-1'
shown testpkg 2.0.0 1.0.0-1
rm -f "$pk/.git/test-sync-token"
STUB_PACMAN_U=ok rp_inst testpkg
same "install (repo), the vendor ahead of the repo: Update refuses, and names Build now" \
  "1|omabump: Omarchy's repo has 1.0.0-1, not the 2.0.0 the vendor's feed shows; Update cannot install it yet. It usually follows within the hour. Build now (b in the panel) builds it from Omarchy's recipe meanwhile." \
  "$irc|$(tail -n1 <<<"$iout")"
no_call "install (repo), the vendor ahead: Update never builds" 'makepkg'
check "install (repo), the vendor ahead: nor runs omarchy-pkgs' sync" test ! -e "$pk/.git/test-sync-token"
same "install (repo), the vendor ahead: the clone is not touched" "$pk_head|$pk_status" \
  "$(git -C "$pk" rev-parse HEAD)|$(git -C "$pk" status --porcelain)"
# The repo newer than what is installed, the vendor newer still: Update
# installs the repo's package, nothing built.
rp_pkg testpkg 1.5.0-1
rp_db 'testpkg 1.5.0-1'
fresh 'testpkg 1.0.0-1'
shown testpkg 2.0.0 1.0.0-1
STUB_PACMAN_U=ok rp_inst testpkg
same "install (repo), the repo behind the vendor, ahead of what is installed: the repo's package" '0|testpkg 1.5.0-1' "$irc|$(<"$idb/installed")"
no_call "install (repo), the repo behind the vendor: no build" 'makepkg'
# Build now there, with buildAhead on: the vendor's 2.0.0 is ahead of the
# repo's 1.5.0-1, so the recipe is built; the repo's package is not
# downloaded.
printf '{"plugins": [{"id": "io.github.vladkarok.omabump", "buildAhead": true}]}\n' >"$ishell"
fresh 'testpkg 1.0.0-1'
shown testpkg 2.0.0 1.0.0-1
jq '.apps[0].vendorVersion = "2.0.0"' "$istatus" >"$istatus.new" && mv "$istatus.new" "$istatus"
: >"$ilog/gnupg"
STUB_PACMAN_U=ok rp_inst --build testpkg
cp "$ilog/gnupg" "$ilog/gnupg.build"
same "install --build, the vendor ahead of the repo: the build, a success" '0|testpkg 2.0.0-1' "$irc|$(<"$idb/installed")"
calls "install --build: makepkg builds" ' -sfC'
says "install --build: says the package is Omarchy's recipe built here, not signed by Omarchy" \
  "Build now: building Test Pkg on this machine from Omarchy's recipe. The package is not signed by Omarchy."
no_call "install --build: the repo's package is not downloaded" "$(rp_file testpkg 1.5.0-1)"
check "install --build: no keyring left behind" test -z "$(find "$it/cache/omabump" -maxdepth 1 -name 'gnupg.*')"
same "install --build: every makepkg of the run had the recipe's keyring for its GnuPG home, none yours" '' \
  "$(grep -v "^$it/cache/omabump/gnupg\.[A-Za-z0-9]*\$" "$ilog/gnupg.build")"
check "install --build: and makepkg ran" test -s "$ilog/gnupg.build"
# The recipe reaches only what the repo has already (the vendor's newest is
# held, or its watch lags): that release is Update's, signed.
rp_pkg testpkg 2.0.0-1
rp_db 'testpkg 2.0.0-1'
fresh 'testpkg 1.0.0-1'
shown testpkg 3.0.0 1.0.0-1
jq '.apps[0].vendorVersion = "3.0.0"' "$istatus" >"$istatus.new" && mv "$istatus.new" "$istatus"
STUB_PACMAN_U=ok rp_inst --build testpkg
same "install --build, the recipe reaches only what the repo has: refused, Update named" \
  "1|omabump: omarchy-pkgs' recipe reaches 2.0.0-1, and Omarchy's repo has 2.0.0-1 already; use Update instead, which installs its signed package|testpkg 1.0.0-1" \
  "$irc|$(grep -F "use Update instead" <<<"$iout")|$(<"$idb/installed")"
no_call "install --build, the recipe at the repo's release: nothing built" ' -sfC'
rm -f "$ishell"
rm -f "$iserved/omarchy.db" "$iserved"/rpapp-* "$iserved"/rpepoch-* "$iserved"/testpkg-* "$rp_cache"/rp* "$rp_cache"/testpkg-*

# --- Omabump's own update: the fast-forward and its rollback ---------------------------

# Omabump updated outside its Update (omarchy plugin update, a git pull) to
# the release the panel showed: nothing to do, and the panel's refresh
# clears the row. A feed behind the panel names both versions.
self_version=$(jq -r .version "$iplugin/manifest.json")
# shellcheck disable=SC2016 # expanded by the child bash
self_inst='feed_version() { echo "$T_FEED"; }; self_git_managed() { :; }; '$isetup'install_self'
fresh
shown self:omabump "$self_version" 0.0.1
T_FEED=$self_version inst_src "$self_inst" self:omabump
same "install (self), the release the panel showed installed since: a success that says so" \
  "0|Omabump $self_version is already installed; nothing to do." "$irc|$(grep -F 'already installed' <<<"$iout")"
calls "install (self), the release the panel showed installed since: refreshes the panel" 'omabump-check --no-notify --wait'
fresh
shown self:omabump 9.9.9 "$self_version"
T_FEED=$self_version inst_src "$self_inst" self:omabump
same "install (self), the feed behind the panel: a failure that names both versions" \
  "1|omabump: Omabump's newest release is $self_version, not the 9.9.9 the panel showed; Update cannot install it yet." \
  "$irc|$(grep -F 'newest release is' <<<"$iout")"
no_call "install (self), the feed behind the panel: no panel refresh" 'omabump-check'

# The release changes a.txt and adds c.txt, d/new, n/sub/f (in directories
# the installed commit does not have) and b.log, which the installed
# commit's .gitignore matches.
igit init -q "$iplugin"
mkdir -p "$iplugin/d"
echo one >"$iplugin/a.txt"
echo keep >"$iplugin/d/keep"
echo '*.log' >"$iplugin/.gitignore"
igit -C "$iplugin" add -A
igit -C "$iplugin" commit -q -m installed
before=$(git -C "$iplugin" rev-parse HEAD)
mkdir -p "$iplugin/n/sub"
echo two >"$iplugin/a.txt"
echo new >"$iplugin/c.txt"
echo new >"$iplugin/d/new"
echo new >"$iplugin/n/sub/f"
echo new >"$iplugin/b.log"
igit -C "$iplugin" add -A
igit -C "$iplugin" add -f b.log
igit -C "$iplugin" commit -q -m release
target=$(git -C "$iplugin" rev-parse HEAD)
# The installed commit, nothing of the release left: git status shows
# neither ignored files nor empty directories, so those are looked for.
at_before() {
  [[ $(git -C "$iplugin" rev-parse HEAD) == "$before" && -z $(git -C "$iplugin" status --porcelain) && $(<"$iplugin/a.txt") == one ]] \
    && [[ ! -e $iplugin/c.txt && ! -e $iplugin/d/new && ! -e $iplugin/n && ! -e $iplugin/b.log ]]
}
self_reset() { igit -C "$iplugin" reset -q --hard "$before"; igit -C "$iplugin" clean -qfdx; : >"$ilog/calls"; }
export T_BEFORE=$before T_TARGET=$target

self_reset
# shellcheck disable=SC2016 # expanded by the child bash
inst_src "$isetup"'self_target=$T_TARGET; self_merge "$T_BEFORE" omarchy-plugin-validate; echo applied' self:omabump
same "self_merge: a validated release stays" "0|applied|$target" "$irc|$iout|$(git -C "$iplugin" rev-parse HEAD)"

self_reset
# shellcheck disable=SC2016 # expanded by the child bash
STUB_VALIDATE=fail inst_src "$isetup"'self_target=$T_TARGET; self_merge "$T_BEFORE" omarchy-plugin-validate' self:omabump
says "self_merge: a failed validation rolls back" "the new version failed validation; rolled back to ${before:0:12}, the old version is still installed"
check "self_merge: back at the installed commit, the release's files gone" at_before

# A merge that moved HEAD and then failed.
self_reset
# shellcheck disable=SC2016 # expanded by the child bash
inst_src "$isetup"'eval "$(declare -f self_git_held | sed "1s/^self_git_held/real_self_git_held/")"
  self_git_held() { real_self_git_held "$@" || return; [[ $1 != merge ]]; }
  self_target=$T_TARGET; self_merge "$T_BEFORE" omarchy-plugin-validate' self:omabump
says "self_merge: a merge that fails after moving HEAD rolls back" "git merge --ff-only $target failed; rolled back to ${before:0:12}, the old version is still installed"
check "self_merge: back at the installed commit" at_before
no_call "self_merge: nothing validated after a failed merge" 'validate'

# Stopped by a signal while the merge runs, slow here: the rollback waits
# for the merge, so it neither races git nor leaves the release to land
# after it. TERM goes to the installer alone (kill <pid>), which reaches no
# git; INT and HUP to its whole process group, as a terminal sends them.
cat >"$istubs/git" <<'EOF'
#!/bin/bash
for a; do [[ $a != merge ]] || { kill "-$T_SIG" -- "$T_KILL"; sleep 1; }; done
PATH=${PATH#*:} exec git "$@"   # the real git, after the stubs directory
EOF
chmod +x "$istubs/git"
for sig in TERM INT HUP; do
  self_reset
  # shellcheck disable=SC2016 # expanded by the child bash
  T_SIG=$sig inst_src "$isetup"'T_KILL=$$; [[ $T_SIG == TERM ]] || { T_KILL=$(ps -o pgid= -p $$); T_KILL=-${T_KILL// /}; }; export T_KILL
    self_target=$T_TARGET; self_merge "$T_BEFORE" omarchy-plugin-validate; echo applied' self:omabump
  says "self_merge: $sig during the merge rolls back once it ends" "the update stopped part way; rolled back to ${before:0:12}, the old version is still installed"
  check "self_merge: back at the installed commit after $sig during the merge" at_before
  no_call "self_merge: nothing validated after $sig during the merge" 'validate'
done
rm -f "$istubs/git"

# Stopped by a signal while validating: the rollback follows the validator.
self_reset
# shellcheck disable=SC2016 # expanded by the child bash
STUB_VALIDATE=term inst_src "$isetup"'self_target=$T_TARGET; self_merge "$T_BEFORE" omarchy-plugin-validate; echo applied' self:omabump
says "self_merge: a run stopped while validating rolls back" "the update stopped part way; rolled back to ${before:0:12}, the old version is still installed"
check "self_merge: back at the installed commit after the signal" at_before
refuse "self_merge: and the run is a failure" test "$irc" = 0

# Ctrl-C during the rollback, sent as a terminal sends it, to the
# installer's whole process group: git, slow here, still finishes the reset.
# The timeout around the test's bash passes the INT on to it once more, a
# moment later; on a loaded machine that came after the reset had ended.
self_reset
cat >"$istubs/git" <<'EOF'
#!/bin/bash
for a; do [[ $a != reset ]] || { kill -INT -- "-$T_PGID"; sleep 1; }; done
PATH=${PATH#*:} exec git "$@"   # the real git, after the stubs directory
EOF
chmod +x "$istubs/git"
# shellcheck disable=SC2016 # expanded by the child bash
STUB_VALIDATE=fail inst_src "$isetup"'T_PGID=$(ps -o pgid= -p $$) && export T_PGID=${T_PGID// /}
  self_target=$T_TARGET; self_merge "$T_BEFORE" omarchy-plugin-validate' self:omabump
rm -f "$istubs/git"
says "self_merge: Ctrl-C during the rollback does not cut it short" "the new version failed validation; rolled back to ${before:0:12}, the old version is still installed"
check "self_merge: the reset finished under Ctrl-C" at_before

# Ctrl-C (or the terminal closing) between the reset and git clean, when
# the installer waits for no command: sent by the installer's own kill
# builtin, so it always lands there. The timeout around the test's bash
# passes it on once more, later, as a second Ctrl-C would come.
for sig in INT HUP; do
  self_reset
  # shellcheck disable=SC2016 # expanded by the child bash
  STUB_VALIDATE=fail T_SIG=$sig inst_src "$isetup"'T_PGID=$(ps -o pgid= -p $$) && T_PGID=${T_PGID// /}
    eval "$(declare -f self_git_held | sed "1s/^self_git_held/real_self_git_held/")"
    self_git_held() { [[ $1 != clean ]] || kill -s "$T_SIG" -- "-$T_PGID"; real_self_git_held "$@"; }
    self_target=$T_TARGET; self_merge "$T_BEFORE" omarchy-plugin-validate' self:omabump
  says "self_merge: $sig between the reset and git clean does not cut the rollback short" "the new version failed validation; rolled back to ${before:0:12}, the old version is still installed"
  check "self_merge: back at the installed commit after $sig between the git commands" at_before
done

self_reset
unset T_BEFORE T_TARGET

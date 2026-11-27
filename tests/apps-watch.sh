# shellcheck shell=bash disable=SC2154,SC2016 # root, scratch and the helpers come from tests/run.sh; single quotes hold the report's Markdown
# Sourced by tests/run.sh: .github/scripts/apps-watch against a source file and
# an apps.json of its own, so nothing reaches the network.

# --- .github/scripts/apps-watch ----------------------------------------------------

aw=$scratch/apps-watch
mkdir -p "$aw"
cat >"$aw/apps.json" <<'EOF'
[
  {"pkg": "claude-code", "source": "omarchy", "section": "cli"},
  {"pkg": "cursor-cli", "source": "vendor-pkg", "section": "cli"},
  {"pkg": "mise:old", "source": "mise", "section": "cli", "tool": "old"},
  {"pkg": "claude-desktop", "source": "omarchy"}
]
EOF
cat >"$aw/source" <<'EOF'
#!/bin/bash
case "$agent" in
  claude) package=claude-code ;;
  cursor-agent) package=cursor-cli ;;
esac
EOF
aw_run() {
  aw_out=$(cd "$aw" && APPS_WATCH_SOURCE="$aw/source" APPS_WATCH_APPS="$aw/apps.json" timeout 60 "$root/.github/scripts/apps-watch" 2>&1 </dev/null)
  aw_rc=$?
}

aw_run
same "apps-watch: every package present is no news" '0|' "$aw_rc|$aw_out"

printf '  codex) package=openai-codex ;;\n' >>"$aw/source"
aw_run
same "apps-watch: a package missing from apps.json is news" 3 "$aw_rc"
check "apps-watch: the report names it" grep -qF '`openai-codex`' <<<"$aw_out"

jq '. + [{"pkg": "gone-cli", "source": "omarchy", "section": "cli"}]' "$aw/apps.json" >"$aw/apps2.json"
mv "$aw/apps2.json" "$aw/apps.json"
aw_run
same "apps-watch: beside a missing package, a CLI entry Omarchy does not name is listed" 3 "$aw_rc"
check "apps-watch: by its pkg" grep -qF '`gone-cli`' <<<"$aw_out"
refuse "apps-watch: a mise CLI entry is not listed" grep -qF 'mise:old' <<<"$aw_out"
jq '. + [{"pkg": "openai-codex", "source": "omarchy", "section": "cli"}]' "$aw/apps.json" >"$aw/apps2.json"
mv "$aw/apps2.json" "$aw/apps.json"
aw_run
same "apps-watch: alone, such an entry is no news (Pi is in no list of Omarchy's)" '0|' "$aw_rc|$aw_out"

printf '#!/bin/bash\ninstall_agents() { :; }\n' >"$aw/source"
aw_run
same "apps-watch: a source with no map lines is news" 3 "$aw_rc"
check "apps-watch: it says the list moved or changed shape" grep -q 'moved or changed shape' <<<"$aw_out"

rm -f "$aw/ran"
printf '%s\n' '  x) package=$(touch '"$aw"'/ran) ;;' '  y) package=bad;touch ;;' '  Z) package=upper ;;' >"$aw/source"
aw_run
same "apps-watch: lines of another shape are not accepted" 3 "$aw_rc"
check "apps-watch: and count as no list" grep -q 'moved or changed shape' <<<"$aw_out"
check "apps-watch: and nothing in them ran" test ! -e "$aw/ran"
refuse "apps-watch: and none is named as a package" grep -qE 'upper|bad|touch' <<<"$aw_out"

printf '  claude) package=claude-code ;;\n  x) package=$(touch %s/ran) ;;\n' "$aw" >"$aw/source"
aw_run
same "apps-watch: a hostile line beside a good one is left out, the rest read, and nothing is missing" '0|' "$aw_rc|$aw_out"
check "apps-watch: and still did not run" test ! -e "$aw/ran"

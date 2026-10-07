# shellcheck shell=bash disable=SC2154 # root and the helpers come from tests/run.sh
# Sourced by tests/run.sh: where Main.qml repeats a rule of the scripts, the
# two must agree. The QML itself needs a shell to run, so these read it.

# --- Main.qml and the scripts -------------------------------------------------

# Refresh during another check runs the checker with --wait under a longer
# deadline: it must cover the lock wait (flock -w) and then a full run.
lock_wait=$(grep -o 'flock -w [0-9]*' "$root/bin/omabump-check" | grep -o '[0-9]*$')
deadlines=$(grep -o 'wait ? "[0-9]*" : "[0-9]*"' "$root/Main.qml" | grep -o '[0-9][0-9]*' | paste -sd' ')
read -r wait_deadline run_deadline <<<"$deadlines"
check "a --wait check's deadline covers the lock wait and a full run" \
  test "${wait_deadline:-0}" -ge $(( ${run_deadline:-1000000} + ${lock_wait:-1000000} ))

# The panel decides skips between checks: mise and self versions as strings,
# every other source with vercmp, as row_skipped does.
qml_strings=$(grep -o 'if (app.source === "[a-z-]*" || app.source === "[a-z-]*") return app.updateAvailable === true && latest === version' "$root/Main.qml" \
  | grep -o '"[a-z-]*"' | tr -d '"' | sort | paste -sd' ')
script_strings=$(for source in $(jq -r '.[].source' "$root/apps.json" | sort -u) self; do
  string_versions "$source" && echo "$source"
done | sort | paste -sd' ')
same "Main.qml compares the same sources' skips as strings as the checker" "$script_strings" "$qml_strings"

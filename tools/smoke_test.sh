#!/usr/bin/env bash
# Everything that can be checked without a person watching. Run it before any
# commit that touches gameplay, and after any asset re-import.
#
#   bash tools/smoke_test.sh
#
# Exits non-zero on the first failure, so it works as a CI gate.
#
# Two of the checks here exist because of bugs that shipped as "done": the
# ragdoll exploded half a second after every death while the preview that
# certified it only looked at the first quarter-second, and the match rules had
# never been run with more than one live player. Anything a still frame cannot
# prove belongs in this file rather than in someone's memory.
#
# What this cannot do is judge whether the game *looks* right. The preview
# scenes under tools/ are for that, and they need eyes. See docs/STATUS.md.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${TMPDIR:-/tmp}/gub_smoke"

failures=0
checks=0

# ------------------------------------------------------------- the engine ---
# $GODOT still wins if it is set, so an unusual install, or a deliberate run
# against a different build, needs no edit here. With it unset the candidates
# below are tried in order and the first one that both exists and reports 4.7 is
# used. This file used to hardcode one Windows path, which meant it aborted on
# every machine that was not the one it was written on.
#
# The version test is not fussiness. The project pins 4.7 (D-001) and 4.6 cannot
# parse it at all: `add_blend_point()` gained a fourth argument in 4.7, so the
# Gub's animation tree fails to load and the error reads exactly like a bug in
# our own code — an hour of looking in the wrong file. A Mac very often has an
# older /Applications/Godot.app sitting next to a newer build in ~/Downloads,
# which is precisely how that happens, so an old one there is rejected rather
# than used.
GODOT_CANDIDATES=(
    "$HOME/Downloads/Godot_v4.7.2-stable_macos/Godot.app/Contents/MacOS/Godot"
    "$HOME/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
    "/Applications/Godot.app/Contents/MacOS/Godot"
    "godot4"
    "godot"
)

# A path if the candidate is one, whatever the PATH resolves it to if it is a
# bare name, and nothing if it is neither.
resolve_binary() {
    case "$1" in
        */*) if [ -x "$1" ]; then printf '%s\n' "$1"; fi ;;
        *)   command -v "$1" 2>/dev/null ;;
    esac
}

# Godot prints its version and exits. An empty answer means it would not run at
# all, which is worth telling apart from running and being the wrong version.
godot_version() {
    "$1" --version 2>/dev/null | tail -n 1
}

rejected=""
if [ -z "${GODOT:-}" ]; then
    for candidate in "${GODOT_CANDIDATES[@]}"; do
        found="$(resolve_binary "$candidate")"
        [ -n "$found" ] || continue
        case "$(godot_version "$found")" in
            4.7.*) GODOT="$found"; break ;;
            *)     rejected="$rejected
       $found (reports $(godot_version "$found" | sed 's/^$/nothing/'))" ;;
        esac
    done
else
    GODOT="$(resolve_binary "$GODOT")"
fi

if [ -z "${GODOT:-}" ]; then
    echo "smoke: cannot find a Godot 4.7 binary. Looked for, in order:"
    for candidate in "${GODOT_CANDIDATES[@]}"; do
        echo "       $candidate"
    done
    if [ -n "$rejected" ]; then
        echo "smoke: these exist but are the wrong version:$rejected"
        echo "       4.6 cannot parse this project — add_blend_point() gained a fourth"
        echo "       argument in 4.7, so the failure looks like a bug in our own code."
    fi
    echo "       Set GODOT=/path/to/Godot and try again."
    echo "       (Note the '.exe' in the Windows path above is a directory, not the binary.)"
    exit 2
fi

GODOT_VERSION="$(godot_version "$GODOT")"
case "$GODOT_VERSION" in
    4.7.*) ;;
    *)
        echo "smoke: ############################################################"
        echo "smoke: WARNING  $GODOT"
        echo "smoke: WARNING  reports ${GODOT_VERSION:-no version at all}, and this project needs 4.7."
        echo "smoke: WARNING  On 4.6 every check below fails with a parse error about"
        echo "smoke: WARNING  add_blend_point(). That is the engine being too old. It is"
        echo "smoke: WARNING  not a bug in this code. Do not go looking for one."
        echo "smoke: ############################################################"
        echo
        ;;
esac

mkdir -p "$LOG_DIR"

# Run a Godot invocation and require `expect` to appear in its output. Also
# fails on any SCRIPT ERROR, which is how a broken script announces itself —
# Godot carries on running afterwards, so a silent exit code proves nothing.
check() {
    local name="$1" expect="$2"; shift 2
    local log="$LOG_DIR/${name// /_}.log"
    checks=$((checks + 1))
    printf '  %-28s ' "$name"

    if ! "$@" >"$log" 2>&1; then
        echo "FAIL (Godot exited non-zero)"
        sed 's/^/      /' "$log" | tail -20
        failures=$((failures + 1))
        return
    fi
    if grep -q "SCRIPT ERROR" "$log"; then
        echo "FAIL (script error)"
        grep -A 3 "SCRIPT ERROR" "$log" | sed 's/^/      /' | head -20
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF "$expect" "$log"; then
        echo "FAIL (expected: $expect)"
        sed 's/^/      /' "$log" | tail -20
        failures=$((failures + 1))
        return
    fi
    echo "ok"
}

echo "smoke: $ROOT"
echo "smoke: $GODOT ($GODOT_VERSION)"
echo

echo "importing assets"
if ! "$GODOT" --headless --path "$ROOT" --import >"$LOG_DIR/import.log" 2>&1; then
    echo "  FAIL — import did not complete"
    tail -20 "$LOG_DIR/import.log" | sed 's/^/      /'
    exit 1
fi
echo "  ok"
echo

echo "headless checks"
check "invite codes" "invite_codes: PASS" \
    "$GODOT" --headless --path "$ROOT" tools/invite_codes.tscn
check "match rules" "match_rules: PASS" \
    "$GODOT" --headless --path "$ROOT" tools/match_rules.tscn
# Menu to results screen, through the real scenes and the real autoloads. The
# only check here that can notice a *join* coming apart — a lobby that never
# hands off to the arena, an arena that never registers, a results screen that
# never opens — none of which any single-seam harness above can see.
check "full playthrough" "playthrough: PASS" \
    "$GODOT" --headless --path "$ROOT" tools/playthrough.tscn
echo

# These need a real window: Godot's headless driver uses the dummy rasteriser
# and renders nothing, and the physics still has to run for a corpse to fall.
echo "rendered checks (a window will flash)"
check "ragdoll survives landing" "ragdoll_stability: PASS" \
    "$GODOT" --path "$ROOT" --resolution 640x360 --script tools/snapshot.gd -- \
    res://tools/ragdoll_stability.tscn "$LOG_DIR/ragdoll.png" 160
# Match on the victim, not the killer. The killer's name is the local player
# setting, which is persisted in Godot's user-data directory (shared by every
# checkout of this project) and is whatever anyone last typed into a name box.
check "spear kills" "killed Dummy 1" \
    "$GODOT" --path "$ROOT" --resolution 640x360 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn "$LOG_DIR/hit.png" 70 hit
check "lure catches" "combat_range: lure caught 1" \
    "$GODOT" --path "$ROOT" --resolution 640x360 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn "$LOG_DIR/lure.png" 132 lure
check "mushroom deploys" "snapshot: wrote" \
    "$GODOT" --path "$ROOT" --resolution 640x360 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn "$LOG_DIR/mushroom.png" 40 mushroom
echo

echo "smoke: $checks checks, $failures failures"
if [ "$failures" -gt 0 ]; then
    echo "smoke: FAIL   (logs in $LOG_DIR)"
    exit 1
fi
echo "smoke: PASS"

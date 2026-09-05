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
# Beside the repo rather than in /tmp: under WSL the Godot we run is a Windows
# binary, and /tmp is inside the Linux filesystem, reachable from Windows only
# as a \wsl.localhost UNC path. `.smoke/` is gitignored.
LOG_DIR="$ROOT/.smoke"

failures=0
checks=0

# ------------------------------------------------------------- the engine ---
# Shared with `tools/net_test.sh` rather than kept here, because a search for
# where people install Godot has to stay in step with reality and two copies of
# it will not. `tools/find_godot.sh` carries the Windows/WSL path hunting, the
# 4.7 version check, and the WSL path translation, and sets $GODOT, $GODOT_ROOT
# and $GODOT_LOG_DIR. It is sourced, so a missing engine ends this script rather
# than a subshell.
GODOT_TAG=smoke
. "$ROOT/tools/find_godot.sh"

mkdir -p "$LOG_DIR"

# Run a Godot invocation and require `expect` to appear in its output. Also
# fails on any SCRIPT ERROR, which is how a broken script announces itself —
# Godot carries on running afterwards, so a silent exit code proves nothing.
check() {
    local name="$1" expect="$2"; shift 2
    local log="$LOG_DIR/${name// /_}.log"
    checks=$((checks + 1))
    printf '  %-32s ' "$name"

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
    # Always a bug, never noise, and it can surface in any check: something asked
    # the multiplayer API for an id while no peer was assigned. Godot prints it
    # and carries on, so it is invisible unless it is looked for. Checked here
    # rather than in one test because the next place it appears will be a
    # different one.
    if grep -q "No multiplayer peer is assigned" "$log"; then
        echo "FAIL (asked a multiplayer peer that is not there)"
        grep -A 4 "No multiplayer peer is assigned" "$log" | sed 's/^/      /' | head -12
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
if ! "$GODOT" --headless --path "$GODOT_ROOT" --import >"$LOG_DIR/import.log" 2>&1; then
    echo "  FAIL — import did not complete"
    tail -20 "$LOG_DIR/import.log" | sed 's/^/      /'
    exit 1
fi
echo "  ok"
echo

echo "headless checks"
check "invite codes" "invite_codes: PASS" \
    "$GODOT" --headless --path "$GODOT_ROOT" tools/invite_codes.tscn
check "match rules" "match_rules: PASS" \
    "$GODOT" --headless --path "$GODOT_ROOT" tools/match_rules.tscn
# Menu to results screen, through the real scenes and the real autoloads. The
# only check here that can notice a *join* coming apart — a lobby that never
# hands off to the arena, an arena that never registers, a results screen that
# never opens — none of which any single-seam harness can see, because each of
# those is the absence of a call rather than a fault inside one.
check "full playthrough" "playthrough: PASS" \
    "$GODOT" --headless --path "$GODOT_ROOT" tools/playthrough.tscn
echo

# These need a real window: Godot's headless driver uses the dummy rasteriser
# and renders nothing, and the physics still has to run for a corpse to fall.
echo "rendered checks (a window will flash)"
check "ragdoll survives landing" "ragdoll_stability: PASS" \
    "$GODOT" --path "$GODOT_ROOT" --resolution 640x360 --script tools/snapshot.gd -- \
    res://tools/ragdoll_stability.tscn "$GODOT_LOG_DIR/ragdoll.png" 160
# Match on the victim, not the killer. The killer's name is the local player
# setting, which is persisted in Godot's user-data directory (shared by every
# checkout of this project) and is whatever anyone last typed into a name box.
check "spear kills" "killed Dummy 1" \
    "$GODOT" --path "$GODOT_ROOT" --resolution 640x360 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn "$GODOT_LOG_DIR/hit.png" 70 hit
check "lure catches" "combat_range: lure caught 1" \
    "$GODOT" --path "$GODOT_ROOT" --resolution 640x360 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn "$GODOT_LOG_DIR/lure.png" 132 lure
check "mushroom deploys" "snapshot: wrote" \
    "$GODOT" --path "$GODOT_ROOT" --resolution 640x360 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn "$GODOT_LOG_DIR/mushroom.png" 40 mushroom
# Holds W and requires the Gub to have gone somewhere. Movement was wired into
# the testbeds and nowhere else, so every testbed could be walked around while
# the real arena could not, and the abilities — which read their own keys —
# kept working and made it look like input was fine.
check "walking with the keyboard" "walk PASS" \
    "$GODOT" --path "$GODOT_ROOT" --resolution 640x360 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn "$GODOT_LOG_DIR/walk.png" 200 walk
# Pulls the peer out from under a live Gub and keeps ticking it, which is what
# leaving a match does: the peer is nulled at once and the arena survives the
# fade. `Gub.is_local` asked the missing peer for an id on every one of those
# frames, from three call sites, for thirteen frames, every time.
check "leaving a match cleanly" "leave PASS" \
    "$GODOT" --path "$GODOT_ROOT" --resolution 640x360 --script tools/snapshot.gd -- \
    res://tools/combat_range.tscn "$GODOT_LOG_DIR/leave.png" 200 leave
# Walks the menu into a real match and asks Input.mouse_mode what happened. It
# grabs the physical mouse for about a second on the way through, which is the
# only way to prove the thing it proves: every other check here stands the arena
# up directly, and this bug only existed on the path a player takes.
check "mouse capture entering a match" "cursor_flow: PASS" \
    "$GODOT" --path "$GODOT_ROOT" --resolution 640x360 res://tools/cursor_flow.tscn
echo

echo "smoke: $checks checks, $failures failures"
if [ "$failures" -gt 0 ]; then
    echo "smoke: FAIL   (logs in $LOG_DIR)"
    exit 1
fi
echo "smoke: PASS"

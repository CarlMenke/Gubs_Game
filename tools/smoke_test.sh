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

# Finding Godot is the one thing this script cannot assume. It is not on PATH on
# any machine this has run on; the download unpacks into a *directory* whose name
# ends in `.exe`, with the real binary inside it; and `$HOME` is not the Windows
# profile under every bash on Windows — Git Bash from the Start menu, a bash
# started from cmd, and WSL can all disagree about it, which is exactly how this
# went wrong once already. So look in every plausible place, in order, and say
# where you looked if none of them has it.
# Captured before the search clears $GODOT below, so an explicit setting is not
# quietly overwritten by the value the search finds.
GODOT_REQUESTED="${GODOT:-}"

# An explicit setting is a claim, not a hint: if it is wrong, say so rather than
# searching on and running a different binary than the one that was asked for.
if [ -n "$GODOT_REQUESTED" ] && { [ ! -x "$GODOT_REQUESTED" ] || [ -d "$GODOT_REQUESTED" ]; }; then
    echo "smoke: GODOT is set to something that is not an executable:"
    echo "       $GODOT_REQUESTED"
    echo "       (The '.exe' in the download's path is a directory, not the"
    echo "       binary — the binary is the _console.exe inside it.)"
    exit 2
fi

godot_candidates() {
    [ -n "$GODOT_REQUESTED" ] && printf '%s\n' "$GODOT_REQUESTED"
    command -v godot 2>/dev/null

    local roots=("$HOME")
    # $USERPROFILE is the Windows profile under Git Bash: C:\Users\name.
    if [ -n "${USERPROFILE:-}" ]; then
        if command -v cygpath >/dev/null 2>&1; then
            roots+=("$(cygpath -u "$USERPROFILE")")
        else
            roots+=("$(printf '%s' "$USERPROFILE" | sed 's|\|/|g; s|^\([A-Za-z]\):|/\1|')")
        fi
    fi
    # WSL mounts the Windows drives under /mnt; a bash from cmd may see /c.
    local d
    for d in /mnt/c/Users/* /c/Users/*; do
        [ -d "$d/Downloads" ] && roots+=("$d")
    done

    local root
    for root in "${roots[@]}"; do
        # The unpacked-directory layout first, then a bare binary beside it.
        printf '%s\n' "$root"/Downloads/Godot_v*_win64.exe/Godot_v*_win64_console.exe
        printf '%s\n' "$root"/Downloads/Godot_v*_win64_console.exe
        printf '%s\n' "$root"/Downloads/Godot_v*_win64.exe
    done
}

GODOT=""
while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    # An unmatched glob comes back as its own pattern, and the download's outer
    # `.exe` is a directory; -x with a -d check rejects both.
    if [ -x "$candidate" ] && [ ! -d "$candidate" ]; then
        GODOT="$candidate"
        break
    fi
done < <(godot_candidates)

if [ -z "$GODOT" ]; then
    echo "smoke: cannot find the Godot binary. Looked on PATH, and under"
    echo "       Downloads in: $HOME${USERPROFILE:+, $USERPROFILE}"
    echo "       Set GODOT=/path/to/Godot_console.exe and try again."
    echo "       (Note the '.exe' in the download's path is a directory, not the"
    echo "       binary — the binary is the _console.exe inside it.)"
    exit 2
fi

mkdir -p "$LOG_DIR"

# Under WSL the binary found above is a *Windows* executable, and a Windows
# executable cannot read a Linux path: `--path /mnt/c/...` gets you "Invalid
# project path specified" and nothing else. Git Bash does this translation for
# you on the way into a native binary; WSL deliberately does not. Translate the
# two paths that reach Godot, and only those — everything the shell itself opens
# stays POSIX.
GODOT_ROOT="$ROOT"
GODOT_LOG_DIR="$LOG_DIR"
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
    case "$GODOT" in
        *.exe)
            if ! command -v wslpath >/dev/null 2>&1; then
                echo "smoke: this is WSL and Godot is a Windows binary, but wslpath is"
                echo "       missing, so the project path cannot be translated."
                echo "       Run this from Git Bash or PowerShell instead."
                exit 2
            fi
            GODOT_ROOT="$(wslpath -w "$ROOT")"
            GODOT_LOG_DIR="$(wslpath -w "$LOG_DIR")"
            ;;
    esac
fi

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
    if ! grep -qF "$expect" "$log"; then
        echo "FAIL (expected: $expect)"
        sed 's/^/      /' "$log" | tail -20
        failures=$((failures + 1))
        return
    fi
    echo "ok"
}

echo "smoke: $ROOT"
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

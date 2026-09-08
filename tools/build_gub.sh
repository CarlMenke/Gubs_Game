#!/usr/bin/env bash
# Rebuild `art/generated/gub.glb` from the eight Mixamo FBX files.
#
#   bash tools/build_gub.sh                    # the shipped build (emission 0.15)
#   bash tools/build_gub.sh -- --emission 0.0  # no emission, to re-judge the night
#
# All this does is find Blender and hand it `tools/build_gub.py`, which is where
# the actual work and all the explanation live. It exists for the same reason
# `tools/find_godot.sh` does: nobody should have to remember where Blender
# unpacked itself on their machine, and a search that lives in one file does not
# go stale in the second copy.
#
# Anything after `--` is passed through to the script. Blender itself needs the
# `--` to stop parsing arguments, so it is included whether you pass one or not.
#
# After a successful build the asset still has to be imported and looked at:
#
#   GODOT --headless --path . --import
#   GODOT --headless --path . --script tools/inspect_scene.gd -- res://art/generated/gub.glb
#   GODOT --path . --resolution 1600x700 --script tools/snapshot.gd -- \
#       res://tools/preview_anim.tscn out/anim_Run.png 30 Run
#
# Inputs:  $BLENDER (optional override).
# Outputs: art/generated/gub.glb, and (after the import) gub_basecolor.jpg.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# An explicit setting is a claim, not a hint: if it is wrong, say so rather than
# searching on and running a different Blender than the one that was asked for.
if [ -n "${BLENDER:-}" ] && { [ ! -x "$BLENDER" ] || [ -d "$BLENDER" ]; }; then
    echo "build_gub: BLENDER is set to something that is not an executable:"
    echo "       $BLENDER"
    exit 2
fi

# Every plausible place, in order. Blender is on PATH on no machine this has run
# on; Windows installs it per minor version under Program Files, so the glob is
# sorted and the newest match wins; and `$HOME` is not the Windows profile under
# every bash on Windows, which is the mistake `tools/find_godot.sh` documents.
blender_candidates() {
    [ -n "${BLENDER:-}" ] && printf '%s\n' "$BLENDER"
    command -v blender 2>/dev/null

    printf '%s\n' /Applications/Blender.app/Contents/MacOS/Blender
    printf '%s\n' "$HOME"/Applications/Blender.app/Contents/MacOS/Blender

    # Newest first: `Blender 5.2` sorts after `Blender 4.2`, and the version
    # check below only settles whether a candidate is new *enough*.
    local dir
    for dir in "/c/Program Files" "/mnt/c/Program Files" \
               "${PROGRAMFILES:+$(cygpath -u "$PROGRAMFILES" 2>/dev/null)}"; do
        [ -n "$dir" ] || continue
        printf '%s\n' "$dir"/Blender\ Foundation/Blender\ */blender.exe | sort -Vr
    done
}

# Blender prints its version and exits. The FBX importer and the layered-action
# API this script uses are 4.4-and-later shapes (`action.fcurves` is gone), so an
# older Blender fails deep inside the script with an AttributeError instead of
# here with an explanation.
BLENDER_BIN=""
BLENDER_REJECTED=""
while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] && [ ! -d "$candidate" ] || continue
    version="$("$candidate" --version 2>/dev/null | head -n 1)"
    case "$version" in
        "Blender "[5-9].*|"Blender "[1-9][0-9]*.*) BLENDER_BIN="$candidate"; break ;;
        *) BLENDER_REJECTED="$BLENDER_REJECTED
       $candidate (reports ${version:-nothing})" ;;
    esac
done < <(blender_candidates)

if [ -z "$BLENDER_BIN" ] && [ -n "${BLENDER:-}" ]; then
    # A binary asked for by name is honoured even at the wrong version.
    BLENDER_BIN="$BLENDER"
fi

if [ -z "$BLENDER_BIN" ]; then
    echo "build_gub: cannot find Blender 5 or newer. Looked on PATH, in"
    echo "       /Applications, and under 'Program Files/Blender Foundation'."
    if [ -n "$BLENDER_REJECTED" ]; then
        echo "build_gub: these exist but are too old:$BLENDER_REJECTED"
        echo "       Blender 4.3 and earlier have unlayered actions, and this"
        echo "       script reads action.layers[].strips[].channelbags[]."
    fi
    echo "       Set BLENDER=/path/to/blender and try again."
    exit 2
fi

echo "build_gub: $BLENDER_BIN ($("$BLENDER_BIN" --version 2>/dev/null | head -n 1))"

# `--factory-startup` is deliberate: this machine has third-party add-ons that
# print into the log and open sockets on load, and a build that depends on what
# add-ons somebody has enabled is not a build.
"$BLENDER_BIN" --background --factory-startup \
    --python "$ROOT/tools/build_gub.py" -- "$@"
status=$?

if [ "$status" -ne 0 ]; then
    echo "build_gub: Blender exited $status — the GLB was NOT rewritten if the"
    echo "       failure was before the export step. Read the log above."
fi
exit "$status"

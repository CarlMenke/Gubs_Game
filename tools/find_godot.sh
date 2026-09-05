# Sourced, not run. Puts the path to a Godot 4.7 binary in $GODOT.
#
#   GODOT_TAG=smoke . "$(dirname "$0")/find_godot.sh"
#
# This lived inside `tools/smoke_test.sh` until `tools/net_test.sh` needed the
# same answer. Two copies of a search that has to be kept in step with where
# people actually install Godot is exactly the kind of thing that is right in
# one file and stale in the other, so it is one file. `$GODOT_TAG` is only the
# prefix on the messages, so each caller still sounds like itself.
#
# Sourcing matters: on failure this calls `exit 2`, which ends the *caller*.
# That is deliberate — every script here wants to stop when there is no engine.

GODOT_TAG="${GODOT_TAG:-godot}"

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
    echo "$GODOT_TAG: cannot find a Godot 4.7 binary. Looked for, in order:"
    for candidate in "${GODOT_CANDIDATES[@]}"; do
        echo "       $candidate"
    done
    if [ -n "$rejected" ]; then
        echo "$GODOT_TAG: these exist but are the wrong version:$rejected"
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
        echo "$GODOT_TAG: ############################################################"
        echo "$GODOT_TAG: WARNING  $GODOT"
        echo "$GODOT_TAG: WARNING  reports ${GODOT_VERSION:-no version at all}, and this project needs 4.7."
        echo "$GODOT_TAG: WARNING  On 4.6 every check below fails with a parse error about"
        echo "$GODOT_TAG: WARNING  add_blend_point(). That is the engine being too old. It is"
        echo "$GODOT_TAG: WARNING  not a bug in this code. Do not go looking for one."
        echo "$GODOT_TAG: ############################################################"
        echo
        ;;
esac

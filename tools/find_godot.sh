# Sourced, not run. Puts the path to a Godot 4.7 binary in $GODOT, and the paths
# to hand that binary in $GODOT_ROOT and $GODOT_LOG_DIR.
#
#   GODOT_TAG=smoke . "$(dirname "$0")/find_godot.sh"
#
# This lived inside `tools/smoke_test.sh` until `tools/net_test.sh` needed the
# same answer. A search for where people actually install Godot is exactly the
# kind of thing that gets fixed in one copy and left stale in the other, so it is
# one file. `$GODOT_TAG` is only the prefix on the messages, so each caller still
# sounds like itself.
#
# Sourcing matters: on failure this calls `exit 2`, which ends the *caller*. That
# is deliberate — every script here wants to stop when there is no engine.
#
# Inputs:  $ROOT (the repo), $LOG_DIR (optional), $GODOT (optional override).
# Outputs: $GODOT, $GODOT_VERSION, $GODOT_ROOT, $GODOT_LOG_DIR.

GODOT_TAG="${GODOT_TAG:-godot}"

# Captured before the search touches $GODOT, so an explicit setting is never
# quietly overwritten by whatever the search turns up.
GODOT_REQUESTED="${GODOT:-}"

# An explicit setting is a claim, not a hint: if it is wrong, say so rather than
# searching on and running a different binary than the one that was asked for.
if [ -n "$GODOT_REQUESTED" ] && { [ ! -x "$GODOT_REQUESTED" ] || [ -d "$GODOT_REQUESTED" ]; }; then
    echo "$GODOT_TAG: GODOT is set to something that is not an executable:"
    echo "       $GODOT_REQUESTED"
    echo "       (The '.exe' in the download's path is a directory, not the"
    echo "       binary — the binary is the _console.exe inside it.)"
    exit 2
fi

# Every plausible place, in order. Godot is on PATH on no machine this has run
# on; the Windows download unpacks into a *directory* whose name ends in `.exe`
# with the real binary inside it; and `$HOME` is not the Windows profile under
# every bash on Windows — Git Bash from the Start menu, a bash started from
# cmd, and WSL can all disagree about it, which is how this went wrong once
# already.
godot_candidates() {
    [ -n "$GODOT_REQUESTED" ] && printf '%s\n' "$GODOT_REQUESTED"
    command -v godot4 2>/dev/null
    command -v godot 2>/dev/null

    # macOS. The Downloads copy is listed before /Applications on purpose: a Mac
    # very often has an older Godot.app installed next to a newer build, and the
    # version check below is what settles it either way.
    printf '%s\n' "$HOME"/Downloads/Godot_v*_macos/Godot.app/Contents/MacOS/Godot
    printf '%s\n' "$HOME"/Applications/Godot.app/Contents/MacOS/Godot
    printf '%s\n' /Applications/Godot.app/Contents/MacOS/Godot

    local roots=("$HOME")
    # $USERPROFILE is the Windows profile under Git Bash: C:\Users\name.
    if [ -n "${USERPROFILE:-}" ]; then
        if command -v cygpath >/dev/null 2>&1; then
            roots+=("$(cygpath -u "$USERPROFILE")")
        else
            roots+=("$(printf '%s' "$USERPROFILE" | sed 's|\\|/|g; s|^\([A-Za-z]\):|/\1|')")
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

# Godot prints its version and exits. An empty answer means it would not run at
# all, which is worth telling apart from running and being the wrong version.
godot_version() {
    "$1" --version 2>/dev/null | tail -n 1
}

# The version test is not fussiness. The project pins 4.7 (D-001) and 4.6 cannot
# parse it at all: `add_blend_point()` gained a fourth argument in 4.7, so the
# Gub's animation tree fails to load and the error reads exactly like a bug in
# our own code — an hour of looking in the wrong file. So a wrong-version binary
# is skipped rather than used, and named at the end if nothing better turns up.
GODOT=""
GODOT_REJECTED=""
while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    # An unmatched glob comes back as its own pattern, and the download's outer
    # `.exe` is a directory; -x with a -d check rejects both.
    [ -x "$candidate" ] && [ ! -d "$candidate" ] || continue
    case "$(godot_version "$candidate")" in
        4.7.*) GODOT="$candidate"; break ;;
        *) GODOT_REJECTED="$GODOT_REJECTED
       $candidate (reports $(godot_version "$candidate" | sed 's/^$/nothing/'))" ;;
    esac
done < <(godot_candidates)

# An explicitly requested binary is honoured even at the wrong version — the
# caller asked for it by name — but loudly, below.
if [ -z "$GODOT" ] && [ -n "$GODOT_REQUESTED" ]; then
    GODOT="$GODOT_REQUESTED"
fi

if [ -z "$GODOT" ]; then
    echo "$GODOT_TAG: cannot find a Godot 4.7 binary. Looked on PATH, in"
    echo "       /Applications, and under Downloads in:"
    echo "       $HOME${USERPROFILE:+, $USERPROFILE}"
    if [ -n "$GODOT_REJECTED" ]; then
        echo "$GODOT_TAG: these exist but are the wrong version:$GODOT_REJECTED"
        echo "       4.6 cannot parse this project — add_blend_point() gained a fourth"
        echo "       argument in 4.7, so the failure looks like a bug in our own code."
    fi
    echo "       Set GODOT=/path/to/Godot and try again."
    echo "       (Note the '.exe' in the Windows download's path is a directory,"
    echo "       not the binary — the binary is the _console.exe inside it.)"
    exit 2
fi

GODOT_VERSION="$(godot_version "$GODOT")"
case "$GODOT_VERSION" in
    4.7.*) ;;
    *)
        echo "$GODOT_TAG: ############################################################"
        echo "$GODOT_TAG: WARNING  $GODOT"
        echo "$GODOT_TAG: WARNING  reports ${GODOT_VERSION:-no version at all}, and this needs 4.7."
        echo "$GODOT_TAG: WARNING  On 4.6 every check below fails with a parse error about"
        echo "$GODOT_TAG: WARNING  add_blend_point(). That is the engine being too old. It is"
        echo "$GODOT_TAG: WARNING  not a bug in this code. Do not go looking for one."
        echo "$GODOT_TAG: ############################################################"
        echo
        ;;
esac

# Under WSL the binary found above is a *Windows* executable, and a Windows
# executable cannot read a Linux path: `--path /mnt/c/...` gets you "Invalid
# project path specified" and nothing else. Git Bash does this translation for
# you on the way into a native binary; WSL deliberately does not. Translate the
# two paths that reach Godot, and only those — everything the shell itself opens
# stays POSIX.
GODOT_ROOT="${ROOT:-$PWD}"
GODOT_LOG_DIR="${LOG_DIR:-}"
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
    case "$GODOT" in
        *.exe)
            if ! command -v wslpath >/dev/null 2>&1; then
                echo "$GODOT_TAG: this is WSL and Godot is a Windows binary, but wslpath"
                echo "       is missing, so the project path cannot be translated."
                echo "       Run this from Git Bash or PowerShell instead."
                exit 2
            fi
            GODOT_ROOT="$(wslpath -w "${ROOT:-$PWD}")"
            [ -n "$GODOT_LOG_DIR" ] && GODOT_LOG_DIR="$(wslpath -w "$GODOT_LOG_DIR")"
            ;;
    esac
fi

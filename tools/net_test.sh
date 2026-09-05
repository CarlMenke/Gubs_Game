#!/usr/bin/env bash
# Two Godot processes, one real socket, over loopback.
#
#   bash tools/net_test.sh
#
# This is a MANUAL tool. It is deliberately **not** in `tools/smoke_test.sh` and
# must not be added to it: it binds UDP 27015 for real, and on macOS the first
# bind by a new binary can raise a firewall dialog. A gate that can stop for a
# dialog is not a gate.
#
# What it is for: every `@rpc` in this project has, until now, only ever run its
# "call locally" half. `Net.start_offline()` (D-011) opens a session on an
# `OfflineMultiplayerPeer` — peer 1, `is_server()` true, no socket — so nothing
# has ever been serialized, sent, received or decoded. `tools/net_loopback.gd`
# is the harness; this script starts its two halves, feeds the client the
# invite code the host prints, and reduces the pair to one PASS/FAIL.
#
# It currently exits non-zero, and that is the correct answer rather than a
# broken tool: all eight stages pass, and the run then reports three engine
# errors raised by shipping code in `scripts/` that the offline peer had been
# hiding. They are printed with an explanation apiece at the bottom of the run.
# When they are fixed this goes green on its own; nothing here needs editing.
#
# Notes for anyone running it:
#   * Both processes share Godot's user data directory (it is keyed on the
#     project *name*, not the path), so they would otherwise join under the same
#     name from `user://settings.cfg`. The harness sets names explicitly; see
#     its header.
#   * Assets are imported once, up front, so neither process has to — two Godot
#     processes writing `.godot/` at the same time is a fight nobody wins.
#   * Everything is cleaned up on the way out, including on failure and on
#     timeout, so a bad run never leaves a Godot sitting on port 27015. If one
#     somehow survives, `lsof -nP -iUDP:27015` will find it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${TMPDIR:-/tmp}/gub_net"
HOST_LOG="$LOG_DIR/host.log"
CLIENT_LOG="$LOG_DIR/client.log"

## Seconds to wait for the host to print its invite code.
CODE_TIMEOUT=60
## Seconds for the whole run, once both processes are up. Two simultaneous
## island builds are the bulk of it.
RUN_TIMEOUT=300

host_pid=""
client_pid=""

# ------------------------------------------------------------- the engine ---
# Shared with `tools/smoke_test.sh`; see `tools/find_godot.sh`.
GODOT_TAG=net
. "$ROOT/tools/find_godot.sh"

# ------------------------------------------------------------------ tidying ---
# Runs on every exit path there is. Without it a failed run leaves a headless
# Godot holding the port, and the *next* run then fails inside `host_lobby()`
# with an error that reads like a bug in the networking code.
cleanup() {
    for pid in "$host_pid" "$client_pid"; do
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2>/dev/null || continue
        kill "$pid" 2>/dev/null
    done
    # A moment to go quietly, then insist.
    sleep 0.5
    for pid in "$host_pid" "$client_pid"; do
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    done
    return 0
}
trap cleanup EXIT INT TERM

dump() {
    echo
    echo "net: ---------------- $1 ----------------"
    if [ -s "$2" ]; then
        sed 's/^/    /' "$2"
    else
        echo "    (nothing)"
    fi
}

fail() {
    echo "net: $1"
    dump "host" "$HOST_LOG"
    dump "client" "$CLIENT_LOG"
    echo
    echo "net: FAIL   (logs in $LOG_DIR)"
    exit 1
}

mkdir -p "$LOG_DIR"
: >"$HOST_LOG"
: >"$CLIENT_LOG"

echo "net: $ROOT"
echo "net: $GODOT ($GODOT_VERSION)"
echo

# One import, before either process starts. Two Godot processes importing into
# the same `.godot/` at once corrupt each other's cache, and the symptom is a
# scene that loads without its script rather than an error.
echo "importing assets"
if ! "$GODOT" --headless --path "$ROOT" --import >"$LOG_DIR/import.log" 2>&1; then
    echo "  FAIL — import did not complete"
    tail -20 "$LOG_DIR/import.log" | sed 's/^/      /'
    exit 1
fi
echo "  ok"
echo

# --------------------------------------------------------------- the host ---
echo "starting the host"
"$GODOT" --headless --path "$ROOT" tools/net_loopback.tscn -- host \
    >"$HOST_LOG" 2>&1 &
host_pid=$!

# Polled, not slept on: the host binds its port in a few hundred milliseconds on
# a warm cache and takes several seconds on a cold one, and a fixed sleep would
# have to be the worst case every time and still be wrong on somebody's machine.
code=""
deadline=$(($(date +%s) + CODE_TIMEOUT))
while [ -z "$code" ]; do
    code="$(sed -n 's/^net_loopback: code=\([A-Z0-9-]*\).*$/\1/p' "$HOST_LOG" | head -1)"
    [ -n "$code" ] && break
    if ! kill -0 "$host_pid" 2>/dev/null; then
        fail "the host exited before it printed an invite code"
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        fail "the host printed no invite code in ${CODE_TIMEOUT}s (a macOS firewall dialog will do this)"
    fi
    sleep 0.2
done
echo "  invite code $code"
echo

# ------------------------------------------------------------- the client ---
echo "starting the client"
"$GODOT" --headless --path "$ROOT" tools/net_loopback.tscn -- join "$code" \
    >"$CLIENT_LOG" 2>&1 &
client_pid=$!
echo "  dialling $code"
echo

echo "running (up to ${RUN_TIMEOUT}s; two island builds are most of it)"
timed_out=0
deadline=$(($(date +%s) + RUN_TIMEOUT))
while kill -0 "$host_pid" 2>/dev/null || kill -0 "$client_pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        timed_out=1
        break
    fi
    sleep 0.25
done

if [ "$timed_out" -eq 1 ]; then
    cleanup
    fail "timed out after ${RUN_TIMEOUT}s — both processes killed"
fi

wait "$host_pid" 2>/dev/null; host_rc=$?
wait "$client_pid" 2>/dev/null; client_rc=$?
host_pid=""
client_pid=""
echo "  host exited $host_rc, client exited $client_rc"
echo

# ---------------------------------------------------------------- verdict ---
# Both halves have to say PASS. An exit code on its own proves nothing here for
# the same reason it proves nothing in `smoke_test.sh`: Godot prints a
# SCRIPT ERROR and carries straight on running.
peers_failed=0
for pair in "host:$HOST_LOG:$host_rc" "client:$CLIENT_LOG:$client_rc"; do
    who="${pair%%:*}"
    rest="${pair#*:}"
    log="${rest%%:*}"
    rc="${rest##*:}"
    printf '  %-8s ' "$who"
    if [ "$rc" -ne 0 ]; then
        echo "FAIL (exited $rc)"
        peers_failed=1
    elif grep -q "SCRIPT ERROR" "$log"; then
        echo "FAIL (script error)"
        peers_failed=1
    elif ! grep -qF "net_loopback: PASS" "$log"; then
        echo "FAIL (never said PASS)"
        peers_failed=1
    else
        echo "ok — $(sed -n 's/^net_loopback: \([0-9]* checks.*\)$/\1/p' "$log" | tail -1)"
    fi
done
echo

if [ "$peers_failed" -ne 0 ]; then
    fail "one of the two peers failed"
fi

# -------------------------------------------------------- what Godot said ---
# Eight green stages and two clean exit codes prove less than they look like
# they do. Godot prints an error and carries straight on running, which is why
# `smoke_test.sh` treats a SCRIPT ERROR as a failure (D-015); these are engine
# errors rather than script errors and the same argument applies to them. Every
# one that has turned up here so far was raised by shipping code in `scripts/`
# doing something the offline peer had been letting it get away with, which is
# the entire point of this tool.
#
# Exit-time complaints are excluded. A couple of dozen leaked ObjectDB
# instances and dummy-renderer RIDs are reported by every harness in this repo
# and always will be — they are the `preload` constants on the item and audio
# scripts, alive for as long as the scripts are, and `playthrough.gd` and
# `match_rules.gd` carry the same tail.
engine_errors() {
    grep '^ERROR: ' "$1" 2>/dev/null | grep -v 'at exit' | sort | uniq -c | sort -rn
}

note_if() {
    if grep -q "$1" "$HOST_LOG" "$CLIENT_LOG" 2>/dev/null; then
        shift
        for line in "$@"; do echo "    $line"; done
        echo
    fi
}

echo "what Godot said"
defects=0
for pair in "host:$HOST_LOG" "client:$CLIENT_LOG"; do
    who="${pair%%:*}"
    log="${pair#*:}"
    errs="$(engine_errors "$log")"
    [ -n "$errs" ] || continue
    defects=1
    echo "  $who:"
    printf '%s\n' "$errs" | sed 's/^ */    /'
done

if [ "$defects" -eq 0 ]; then
    echo "  nothing — the engine was quiet"
    echo
    echo "net: PASS   (logs in $LOG_DIR)"
    exit 0
fi

echo
echo "  these are bugs in scripts/, not in the harness:"
echo
note_if "on yourself is not allowed" \
    "* Net does rpc_id(1, ...) from peer 1. \`_submit_chat\`, \`_request_ready\`," \
    "  \`_request_team\` and \`_request_rename\` are all \"call_remote\", so the host" \
    "  chatting, readying, switching team or renaming raises this every time." \
    "  Nothing is lost — each of those calls the same function locally straight" \
    "  afterwards — but the log fills up. Fix: only send when not the host, or" \
    "  make the RPCs \"call_local\" and drop the manual local call."
note_if "Failed to get cached node" \
    "* MatchState spawns Gubs with a reliable RPC while the" \
    "  MultiplayerSynchronizer on each Gub begins sending unreliable updates" \
    "  immediately. Those are different ENet channels, so an update can overtake" \
    "  the spawn and land on a node the receiver has not built yet. Transient —" \
    "  the first fraction of a second of movement is dropped, then it settles."
note_if "Unable to get unique ID" \
    "* MatchState.local_gub() asks multiplayer for its unique id with no peer" \
    "  assigned. Gub.is_local() already guards against exactly this and says so" \
    "  in a comment; MatchState never got the same guard, and hud.gd reaches" \
    "  local_gub() three times a frame — so leaving a match, or being dropped by" \
    "  a host who closed the lobby, logs three of these per frame until the" \
    "  scene finally changes."

echo "net: FAIL   (the eight stages passed; the engine did not stay quiet)"
echo "net:        logs in $LOG_DIR"
exit 1

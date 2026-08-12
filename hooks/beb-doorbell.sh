#!/bin/sh
# beb-doorbell — wake an idle Claude when beb mail arrives.
#
# Wired as an asyncRewake hook on SessionStart and Stop: it parks in the
# background on `beb wait` (a kernel watch, no polling) and exits 2 when
# a message arrives, which wakes the session. The woken turn is told to
# read, not handed mail: delivery is the drain's job at the boundary and
# the cursor belongs to the agent's own `beb read`.
#
# `beb wait` is edge-triggered by contract: mail already standing unread
# never fires it (the drain announces that at each boundary), only the
# next arrival does. One arrival, one wake, no wake loops.
#
# A doorbell is superseded on every arm: the previous one, found by
# recorded pid and live command line, is killed before the new one
# parks, so a reloaded plugin or a queue of re-arms can never ring
# twice. No session id on stdin means no reaping: killing across
# sessions is worse than a stale doorbell.
set -u
BEB="${BEB_BIN:-beb}"

# Same identity gate as everywhere: beb answers, we don't guess.
"$BEB" whoami >/dev/null 2>&1 || exit 0

sid=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null | head -n 1)
den="${TMPDIR:-/tmp}/claude-beb-doorbells.$(id -u)"
if [ -n "$sid" ]; then
    mkdir -p "$den"
    if [ -f "$den/$sid" ]; then
        while IFS= read -r opid; do
            case $opid in '' | *[!0-9]*) continue ;; esac
            case $(ps -o command= -p "$opid" 2>/dev/null) in
            *"beb wait"*) kill "$opid" 2>/dev/null ;;
            esac
        done <"$den/$sid"
        rm -f "$den/$sid"
    fi
fi

# Park. The recorded pid is the `beb wait` child itself, so the next arm
# can supersede this doorbell by killing exactly that process; a killed
# wait comes back nonzero and this doorbell stands down in silence.
"$BEB" wait -t "${CLAUDE_BEB_WAIT_SECS:-86400}" &
wpid=$!
[ -n "$sid" ] && printf '%s\n' "$wpid" >"$den/$sid" 2>/dev/null
wait "$wpid"
rc=$?
[ -n "$sid" ] && rm -f "$den/$sid" 2>/dev/null

# Timeout, refusal, or superseded: quiet. The next boundary re-arms.
[ "$rc" -eq 0 ] || exit 0
# Confirm something still stands unread at wake time; delivered-elsewhere
# silence is correct silence.
[ -n "$("$BEB" list 2>/dev/null)" ] || exit 0

echo "beb mail is waiting; read it with: beb read" >&2
exit 2

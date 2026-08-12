#!/bin/sh
# beb-doorbell — wake an idle Claude when beb mail arrives.
#
# Wired as an asyncRewake hook on SessionStart and Stop: it parks in the
# background on `beb wait` (a kernel watch, no polling) and exits 2 when
# a message arrives, which wakes the session. The woken turn is told to
# read, not handed mail: delivery is the drain's job at the boundary and
# the cursor belongs to the agent's own `beb read`.
#
# Ownership, not supersession-by-kill: each arm writes a fresh token to
# the session's file, last writer wins, and every doorbell re-reads the
# file at each waking moment — a doorbell that no longer holds the token
# exits on its own, silently. Nothing is ever killed by pid, so
# process-id reuse can never reach an innocent process, and any
# interleaving of simultaneous arms converges to exactly one owner. The
# wait runs in short legs so a superseded doorbell lingers minutes, not
# a day.
#
# Arrival is judged by content, not by the wait alone: `beb list` at arm
# time is the baseline, and a ring needs the list to be non-empty AND
# changed — so standing unread never re-rings (the boundary drain owns
# that), and mail consumed by another integration before we looked is
# silence, not a stale wake.
set -u
BEB="${BEB_BIN:-beb}"

# Same identity gate as everywhere: beb answers, we don't guess.
"$BEB" whoami >/dev/null 2>&1 || exit 0

sid=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null | head -n 1)
den="${TMPDIR:-/tmp}/claude-beb-doorbells.$(id -u)"
own="$den/$sid"
token="$$.$(od -An -N4 -tx4 /dev/urandom 2>/dev/null | tr -d ' \t')"

if [ -n "$sid" ]; then
    mkdir -p "$den"
    printf '%s\n' "$token" >"$own"
    # Concurrent arms both write before either reads; re-reading after a
    # beat leaves exactly one owner under any interleaving.
    sleep 1
    [ "$(head -n 1 "$own" 2>/dev/null)" = "$token" ] || exit 0
fi

owned() { [ -z "$sid" ] || [ "$(head -n 1 "$own" 2>/dev/null)" = "$token" ]; }

total="${CLAUDE_BEB_WAIT_SECS:-86400}"
leg=900
[ "$total" -lt "$leg" ] && leg=$total
start=$(date +%s)
base=$("$BEB" list 2>/dev/null)

while :; do
    t0=$(date +%s)
    "$BEB" wait -t "$leg"
    rc=$?
    owned || exit 0
    now=$(date +%s)
    cur=$("$BEB" list 2>/dev/null)
    if [ -n "$cur" ] && [ "$cur" != "$base" ]; then
        [ -n "$sid" ] && rm -f "$own"
        echo "beb mail is waiting; read it with: beb read" >&2
        exit 2
    fi
    # A wait that came back non-zero long before its leg elapsed is a
    # refusal (mailbox gone, beb missing), not a timeout: stand down
    # quietly, the next boundary re-arms.
    [ "$rc" -ne 0 ] && [ $((now - t0)) -lt 5 ] && exit 0
    [ $((now - start)) -ge "$total" ] && exit 0
    base=$cur
done

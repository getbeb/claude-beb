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
# Arrival is judged by a mark, not by the wait alone. `beb wait` marks
# from the reader's cursor by default, which would ring for standing
# mail the boundary drain already announced — and ring again at every
# arm, waking a session forever for mail it was told about. So the arm
# takes a mark of its own with `--timeout 0`, one past everything that
# exists, and every leg waits `--from` it: a leg boundary drops nothing,
# and mail consumed by another integration before we looked is silence
# rather than a stale wake.
set -u
BEB="${BEB_BIN:-beb}"

# Read once: the session id and the launch directory are both in it.
input=$(cat 2>/dev/null) || input=""
sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)

# The pin, when the environment carries none.
#
# beb-identity.sh writes BEB_IDENTITY to CLAUDE_ENV_FILE, which Claude
# Code sources before every Bash command -- and not before a hook. So on
# a machine that does not already export BEB_IDENTITY in the environment
# Claude Code was launched from, every hook here saw no identity, beb
# refused, and each exited 0 saying nothing. The agent's own `beb` calls
# worked the whole time, which is what made it invisible: mail arrived,
# nothing announced it, and nothing had failed.
#
# The launch directory is in the same hook input already being read, so
# it is read from there rather than guessed from a working directory a
# hook does not control.
if [ -z "${BEB_IDENTITY:-}" ]; then
    dir=$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$dir" ] && export BEB_IDENTITY="$dir"
fi

# Same identity gate as everywhere: beb answers, we don't guess.
"$BEB" whoami >/dev/null 2>&1 || exit 0
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

# One past everything present at arm time. beb prints it whether or not
# anything was waiting, so this bootstraps against an empty mailbox too.
mark=$("$BEB" wait --timeout 0 2>/dev/null)
[ -n "$mark" ] || exit 0

while :; do
    next=$("$BEB" wait --from "$mark" --timeout "$leg" 2>/dev/null)
    rc=$?
    owned || exit 0
    [ -n "$next" ] && mark=$next

    # beb's exit codes say which of the three happened, so nothing here
    # has to time the wait and guess: 0 something landed, 2 the leg
    # elapsed, anything else a refusal (no mailbox, no identity, no beb).
    case $rc in
        0)
            # Still unread? Mail taken by another integration between the
            # wait returning and this check is silence, not a stale wake.
            if "$BEB" wait --timeout 0 >/dev/null 2>&1; then
                [ -n "$sid" ] && rm -f "$own"
                echo "beb mail is waiting; read it with: beb read" >&2
                exit 2
            fi
            ;;
        2) ;;
        *) exit 0 ;;
    esac
    [ $(( $(date +%s) - start )) -ge "$total" ] && exit 0
done

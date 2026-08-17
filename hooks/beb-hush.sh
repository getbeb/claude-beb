#!/bin/sh
# beb-hush — stand the doorbell down while the session is working.
#
# The doorbell is armed at a turn boundary and waits from there, which
# means it is still waiting during the next turn. Mail landing mid-work
# then rang it, and its wake is an exit 2: the session was interrupted
# and made to handle mail it had not asked for, halfway through
# something else. That is the opposite of what beb is for -- mail waits,
# and is never pushed, because a context switch costs an agent what it
# costs a person.
#
# So a turn beginning takes the doorbell's ownership away. It is already
# the mechanism that decides whether a woken doorbell may speak: the
# check sits between the wait returning and the announcement, so one
# removed file turns a wake into a silent exit. Nothing is lost -- the
# drain announces at the next boundary, which is where an interruption
# belongs in the first place.
#
# Re-armed by the Stop hook, when the turn ends and the session is idle
# again and a doorbell is once more the right thing to have.
set -u

input=$(cat 2>/dev/null) || input=""
sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$sid" ] || exit 0

den="${TMPDIR:-/tmp}/claude-beb-doorbells.$(id -u)"
rm -f "$den/$sid"
exit 0

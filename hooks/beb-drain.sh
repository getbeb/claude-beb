#!/bin/sh
# beb-drain — announce waiting beb mail at a Claude Code turn boundary.
#
# Wired to SessionStart and Stop: ask `beb list`, and if anything stands
# unread, hand back one bounded announcement as additional context. The
# agent reads with `beb read` itself; this script never consumes, so the
# cursor moves only by the agent's own act, and the announcement repeats
# at each boundary until reading makes it stop being true.
#
# beb resolves identity from the working directory (./.beb); nothing is
# configured here. No identity or no mail is a silent exit 0, so a quiet
# boundary stays quiet.
#
# Hook input arrives as JSON on stdin. The only thing read from it is the
# event name, echoed back so the output is valid for whichever hook
# invoked us.
set -u
BEB="${BEB_BIN:-beb}"

input=$(cat)
event=$(printf '%s' "$input" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p')
[ -n "$event" ] || event="Stop"

unread=$("$BEB" list 2>/dev/null) || exit 0
[ -n "$unread" ] || exit 0

msg="[beb] mail waits:
$unread
read with: beb read"

# jq builds valid JSON so a sender key or any future list column can
# never break the envelope.
if command -v jq >/dev/null 2>&1; then
    printf '%s' "$msg" | jq -Rs --arg ev "$event" '{
    hookSpecificOutput: {
      hookEventName: $ev,
      additionalContext: .
    }
  }'
else
    # No jq: exit-2 stderr is surfaced by Claude as feedback. Loses
    # structure but never mangles JSON.
    printf '%s\n' "$msg" >&2
    exit 2
fi

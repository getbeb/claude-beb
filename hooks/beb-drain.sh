#!/bin/sh
# beb-drain — announce waiting beb mail at a Claude Code turn boundary.
#
# Wired to SessionStart and Stop: ask `beb list`, and if anything stands
# unread, hand back one bounded announcement as additional context. The
# agent reads with `beb read` itself; this script never consumes, so the
# cursor moves only by the agent's own act, and the announcement repeats
# at each boundary until reading makes it stop being true.
#
# beb resolves identity; this hook doesn't. No identity or no mail is a
# silent exit 0, so a quiet boundary stays quiet.
#
# Hook input arrives as JSON on stdin. The only thing read from it is the
# event name, echoed back so the output is valid for whichever hook
# invoked us.
set -u
BEB="${BEB_BIN:-beb}"

input=$(cat)
event=$(printf '%s' "$input" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p')
[ -n "$event" ] || event="Stop"

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

# `beb list` pages: the rows are stdout, and how much was NOT shown is
# on stderr with every other line beb says about them. Taking only
# stdout would hand back ten rows of twenty-five and call it the mail.
# Every line beb writes to stderr begins `beb: `, so one capture splits
# cleanly into the artifact and what is said about it.
out=$("$BEB" list --unread --limit 10 2>&1) || exit 0
unread=$(printf '%s\n' "$out" | grep -v '^beb:')
[ -n "$unread" ] || exit 0
summary=$(printf '%s\n' "$out" | sed -n 's/^beb: //p' | head -n 1)

msg="[beb] mail waits: $summary
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
elif command -v python3 >/dev/null 2>&1; then
    # Same JSON, same guarantee, from a different interpreter. Whether
    # this hook interrupts must not depend on which binaries a machine
    # happens to carry: with jq it hands back context and exits 0, and
    # without it the only other path was exit 2, which Claude surfaces
    # as blocking feedback. One host in this fleet has no jq, so its
    # every boundary with mail standing was an interruption -- the exact
    # thing the doorbell was just taught not to do.
    printf '%s' "$msg" | python3 -c 'import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": sys.argv[1],
                                         "additionalContext": sys.stdin.read()}}))' "$event"
else
    # Neither: exit-2 stderr is surfaced by Claude as feedback. It
    # interrupts, which is worse than context and better than silence,
    # and it never mangles JSON because it builds none.
    printf '%s\n' "$msg" >&2
    exit 2
fi

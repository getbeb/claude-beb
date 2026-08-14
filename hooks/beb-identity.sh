#!/bin/sh
# beb-identity — pin the session to the identity it started in.
#
# Wired to SessionStart alone. beb resolves identity from the working
# directory, and an agent's working directory is not a place it stays:
# it moves between subdirectories, spawns shells, and hands work to
# subagents. Every one of those is a chance to sign as somebody else or
# as nobody, silently, in a tool whose whole subject is who signed.
#
# So the directory the session began in is written once to
# CLAUDE_ENV_FILE, which Claude Code sources before every Bash command.
# From then on `cd` moves the shell and not the signer.
#
# This is not claude-beb resolving identity — it still never opens a
# key, reads a roster, or chooses between candidates. It records where
# the session started; beb decides who lives there, and refuses if the
# answer is nobody or two.
#
# SessionStart only, deliberately. The same variable is offered on
# CwdChanged, and writing it there would re-pin on every directory
# change, which is the drift this exists to stop.
set -u

# No env file, nothing to write. Older builds are reported to leave it
# empty, so absence is a quiet exit rather than an error.
[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0

# An operator who launched with BEB_IDENTITY already said who they are.
# A hook that overrode that would be guessing over an explicit choice.
[ -n "${BEB_IDENTITY:-}" ] && exit 0

# The session's own directory, from the hook input, falling back to the
# process's. Reading it from the JSON matters: the launch directory is
# what the session is, and it is not always where this hook is run.
input=$(cat 2>/dev/null) || input=""
dir=$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$dir" ] || dir=$(pwd)

# Pinned whether or not the directory is an identity yet. The guard used
# to skip a bare directory, because beb resolved the working directory
# and its own "no .beb here" was the better sentence. beb 0.6.0 reads
# nothing but the pin, so an unpinned session gets the generic
# "BEB_IDENTITY is not set" instead, while a pinned one gets the
# specific "BEB_IDENTITY=/path has no .beb; make one with: (cd /path &&
# beb init)" -- which names the directory and the command. The pin is
# what turns a nothing into an answerable nothing.

# Single-quote the value and escape any quote inside it, so a path with
# spaces or punctuation survives being sourced.
escaped=$(printf '%s' "$dir" | sed "s/'/'\\\\''/g")
printf "export BEB_IDENTITY='%s'\n" "$escaped" >> "$CLAUDE_ENV_FILE" 2>/dev/null || exit 0
exit 0

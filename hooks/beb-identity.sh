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

# The project directory, passed from hooks.json because it is a command
# substitution rather than a variable in the environment. It names where
# the session started and stays there when Claude enters a worktree.
proj=${1:-}

# The session's own directory, from the hook input, falling back to the
# process's. Reading it from the JSON matters: the launch directory is
# what the session is, and it is not always where this hook is run.
input=$(cat 2>/dev/null) || input=""
cwd=$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$cwd" ] || cwd=$(pwd)

# An operator who launched with an absolute BEB_IDENTITY already said who
# they are, and a hook that overrode that would be guessing over an
# explicit choice.
#
# A relative one cannot be left alone the same way. beb refuses it, since
# it names a different directory from every cwd, so the session would
# have no identity at all -- and the refusal is swallowed by every hook
# here, each of which reads one as "nothing to do in this directory".
# It is resolved against where the session started, which is what a
# relative pin was written against; Claude's cwd has already followed it
# into the worktree where the identity is not.
explicit=0
case "${BEB_IDENTITY:-}" in
    "")  dir=$cwd ;;
    /*)  exit 0 ;;
    *)   explicit=1
         base=${proj:-$cwd}
         dir="$base/$BEB_IDENTITY" ;;
esac

# What every failure here comes to, said once.
#
# SessionStart stdout is added to the session's context, so this reaches
# the agent that is about to run beb commands, and it names the pin it
# can put in front of them. Exit stays 0: a session that cannot be
# pinned is still a session, and beb's own refusal is the backstop.
unpinned() {
    echo "[beb] this session is not pinned: $1"
    echo "[beb] beb will refuse every command here until it is. Prefix each call with BEB_IDENTITY='$dir', or restart with: BEB_IDENTITY='$dir' claude"
    exit 0
}

# No env file, nothing to write, and now nothing quiet about it.
#
# This used to exit 0 in silence, on the report that older builds leave
# the variable empty. Claude Code 2.1.220 supplies it on every
# SessionStart hook, and overrides an inherited one rather than passing
# it through, so absence is no longer a build quirk to tolerate: it is
# the pin not happening. A hook that announces "pinning identity" and
# then returns 0 having pinned nothing is indistinguishable from one
# that worked, which is how an unpinned session survived long enough to
# need a `beb whoami` to find.
[ -n "${CLAUDE_ENV_FILE:-}" ] || unpinned "Claude Code gave this hook no env file to write the pin to"

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
#
# Truncating, not appending. The file is this hook's own -- Claude Code
# hands each hook its own sessionstart-hook-<n>.sh -- and SessionStart
# fires again on every resume with the same path, so appending wrote the
# same export a second time, and a third. Sourcing stayed correct and the
# file grew for the life of the session. One line is the whole state
# this hook has.
escaped=$(printf '%s' "$dir" | sed "s/'/'\\\\''/g")
printf "export BEB_IDENTITY='%s'\n" "$escaped" >"$CLAUDE_ENV_FILE" 2>/dev/null ||
    unpinned "the env file at $CLAUDE_ENV_FILE could not be written"

# A pin the caller chose and beb cannot use is the one failure here that
# has to be loud. Everywhere else silence is right: a session in a
# directory that is not an identity should say nothing at all. But
# somebody who set BEB_IDENTITY meant to be somebody, and otherwise the
# way they find out they are not is a mailbox quietly filling up.
if [ "$explicit" = 1 ] && ! BEB_IDENTITY="$dir" "${BEB_BIN:-beb}" whoami >/dev/null 2>&1; then
    echo "[beb] BEB_IDENTITY was relative and does not resolve to an identity: $dir"
    echo "[beb] relaunch with an absolute pin: BEB_IDENTITY=/path/to/identity claude"
fi
exit 0

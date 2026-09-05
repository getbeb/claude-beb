# beb-pin.sh — decide a hook's BEB_IDENTITY, the way the session's own
# shell has it. Sourced by the hooks that need one; sets nothing else.
#
# Two things go wrong without this, and both fail the same silent way,
# because every caller here reads a beb refusal as "no identity, stay
# quiet" -- which is correct for a session in a directory that is not an
# identity, and indistinguishable from a session whose pin is broken.
#
# The pin is missing. beb-identity.sh writes BEB_IDENTITY to
# CLAUDE_ENV_FILE, which Claude Code sources before every Bash command
# and not before a hook. So on a machine that does not already export it
# in the environment Claude Code was launched from, every hook saw no
# identity while the agent's own beb calls worked the whole time.
#
# The pin is relative. beb refuses one, since it names a different
# directory from every cwd. Claude's cwd follows it into a git worktree
# and an identity does not live there, so a coder launched with
# BEB_IDENTITY=.agents/coder2 had no drain and no doorbell for ten
# minutes and nothing said why. The base for resolving it is the
# directory the session started in -- what CLAUDE_PROJECT_DIR names,
# passed in from hooks.json because it is a command substitution rather
# than a variable in the environment. Claude's own cwd is the one base
# it must not be: that is the directory the pin was already wrong from.
beb_pin() {   # $1 the hook input JSON, $2 the project dir if there is one
    _cwd=$(printf '%s' "$1" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    case "${BEB_IDENTITY:-}" in
        # Absolute, so the caller has already said who they are.
        /*) return 0 ;;
        # None at all: the launch directory, which is where the pin hook
        # would have put it.
        "") [ -n "$_cwd" ] && export BEB_IDENTITY="$_cwd"
            return 0 ;;
    esac
    _base=${2:-$_cwd}
    case "$_base" in
        /*) export BEB_IDENTITY="$_base/$BEB_IDENTITY" ;;
    esac
}


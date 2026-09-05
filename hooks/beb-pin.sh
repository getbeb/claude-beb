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

# Who the pin makes this session, said the way a reader says it.
#
# The announcement exists so a session that could be either role knows
# which one it is speaking for, and a path is a poor answer to that: two
# coders under one checkout differ by a trailing word, and the reader
# already chose a better name for each. So the roster name, and the pin
# only when nobody has named this identity here -- where a path is the
# one thing that still distinguishes it, and is what a wrong pin needs
# shown anyway.
#
# Both halves are artifacts on stdout, not prose: `whoami` prints the
# address, `contacts` prints the roster in the file's own format, and
# the address is exactly its second and third fields. Nothing here reads
# a sentence beb wrote, which is the rule that lets beb reword them.
beb_who() {
    _b=${BEB_BIN:-beb}
    _addr=$("$_b" whoami 2>/dev/null) || _addr=""
    if [ -n "$_addr" ]; then
        _name=$("$_b" contacts 2>/dev/null |
            awk -v k="$_addr" '$2" "$3==k { print $1; exit }')
        if [ -n "$_name" ]; then
            printf '%s' "$_name"
            return 0
        fi
    fi
    printf '%s' "${BEB_IDENTITY:-}"
}

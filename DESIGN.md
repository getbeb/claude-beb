# claude-beb

beb mail as an event-driven wake for Claude Code.

beb delivers signed messages into a mailbox and never interrupts
anyone; wake policy belongs to the runtime. claude-beb is that policy
for Claude Code: mail arriving while the session is idle wakes it,
and mail waiting at a turn boundary is announced there. Nothing ever
lands mid-turn.

## The two primitives it joins

From beb, three verbs. `list` shows what is unread and moves
nothing; `read` consumes; `wait` blocks on a kernel watch until the
next message arrives, edge-triggered, so a shell process can stand
at the door without polling. claude-beb never touches the spool
directly; everything goes through beb.

From Claude Code, that surface is exactly two seams. Boundary hooks
(SessionStart, Stop) run at the edges of turns and can hand back
context. An `asyncRewake` hook runs in the background while the
session is idle and wakes it by exiting 2 (proven behavior, one-shot
per invocation, re-armed at each boundary).

## Invariants

1. claude-beb never consumes mail. It announces; the agent reads.
   The cursor moves only by the agent running `beb read` itself.
2. Nothing lands mid-turn. Announcement happens at boundaries; the
   wake fires only while the session is idle, and the woken turn is
   told to read, not handed bodies.
3. Injected text is bounded: the unread `list` lines and the verb to
   act on them. Bodies are uncapped and belong to `beb read`.
4. The doorbell wakes on arrival, never on standing. `beb wait` is
   edge-triggered by contract, so mail that merely sits unread is
   re-announced at each boundary instead of re-waking the session.
   One arrival, one wake, no wake loops.
5. State is one token file per session. Each arm writes a fresh
   token, last writer wins, and every doorbell re-checks ownership
   at each waking moment: a superseded doorbell exits on its own,
   silently. Nothing is ever killed by pid — process-id reuse can
   never reach an innocent — and simultaneous arms converge to one
   owner under any interleaving. Everything else claude-beb knows
   it learns from beb at the moment it looks.
6. No identity, no activity. Every hook stands as whatever identity
   beb resolves for the session's process — `BEB_IDENTITY` in Claude
   Code's environment, which hooks inherit; the resolution is beb's,
   never claude-beb's. Where beb resolves nobody, every hook exits
   silently.

   beb 0.6.0 reads the pin and nothing else. It resolved the working
   directory as well until then, which is why 7 could once skip a
   directory that was not yet an identity: beb's own "no .beb here"
   was the better sentence. It no longer says that, so the pin is
   written either way and the refusal names the directory and the
   command that fixes it.
7. The session is pinned to the directory it began in. An agent's
   working directory is not a place it stays: it moves between
   subdirectories, spawns shells, hands work to subagents, and each
   move is a chance to sign as somebody else or as nobody, quietly,
   in a tool whose subject is who signed. So SessionStart writes that
   one directory to `CLAUDE_ENV_FILE`, and `cd` moves the shell
   rather than the signer.

   This does not make claude-beb the resolver, and 6 still holds: it
   opens no key, reads no roster, and chooses between no candidates.
   It records where the session started. beb decides who lives there
   and refuses if the answer is nobody. An operator who launched with
   `BEB_IDENTITY` already said who they are, and the pin never argues
   with them.

   SessionStart alone. The same variable is offered on `CwdChanged`,
   and writing it there would re-pin on every directory change, which
   is the drift the pin exists to stop.

## Behavior

Two hooks, both armed on SessionStart and Stop.

The drain (synchronous) asks `beb list`, which pages: the rows are
stdout and how much was not shown is on stderr, so the drain takes
both and carries beb's summary line into the announcement. Ten rows
of twenty-five handed back without the count would read as all of the
mail. Unread mail becomes
additional context in the same shape at either boundary:

    [beb] mail waits:
    3  frontend
    4  ssh-ed25519 AAAA...
    read with: beb read

An empty list is a silent exit; a quiet boundary stays quiet. The
announcement repeats at each boundary until the agent reads, because
reading is what makes it true to stop saying.

The doorbell (asyncRewake) is `beb wait` with an exit code: it
parks on the kernel watch, in short legs, and exits 2 with one line
naming the next step when mail has arrived; the harness wakes the
session and the agent reads. Arrival is judged by content: `list`
at arm time is the baseline, and a ring needs a changed, non-empty
list — standing unread never re-rings (the drain owns it), and mail
consumed by another integration before we looked is silence. A
timeout is a silent exit 0; the next boundary arms afresh. A
doorbell is superseded by ownership, never force: the new arm
writes its token, and the old doorbell notices at its next waking
moment and exits on its own. The total wait is bounded and
overridable (`CLAUDE_BEB_WAIT_SECS`, default a day).

The agent answers mail with the same four beb verbs every other beb
user has. claude-beb adds no verbs, no tools, and no reply path.

## Out of scope

Consuming on the agent's behalf, delivering bodies, filesystem
watching from hook processes, presence, multiple identities per
session, remote mailboxes. Whatever claude-beb cannot learn by
running beb as the session's identity, it does not know.

## Design test

Every proposed feature answers one question:

> Is this necessary to wake Claude Code when mail arrives for the
> identity it is running as?

## The pin reaches Bash, not hooks (2026-08-17)

`beb-identity.sh` writes `BEB_IDENTITY` to `CLAUDE_ENV_FILE`, which
Claude Code sources before every Bash command. It does not source it
before a hook. So on a machine whose environment does not already carry
`BEB_IDENTITY`, `beb-drain.sh` and `beb-doorbell.sh` both asked beb who
they were, got a refusal, and exited 0 in silence -- no announcement at
a turn boundary, and no doorbell armed at all.

It stayed hidden because the agent's own `beb` calls worked throughout:
those are Bash commands, and Bash commands do get the env file. Mail
arrived and nothing said so. It was found on a second machine three days
after that machine's last doorbell, and never on the first, whose shell
exports `BEB_IDENTITY` and so passed it to every hook by inheritance.

Both hooks now read the launch directory out of the hook input they were
already parsing, and pin themselves when nothing else has. The suite
handed every hook an explicit `BEB_IDENTITY` before this, which is what
made the gap invisible to it too.

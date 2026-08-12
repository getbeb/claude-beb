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
   beb resolves for the session's process — the working directory's
   `.beb`, or `BEB_IDENTITY` in Claude Code's environment, which
   hooks inherit; the resolution is beb's, never claude-beb's. Where
   beb resolves nobody, every hook exits silently.

## Behavior

Two hooks, both armed on SessionStart and Stop.

The drain (synchronous) asks `beb list`. Unread mail becomes
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

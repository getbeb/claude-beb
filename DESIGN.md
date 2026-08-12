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
5. State is one pidfile per session, so each newly armed doorbell
   supersedes the last and a reloaded plugin cannot leave a stale
   wake channel ringing. Everything else claude-beb knows it learns
   from beb at the moment it looks.
6. No identity, no activity. A directory without a `.beb` makes
   every hook exit silently.

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
parks on the kernel watch until the next message arrives, confirms
with `list` that something stands unread, and exits 2 with one line
naming the next step; the harness wakes the session and the agent
reads. A timeout is a silent exit 0: no mail, no wake, and the next
boundary arms a fresh doorbell. A doorbell is superseded on every
arm: the previous one, found by recorded pid and live command line,
is killed before the new one parks. The wait is bounded and
overridable (`CLAUDE_BEB_WAIT_SECS`, default a day).

The agent answers mail with the same four beb verbs every other beb
user has. claude-beb adds no verbs, no tools, and no reply path.

## Out of scope

Consuming on the agent's behalf, delivering bodies, filesystem
watching from hook processes, presence, multiple identities per
session, remote mailboxes. Whatever claude-beb cannot learn by
running beb in the session's directory, it does not know.

## Design test

Every proposed feature answers one question:

> Is this necessary to wake Claude Code when mail arrives for the
> identity it is running as?

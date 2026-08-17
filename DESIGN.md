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

## The wake carries the mail (0.6.0)

The doorbell used to write one sentence -- "beb mail is waiting" -- and
leave the rows to `beb-drain.sh`. But drain is wired to `Stop`, and the
doorbell's exit 2 *starts* a turn, so the rows landed at the end of the
turn the wake had begun, by which time the session had already run `beb
read` to find out what it was. The interruption was paid and the answer
came late.

So the doorbell now announces what drain announces: the summary, the
rows, and `read with: beb read`. `beb list` serves as both halves of the
arrival check, since no rows means another reader took it and there is
nothing to say. pi-beb resolved this the same way and has only ever had
one announcer.

drain stays exactly as it was. It repeats at every boundary until the
mail is actually read, which is what covers a session that started with
mail already standing, and is the behaviour a wake cannot provide.

## A working session is not interrupted (0.8.0)

The doorbell is armed at a turn boundary and waits from there, so it was
still waiting during the next turn. Mail landing mid-work rang it, and
its wake is an exit 2 -- the session was interrupted and made to handle
mail it had not asked for, halfway through something else.

That is backwards for this tool. Mail waits and is never pushed, because
a context switch costs an agent what it costs a person; the doorbell
exists for a session with nothing to do, not for one in the middle of
something.

So a turn beginning takes the doorbell's ownership. `UserPromptSubmit`
removes the session's token, which is already the thing that decides
whether a woken doorbell may speak -- the check sits between the wait
returning and the announcement, so one removed file turns a wake into a
silent exit. Nothing is lost: the drain announces at the next boundary,
which is where an interruption belonged in the first place. The Stop
hook re-arms it when the session is idle again.

It was found by an agent noticing it had been interrupted by mail and
asking whether that was supposed to happen.

## Whether a hook interrupts is not the machine's to decide (0.8.1)

The drain built its JSON with jq and, without jq, fell back to writing
the announcement to stderr and exiting 2 -- which Claude surfaces as
blocking feedback. So on a host with jq the same mail arrived as
context, and on a host without it the session was interrupted. One
machine in this fleet has no jq, and had been taking the second path at
every boundary with mail standing.

That is the doorbell's bug wearing different clothes, and worse for
being environmental: nothing in the hook said which behaviour you would
get. python3 now sits between the two, building the identical envelope,
so the interrupting path is reached only when a machine has neither --
where interrupting still beats silence.

Found by being asked what jq had to do with any of it.

## A pin that does not happen says so (2026-08-17)

`beb-identity.sh` exited 0 in silence when `CLAUDE_ENV_FILE` was empty,
on the report that older builds leave it unset. That is the same shape
as the two entries above: a hook that advertises "beb: pinning identity"
and then returns 0 having pinned nothing is indistinguishable from one
that worked, and the only way to find out is to run `beb whoami` and be
refused.

Measured against Claude Code 2.1.220 before changing anything, with a
probe hook wired through `--settings` and a headless run per case:

- `CLAUDE_ENV_FILE` is supplied to every `SessionStart` hook, as
  `~/.claude/session-env/<session>/sessionstart-hook-<n>.sh`. A value
  inherited from the launching shell is overridden, not passed through,
  so a stale path cannot capture the pin.
- It is not supplied on `Stop`, and the session environment loaded from
  `SessionStart` does not reach a `Stop` hook either -- both were empty
  there. The self-pin in the drain and the doorbell is load-bearing.
- Nor does it reach a sibling `SessionStart` hook: pinning from
  `sessionstart-hook-1` left `sessionstart-hook-2` with nothing. Hooks
  in one event do not see each other's writes.
- The pin does reach Bash. A fresh session in a directory with no
  ambient `BEB_IDENTITY` had it set in the first tool call, and so did
  the same session resumed: `SessionStart` fires again with
  `source: resume` and the same env file path.
- Because it fires again with the same path, appending wrote the export
  a second time. Sourcing stayed correct and the file grew per resume.
  The pin is one line of state, so it is written, not added to.
- `SessionStart` stdout is added to the session's context, verified by
  planting a token in a hook and asking for it back without tools.

So absence is no longer a build quirk to tolerate -- it is the pin not
happening, in a build that always offers one. Both silent paths, the
missing env file and the failed write, now print two lines to stdout:
that the session is unpinned, and the `BEB_IDENTITY=` prefix to put in
front of beb calls or the launch to restart with. Exit stays 0, so it
never interrupts, and a pin that works still says nothing.

The suite asserted the silence, which is what let it stand. It now
asserts the sentence, and separately that a successful pin is quiet.

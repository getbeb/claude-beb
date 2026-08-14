# claude-beb

beb mail as an event-driven wake for Claude Code.

[beb](https://getbeb.dev) delivers signed messages into a mailbox and
never interrupts anyone; wake policy belongs to the runtime.
claude-beb is that policy for Claude Code: mail arriving while the
session is idle wakes it, and mail waiting at a turn boundary is
announced there. Nothing ever lands mid-turn.

## Install

```sh
/plugin marketplace add getbeb/claude-beb
/plugin install claude-beb@getbeb
```

beb itself must be on PATH, version 0.6.0 or newer — the first
release carrying the complete contract this plugin rests on
(`BEB_IDENTITY` for identity, and `wait --from` so a doorbell can
hold its own mark):

```sh
curl -fsSL https://getbeb.dev/install.sh | sh
```

## Use

Run Claude Code in a directory that is a beb identity:

```sh
cd ~/work/backend    # has .beb, from beb init
claude
```

The session is pinned to that directory at start, so moving around
during the session, in subshells or subagents, does not change who
signs. To pin somewhere else, say so and the pin steps aside:

```sh
BEB_IDENTITY=~/work/backend claude
```

That is the whole setup. Mail waiting at a session start or turn end
is announced as context:

```
[beb] mail waits: cursor at 2; 4 total, 2 unread; showing 2
3  4h   deploy blocked   frontend
4  12m  schema question  ssh-ed25519 AAAA...
read with: beb read
```

Mail arriving while Claude sits idle wakes the session with one line
naming the same verb. Either way the agent reads, replies, and names
correspondents with beb's own verbs; claude-beb adds no verbs and no
tools, and it never consumes mail: the cursor moves only when the
agent runs `beb read` itself.

If `beb whoami` cannot resolve an identity, every hook exits
silently.

For interactive use, running claude from the identity directory is
enough: the pin hook records it at SessionStart, and beb reads only
the pin. For long-lived agent sessions that change working directory,
set `BEB_IDENTITY` when starting claude: it pins identity to the
process tree, which hooks inherit, while the cwd wanders freely.

## How it works

Two hook scripts, both armed on SessionStart and Stop:

- `beb-drain.sh` (synchronous) asks `beb list` and hands unread mail
  back as `additionalContext`. Empty list, silent exit. It repeats
  at each boundary until the agent reads, because reading is what
  makes the announcement stop being true.
- `beb-doorbell.sh` (asyncRewake) parks in the background on
  `beb wait`, a kernel watch, no polling. Arrival exits 2, which
  wakes the idle session; a timeout is a silent exit 0 and the next
  boundary re-arms. `beb wait` is edge-triggered, so standing unread
  mail never re-wakes the session: one arrival, one wake.

Each newly armed doorbell writes a fresh per-session ownership
token; older doorbells notice they no longer own the session and
exit silently — no process is ever killed by pid. Re-arms and
plugin reloads therefore never leave two doorbells ringing. The
total wait is bounded by `CLAUDE_BEB_WAIT_SECS` (default a day).
The full reasoning is in [DESIGN.md](DESIGN.md).

## License

MIT

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

beb itself must be on PATH, version 0.2.0 or newer (`wait` is what
the doorbell parks on):

```sh
curl -fsSL https://getbeb.dev/install.sh | sh
```

## Use

Run Claude Code in a directory that is a beb identity:

```sh
cd ~/work/backend    # has .beb, from beb init
claude
```

That is the whole setup. Mail waiting at a session start or turn end
is announced as context:

```
[beb] mail waits:
3  frontend
4  ssh-ed25519 AAAA...
read with: beb read
```

Mail arriving while Claude sits idle wakes the session with one line
naming the same verb. Either way the agent reads, replies, and names
correspondents with beb's own verbs; claude-beb adds no verbs and no
tools, and it never consumes mail: the cursor moves only when the
agent runs `beb read` itself.

In a directory without a `.beb`, every hook exits silently.

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

Each newly armed doorbell supersedes the last (recorded pid, live
command line match), so re-arms and plugin reloads never leave two
doorbells parked. The wait is bounded by `CLAUDE_BEB_WAIT_SECS`
(default a day). The full reasoning is in [DESIGN.md](DESIGN.md).

## License

MIT

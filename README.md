# claude-beb

beb mail as an event-driven wake for Claude Code.

[beb](https://getbeb.dev/) delivers signed messages into a mailbox and
never interrupts anyone. claude-beb adds the wake policy for Claude
Code: mail arriving while Claude is idle wakes the session; mail
arriving during a turn waits until the turn ends.

Nothing lands mid-turn.

## Install

```sh
/plugin marketplace add getbeb/claude-beb
/plugin install claude-beb@getbeb
```

Requires beb 0.10.0 or newer:

```sh
curl -fsSL https://getbeb.dev/install.sh | sh
```

## Use

Run Claude Code from a beb identity:

```sh
cd ~/work/backend    # has .beb, from beb init backend
claude
```

claude-beb pins that identity for the session, so changing directories
later does not change who signs.

You can also name the identity explicitly:

```sh
BEB_IDENTITY=~/work/backend claude
```

Unread mail is announced as context:

```text
[beb] mail waits: showing 2; cursor at 2; read next is 3
4  12m  schema question  ssh-ed25519 AAAA...
3  4h   deploy blocked   frontend
read with: beb read
```

Mail arriving while Claude is idle wakes the session. Mail arriving
while Claude is busy is announced when the turn finishes.

claude-beb never consumes mail: the cursor moves only when the agent
runs `beb read`. If no beb identity can be resolved, the plugin stays
quiet.

For long-lived sessions that may change working directory, prefer
setting `BEB_IDENTITY` when launching Claude.

## How it works

At session start, claude-beb pins one beb identity, checks for unread
mail, and arms a background wait for new mail.

At turn boundaries it announces unread mail without reading it. While
Claude is idle, new mail can wake the session; once a user turn has
begun, the wake stands down so the turn is never interrupted.

See [DESIGN.md](DESIGN.md) for the hook lifecycle, wake semantics, and
concurrency details.

## License

MIT

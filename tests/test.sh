#!/usr/bin/env bash
# Standalone tests for the three hook scripts. Needs beb 0.6.0+ on PATH
# or in BEB_BIN. Run: bash tests/test.sh
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
DRAIN=$HERE/hooks/beb-drain.sh
PIN=$HERE/hooks/beb-identity.sh
BELL=$HERE/hooks/beb-doorbell.sh
BEB=${BEB_BIN:-beb}
export BEB_BIN=$BEB

# The version gate is first, and loud. An older beb fails four tests in
# with "drain did not carry the paging summary", which is true and says
# nothing about why: 0.6.0 is where `list` grew its header, `wait` grew
# `--from`, and identity stopped resolving the working directory.
have=$("$BEB" --version 2>/dev/null | awk '{print $2}')
case "$have" in
    "") echo "not ok - no beb on PATH or in BEB_BIN (\"$BEB\")"; exit 1 ;;
esac
gate=0.10.0
older=$(printf '%s\n%s\n' "$gate" "$have" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)
if [ "$have" != "$gate" ] && [ "$older" = "$have" ]; then
    echo "not ok - beb $have is older than $gate"
    echo "  0.6.0 is where list grew its header, wait grew --from, and"
    echo "  identity stopped resolving the working directory."
    exit 1
fi

S=$(mktemp -d)
# BEB_IDENTITY too: these run on machines that use beb, and a pinned
# identity inherited from the caller would answer for every command in
# the suite. The pin tests set it per-invocation, deliberately.
unset BEB_IDENTITY 2>/dev/null || true
export XDG_CONFIG_HOME=$S/config XDG_DATA_HOME=$S/data
export TMPDIR=$S/tmp
mkdir -p "$S/config/beb" "$S/tmp" "$S/a" "$S/b" "$S/bare"

n=0
OUT=$S/out.txt
ERR=$S/err.txt
ok() { n=$((n + 1)); echo "ok $n - $1"; }
die() {
    echo "not ok - $1"
    echo "--- stdout ---"; cat "$OUT" 2>/dev/null
    echo "--- stderr ---"; cat "$ERR" 2>/dev/null
    exit 1
}

(cd "$S/a" && "$BEB" init a >/dev/null 2>&1) || die "init a"
(cd "$S/b" && "$BEB" init b >/dev/null 2>&1) || die "init b"
# beb 0.6.0 resolves BEB_IDENTITY and nothing else: no working
# directory, no fallback. Every invocation below pins deliberately, the
# way the pin hook does for a real session.
as() { d=$1; shift; BEB_IDENTITY="$S/$d" "$BEB" "$@"; }
A=$(as a whoami 2>/dev/null)
echo "b $(as b whoami 2>/dev/null)" >"$S/config/beb/known_signers"

EV='{"hook_event_name":"SessionStart","session_id":"test-session"}'

# ---- drain -------------------------------------------------------------

printf '%s' "$EV" | BEB_IDENTITY="$S/a" "$DRAIN" >"$OUT" 2>"$ERR" || die "drain empty failed"
test -s "$OUT" && die "drain spoke with no mail"
ok "no mail: drain is silent"

printf '%s' "$EV" | BEB_IDENTITY="$S/bare" "$DRAIN" >"$OUT" 2>"$ERR" || die "drain no-identity failed"
test -s "$OUT" && die "drain spoke without identity"
ok "no identity: drain is silent"

as b send "$A" --subject "first mail" --body "first mail" >/dev/null 2>&1 || die "send"

printf '%s' "$EV" | BEB_IDENTITY="$S/a" "$DRAIN" >"$OUT" 2>"$ERR" || die "drain with mail failed"
python3 -c "
import json,sys
d=json.load(open('$OUT'))
o=d['hookSpecificOutput']
assert o['hookEventName']=='SessionStart', o
c=o['additionalContext']
assert c.startswith('[beb] mail waits:'), c
assert 'read with: beb read' in c, c
assert '1  ' in c, c
" || die "drain output shape: $(cat "$OUT")"
ok "mail waiting: drain announces list as additionalContext"

printf '%s' "$EV" | BEB_IDENTITY="$S/a" "$DRAIN" >"$S/out2.txt" 2>"$ERR" || die "drain rerun failed"
cmp -s "$OUT" "$S/out2.txt" || die "drain is not idempotent"
ok "drain never consumes: rerun announces the same mail"

# `beb list` pages at ten. Taking only its stdout would hand back ten
# rows of twenty-five and call it the mail, so the drain carries beb's
# own summary line and the count comes with it.
i=2
while [ "$i" -le 14 ]; do
    as b send "$A" --subject "bulk $i" --body "x" >/dev/null 2>&1 || die "bulk send $i"
    i=$((i + 1))
done
printf '%s' "$EV" | BEB_IDENTITY="$S/a" "$DRAIN" >"$OUT" 2>"$ERR" || die "drain bulk failed"
python3 -c "
import json
c=json.load(open('$OUT'))['hookSpecificOutput']['additionalContext']
first=c.splitlines()[0]
# What has to survive is that a paged listing says so: this hook carries
# one line of what beb says, so the fact that more is waiting has to be
# in that line and not only in the paging hint below it. beb 0.10.0
# spells it ', more' -- ', more waiting' claimed unread mail even when
# paging through mail already read, which a fully-read mailbox answered
# two different ways in consecutive commands.
assert 'showing' in first, first
assert ', more' in first, first
rows=[l for l in c.splitlines() if l.strip()[:1].isdigit()]
assert len(rows)==10, len(rows)
" || die "drain did not carry the paging summary: $(cat "$OUT")"
ok "drain announces beb's summary, so a paged listing is not mistaken for all of it"

# ---- identity: pin the session to where it started ---------------------

# An agent's working directory is not a place it stays. The pin is
# written once, from the directory the session began in, so a later cd
# moves the shell and not the signer.
ENVF=$S/envfile
: >"$ENVF"
printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$S/a" |
    CLAUDE_ENV_FILE=$ENVF BEB_IDENTITY= "$PIN" >"$OUT" 2>"$ERR" || die "pin failed: $(cat "$ERR")"
grep -q "BEB_IDENTITY=" "$ENVF" || die "pin wrote nothing: [$(cat "$ENVF")]"
( . "$ENVF"; [ "$BEB_IDENTITY" = "$S/a" ] ) || die "pin value wrong: $(cat "$ENVF")"
ok "SessionStart pins the launch directory, and the line sources back exactly"

# A directory that is not an identity is pinned anyway. The guard used
# to skip it, because beb resolved the working directory and its own
# "no .beb here" was the better sentence. beb 0.6.0 reads nothing but
# the pin, so unpinned means the generic "BEB_IDENTITY is not set",
# while pinned means the specific refusal that names the directory and
# the command to fix it.
: >"$ENVF"
printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$S/bare" |
    CLAUDE_ENV_FILE=$ENVF BEB_IDENTITY= "$PIN" >"$OUT" 2>"$ERR" || die "pin errored on a bare dir"
( . "$ENVF"; [ "$BEB_IDENTITY" = "$S/bare" ] ) || die "bare dir not pinned: [$(cat "$ENVF")]"
BEB_IDENTITY="$S/bare" "$BEB" whoami >"$OUT" 2>"$ERR" && die "whoami resolved in a bare dir"
grep -q "has no .beb" "$ERR" || die "the pin did not buy the specific refusal: $(cat "$ERR")"
grep -q "beb init" "$ERR" || die "the refusal does not name the fix: $(cat "$ERR")"
ok "a bare directory is pinned too, which is what makes beb name the fix"

# An operator who launched with BEB_IDENTITY already said who they are.
: >"$ENVF"
printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$S/a" |
    CLAUDE_ENV_FILE=$ENVF BEB_IDENTITY=/already/chosen "$PIN" >"$OUT" 2>"$ERR" || die "pin errored"
test -s "$ENVF" && die "overrode an explicit BEB_IDENTITY: $(cat "$ENVF")"
ok "an explicit BEB_IDENTITY is never overridden"

# Builds that leave the variable empty must stay quiet, not fail.
printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$S/a" |
    env -u CLAUDE_ENV_FILE "$PIN" >"$OUT" 2>"$ERR" || die "no CLAUDE_ENV_FILE should exit 0"
test -s "$OUT" && die "spoke on stdout with no env file: $(cat "$OUT")"
ok "no CLAUDE_ENV_FILE: silent exit 0"

# A path with a space has to survive being sourced.
mkdir -p "$S/two words/.beb"
: >"$ENVF"
printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$S/two words" |
    CLAUDE_ENV_FILE=$ENVF BEB_IDENTITY= "$PIN" >"$OUT" 2>"$ERR" || die "pin failed on a spaced path"
( . "$ENVF"; [ "$BEB_IDENTITY" = "$S/two words" ] ) || die "spaced path mangled: $(cat "$ENVF")"
ok "a path with spaces survives the round trip through sourcing"

# ---- doorbell: edge semantics ------------------------------------------

# Mail stands unread; an edge-triggered doorbell must NOT wake for it.
printf '%s' "$EV" | BEB_IDENTITY="$S/a" CLAUDE_BEB_WAIT_SECS=2 "$BELL" >"$OUT" 2>"$ERR"
rc=$?
test "$rc" = 0 || die "doorbell woke on standing mail (rc=$rc): $(cat "$ERR")"
ok "standing unread: doorbell stays quiet, times out clean"

# The doorbell marks from `--timeout 0` at arm time and waits `--from`
# it, so nothing falls into the gap between legs. Before the mark, each
# leg re-baselined on entry and a message landing between two legs woke
# neither; the old code patched that by diffing `beb list` every leg.
MARK=$(BEB_IDENTITY="$S/a" "$BEB" wait --timeout 0 2>/dev/null)
[ -n "$MARK" ] || die "wait --timeout 0 handed back no mark"
BEB_IDENTITY="$S/a" "$BEB" wait --from "$MARK" --timeout 1 >/dev/null 2>&1 &&
    die "a mark past everything fired on standing mail"
as b send "$A" --subject "between legs" --body x >/dev/null 2>&1 || die "send between legs"
BEB_IDENTITY="$S/a" "$BEB" wait --from "$MARK" --timeout 2 >/dev/null 2>&1 ||
    die "a message that landed between legs was missed"
ok "the arm mark survives a leg boundary: nothing lands in the gap"

# ---- doorbell: wakes on arrival ----------------------------------------

printf '%s' "$EV" | BEB_IDENTITY="$S/a" CLAUDE_BEB_WAIT_SECS=15 "$BELL" >"$OUT" 2>"$ERR" &
BPID=$!
sleep 2 # past the arm's converge beat, so the wait is parked
as b send "$A" --subject "ding" --body "ding" >/dev/null 2>&1 || die "send ding"
t0=$(date +%s)
wait $BPID
rc=$?
t1=$(date +%s)
test "$rc" = 2 || die "doorbell did not exit 2 on arrival (rc=$rc)"
test $((t1 - t0)) -lt 8 || die "doorbell took $((t1 - t0))s"
# The wake carries the mail, not a sentence about it. A doorbell that
# only says "mail is waiting" makes the session spend a turn asking who
# it was from, and the drain that would answer runs at the *end* of that
# turn, by which time it has been read.
grep -q "read with: beb read" "$ERR" || die "wake line: $(cat "$ERR")"
grep -q "mail waits:" "$ERR" || die "the wake carries no summary: $(cat "$ERR")"
# A row, which is id / age / subject / sender. Not a particular subject:
# ten already stand unread here, so beb pages and the newest is not on
# the page -- which is beb's answer and the drain's behaviour too.
grep -qE '^[[:space:]]*[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+.*[[:space:]]b$' "$ERR" ||
    die "the wake carries no rows, only a sentence: $(cat "$ERR")"
ok "arrival: doorbell exits 2 fast, names the verb"

# ---- doorbell: supersession --------------------------------------------

printf '%s' "$EV" | BEB_IDENTITY="$S/a" CLAUDE_BEB_WAIT_SECS=30 "$BELL" >"$OUT" 2>"$S/e1.txt" &
D1=$!
sleep 1
printf '%s' "$EV" | BEB_IDENTITY="$S/a" CLAUDE_BEB_WAIT_SECS=30 "$BELL" >"$OUT" 2>"$S/e2.txt" &
D2=$!
sleep 2
as b send "$A" --subject "dong" --body "dong" >/dev/null 2>&1 || die "send dong"
wait $D1; r1=$?
wait $D2; r2=$?
test "$r1" = 0 || die "superseded doorbell woke (rc=$r1)"
test "$r2" = 2 || die "live doorbell did not wake (rc=$r2)"
ok "supersession by ownership: old doorbell exits itself, only the owner wakes"

# ---- doorbell: concurrent arms converge to one -------------------------

printf '%s' "$EV" | BEB_IDENTITY="$S/a" CLAUDE_BEB_WAIT_SECS=30 "$BELL" >"$OUT" 2>"$S/c1.txt" &
C1=$!
printf '%s' "$EV" | BEB_IDENTITY="$S/a" CLAUDE_BEB_WAIT_SECS=30 "$BELL" >"$OUT" 2>"$S/c2.txt" &
C2=$!
sleep 3
as b send "$A" --subject "race ding" --body "race ding" >/dev/null 2>&1 || die "send race ding"
wait $C1; c1=$?
wait $C2; c2=$?
test "$((c1 + c2))" = 2 || die "concurrent arms: rc $c1 and $c2, want exactly one 2"
ok "concurrent arms: exactly one doorbell survives and wakes"

# ---- doorbell: no identity ---------------------------------------------

printf '%s' "$EV" | BEB_IDENTITY="$S/bare" "$BELL" >"$OUT" 2>"$ERR"
test $? = 0 || die "doorbell errored without identity"
ok "no identity: doorbell exits silently"

# ---- a working session is not interrupted ------------------------------
#
# The doorbell is armed at a boundary and keeps waiting through the next
# turn, so mail landing mid-work rang it -- and its wake is an exit 2,
# which interrupts. Mail waits; it is never pushed. A turn beginning
# takes the doorbell's ownership, and the drain announces at the next
# boundary instead.
HUSH=$HERE/hooks/beb-hush.sh
EVH='{"hook_event_name":"UserPromptSubmit","session_id":"hush-session","cwd":"'"$S/a"'"}'
EVD='{"hook_event_name":"Stop","session_id":"hush-session","cwd":"'"$S/a"'"}'

printf '%s' "$EVD" | BEB_IDENTITY="$S/a" CLAUDE_BEB_WAIT_SECS=30 "$BELL" >"$OUT" 2>"$ERR" &
HP=$!
sleep 3                                   # armed and parked
printf '%s' "$EVH" | "$HUSH" >/dev/null 2>&1 || die "hush errored"
as b send "$A" --subject "mid-turn" --body "mid-turn" >/dev/null 2>&1 || die "send mid-turn"
wait $HP; rc=$?
test "$rc" = 0 || die "a hushed doorbell exited $rc; it interrupted a working session"
test ! -s "$ERR" || die "a hushed doorbell still spoke: $(cat "$ERR")"
ok "mail landing mid-turn does not ring a doorbell the session has hushed"

# And with no hush it still wakes, or the hush would be indistinguishable
# from a doorbell that never worked.
printf '%s' "$EVD" | BEB_IDENTITY="$S/a" CLAUDE_BEB_WAIT_SECS=30 "$BELL" >"$OUT" 2>"$ERR" &
HP2=$!
sleep 3
as b send "$A" --subject "idle ding" --body "idle ding" >/dev/null 2>&1 || die "send idle ding"
wait $HP2; rc=$?
test "$rc" = 2 || die "an idle doorbell exited $rc, wanted 2"
grep -q 'mail waits' "$ERR" || die "an idle doorbell said nothing: $(cat "$ERR")"
ok "and an idle session is still woken, which is what a doorbell is for"

# ---- hooks pin themselves from the hook input --------------------------
#
# Every test above hands the hook a BEB_IDENTITY, which is how this was
# missed: beb-identity.sh writes the pin to CLAUDE_ENV_FILE, and Claude
# Code sources that for Bash commands, not for hooks. On a machine whose
# environment does not already carry BEB_IDENTITY, every hook here saw no
# identity and exited 0 in silence, for three days, while the agent's own
# beb calls worked the whole time.
EVC='{"hook_event_name":"SessionStart","session_id":"pin-session","cwd":"'"$S/a"'"}'

printf '%s' "$EVC" | env -u BEB_IDENTITY CLAUDE_BEB_WAIT_SECS=30 "$BELL" >"$OUT" 2>"$ERR" &
BP=$!
sleep 3
as b send "$A" --subject "pinned ding" --body "pinned ding" >/dev/null 2>&1 || die "send pinned ding"
wait $BP; rc=$?
test "$rc" = 2 || die "an unpinned doorbell exited $rc; it never armed from the input cwd"
ok "the doorbell pins itself from the hook input, so it arms with nothing in the environment"

printf '%s' "$EVC" | env -u BEB_IDENTITY "$DRAIN" >"$OUT" 2>"$ERR"
# Any announcement will do: the mailbox holds more than one page by now,
# so naming a subject would be asserting which page it is on.
grep -q 'mail waits' "$OUT" "$ERR" 2>/dev/null ||
    die "an unpinned drain announced nothing: $(cat "$OUT" "$ERR" 2>/dev/null | head -3)"
ok "and so does the drain, which is what announces mail at a turn boundary"

echo "all $n tests passed"

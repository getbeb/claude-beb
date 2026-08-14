#!/usr/bin/env bash
# Standalone tests for the two hook scripts. Needs a beb with `wait`
# (0.2.0+) on PATH or in BEB_BIN. Run: bash tests/test.sh
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
DRAIN=$HERE/hooks/beb-drain.sh
PIN=$HERE/hooks/beb-identity.sh
BELL=$HERE/hooks/beb-doorbell.sh
BEB=${BEB_BIN:-beb}
export BEB_BIN=$BEB

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

(cd "$S/a" && "$BEB" init >/dev/null) || die "init a"
(cd "$S/b" && "$BEB" init >/dev/null) || die "init b"
A=$(cd "$S/a" && "$BEB" whoami)
echo "b $(cd "$S/b" && "$BEB" whoami)" >"$S/config/beb/known_signers"

EV='{"hook_event_name":"SessionStart","session_id":"test-session"}'

# ---- drain -------------------------------------------------------------

printf '%s' "$EV" | (cd "$S/a" && "$DRAIN") >"$OUT" 2>"$ERR" || die "drain empty failed"
test -s "$OUT" && die "drain spoke with no mail"
ok "no mail: drain is silent"

printf '%s' "$EV" | (cd "$S/bare" && "$DRAIN") >"$OUT" 2>"$ERR" || die "drain no-identity failed"
test -s "$OUT" && die "drain spoke without identity"
ok "no identity: drain is silent"

(cd "$S/b" && "$BEB" send "$A" "first mail") >/dev/null || die "send"

printf '%s' "$EV" | (cd "$S/a" && "$DRAIN") >"$OUT" 2>"$ERR" || die "drain with mail failed"
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

printf '%s' "$EV" | (cd "$S/a" && "$DRAIN") >"$S/out2.txt" 2>"$ERR" || die "drain rerun failed"
cmp -s "$OUT" "$S/out2.txt" || die "drain is not idempotent"
ok "drain never consumes: rerun announces the same mail"

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

# A directory that is not an identity gets no pin: beb's own "no .beb
# here" is a better sentence about that nothing than a pin would make.
: >"$ENVF"
printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$S/bare" |
    CLAUDE_ENV_FILE=$ENVF BEB_IDENTITY= "$PIN" >"$OUT" 2>"$ERR" || die "pin errored on a bare dir"
test -s "$ENVF" && die "pinned a directory with no identity: $(cat "$ENVF")"
ok "a directory that is not an identity is left unpinned"

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
printf '%s' "$EV" | (cd "$S/a" && CLAUDE_BEB_WAIT_SECS=2 "$BELL") >"$OUT" 2>"$ERR"
rc=$?
test "$rc" = 0 || die "doorbell woke on standing mail (rc=$rc): $(cat "$ERR")"
ok "standing unread: doorbell stays quiet, times out clean"

# ---- doorbell: wakes on arrival ----------------------------------------

printf '%s' "$EV" | (cd "$S/a" && CLAUDE_BEB_WAIT_SECS=15 "$BELL") >"$OUT" 2>"$ERR" &
BPID=$!
sleep 2 # past the arm's converge beat, so the wait is parked
(cd "$S/b" && "$BEB" send "$A" "ding") >/dev/null || die "send ding"
t0=$(date +%s)
wait $BPID
rc=$?
t1=$(date +%s)
test "$rc" = 2 || die "doorbell did not exit 2 on arrival (rc=$rc)"
test $((t1 - t0)) -lt 8 || die "doorbell took $((t1 - t0))s"
grep -q "read it with: beb read" "$ERR" || die "wake line: $(cat "$ERR")"
ok "arrival: doorbell exits 2 fast, names the verb"

# ---- doorbell: supersession --------------------------------------------

printf '%s' "$EV" | (cd "$S/a" && CLAUDE_BEB_WAIT_SECS=30 "$BELL") >"$OUT" 2>"$S/e1.txt" &
D1=$!
sleep 1
printf '%s' "$EV" | (cd "$S/a" && CLAUDE_BEB_WAIT_SECS=30 "$BELL") >"$OUT" 2>"$S/e2.txt" &
D2=$!
sleep 2
(cd "$S/b" && "$BEB" send "$A" "dong") >/dev/null || die "send dong"
wait $D1; r1=$?
wait $D2; r2=$?
test "$r1" = 0 || die "superseded doorbell woke (rc=$r1)"
test "$r2" = 2 || die "live doorbell did not wake (rc=$r2)"
ok "supersession by ownership: old doorbell exits itself, only the owner wakes"

# ---- doorbell: concurrent arms converge to one -------------------------

printf '%s' "$EV" | (cd "$S/a" && CLAUDE_BEB_WAIT_SECS=30 "$BELL") >"$OUT" 2>"$S/c1.txt" &
C1=$!
printf '%s' "$EV" | (cd "$S/a" && CLAUDE_BEB_WAIT_SECS=30 "$BELL") >"$OUT" 2>"$S/c2.txt" &
C2=$!
sleep 3
(cd "$S/b" && "$BEB" send "$A" "race ding") >/dev/null || die "send race ding"
wait $C1; c1=$?
wait $C2; c2=$?
test "$((c1 + c2))" = 2 || die "concurrent arms: rc $c1 and $c2, want exactly one 2"
ok "concurrent arms: exactly one doorbell survives and wakes"

# ---- doorbell: no identity ---------------------------------------------

printf '%s' "$EV" | (cd "$S/bare" && "$BELL") >"$OUT" 2>"$ERR"
test $? = 0 || die "doorbell errored without identity"
ok "no identity: doorbell exits silently"

echo "all $n tests passed"

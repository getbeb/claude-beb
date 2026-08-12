#!/usr/bin/env bash
# Standalone tests for the two hook scripts. Needs a beb with `wait`
# (0.2.0+) on PATH or in BEB_BIN. Run: bash tests/test.sh
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
DRAIN=$HERE/hooks/beb-drain.sh
BELL=$HERE/hooks/beb-doorbell.sh
BEB=${BEB_BIN:-beb}
export BEB_BIN=$BEB

S=$(mktemp -d)
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

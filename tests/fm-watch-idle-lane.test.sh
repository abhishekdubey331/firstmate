#!/usr/bin/env bash
# tests/fm-watch-idle-lane.test.sh - the heartbeat's idle/dead lane predicate
# added to bin/fm-watch.sh (scan_idle_lanes, heartbeat_idle_lane_actionable,
# mark_all_idle_lanes_surfaced, fleet_has_recorded_endpoint) and the heartbeat
# backoff cap it feeds (HEARTBEAT_BUSY_MAX).
#
# The gap this closes: the watcher's per-wake and per-window-stale paths only
# ever surface a captain-relevant STATUS LINE. A worker that finished cleanly
# with no done: status, or that died and stopped writing (and whose pane
# capture then fails, skipping it entirely in the per-window stale loop), emits
# no status at all - supervision detects failure, never silence. The heartbeat
# fleet-scan backstop already exists for a missed captain-relevant status; this
# suite covers its sibling backstop for a live-but-idle or dead endpoint, and
# the tighter heartbeat cadence that keeps a busy fleet from going unobserved
# for up to HEARTBEAT_MAX (7200s) at a time.
#
# Most cases here call the predicate functions directly (a real interface, real
# fm-busy-event.sh writer process, a real fake tmux backing the endpoint-exists
# probe, no harness) rather than driving a live watcher subprocess, so the busy/
# idle/dead/unknown matrix stays fast and precise. Two integration cases at the
# end drive a real fm-watch.sh subprocess end to end, proving the wiring: a dead
# lane actually wakes the watcher, and the backoff cap actually changes cadence.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"

TMP=$(fm_test_tmproot fm-watch-idle-lane-tests)
STATE_DIR="$TMP/state"
FAKEBIN="$TMP/fakebin"
mkdir -p "$STATE_DIR" "$FAKEBIN"

# Fake tmux backing ONLY the two calls these tests exercise:
#   - `display-message -p -t <target> '#{pane_id}'`, fm_backend_target_exists's
#     endpoint-existence probe. A target listed in FM_FAKE_TMUX_DEAD (a
#     space-separated set) fails (endpoint gone); every other target succeeds.
#   - `display-message ... pane_current_command`, unused here but harmless to
#     keep answering so a stray caller never hangs on a wrong branch.
#   - `capture-pane`, answered with FM_FAKE_TMUX_CAPTURE ONLY while that
#     variable is set, for the Grok rendered-tail arm of fm_busy_classify.
# recorded_windows, window_kind/backend/harness/label, and the busy-record path
# all resolve from *.meta and state/*.busy-state, never from tmux, so no other
# subcommand (list-windows) is needed; a genuinely dead lane's pane capture
# failing (and being skipped by the per-window stale loop) is exactly the
# production gap this predicate exists to close, so this fake leaves every
# unlisted subcommand - and capture-pane with no FM_FAKE_TMUX_CAPTURE set -
# unhandled (exit 1) on purpose.
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "capture-pane" ] && [ -n "${FM_FAKE_TMUX_CAPTURE+set}" ]; then
  printf '%s\n' "$FM_FAKE_TMUX_CAPTURE"
  exit 0
fi
if [ "${1:-}" = "display-message" ]; then
  target="" prev=""
  for a in "$@"; do
    [ "$prev" = "-t" ] && target=$a
    prev=$a
  done
  case "$*" in
    *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
  esac
  case " ${FM_FAKE_TMUX_DEAD:-} " in
    *" $target "*) exit 1 ;;
  esac
  printf '%%1\n'
  exit 0
fi
exit 1
SH
chmod +x "$FAKEBIN/tmux"
make_fake_crew_state "$FAKEBIN" >/dev/null

export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
export PATH="$FAKEBIN:$PATH"
# Source the watcher to load its functions without acquiring the singleton lock
# or entering the blocking loop (its own source guard returns early); see
# tests/fm-supervision-events.test.sh for the same pattern.
# shellcheck disable=SC1091
. "$WATCH"

reset_state() {
  rm -f "$STATE_DIR"/*.meta "$STATE_DIR"/*.status "$STATE_DIR"/*.busy-state \
    "$STATE_DIR"/*.busy-gen "$STATE_DIR"/.hb-idle-surfaced-* "$STATE_DIR"/.hb-surfaced-* \
    "$STATE_DIR"/.wake-queue "$STATE_DIR"/.wake-queue.seq "$STATE_DIR"/.heartbeat-streak \
    "$STATE_DIR"/.last-heartbeat "$STATE_DIR"/.watcher-down 2>/dev/null || true
  rm -rf "$STATE_DIR/.watch.lock" 2>/dev/null || true
  unset FM_FAKE_TMUX_DEAD FM_FAKE_TMUX_CAPTURE
}

# Record one busy-state event for <task> through the real writer (a real
# process, no harness): arms a fresh incarnation, then applies the given
# state/source/event.
busy_record() {  # <task> <busy|idle> <event>
  local task=$1 st=$2 event=$3 gen
  gen=$("$BUSY_EVENT" arm "$STATE_DIR" "$task") || fail "fm-busy-event.sh arm failed for $task"
  "$BUSY_EVENT" apply "$STATE_DIR" "$task" "$st" --gen "$gen" --source pi-ext --event "$event" >/dev/null \
    || fail "fm-busy-event.sh apply failed for $task"
}

# Portable mtime in epoch seconds (BSD vs GNU stat).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Set <file>'s mtime to exactly <epoch> seconds (BSD `date -r` vs GNU `date -d`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# --- scan_idle_lanes / heartbeat_idle_lane_actionable: the predicate matrix --

test_busy_lane_not_actionable() {
  reset_state
  fm_write_meta "$STATE_DIR/t1.meta" "window=sess:w1" "backend=tmux" "harness=pi" "kind=ship"
  busy_record t1 busy agent-start
  local out
  out=$(scan_idle_lanes)
  [ -z "$out" ] || fail "a busy lane was classified idle/dead: $out"
  heartbeat_idle_lane_actionable && fail "a busy lane was reported actionable"
  pass "a lane whose agent is genuinely busy is not actionable"
}

test_dead_lane_actionable() {
  reset_state
  fm_write_meta "$STATE_DIR/t2.meta" "window=sess:w2" "backend=tmux" "harness=pi" "kind=ship"
  export FM_FAKE_TMUX_DEAD="sess:w2"
  local out
  out=$(scan_idle_lanes)
  printf '%s' "$out" | grep -F "$(printf 'sess:w2\tt2\tdead')" >/dev/null \
    || fail "a dead lane (endpoint gone) was not classified dead: $out"
  heartbeat_idle_lane_actionable || fail "a dead lane was not reported actionable"
  unset FM_FAKE_TMUX_DEAD
  pass "a lane whose endpoint is gone (a worker that died and stopped writing) is actionable"
}

test_idle_lane_actionable() {
  reset_state
  fm_write_meta "$STATE_DIR/t3.meta" "window=sess:w3" "backend=tmux" "harness=pi" "kind=ship"
  busy_record t3 idle agent-settled
  local out
  out=$(scan_idle_lanes)
  printf '%s' "$out" | grep -F "$(printf 'sess:w3\tt3\tidle')" >/dev/null \
    || fail "a live idle lane was not classified idle: $out"
  heartbeat_idle_lane_actionable || fail "a live idle lane was not reported actionable"
  pass "a live endpoint whose agent is not busy (idle, no captain-relevant status) is actionable"
}

test_pr_waiting_lane_not_actionable() {
  reset_state
  fm_write_meta "$STATE_DIR/t4.meta" "window=sess:w4" "backend=tmux" "harness=pi" "kind=ship"
  printf 'done: PR https://example.test/pr/9\n' > "$STATE_DIR/t4.status"
  busy_record t4 idle agent-settled
  local out
  out=$(scan_idle_lanes)
  [ -z "$out" ] || fail "a PR-ready-and-waiting lane was classified idle-actionable: $out"
  heartbeat_idle_lane_actionable && fail "a PR-ready-and-waiting lane was reported actionable"
  pass "a lane whose PR is open and waiting on review is not actionable"
}

test_captain_decision_lane_not_actionable() {
  reset_state
  fm_write_meta "$STATE_DIR/t5.meta" "window=sess:w5" "backend=tmux" "harness=pi" "kind=ship"
  # The open decision is buried under a later non-terminal line, so only the
  # status-fold (status_open_decisions), not the last line alone, can see it.
  printf 'needs-decision [key=q1]: pick A or B\nworking: still deciding\n' > "$STATE_DIR/t5.status"
  busy_record t5 idle agent-settled
  local out
  out=$(scan_idle_lanes)
  [ -z "$out" ] || fail "a lane parked on an open captain decision was classified idle-actionable: $out"
  heartbeat_idle_lane_actionable && fail "a lane parked on an open captain decision was reported actionable"
  pass "a lane parked on a still-open captain decision is not actionable"
}

test_paused_lane_not_actionable() {
  reset_state
  fm_write_meta "$STATE_DIR/t6.meta" "window=sess:w6" "backend=tmux" "harness=pi" "kind=ship"
  printf 'paused: holding for the upstream release\n' > "$STATE_DIR/t6.status"
  busy_record t6 idle agent-settled
  local out
  out=$(scan_idle_lanes)
  [ -z "$out" ] || fail "a paused lane was classified idle-actionable: $out"
  heartbeat_idle_lane_actionable && fail "a paused lane was reported actionable"
  pass "a lane on a declared external-wait pause is not actionable"
}

test_unknown_verdict_not_actionable() {
  reset_state
  fm_write_meta "$STATE_DIR/t7.meta" "window=sess:w7" "backend=tmux" "harness=pi" "kind=ship"
  # No busy-state record was ever armed for t7: fm_busy_classify reports
  # "unknown missing", never idle - the source could not answer.
  local out
  out=$(scan_idle_lanes)
  [ -z "$out" ] || fail "an unknown busy verdict was classified idle/dead: $out"
  heartbeat_idle_lane_actionable && fail "an unknown busy verdict was reported actionable"
  pass "an unknown busy verdict is never promoted to idle-actionable"
}

test_secondmate_lane_excluded() {
  reset_state
  fm_write_meta "$STATE_DIR/t9.meta" "window=sess:w9" "backend=tmux" "harness=pi" "kind=secondmate"
  busy_record t9 idle agent-settled
  local out
  out=$(scan_idle_lanes)
  [ -z "$out" ] || fail "a secondmate lane was classified idle-actionable: $out"
  pass "a secondmate lane is excluded (its routed status is the supervision signal, not its pane)"
}

test_already_surfaced_idle_lane_not_refired() {
  reset_state
  fm_write_meta "$STATE_DIR/t8.meta" "window=sess:w8" "backend=tmux" "harness=pi" "kind=ship"
  busy_record t8 idle agent-settled
  heartbeat_idle_lane_actionable || fail "a fresh idle lane was not reported actionable before marking"
  mark_all_idle_lanes_surfaced
  [ -s "$STATE_DIR/.hb-idle-surfaced-t8" ] || fail "mark_all_idle_lanes_surfaced did not write the surfaced marker"
  heartbeat_idle_lane_actionable && fail "an idle lane already marked surfaced re-fired with nothing changed"
  # A genuinely new event (a fresh status line, e.g. progress the crew logged
  # while still idle) clears back to actionable: dedup is on the (verdict,
  # last-status) pair, not on task identity alone.
  printf 'working: still setting up\n' > "$STATE_DIR/t8.status"
  heartbeat_idle_lane_actionable || fail "an idle lane with a genuinely new status line did not re-fire"
  pass "an idle lane already surfaced does not re-fire until its verdict or status genuinely changes"
}

# The marker key carries the lane's freshness stamp (the busy-state record's
# mtime), so a second silence episode re-fires even when the heartbeat never
# sampled the intervening busy moment and the status line never changed - the
# worker this predicate targets goes idle without writing a status.
test_idle_marker_keyed_on_busy_state_freshness() {
  reset_state
  fm_write_meta "$STATE_DIR/t11.meta" "window=sess:w11" "backend=tmux" "harness=pi" "kind=ship"
  printf 'working: setting up\n' > "$STATE_DIR/t11.status"
  busy_record t11 idle agent-settled
  heartbeat_idle_lane_actionable || fail "a fresh idle lane was not reported actionable before marking"
  mark_all_idle_lanes_surfaced
  [ -s "$STATE_DIR/.hb-idle-surfaced-t11" ] || fail "mark_all_idle_lanes_surfaced did not write the surfaced marker"
  heartbeat_idle_lane_actionable && fail "an idle lane already marked surfaced re-fired with nothing changed"
  # The busy spell and the return to idle both happen between two heartbeats, so
  # the scan only ever sees idle -> idle with the same status text. Only the
  # busy-state record's mtime distinguishes the second episode from the first.
  busy_record t11 busy agent-start
  busy_record t11 idle agent-settled
  set_mtime "$(( $(file_mtime "$STATE_DIR/t11.busy-state") + 60 ))" "$STATE_DIR/t11.busy-state"
  heartbeat_idle_lane_actionable || fail "a second idle spell with an unchanged status line did not re-fire"
  mark_all_idle_lanes_surfaced
  heartbeat_idle_lane_actionable && fail "the re-surfaced idle lane re-fired again with nothing changed"
  pass "the surfaced marker is keyed on busy-state freshness, so a later idle spell re-fires on an unchanged status line"
}

# A harness with no busy-state record writer (grok/muse/cursor) has no
# freshness signal at all: the field is empty, never a stand-in mtime that
# would look fresh without ever moving. Those lanes keep the original
# last-status-only dedup, and the empty field must stay stable across scans.
test_recordless_harness_has_an_empty_freshness_field() {
  reset_state
  fm_write_meta "$STATE_DIR/t12.meta" "window=sess:w12" "backend=tmux" "harness=grok" "kind=ship"
  printf 'working: setting up\n' > "$STATE_DIR/t12.status"
  export FM_FAKE_TMUX_CAPTURE="waiting for your next instruction"
  local first second
  first=$(scan_idle_lanes)
  [ -n "$first" ] || fail "a grok lane with no busy-state record was not classified idle"
  [ -z "$(printf '%s' "$first" | cut -f4)" ] || fail "a lane with no busy-state record got a non-empty freshness field: $first"
  [ -e "$STATE_DIR/t12.busy-state" ] && fail "the grok lane unexpectedly has a busy-state record, so this case proves nothing"
  heartbeat_idle_lane_actionable || fail "a fresh idle grok lane was not reported actionable"
  mark_all_idle_lanes_surfaced
  second=$(scan_idle_lanes)
  [ "$second" = "$first" ] || fail "the marker key of a recordless lane changed with nothing else changing: $first -> $second"
  heartbeat_idle_lane_actionable && fail "a recordless idle lane re-fired with nothing changed"
  unset FM_FAKE_TMUX_CAPTURE
  pass "a lane with no busy-state record gets an empty freshness field and a stable marker key"
}

# --- fleet_has_recorded_endpoint: the backoff-cap selector -------------------

test_fleet_has_recorded_endpoint() {
  reset_state
  fleet_has_recorded_endpoint && fail "an empty fleet (no recorded windows) was classified as having a recorded endpoint"
  fm_write_meta "$STATE_DIR/t10.meta" "window=sess:w10" "backend=tmux" "harness=pi" "kind=ship"
  fleet_has_recorded_endpoint || fail "a fleet with one recorded window was classified empty"
  pass "fleet_has_recorded_endpoint distinguishes an empty fleet from one with a recorded endpoint"
}

# --- integration: a dead lane actually wakes a live watcher ------------------
# The reported incident: a worker died mid-response and nothing surfaced it for
# 40+ minutes because supervision only ever detects a captain-relevant status,
# never silence. This drives a real fm-watch.sh subprocess end to end.

test_dead_lane_surfaces_via_heartbeat() {
  reset_state
  local dir out pid
  dir="$TMP/dead-lane-integration"
  mkdir -p "$dir"
  out="$dir/watch.out"
  fm_write_meta "$STATE_DIR/dead1.meta" "window=deadsess:w1" "backend=tmux" "harness=pi" "kind=ship"
  export FM_FAKE_TMUX_DEAD="deadsess:w1"
  FM_STATE_OVERRIDE="$STATE_DIR" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || { unset FM_FAKE_TMUX_DEAD; fail "watcher did not surface a dead lane with no captain-relevant status"; }
  grep -Fx "heartbeat" "$out" >/dev/null || fail "the dead-lane wake was not a heartbeat wake: $(cat "$out")"
  [ -s "$STATE_DIR/.hb-idle-surfaced-dead1" ] || fail "the dead lane was not recorded as surfaced"
  unset FM_FAKE_TMUX_DEAD
  pass "a dead lane with no captain-relevant status wakes the watcher (the silence backstop)"
}

# --- integration: the backoff cap ---------------------------------------

test_heartbeat_backoff_capped_while_fleet_busy() {
  reset_state
  local dir out pid before after
  dir="$TMP/busy-cap-integration"
  mkdir -p "$dir"
  out="$dir/watch.out"
  fm_write_meta "$STATE_DIR/wb.meta" "window=capsess:w1" "backend=tmux" "harness=pi" "kind=ship"
  busy_record wb busy agent-start
  # A high pre-seeded streak means an EMPTY fleet would compute an hb far past
  # HEARTBEAT_MAX (uselessly large; clamped to it), so age 6s would never
  # trigger. A recorded endpoint must instead clamp to the tiny busy cap.
  echo 10 > "$STATE_DIR/.heartbeat-streak"
  touch "$STATE_DIR/.last-heartbeat"
  set_mtime "$(( $(date +%s) - 6 ))" "$STATE_DIR/.last-heartbeat"
  before=$(file_mtime "$STATE_DIR/.last-heartbeat")
  FM_STATE_OVERRIDE="$STATE_DIR" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=600 FM_HEARTBEAT_MAX=7200 FM_HEARTBEAT_BUSY_MAX=5 \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited while the fleet was genuinely busy: $(cat "$out")"
  fi
  sleep 1.5
  after=$(file_mtime "$STATE_DIR/.last-heartbeat")
  reap "$pid"
  [ "$after" -gt "$before" ] \
    || fail "heartbeat did not fire promptly with a recorded endpoint present (backoff not capped to HEARTBEAT_BUSY_MAX)"
  pass "the heartbeat backoff stays capped at HEARTBEAT_BUSY_MAX while any task has a recorded endpoint"
}

test_heartbeat_backoff_unchanged_when_fleet_empty() {
  reset_state
  local dir out pid before after
  dir="$TMP/empty-cap-integration"
  mkdir -p "$dir"
  out="$dir/watch.out"
  # No *.meta at all: an empty fleet. The same high streak and backdated age
  # that trips the busy cap above must NOT trip the (much larger) empty-fleet
  # HEARTBEAT_MAX cap - existing behavior for the case backoff exists for.
  echo 10 > "$STATE_DIR/.heartbeat-streak"
  touch "$STATE_DIR/.last-heartbeat"
  set_mtime "$(( $(date +%s) - 6 ))" "$STATE_DIR/.last-heartbeat"
  before=$(file_mtime "$STATE_DIR/.last-heartbeat")
  FM_STATE_OVERRIDE="$STATE_DIR" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=600 FM_HEARTBEAT_MAX=7200 FM_HEARTBEAT_BUSY_MAX=5 \
    "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for an empty fleet's backed-off heartbeat: $(cat "$out")"
  fi
  sleep 1.5
  after=$(file_mtime "$STATE_DIR/.last-heartbeat")
  reap "$pid"
  [ "$after" -eq "$before" ] \
    || fail "an empty fleet's heartbeat fired before HEARTBEAT_MAX (busy cap leaked into the empty-fleet case)"
  pass "an empty fleet keeps its existing HEARTBEAT_MAX backoff, unaffected by the busy cap"
}

test_busy_lane_not_actionable
test_dead_lane_actionable
test_idle_lane_actionable
test_pr_waiting_lane_not_actionable
test_captain_decision_lane_not_actionable
test_paused_lane_not_actionable
test_unknown_verdict_not_actionable
test_secondmate_lane_excluded
test_already_surfaced_idle_lane_not_refired
test_idle_marker_keyed_on_busy_state_freshness
test_recordless_harness_has_an_empty_freshness_field
test_fleet_has_recorded_endpoint
test_dead_lane_surfaces_via_heartbeat
test_heartbeat_backoff_capped_while_fleet_busy
test_heartbeat_backoff_unchanged_when_fleet_empty

#!/usr/bin/env bash
# tests/fm-crew-fitness.test.sh - the restart-recovery contract, end to end:
# bin/fm-crew-fitness.sh detects a pane that is alive but unable to work, and
# bin/fm-crew-relaunch.sh repairs it.
#
# The failure these guard against is a session-provider restart that brings a
# crewmate pane back looking perfectly healthy while it is silently useless: the
# harness relaunched without its autonomy flag (so it stalls on the first tool
# call waiting for an approval nobody is watching for) and outside its task
# worktree. Endpoint liveness reports that pane ALIVE, which is what let it cost
# real time twice in one day.
#
# Detection and repair share one expensive fixture - a real tmux server on a
# private socket plus a real git worktree - so they are exercised in one script
# rather than duplicating it. The tmux socket is private (`-L`) and reached
# through a PATH shim, exactly as tests/fm-backend-tmux-smoke.test.sh does, so
# this never touches the host's real sessions.
#
# The agent is a copy of bash named `claude`: that gives tmux's
# pane_current_command the value the tmux agent-state classifier needs to report
# `alive`, while /proc/<pid>/cmdline carries whatever argv the case under test
# wants. No real harness is launched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

assert_contains() {  # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3 (expected to contain '$2', got: $1)" ;;
  esac
}

assert_not_contains() {  # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) fail "$3 (expected NOT to contain '$2', got: $1)" ;;
    *) pass "$3" ;;
  esac
}

assert_eq() {  # <actual> <expected> <label>
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }
[ -r /proc/self/cmdline ] || { echo "skip: no readable /proc (argv element boundaries unavailable)"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-crew-fitness-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-fitness.XXXXXX")

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup_all EXIT

# tmux shim: every bare `tmux` call from bin/backends/tmux.sh lands on the
# private socket.
mkdir -p "$WORK/shim"
cat > "$WORK/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$WORK/shim/tmux"
PATH="$WORK/shim:$PATH"
export PATH

# The stand-in harness binary.
cp /bin/bash "$WORK/shim/claude"

# --- private firstmate home --------------------------------------------------
HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$HOME_DIR/state"
export FM_DATA_OVERRIDE="$HOME_DIR/data"

# --- a real project checkout and a real task worktree ------------------------
PROJECT="$WORK/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config user.email t@example.com
git -C "$PROJECT" config user.name Test
echo base > "$PROJECT/file.txt"
git -C "$PROJECT" add file.txt
git -C "$PROJECT" commit -qm base
WORKTREE="$WORK/worktree"
git -C "$PROJECT" worktree add -q -b task "$WORKTREE"
# Uncommitted work that MUST survive every repair path.
echo "precious uncommitted work" > "$WORKTREE/uncommitted.txt"
echo "edited" >> "$WORKTREE/file.txt"

SESSION=fmtest
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n placeholder

# launch_pane: create window <name>, cd to <cwd>, run the fake harness with the
# remaining argv. Mirrors how a real crewmate pane ends up running its harness -
# deliberately NOT `exec`, so interrupting the harness returns the pane to its
# shell with the window intact, exactly as a real adapter's exit command does.
launch_pane() {  # <window> <cwd> <argv...>
  local win=$1 cwd=$2
  shift 2
  local cmd
  printf -v cmd 'cd %q && %q -c %q' "$cwd" "$WORK/shim/claude" 'while :; do sleep 1; done'
  local a
  for a in "$@"; do printf -v cmd '%s %q' "$cmd" "$a"; done
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:$win" "$cmd" Enter
}

# launch_pane_env: the same, with one env prefix in front of the harness, so a
# pane can be stood up either carrying or missing the env-prefix grant its
# recorded launch command specifies.
launch_pane_env() {  # <window> <cwd> <name> <value> <argv...>
  local win=$1 cwd=$2 name=$3 value=$4
  shift 4
  local cmd
  printf -v cmd 'cd %q && %s=%q %q -c %q' "$cwd" "$name" "$value" "$WORK/shim/claude" 'while :; do sleep 1; done'
  local a
  for a in "$@"; do printf -v cmd '%s %q' "$cmd" "$a"; done
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:$win" "$cmd" Enter
}

write_meta() {  # <id> <window> <worktree> <launch>
  cat > "$HOME_DIR/state/$1.meta" <<EOF
window=$2
worktree=$3
project=$PROJECT
harness=claude
model=opus
effort=xhigh
kind=ship
mode=no-mistakes
yolo=0
launch=$4
EOF
}

wait_for_command() {  # <target> <expected-pane_current_command>
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)" = "$2" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

FITNESS="$ROOT/bin/fm-crew-fitness.sh"
RELAUNCH="$ROOT/bin/fm-crew-relaunch.sh"

# The real resolved launch shape fm-spawn.sh records for a claude crewmate.
AUTONOMOUS_LAUNCH="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --model opus --effort xhigh \"\$(fm-operational-input.sh encode launch-brief < '$HOME_DIR/data/t/brief.md')\""

# =============================================================================
# Detection
# =============================================================================

# --- healthy: autonomy flag in force, in the recorded worktree ---------------
launch_pane fm-fit "$WORKTREE" --dangerously-skip-permissions --model opus 'the brief'
write_meta fit "$SESSION:fm-fit" "$WORKTREE" "$AUTONOMOUS_LAUNCH"
wait_for_command "$SESSION:fm-fit" claude || fail "fake harness did not start for the healthy case"
OUT=$("$FITNESS" fit); RC=$?
assert_contains "$OUT" 'fitness: fit (autonomy=ok cwd=ok)' 'healthy pane reports fit'
assert_eq "$RC" 0 'healthy pane exits 0'

# --- the manual-mode case: relaunched WITHOUT the autonomy flag --------------
# This is what herdr's resume_agents_on_restore produces: `claude --resume <id>`,
# carrying none of firstmate's launch shape.
launch_pane fm-manual "$WORKTREE" --resume 21637ebd-8ca7-41bc-9c3b-1b8079c08ed0
write_meta manual "$SESSION:fm-manual" "$WORKTREE" "$AUTONOMOUS_LAUNCH"
wait_for_command "$SESSION:fm-manual" claude || fail "fake harness did not start for the manual-mode case"
OUT=$("$FITNESS" manual); RC=$?
assert_contains "$OUT" 'fitness: unfit' 'manual-mode pane reports unfit'
assert_contains "$OUT" 'autonomy=lost' 'manual-mode pane names the autonomy axis'
assert_contains "$OUT" '--dangerously-skip-permissions' 'manual-mode detail names the lost flag'
assert_eq "$RC" 1 'manual-mode pane exits 1'

# --- the wrong-cwd case: autonomous, but sitting in the project checkout ------
launch_pane fm-wrongcwd "$PROJECT" --dangerously-skip-permissions --model opus 'the brief'
write_meta wrongcwd "$SESSION:fm-wrongcwd" "$WORKTREE" "$AUTONOMOUS_LAUNCH"
wait_for_command "$SESSION:fm-wrongcwd" claude || fail "fake harness did not start for the wrong-cwd case"
OUT=$("$FITNESS" wrongcwd); RC=$?
assert_contains "$OUT" 'fitness: unfit' 'wrong-cwd pane reports unfit'
assert_contains "$OUT" 'cwd=wrong' 'wrong-cwd pane names the cwd axis'
assert_contains "$OUT" "$PROJECT" 'wrong-cwd detail names where the pane actually is'
assert_eq "$RC" 1 'wrong-cwd pane exits 1'

# --- the observed crash shape: both losses at once ---------------------------
launch_pane fm-both "$PROJECT" --resume 21637ebd-8ca7-41bc-9c3b-1b8079c08ed0
write_meta both "$SESSION:fm-both" "$WORKTREE" "$AUTONOMOUS_LAUNCH"
wait_for_command "$SESSION:fm-both" claude || fail "fake harness did not start for the combined case"
OUT=$("$FITNESS" both)
assert_contains "$OUT" 'autonomy=lost' 'combined case reports lost autonomy'
assert_contains "$OUT" 'cwd=wrong' 'combined case reports wrong cwd'

# --- a brief that QUOTES the flag must not be mistaken for the flag ----------
# The autonomy flag travels in argv alongside the whole brief, and a brief can
# name the flag - this task's own brief does. Substring matching over a
# flattened command line would call this pane healthy. It is not.
launch_pane fm-quoted "$WORKTREE" --resume abc123 \
  'brief: the restored process no longer carried --dangerously-skip-permissions, so it stalls'
write_meta quoted "$SESSION:fm-quoted" "$WORKTREE" "$AUTONOMOUS_LAUNCH"
wait_for_command "$SESSION:fm-quoted" claude || fail "fake harness did not start for the quoted-flag case"
OUT=$("$FITNESS" quoted)
assert_contains "$OUT" 'autonomy=lost' 'a brief quoting the flag is not mistaken for the flag itself'

# --- a launch with no recognized autonomy flag is n/a, not a false alarm -----
# pi grants autonomy without a flag; there is nothing whose loss could be seen.
launch_pane fm-noflag "$WORKTREE" --model opus 'the brief'
write_meta noflag "$SESSION:fm-noflag" "$WORKTREE" "FM_PI_HARNESS=pi pi --model opus \"\$(encode)\""
wait_for_command "$SESSION:fm-noflag" claude || fail "fake harness did not start for the no-flag case"
OUT=$("$FITNESS" noflag); RC=$?
assert_contains "$OUT" 'autonomy=n/a' 'a launch with no recognized autonomy flag reports n/a'
assert_contains "$OUT" 'fitness: fit' 'n/a autonomy with a correct cwd is still fit'
assert_eq "$RC" 0 'n/a autonomy with a correct cwd exits 0'

# --- an env-prefix grant counts on the autonomy axis, both ways ---------------
# opencode's autonomy IS its env prefix, and a restart drops an env prefix
# exactly as it drops a flag. It carries a JSON value with a glob character in
# it, which is exactly the value whole-entry matching has to survive.
OPENCODE_GRANT='{"permission":{"*":"allow"}}'
OPENCODE_LAUNCH="OPENCODE_CONFIG_CONTENT='$OPENCODE_GRANT' opencode --model opus --prompt \"\$(encode)\""

launch_pane fm-envlost "$WORKTREE" --model opus 'the brief'
write_meta envlost "$SESSION:fm-envlost" "$WORKTREE" "$OPENCODE_LAUNCH"
wait_for_command "$SESSION:fm-envlost" claude || fail "fake harness did not start for the dropped-env-prefix case"
OUT=$("$FITNESS" envlost); RC=$?
assert_contains "$OUT" 'autonomy=lost' 'a dropped env-prefix grant is detected as lost, not excused as n/a'
assert_contains "$OUT" 'OPENCODE_CONFIG_CONTENT=' 'the detail names the env-prefix grant that is gone'
assert_eq "$RC" 1 'a dropped env-prefix grant exits 1'

launch_pane_env fm-envok "$WORKTREE" OPENCODE_CONFIG_CONTENT "$OPENCODE_GRANT" --model opus 'the brief'
write_meta envok "$SESSION:fm-envok" "$WORKTREE" "$OPENCODE_LAUNCH"
wait_for_command "$SESSION:fm-envok" claude || fail "fake harness did not start for the intact-env-prefix case"
OUT=$("$FITNESS" envok); RC=$?
assert_contains "$OUT" 'fitness: fit (autonomy=ok cwd=ok)' 'an env-prefix grant still in force reads ok, not a permanent unknown'
assert_eq "$RC" 0 'an env-prefix grant still in force exits 0'

# A secondmate carries FM_HOME, which is what makes it address its own home
# rather than its parent's. A flag reading ok must not certify the whole axis
# while that prefix is gone.
launch_pane fm-secondmate "$WORKTREE" --dangerously-skip-permissions --model opus 'the brief'
write_meta secondmate "$SESSION:fm-secondmate" "$WORKTREE" \
  "FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_HOME='$WORK/secondmate-home' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --model opus \"\$(encode)\""
wait_for_command "$SESSION:fm-secondmate" claude || fail "fake harness did not start for the secondmate case"
OUT=$("$FITNESS" secondmate); RC=$?
assert_contains "$OUT" 'autonomy=lost' 'a secondmate that lost its FM_HOME prefix is unfit even with its flag intact'
assert_contains "$OUT" 'FM_HOME=' 'the detail names the lost secondmate identity prefix'
assert_eq "$RC" 1 'a secondmate that lost its identity prefix exits 1'

# A value this cannot decode with certainty must be unknown, never a claim that
# the grant is missing: a recorded value containing a space is split across
# words and can no longer be compared.
launch_pane fm-envundecodable "$WORKTREE" --model opus 'the brief'
write_meta envundecodable "$SESSION:fm-envundecodable" "$WORKTREE" \
  "OPENCODE_CONFIG_CONTENT='a value with spaces' opencode --model opus"
wait_for_command "$SESSION:fm-envundecodable" claude || fail "fake harness did not start for the undecodable-grant case"
OUT=$("$FITNESS" envundecodable); RC=$?
assert_contains "$OUT" 'autonomy=unknown' 'an undecodable recorded grant is unknown'
assert_not_contains "$OUT" 'autonomy=lost' 'an undecodable recorded grant is never claimed to be lost'
assert_not_contains "$OUT" 'fitness: fit' 'an undecodable recorded grant never reports fit'
assert_eq "$RC" 3 'an undecodable recorded grant exits 3'

# --- the env contract itself: a backend that cannot see an environment --------
# herdr's pane process-info exposes argv, argv0, cmdline, cwd, name, and pid and
# no environment at all, so it must answer undeterminable rather than absent.
( . "$ROOT/bin/fm-backend.sh"; fm_backend_pane_env_has herdr default:w1:p2 'FM_HOME=/tmp/x' )
assert_eq "$?" 2 'a backend that cannot read an environment answers undeterminable, never absent'
( . "$ROOT/bin/fm-backend.sh"; fm_backend_pane_env_has tmux "$SESSION:fm-envok" 'not-an-entry' )
assert_eq "$?" 2 'a malformed environment entry is undeterminable, never a verdict'

# --- fail closed: unreadable or unrecorded inputs are unknown, never fit -----
launch_pane fm-nolaunch "$WORKTREE" --dangerously-skip-permissions
cat > "$HOME_DIR/state/nolaunch.meta" <<EOF
window=$SESSION:fm-nolaunch
worktree=$WORKTREE
harness=claude
EOF
wait_for_command "$SESSION:fm-nolaunch" claude || fail "fake harness did not start for the no-launch case"
OUT=$("$FITNESS" nolaunch); RC=$?
assert_contains "$OUT" 'fitness: unknown' 'a task with no recorded launch command reports unknown'
assert_not_contains "$OUT" 'fitness: fit' 'a task with no recorded launch command never reports fit'
assert_eq "$RC" 3 'unknown exits 3'

OUT=$("$FITNESS" no-such-task); RC=$?
assert_contains "$OUT" 'fitness: unknown' 'an unrecorded task reports unknown'
assert_eq "$RC" 3 'an unrecorded task exits 3'

cat > "$HOME_DIR/state/nowindow.meta" <<EOF
worktree=$WORKTREE
launch=$AUTONOMOUS_LAUNCH
EOF
OUT=$("$FITNESS" nowindow)
assert_contains "$OUT" 'fitness: unknown' 'a task with no recorded endpoint reports unknown'

# A pane whose endpoint is gone entirely must not read as a lost flag: an
# unreadable process is unknown, never a verdict.
cat > "$HOME_DIR/state/gone.meta" <<EOF
window=$SESSION:fm-does-not-exist
worktree=$WORKTREE
launch=$AUTONOMOUS_LAUNCH
EOF
OUT=$("$FITNESS" gone)
assert_contains "$OUT" 'fitness: unknown' 'a vanished endpoint reports unknown, not a lost flag'
assert_not_contains "$OUT" 'autonomy=lost' 'a vanished endpoint does not claim the flag was lost'

# --- --all aggregates and reports the worst verdict --------------------------
OUT=$("$FITNESS" --all); RC=$?
assert_contains "$OUT" 'manual: fitness: unfit' '--all labels each task'
assert_contains "$OUT" 'fit: fitness: fit' '--all reports healthy tasks too'
assert_eq "$RC" 1 '--all exits 1 when any task is unfit'

# =============================================================================
# Repair
# =============================================================================

# --- never relaunch over a live agent ----------------------------------------
ERR=$("$RELAUNCH" manual 2>&1 >/dev/null); RC=$?
assert_contains "$ERR" 'still running' 'relaunch refuses while an agent still owns the task'
assert_eq "$RC" 1 'relaunch refusal over a live agent exits 1'

# --- never allocate a second worktree ----------------------------------------
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n fm-nowt
write_meta nowt "$SESSION:fm-nowt" "$WORK/worktree-that-vanished" "$AUTONOMOUS_LAUNCH"
ERR=$("$RELAUNCH" nowt 2>&1 >/dev/null); RC=$?
assert_contains "$ERR" 'no longer exists' 'relaunch refuses when the recorded worktree is gone'
assert_eq "$RC" 1 'relaunch refusal for a missing worktree exits 1'
[ -d "$WORK/worktree-that-vanished" ] && fail 'relaunch must never create the missing worktree'
[ -d "$WORK/worktree-that-vanished" ] || pass 'relaunch created no replacement worktree'

# --- refuse a task with no recorded launch command ---------------------------
ERR=$("$RELAUNCH" nolaunch 2>&1 >/dev/null); RC=$?
assert_contains "$ERR" 'no recorded launch command' 'relaunch refuses without a recorded launch command'
assert_eq "$RC" 1 'relaunch refusal without a launch command exits 1'

# --- a vanished endpoint is a respawn, and refusing it must cost nothing ------
# There is no pane to relaunch into, so the only honest answer is a refusal -
# and it has to happen before the brief is written, or a failed repair leaves a
# recovery note claiming a relaunch that never occurred.
mkdir -p "$HOME_DIR/data/vanished"
printf '# Brief\n\nOriginal task instructions.\n' > "$HOME_DIR/data/vanished/brief.md"
BRIEF_BEFORE=$(cat "$HOME_DIR/data/vanished/brief.md")
write_meta vanished "$SESSION:fm-endpoint-is-gone" "$WORKTREE" "$AUTONOMOUS_LAUNCH"
ERR=$("$RELAUNCH" vanished 2>&1 >/dev/null); RC=$?
assert_contains "$ERR" 'respawn, not a relaunch' 'relaunch refuses a vanished endpoint as a respawn'
assert_eq "$RC" 1 'relaunch refusal for a vanished endpoint exits 1'
assert_eq "$(cat "$HOME_DIR/data/vanished/brief.md")" "$BRIEF_BEFORE" \
  'a refused relaunch leaves the brief exactly as it was'

# --- the repair itself -------------------------------------------------------
# Set the broken pane up exactly as the crash left it: no autonomy flag, sitting
# in the project checkout, with the task's real uncommitted work in its worktree.
mkdir -p "$HOME_DIR/data/repair"
cat > "$HOME_DIR/data/repair/brief.md" <<'EOF'
# Brief

Original task instructions.
EOF
REPAIR_LAUNCH="$WORK/shim/claude -c 'while :; do sleep 1; done' --dangerously-skip-permissions --model opus 'the brief'"
launch_pane fm-repair "$PROJECT" --resume stale-session-id
write_meta repair "$SESSION:fm-repair" "$WORKTREE" "$REPAIR_LAUNCH"
wait_for_command "$SESSION:fm-repair" claude || fail "fake harness did not start for the repair case"

OUT=$("$FITNESS" repair)
assert_contains "$OUT" 'fitness: unfit' 'the pane to be repaired starts unfit'

# --dry-run must change nothing.
BRIEF_BEFORE=$(cat "$HOME_DIR/data/repair/brief.md")
"$RELAUNCH" repair --dry-run >/dev/null 2>&1
assert_eq "$(cat "$HOME_DIR/data/repair/brief.md")" "$BRIEF_BEFORE" '--dry-run does not touch the brief'

WORKTREE_COUNT_BEFORE=$(git -C "$PROJECT" worktree list | wc -l)

# Exit the agent, as the recovery playbook requires before relaunching.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:fm-repair" C-c
i=0
while [ "$i" -lt 100 ]; do
  case "$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:fm-repair" '#{pane_current_command}' 2>/dev/null)" in
    claude) sleep 0.1; i=$((i + 1)) ;;
    *) break ;;
  esac
done

OUT=$("$RELAUNCH" repair 2>&1); RC=$?
assert_eq "$RC" 0 'relaunch succeeds once no agent owns the task'
assert_contains "$OUT" 'relaunched repair' 'relaunch reports the task it restored'
wait_for_command "$SESSION:fm-repair" claude || fail 'relaunch did not bring the harness back up'

OUT=$("$FITNESS" repair)
assert_contains "$OUT" 'fitness: fit (autonomy=ok cwd=ok)' 'the repaired pane is autonomous and in its worktree'

# The repair must not have disturbed the work the task had already done.
assert_eq "$(cat "$WORKTREE/uncommitted.txt" 2>/dev/null)" 'precious uncommitted work' \
  'uncommitted work in the worktree survives the repair'
assert_contains "$(cat "$WORKTREE/file.txt")" 'edited' 'uncommitted edits survive the repair'
assert_eq "$(git -C "$PROJECT" worktree list | wc -l)" "$WORKTREE_COUNT_BEFORE" \
  'the repair allocates no second worktree for the task'
assert_contains "$(cat "$HOME_DIR/data/repair/brief.md")" 'Recovery note' \
  'the repair leaves a recovery note in the brief'
assert_contains "$(cat "$HOME_DIR/data/repair/brief.md")" 'Original task instructions' \
  'the repair preserves the original brief'

# --- the repair lands in the right directory and restores the task env -------
# A worktree path holding a space proves the sent `cd` is shell-quoted: unquoted,
# the pane would cd to a truncated path and the launch would be typed there while
# the script still reported success. GOTMPDIR proves the pane's env is restored,
# because a restart leaves a fresh shell that never saw fm-spawn.sh's export.
SPACED="$WORK/task worktree"
git -C "$PROJECT" worktree add -q -b spaced-task "$SPACED"
echo "spaced uncommitted work" > "$SPACED/uncommitted.txt"
SPACED_TMP="$WORK/tasktmp with space"
SPACED_OUT="$WORK/spaced-out"
mkdir -p "$SPACED_OUT"
mkdir -p "$HOME_DIR/data/spaced"
printf '# Brief\n\nOriginal task instructions.\n' > "$HOME_DIR/data/spaced/brief.md"
SPACED_INNER="printf '%s\n' \"\$PWD\" > '$SPACED_OUT/cwd.txt'; printf '%s\n' \"\${GOTMPDIR:-unset}\" > '$SPACED_OUT/gotmp.txt'; while :; do sleep 1; done"
printf -v SPACED_LAUNCH '%q -c %q --dangerously-skip-permissions' "$WORK/shim/claude" "$SPACED_INNER"
cat > "$HOME_DIR/state/spaced.meta" <<EOF
window=$SESSION:fm-spaced
worktree=$SPACED
project=$PROJECT
harness=claude
kind=ship
tasktmp=$SPACED_TMP
launch=$SPACED_LAUNCH
EOF
# A bare shell window: the endpoint exists but no agent owns it, which is the
# only state a relaunch is licensed for.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n fm-spaced

OUT=$("$RELAUNCH" spaced --dry-run); RC=$?
assert_eq "$RC" 0 '--dry-run on a task with a recorded tasktmp exits 0'
assert_contains "$OUT" 'would send env: export GOTMPDIR=' '--dry-run names the GOTMPDIR export it would replay'
[ -d "$SPACED_TMP/gotmp" ] && fail '--dry-run must not create the GOTMPDIR it would export'
[ -d "$SPACED_TMP/gotmp" ] || pass '--dry-run creates nothing'

# The reboot this repair exists to recover from is exactly what clears the task
# tmp root, and Go does not create GOTMPDIR, so exporting the path without
# recreating the directory would break the relaunched agent's first build.
OUT=$("$RELAUNCH" spaced 2>&1); RC=$?
[ -d "$SPACED_TMP/gotmp" ] || fail 'the repair must recreate the GOTMPDIR it exports'
[ -d "$SPACED_TMP/gotmp" ] && pass 'the repair recreates the task GOTMPDIR the reboot removed'
assert_eq "$RC" 0 'relaunch into a worktree path containing a space succeeds'
wait_for_command "$SESSION:fm-spaced" claude || fail 'relaunch did not bring the harness up in the spaced worktree'

i=0
while [ "$i" -lt 100 ] && [ ! -s "$SPACED_OUT/gotmp.txt" ]; do sleep 0.1; i=$((i + 1)); done
assert_eq "$(cat "$SPACED_OUT/cwd.txt" 2>/dev/null)" "$SPACED" \
  'the relaunched command runs in the recorded worktree even when its path contains a space'
assert_eq "$(cat "$SPACED_OUT/gotmp.txt" 2>/dev/null)" "$SPACED_TMP/gotmp" \
  'the relaunched agent inherits the task GOTMPDIR fm-spawn.sh sets at launch'
assert_eq "$(cat "$SPACED/uncommitted.txt" 2>/dev/null)" 'spaced uncommitted work' \
  'uncommitted work in a spaced worktree survives the repair'

[ "$FAILED" -eq 0 ] || exit 1
echo "all fm-crew-fitness tests passed"

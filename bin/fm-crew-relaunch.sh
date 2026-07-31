#!/usr/bin/env bash
# fm-crew-relaunch.sh - relaunch a recorded task in its own worktree, exactly as
# it was originally launched.
#
# This exists because the correct relaunch used to be assembled from memory
# during an incident: the right env prefixes, the autonomy flag, the recorded
# model and effort, the encoded brief, and a `cd` into the right worktree, all
# reconstructed by hand while a crashed fleet sat idle. Every one of those is
# already decided at spawn time, so fm-spawn.sh records the resolved command as
# `launch=` in state/<id>.meta and this script replays it. Nothing is re-derived.
#
# Typical use: a session-provider restart brought a pane back alive but unable to
# work (see bin/fm-crew-fitness.sh for the mechanism and detection). Exit that
# pane's agent with the adapter's exit command from the harness-adapters skill,
# then run this.
#
# SAFETY - this script refuses rather than risking the task:
#   * It NEVER relaunches over a live agent. Only the recovery-grade `dead` and
#     `missing` endpoint states license a relaunch; `alive`, `ambiguous`,
#     `unreadable`, and `unverified` all refuse, so two agents can never end up
#     owning one task. Exit the agent first - do not force past this.
#   * It NEVER allocates a worktree. It relaunches into the recorded worktree or
#     it refuses, because allocating a second worktree for a task whose first one
#     is unaccounted for is how one task becomes two diverging copies.
#   * It NEVER touches the worktree's contents: no checkout, no clean, no stash,
#     no reset. Uncommitted work is preserved by not being touched at all.
#   * It appends a recovery note to the brief BEFORE relaunching, so the agent
#     builds on the work already in the worktree instead of starting over.
#
# Read `bin/fm-crew-fitness.sh --help` for the detection side of the same
# failure. Exit status: 0 relaunched, 1 refused (with the reason on stderr),
# 2 usage error.
set -u

usage() {
  cat <<'EOF'
usage: fm-crew-relaunch.sh <task-id> [--note <text>] [--dry-run]

Replays the task's recorded launch command in its recorded worktree, after
proving no live agent still owns it.

  --note <text>  recovery note appended to data/<id>/brief.md before relaunch
                 (default: a generic interrupted-and-resumed note)
  --dry-run      print what would be sent and exit without sending or writing

Refuses unless the recorded endpoint is dead or missing: exit the agent with its
adapter's exit command first (see the harness-adapters skill).
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

ID=
NOTE=
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --note) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; NOTE=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) usage >&2; exit 2 ;;
    *) [ -z "$ID" ] || { usage >&2; exit 2; }; ID=$1; shift ;;
  esac
done
[ -n "$ID" ] || { usage >&2; exit 2; }

META="$STATE/$ID.meta"
[ -f "$META" ] || die "no durable record for task '$ID' ($META)"

LAUNCH=$(fm_meta_get "$META" launch)
WORKTREE=$(fm_meta_get "$META" worktree)
WINDOW=$(fm_meta_get "$META" window)
BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
TARGET=${TARGET:-$WINDOW}

[ -n "$LAUNCH" ] || die "task '$ID' has no recorded launch command; it was spawned before launch= was tracked, so a deterministic relaunch is not possible - recover it by hand through the stuck-crewmate-recovery playbook"
[ -n "$TARGET" ] || die "task '$ID' has no recorded endpoint to relaunch into"
[ -n "$WORKTREE" ] || die "task '$ID' has no recorded worktree; refusing to relaunch somewhere else"

# --- worktree must still be the same accounted-for worktree ------------------
# Never allocate, never substitute. A missing or moved worktree is a
# stop-and-investigate result, because the task's uncommitted work lives there.
[ -d "$WORKTREE" ] || die "recorded worktree $WORKTREE no longer exists; refusing to allocate another one for task '$ID' - investigate where its work went before relaunching"
WT_TOP=$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null) || \
  die "recorded worktree $WORKTREE is not a git worktree any more; refusing to relaunch task '$ID' into it"
WT_REAL=$( cd "$WORKTREE" && pwd -P )
TOP_REAL=$( cd "$WT_TOP" && pwd -P )
[ "$WT_REAL" = "$TOP_REAL" ] || \
  die "recorded worktree $WORKTREE is now inside a different checkout ($WT_TOP); refusing to relaunch task '$ID'"

# --- no live agent may still own this task -----------------------------------
AGENT_STATE=$(fm_backend_agent_state "$BACKEND" "$TARGET")
case "$AGENT_STATE" in
  dead|missing) ;;
  alive)
    die "an agent is still running in task '$ID''s pane; exit it with its adapter's exit command first (harness-adapters skill), then re-run - relaunching over a live agent would put two agents on one task"
    ;;
  *)
    die "cannot confirm task '$ID''s pane is free (endpoint state: $AGENT_STATE); refusing to relaunch until it reads dead or missing"
    ;;
esac

BRIEF="$DATA/$ID/brief.md"
[ -n "$NOTE" ] || NOTE="This session was interrupted and relaunched in place. Your worktree, its commits, and its uncommitted changes are exactly as you left them. Inspect the worktree first and continue from that state - do not restart the task from the beginning."

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'would append recovery note to: %s\n' "$BRIEF"
  printf 'would cd pane %s (backend=%s) to: %s\n' "$TARGET" "$BACKEND" "$WORKTREE"
  printf 'would send launch: %s\n' "$LAUNCH"
  exit 0
fi

# Append the recovery note BEFORE relaunching: the launch command re-reads the
# brief from disk, so a note written afterwards would be invisible to the agent
# it is meant for.
if [ -f "$BRIEF" ]; then
  {
    printf '\n## Recovery note\n\n'
    printf '%s\n' "$NOTE"
  } >> "$BRIEF" || die "could not append the recovery note to $BRIEF"
else
  printf 'warning: no brief at %s; relaunching without a recovery note\n' "$BRIEF" >&2
fi

# cd first, then launch. The recorded launch command is worktree-relative in
# effect - it is the same string fm-spawn.sh sent once the pane was already
# inside the worktree - so sending it from the wrong directory is what produced
# the failure this script repairs.
fm_backend_send_text_line "$BACKEND" "$TARGET" "cd $WORKTREE" "$WINDOW" \
  || die "could not send the directory change to task '$ID''s pane"
sleep 0.3
fm_backend_send_text_line "$BACKEND" "$TARGET" "$LAUNCH" "$WINDOW" \
  || die "could not send the launch command to task '$ID''s pane"

printf 'relaunched %s harness=%s backend=%s worktree=%s\n' \
  "$ID" "$(fm_meta_get "$META" harness)" "$BACKEND" "$WORKTREE"

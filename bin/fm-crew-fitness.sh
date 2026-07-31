#!/usr/bin/env bash
# fm-crew-fitness.sh - can this task's recorded pane actually still do the work?
#
# Endpoint liveness answers "is the pane there". It cannot answer "is the thing
# in the pane still able to act", and those two came apart in production: a
# session-provider restart can leave a pane that is alive, has full conversation
# context, shows no error, and is nonetheless permanently unable to work.
#
# The observed mechanism (verified 2026-07-31, herdr 0.7.5, Claude Code 2.1.220):
# herdr persists only each pane's CREATION cwd in ~/.config/herdr/session.json,
# and its `[session] resume_agents_on_restore` default relaunches the agent from
# the integration-reported session ref - `claude --resume <id>`. That resume
# command is herdr's, not firstmate's, so it carries NONE of the launch shape
# fm-spawn resolved: no autonomy flag, no model/effort, no env prefixes. The
# restored pane therefore comes back (a) without permission bypass, so it stalls
# forever on its first tool call waiting for an approval nobody is watching for,
# and (b) in the project checkout instead of the task worktree, because the
# worktree was only ever entered by a `treehouse get` subshell that the persisted
# creation cwd never followed. See docs/herdr-backend.md "Restart and liveness
# behavior" for the backend-side statement of the same facts.
#
# So this check reads the two properties that failure destroys:
#
#   autonomy - every autonomy-granting flag that THIS task's recorded launch
#              command specified is still an exact argv element of the process
#              running in the pane right now.
#   cwd      - the pane's live foreground cwd is still the task's recorded
#              worktree.
#
# The autonomy flag set is never inferred per harness. It is intersected with the
# task's own recorded `launch=`, so whatever fm-spawn.sh's launch_template
# actually used for this task is what gets enforced, and changing a template can
# never leave this check silently asserting a stale flag.
#
# Output is one stable line:
#
#   fitness: <fit|unfit|unknown> (autonomy=<ok|lost|n/a|unknown> cwd=<ok|wrong|unknown>)[ - <detail>]
#
# Verdict rules, in order:
#   1. Either axis definitely bad (autonomy=lost or cwd=wrong) -> unfit.
#   2. Otherwise either axis unknown -> unknown.
#   3. Otherwise -> fit.
#
# It FAILS CLOSED toward unknown and never toward fit: every unreadable target,
# unsupported backend, missing record, or unattributable process is `unknown`,
# because a false `fit` is exactly the silent failure this script exists to end.
# `n/a` is not a failure - it means the recorded launch command granted autonomy
# by some means other than a recognized flag (pi needs none; opencode uses an env
# prefix), so there is no flag whose loss could be detected.
#
# Read-only and side-effect free. Exit status: 0 fit, 1 unfit, 3 unknown,
# 2 usage error. The exit status lets a caller branch without parsing the line.
set -u

usage() {
  cat <<'EOF'
usage: fm-crew-fitness.sh <task-id>
       fm-crew-fitness.sh --all

Reports whether a recorded task's pane is still able to work: its harness still
carries the autonomy flags its recorded launch command specified, and it is
still in the task's recorded worktree.

  <task-id>   report on one task
  --all       report on every state/*.meta in this home, one line per task,
              prefixed "<id>: "; exit 1 if any task is unfit, else 3 if any is
              unknown, else 0

Exit: 0 fit, 1 unfit, 3 unknown, 2 usage error.
Repair an unfit pane with bin/fm-crew-relaunch.sh after exiting its agent.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# Recognized autonomy-granting flags across every verified adapter's launch
# template in bin/fm-spawn.sh. This list only has to CONTAIN the flags; it never
# maps harness -> flag, because the flag actually in force is read from the
# task's own recorded launch command. A harness whose autonomy rides an env
# prefix (opencode's OPENCODE_CONFIG_CONTENT) or needs no grant at all (pi)
# simply matches nothing here and reports n/a.
AUTONOMY_FLAGS='--dangerously-skip-permissions
--dangerously-bypass-approvals-and-sandbox
--always-approve
--auto'

# real_path: physical path, or the input unchanged when it cannot be resolved.
# Worktree comparison must be physical: a symlinked project or worktree prefix
# would otherwise read as a mismatch and manufacture a false `wrong`.
real_path() {  # <path>
  [ -n "$1" ] || return 0
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"
}

# launch_autonomy_flags: the recognized autonomy flags present as whitespace-
# delimited words in <launch>. Word matching (not substring) keeps a longer flag
# from being reported because a shorter one is its prefix.
launch_autonomy_flags() {  # <launch-command>
  local launch=$1 flag word
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    for word in $launch; do
      if [ "$word" = "$flag" ]; then
        printf '%s\n' "$flag"
        break
      fi
    done
  done <<EOF
$AUTONOMY_FLAGS
EOF
}

report() {  # <verdict> <autonomy> <cwd> [detail]
  local verdict=$1 autonomy=$2 cwd=$3 detail=${4:-}
  if [ -n "$detail" ]; then
    printf 'fitness: %s (autonomy=%s cwd=%s) - %s\n' "$verdict" "$autonomy" "$cwd" "$detail"
  else
    printf 'fitness: %s (autonomy=%s cwd=%s)\n' "$verdict" "$autonomy" "$cwd"
  fi
  case "$verdict" in
    fit) return 0 ;;
    unfit) return 1 ;;
    *) return 3 ;;
  esac
}

check_one() {  # <task-id>
  local id=$1 meta backend target window worktree launch
  local autonomy=unknown cwd=unknown detail='' flag rc live live_real want_real
  local -a lost=()

  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { report unknown unknown unknown "no durable record for task '$id'"; return; }

  window=$(fm_meta_get "$meta" window)
  worktree=$(fm_meta_get "$meta" worktree)
  launch=$(fm_meta_get "$meta" launch)
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  target=${target:-$window}

  [ -n "$target" ] || { report unknown unknown unknown "no endpoint recorded"; return; }

  # The exact recorded endpoint must be proven present BEFORE either axis is
  # read, and only the recovery-grade state contract can prove it. Tmux
  # silently resolves an absent target to the CALLER'S OWN active window, and
  # the cheap fm_backend_target_exists probe inherits that fallback - so a task
  # whose window is gone would be measured against firstmate's own pane and
  # condemned as having lost its flag and left its worktree. That false
  # accusation is worse than no answer: it could send a relaunch after a task
  # that no longer has an endpoint at all. fm_backend_agent_state is the
  # primitive that checks the exact window against a real inventory.
  #
  # Only `missing` and `unreadable` short-circuit. `dead` deliberately does
  # NOT: a pane that fell back to a bare shell still exists, still reports
  # alive to the digest's liveness probe, and is genuinely unfit - that is the
  # third shape of this same failure.
  case "$(fm_backend_agent_state "$backend" "$target")" in
    missing)
      report unknown unknown unknown "recorded endpoint $target is gone; its liveness, not its fitness, is the question"
      return
      ;;
    unreadable)
      report unknown unknown unknown "could not read the recorded endpoint $target on backend=$backend"
      return
      ;;
  esac

  # --- autonomy axis --------------------------------------------------------
  if [ -z "$launch" ]; then
    # Spawned before launch= was recorded. The flags in force cannot be known,
    # and guessing them per harness is exactly the drift this design avoids.
    detail="no launch command recorded (spawned before this was tracked); deterministic relaunch is unavailable for this task"
  else
    local -a want=()
    while IFS= read -r flag; do
      [ -n "$flag" ] || continue
      want+=("$flag")
    done < <(launch_autonomy_flags "$launch")
    if [ "${#want[@]}" -eq 0 ]; then
      # The recorded launch grants autonomy by some means other than a
      # recognized flag, so no flag exists whose loss could be detected.
      autonomy=n/a
    else
      autonomy=ok
      for flag in "${want[@]}"; do
        fm_backend_pane_argv_has "$backend" "$target" "$flag"
        rc=$?
        case "$rc" in
          0) ;;
          1) lost+=("$flag"); autonomy=lost ;;
          # An undeterminable read cannot clear an ALREADY-PROVEN loss: one
          # confidently absent flag is enough to condemn the pane.
          *) [ "$autonomy" = lost ] || autonomy=unknown; break ;;
        esac
      done
    fi
  fi

  # --- worktree axis --------------------------------------------------------
  if [ -z "$worktree" ]; then
    cwd=unknown
  else
    live=$(fm_backend_current_path "$backend" "$target" "$window" 2>/dev/null || true)
    if [ -z "$live" ]; then
      cwd=unknown
    else
      live_real=$(real_path "$live")
      want_real=$(real_path "$worktree")
      if [ "$live_real" = "$want_real" ]; then
        cwd=ok
      else
        cwd=wrong
      fi
    fi
  fi

  # --- verdict --------------------------------------------------------------
  if [ "$autonomy" = lost ] || [ "$cwd" = wrong ]; then
    [ "$autonomy" != lost ] || detail="autonomy flag no longer in force: ${lost[*]:-}"
    if [ "$cwd" = wrong ]; then
      if [ -n "$detail" ]; then
        detail="$detail; pane is in $live, not the recorded worktree $worktree"
      else
        detail="pane is in $live, not the recorded worktree $worktree"
      fi
    fi
    report unfit "$autonomy" "$cwd" "$detail"
    return
  fi
  if [ "$autonomy" = unknown ] || [ "$cwd" = unknown ]; then
    [ -n "$detail" ] || detail="could not read the pane's process or working directory on backend=$backend"
    report unknown "$autonomy" "$cwd" "$detail"
    return
  fi
  report fit "$autonomy" "$cwd"
}

case "${1:-}" in
  ''|-h|--help) usage; [ -n "${1:-}" ] && exit 0; exit 2 ;;
esac

if [ "$1" = --all ]; then
  worst=0
  found=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    found=1
    id=$(basename "$meta" .meta)
    line=$(check_one "$id")
    rc=$?
    printf '%s: %s\n' "$id" "$line"
    case "$rc" in
      1) worst=1 ;;
      3) [ "$worst" -eq 1 ] || worst=3 ;;
    esac
  done
  [ "$found" -eq 1 ] || printf '(no recorded tasks)\n'
  exit "$worst"
fi

check_one "$1"

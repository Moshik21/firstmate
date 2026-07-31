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
#              running in the pane right now, and every autonomy-granting env
#              prefix it specified is still an exact entry in that process's
#              environment.
#   cwd      - the pane's live foreground cwd is still the task's recorded
#              worktree.
#
# The grant set is never inferred per harness. It is intersected with the
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
# A grant that rides an ENV PREFIX rather than a flag counts on the same axis,
# because a restart that rebuilds the launch command drops an env prefix exactly
# as it drops a flag. It is read where it can be read and reported `unknown`
# where it cannot; it is never assumed satisfied.
#
# It FAILS CLOSED toward unknown and never toward fit: every unreadable target,
# unsupported backend, missing record, or unattributable process is `unknown`,
# because a false `fit` is exactly the silent failure this script exists to end.
# `n/a` is not a failure - it means the recorded launch command carried no grant
# of either kind (pi), so there is nothing whose loss could be detected.
#
# Read-only and side-effect free. Exit status: 0 fit, 1 unfit, 3 unknown,
# 2 usage error. The exit status lets a caller branch without parsing the line.
set -u

usage() {
  cat <<'EOF'
usage: fm-crew-fitness.sh <task-id>
       fm-crew-fitness.sh --all

Reports whether a recorded task's pane is still able to work: its harness still
carries the autonomy grants its recorded launch command specified, as flags and
as env prefixes, and it is still in the task's recorded worktree.

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
# task's own recorded launch command. A harness that needs no grant at all (pi)
# simply matches nothing here.
AUTONOMY_FLAGS='--dangerously-skip-permissions
--dangerously-bypass-approvals-and-sandbox
--always-approve
--auto'

# Env-prefix names in a recorded launch command that carry a grant the worker
# cannot work without. These do not appear in argv at all, so they are read
# through fm_backend_pane_env_has, which answers from the running process's own
# environment where the backend can reach it (tmux) and `undeterminable` where
# it cannot (herdr's process-info exposes no environment; a host without /proc).
# An undeterminable grant is `unknown`, never satisfied.
#
# Membership is deliberately narrow - only prefixes whose loss leaves the worker
# unable to do its job. opencode's OPENCODE_CONFIG_CONTENT IS its permission
# grant, and FM_HOME is what makes a secondmate address its own home rather than
# its parent's. Prefixes that merely tune a working agent (claude's
# CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION, pi's FM_PI_HARNESS) are not listed,
# because a task is not unfit for having lost one.
AUTONOMY_ENV_GRANTS='OPENCODE_CONFIG_CONTENT
FM_HOME'

# real_path: physical path, or the input unchanged when it cannot be resolved.
# Worktree comparison must be physical: a symlinked project or worktree prefix
# would otherwise read as a mismatch and manufacture a false `wrong`.
real_path() {  # <path>
  [ -n "$1" ] || return 0
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"
}

# launch_words: the recorded launch command split on whitespace, with NO
# pathname expansion. `read -ra` rather than an unquoted `for word in $launch`,
# because a launch command legitimately contains glob characters - opencode's
# grant is literally OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' -
# and letting the shell expand one against the cwd would silently rewrite the
# very evidence being examined.
launch_words() {  # <launch-command>
  local -a words=()
  read -ra words <<<"$1"
  [ "${#words[@]}" -eq 0 ] || printf '%s\n' "${words[@]}"
}

# launch_autonomy_flags: the recognized autonomy flags present as whitespace-
# delimited words in <launch>. Word matching (not substring) keeps a longer flag
# from being reported because a shorter one is its prefix.
launch_autonomy_flags() {  # <launch-command>
  local flag word
  local -a words=()
  while IFS= read -r word; do words+=("$word"); done < <(launch_words "$1")
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    for word in ${words[@]+"${words[@]}"}; do
      if [ "$word" = "$flag" ]; then
        printf '%s\n' "$flag"
        break
      fi
    done
  done <<EOF
$AUTONOMY_FLAGS
EOF
}

# launch_env_grants: the recognized env-prefix grant words of <launch>, whole,
# as they were recorded. Only the LEADING assignment words are considered,
# because only those are env prefixes of the command itself; a `NAME=value`
# appearing later is an argument to the harness, not part of its environment.
launch_env_grants() {  # <launch-command>
  local word name grant
  local -a words=()
  while IFS= read -r word; do words+=("$word"); done < <(launch_words "$1")
  for word in ${words[@]+"${words[@]}"}; do
    case "$word" in
      [A-Za-z_]*=*) name=${word%%=*} ;;
      *) break ;;
    esac
    while IFS= read -r grant; do
      [ -n "$grant" ] || continue
      [ "$name" = "$grant" ] && printf '%s\n' "$word"
    done <<EOF
$AUTONOMY_ENV_GRANTS
EOF
  done
}

# shell_unquote: the inverse of fm-spawn.sh's shell_quote, for the two forms a
# recorded launch word's value can take - a fully single-quoted string, where an
# embedded quote appears as the '\'' sequence, or a bare word carrying no shell
# metacharacter at all. Prints the literal value the pane's shell would have
# exported. Returns 1 for anything else, including a value that was split across
# words because it contained a space, because a value this cannot decode with
# certainty must be reported unknown rather than compared and found "missing".
shell_unquote() {  # <word>
  local v=$1 tmp
  case "$v" in
    \'*\')
      [ "${#v}" -ge 2 ] || return 1
      v=${v#\'}
      v=${v%\'}
      tmp=${v//\'\\\'\'/$'\x01'}
      case "$tmp" in *\'*) return 1 ;; esac
      printf '%s' "${tmp//$'\x01'/\'}"
      ;;
    *[\'\"\\\$\`]*) return 1 ;;
    *) printf '%s' "$v" ;;
  esac
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
    local -a want=() env_grants=()
    local grant name value
    while IFS= read -r flag; do
      [ -n "$flag" ] || continue
      want+=("$flag")
    done < <(launch_autonomy_flags "$launch")
    while IFS= read -r grant; do
      [ -n "$grant" ] || continue
      env_grants+=("$grant")
    done < <(launch_env_grants "$launch")
    if [ "${#want[@]}" -eq 0 ] && [ "${#env_grants[@]}" -eq 0 ]; then
      # The recorded launch carries no grant whose loss could be detected.
      autonomy=n/a
    else
      autonomy=ok
      for flag in "${want[@]+"${want[@]}"}"; do
        fm_backend_pane_argv_has "$backend" "$target" "$flag"
        rc=$?
        case "$rc" in
          0) ;;
          1) lost+=("$flag"); autonomy=lost ;;
          # An undeterminable read cannot clear an ALREADY-PROVEN loss: one
          # confidently absent grant is enough to condemn the pane.
          *) [ "$autonomy" = lost ] || autonomy=unknown; break ;;
        esac
      done
      # Env-prefix grants are read from the live process's own environment. Only
      # a grant actually READ as present counts as satisfied: an undeterminable
      # read is unknown, never assumed in force, because assuming it is the
      # false `fit` this whole script exists to prevent.
      for grant in "${env_grants[@]+"${env_grants[@]}"}"; do
        name=${grant%%=*}
        if ! value=$(shell_unquote "${grant#*=}"); then
          [ "$autonomy" = lost ] || autonomy=unknown
          [ -n "$detail" ] || detail="could not decode the recorded env-prefix grant $name= to compare it against the running process"
          continue
        fi
        fm_backend_pane_env_has "$backend" "$target" "$name=$value"
        rc=$?
        case "$rc" in
          0) ;;
          1) lost+=("$name="); autonomy=lost ;;
          *)
            [ "$autonomy" = lost ] || autonomy=unknown
            [ -n "$detail" ] || detail="could not read the running process's environment on backend=$backend, so the env-prefix grant $name= is unproven; verify it by hand or relaunch"
            ;;
        esac
      done
    fi
  fi

  # --- worktree axis --------------------------------------------------------
  # PASSIVE read only. This runs against a pane that is expected to be running
  # an agent, so the cwd must come from data the backend already holds. The
  # general fm_backend_current_path is not usable here: on zellij and cmux it
  # types a marked `pwd` into the pane, which in a live agent's composer would
  # submit a bogus prompt - and this script promises to be side-effect free.
  # Those backends therefore report cwd=unknown, never a guess.
  if [ -z "$worktree" ]; then
    cwd=unknown
  else
    live=$(fm_backend_current_path_passive "$backend" "$target" 2>/dev/null || true)
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
    [ "$autonomy" != lost ] || detail="autonomy grant no longer in force: ${lost[*]:-}"
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

#!/usr/bin/env bash
# Remove stale Firstmate crewmate lifecycle hooks from the primary Claude local
# settings without disturbing the primary's own Stop guards or unrelated hooks.
#
# A task's Claude wiring belongs in its isolated worktree.  If a historical
# launch wrote that wiring into the primary home's .claude/settings.local.json,
# the task IDs embedded in its fm-busy-event and *.turn-ended commands let this
# cleanup remove only entries whose state/<id>.meta is gone.
#
# Usage: fm-claude-task-hook-cleanup.sh cleanup
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SETTINGS="$FM_HOME/.claude/settings.local.json"

usage() {
  cat <<'EOF'
Usage: fm-claude-task-hook-cleanup.sh cleanup

Remove stale Firstmate crewmate lifecycle hooks from this home's Claude local settings.
EOF
}

[ "${1:-}" = cleanup ] && [ "$#" -eq 1 ] || { usage >&2; exit 2; }
[ -e "$SETTINGS" ] || exit 0
[ -f "$SETTINGS" ] && [ ! -L "$SETTINGS" ] || {
  echo "error: refusing to inspect unsafe Claude local settings path: $SETTINGS" >&2
  exit 1
}
[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  echo "error: refusing to inspect unsafe state directory: $STATE" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required to clean Claude local settings" >&2
  exit 1
}

STATE_REAL=$(cd "$STATE" && pwd -P)
ACTIVE_IDS=$(for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  basename "${meta%.meta}"
done | jq -Rsc 'split("\n") | map(select(length > 0))')
TMP=$(mktemp "$(dirname "$SETTINGS")/.settings.local.json.fm-cleanup.XXXXXX") || exit 1
cleanup() {
  rm -f "$TMP"
}
trap cleanup EXIT HUP INT TERM

jq --arg state "$STATE_REAL" --argjson active "$ACTIVE_IDS" '
  def match_task_id($pattern):
    ([match($pattern)? | .captures[] | select(.name == "id").string] | first // "");
  def task_id:
    match_task_id("fm-busy-event\\.sh[^\\n]* apply '\''[^'\'']*'\'' '\''(?<id>[A-Za-z0-9][A-Za-z0-9_.-]*)'\''") as $busy_id |
    if $busy_id != "" then $busy_id
    else match_task_id("(?<id>[A-Za-z0-9][A-Za-z0-9_.-]*)\\.turn-ended")
    end;
  def stale_firstmate_task_hook:
    . as $hook |
    if ($hook.command? | type) != "string" then false
    else
      ($hook.command | task_id) as $id |
      $id != "" and
      ($active | index($id) == null) and
      (($hook.command | contains("fm-busy-event.sh")) or
       ($hook.command | contains($state + "/" + $id + ".turn-ended")))
    end;
  .hooks |= with_entries(
    .value |= (
      map(
        if (.hooks? | type) == "array" then
          .hooks |= map(select(stale_firstmate_task_hook | not)) |
          select(.hooks | length > 0)
        else . end
      ) | map(select(. != null))
    )
  )
' "$SETTINGS" > "$TMP" || {
  echo "error: Claude local settings are not valid hook JSON: $SETTINGS" >&2
  exit 1
}

if cmp -s "$SETTINGS" "$TMP"; then
  exit 0
fi
chmod --reference="$SETTINGS" "$TMP" 2>/dev/null || chmod 600 "$TMP"
mv -f "$TMP" "$SETTINGS"
trap - EXIT HUP INT TERM
printf 'removed stale Firstmate Claude task hooks from %s\n' "$SETTINGS"

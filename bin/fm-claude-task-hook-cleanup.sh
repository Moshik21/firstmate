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
# Legacy hooks embedded the logical "$FM_ROOT/state/<id>.turn-ended"; the
# current wiring embeds the resolved path. Accept either spelling so a home
# reached through a symlinked path component still matches.
STATE_PATHS=$(printf '%s\n' "$STATE_REAL" "$STATE" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')
ACTIVE_IDS=$(for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  basename "${meta%.meta}"
done | jq -Rsc 'split("\n") | map(select(length > 0))')
TMP=$(mktemp "$(dirname "$SETTINGS")/.settings.local.json.fm-cleanup.XXXXXX") || exit 1
cleanup() {
  rm -f "$TMP"
}
trap cleanup EXIT HUP INT TERM

jq --argjson states "$STATE_PATHS" --argjson active "$ACTIVE_IDS" '
  def match_task_id($pattern):
    ([match($pattern)? | .captures[] | select(.name == "id").string] | first // "");
  def task_id:
    match_task_id("fm-busy-event\\.sh[^\\n]* apply '\''[^'\'']*'\'' '\''(?<id>[A-Za-z0-9][A-Za-z0-9_.-]*)'\''") as $busy_id |
    if $busy_id != "" then $busy_id
    else match_task_id("(?<id>[A-Za-z0-9][A-Za-z0-9_.-]*)\\.turn-ended")
    end;
  def stale_firstmate_task_hook:
    if type != "object" then false
    elif (.command | type) != "string" then false
    else
      .command as $cmd |
      ($cmd | task_id) as $id |
      $id != "" and
      ($active | index($id) == null) and
      (($cmd | contains("fm-busy-event.sh")) or
       ($states | any(. as $s | $cmd | contains($s + "/" + $id + ".turn-ended"))))
    end;
  def sweep_matcher:
    if type == "object" and ((.hooks? | type) == "array") then
      (.hooks | map(select(stale_firstmate_task_hook | not))) as $kept |
      if ($kept | length) == 0 and ((.hooks | length) > 0) then empty
      else .hooks = $kept
      end
    else . end;
  . as $orig |
  (if type == "object" and ((.hooks | type) == "object") then
     .hooks |= with_entries(
       .value |= (if type == "array" then map(sweep_matcher) else . end)
     )
   else . end) as $swept |
  if $swept == $orig then empty else $swept end
' "$SETTINGS" > "$TMP" || {
  echo "error: Claude local settings are not valid hook JSON: $SETTINGS" >&2
  exit 1
}

if [ ! -s "$TMP" ]; then
  exit 0
fi
chmod --reference="$SETTINGS" "$TMP" 2>/dev/null || chmod 600 "$TMP"
mv -f "$TMP" "$SETTINGS"
trap - EXIT HUP INT TERM
printf 'removed stale Firstmate Claude task hooks from %s\n' "$SETTINGS"

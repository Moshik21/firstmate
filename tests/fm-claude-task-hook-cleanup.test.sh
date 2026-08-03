#!/usr/bin/env bash
# Behavior tests for stale Firstmate crewmate hooks in primary Claude settings.
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLEANUP="$ROOT/bin/fm-claude-task-hook-cleanup.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-task-hook-cleanup)

make_home() {
  local home=$1
  mkdir -p "$home/.claude" "$home/state"
  printf '%s\n' "$home"
}

run_cleanup() {
  local home=$1
  FM_HOME="$home" "$CLEANUP" cleanup
}

firstmate_hook_json() {
  local state=$1 id=$2
  jq -cn --arg state "$state" --arg id "$id" '{
    hooks: {
      UserPromptSubmit: [{hooks: [{type: "command", command: ("'\''/opt/fm-busy-event.sh'\'' apply '\''" + $state + "'\'' '\''" + $id + "'\'' busy --source claude-hook")}]}],
      Stop: [{hooks: [{type: "command", command: ("touch '\''" + $state + "/" + $id + ".turn-ended'\''; '\''/opt/fm-busy-event.sh'\'' apply '\''" + $state + "'\'' '\''" + $id + "'\'' idle --source claude-hook")}]}]
    }
  }'
}

test_removes_only_nonexistent_task_hooks() {
  local home settings
  home=$(make_home "$TMP_ROOT/stale")
  settings="$home/.claude/settings.local.json"
  : > "$home/state/live-task.meta"
  jq -n \
    --argjson stale "$(firstmate_hook_json "$home/state" deleted-task)" \
    --argjson live "$(firstmate_hook_json "$home/state" live-task)" \
    '{hooks: {
      UserPromptSubmit: [$stale.hooks.UserPromptSubmit[0], $live.hooks.UserPromptSubmit[0]],
      Stop: [$stale.hooks.Stop[0], $live.hooks.Stop[0], {hooks: [{type: "command", command: "bash bin/fm-claude-stop-autoarm.sh"}]}],
      PreToolUse: [{hooks: [{type: "command", command: "bash bin/fm-arm-pretool-check.sh"}]}]
    }}' > "$settings"

  run_cleanup "$home" >/dev/null

  jq -e '(.hooks.UserPromptSubmit | length == 1) and (.hooks.UserPromptSubmit[0].hooks[0].command | contains("live-task"))' "$settings" >/dev/null \
    || fail "cleanup removed or retained the wrong UserPromptSubmit hook"
  jq -e '(.hooks.Stop | length == 2) and any(.hooks.Stop[]; .hooks[0].command | contains("fm-claude-stop-autoarm.sh")) and any(.hooks.Stop[]; .hooks[0].command | contains("live-task"))' "$settings" >/dev/null \
    || fail "cleanup must retain live task and primary Stop guard hooks"
  jq -e '.hooks.PreToolUse[0].hooks[0].command == "bash bin/fm-arm-pretool-check.sh"' "$settings" >/dev/null \
    || fail "cleanup must retain unrelated primary hooks"
  pass "fm-claude-task-hook-cleanup: removes only hooks for deleted tasks"
}

test_removes_legacy_turnended_only_hook() {
  local home settings
  home=$(make_home "$TMP_ROOT/legacy")
  settings="$home/.claude/settings.local.json"
  jq -cn --arg state "$home/state" '{hooks: {Stop: [{hooks: [{type: "command", command: ("touch '\''" + $state + "/gone.turn-ended'\''")}]}]}}' > "$settings"

  run_cleanup "$home" >/dev/null

  jq -e '.hooks.Stop == []' "$settings" >/dev/null \
    || fail "cleanup must remove legacy stale turn-ended-only hook"
  pass "fm-claude-task-hook-cleanup: removes legacy stale turn-ended-only hook"
}

test_refuses_malformed_settings_without_rewriting() {
  local home settings before status
  home=$(make_home "$TMP_ROOT/malformed")
  settings="$home/.claude/settings.local.json"
  printf '{not json\n' > "$settings"
  before=$(cksum "$settings")
  set +e
  run_cleanup "$home" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "cleanup must refuse malformed settings"
  [ "$(cksum "$settings")" = "$before" ] || fail "cleanup rewrote malformed settings"
  pass "fm-claude-task-hook-cleanup: refuses malformed settings without rewriting"
}

test_accepts_settings_without_hooks_key() {
  local home settings before status
  home=$(make_home "$TMP_ROOT/hookless")
  settings="$home/.claude/settings.local.json"
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}' > "$settings"
  before=$(cksum "$settings")
  set +e
  run_cleanup "$home" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "cleanup must accept settings without a hooks key"
  [ "$(cksum "$settings")" = "$before" ] || fail "cleanup rewrote hook-free settings"
  pass "fm-claude-task-hook-cleanup: accepts settings without a hooks key"
}

test_leaves_settings_byte_identical_when_nothing_is_stale() {
  local home settings before
  home=$(make_home "$TMP_ROOT/nostale")
  settings="$home/.claude/settings.local.json"
  : > "$home/state/live-task.meta"
  firstmate_hook_json "$home/state" live-task > "$settings"
  before=$(cksum "$settings")

  run_cleanup "$home" >/dev/null

  [ "$(cksum "$settings")" = "$before" ] \
    || fail "cleanup rewrote settings that hold no stale hooks"
  pass "fm-claude-task-hook-cleanup: leaves settings untouched when nothing is stale"
}

test_retains_unrecognized_hook_entries() {
  local home settings
  home=$(make_home "$TMP_ROOT/unrecognized")
  settings="$home/.claude/settings.local.json"
  jq -cn --arg state "$home/state" '{hooks: {
    Stop: [{hooks: ["weird", {type: "command"}, {type: "command", command: ("touch '\''" + $state + "/gone.turn-ended'\''")}]}],
    SessionStart: "not-an-array"
  }}' > "$settings"

  run_cleanup "$home" >/dev/null

  jq -e '(.hooks.Stop[0].hooks | length == 2) and (.hooks.Stop[0].hooks[0] == "weird") and (.hooks.Stop[0].hooks[1] == {type: "command"})' "$settings" >/dev/null \
    || fail "cleanup must retain hook entries it does not recognize"
  jq -e '.hooks.SessionStart == "not-an-array"' "$settings" >/dev/null \
    || fail "cleanup must retain non-array hook event values"
  pass "fm-claude-task-hook-cleanup: retains unrecognized hook entries"
}

test_removes_legacy_turnended_hook_through_symlinked_home() {
  local real link settings
  real="$TMP_ROOT/legacy-real"
  link="$TMP_ROOT/legacy-link"
  make_home "$real" >/dev/null
  ln -s "$real" "$link"
  settings="$real/.claude/settings.local.json"
  jq -cn --arg state "$link/state" '{hooks: {Stop: [{hooks: [{type: "command", command: ("touch '\''" + $state + "/gone.turn-ended'\''")}]}]}}' > "$settings"

  run_cleanup "$link" >/dev/null

  jq -e '.hooks.Stop == []' "$settings" >/dev/null \
    || fail "cleanup must remove a legacy stale hook recorded through the logical home path"
  pass "fm-claude-task-hook-cleanup: removes legacy stale hook via logical home path"
}

test_removes_only_nonexistent_task_hooks
test_removes_legacy_turnended_only_hook
test_refuses_malformed_settings_without_rewriting
test_accepts_settings_without_hooks_key
test_leaves_settings_byte_identical_when_nothing_is_stale
test_retains_unrecognized_hook_entries
test_removes_legacy_turnended_hook_through_symlinked_home

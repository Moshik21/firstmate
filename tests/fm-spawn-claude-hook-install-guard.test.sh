#!/usr/bin/env bash
# Tests for fm-spawn.sh's validate_claude_task_hook_install_location.
#
# A Claude task launch writes lifecycle wiring into "<worktree>/.claude/
# settings.local.json". That file is disposable in an isolated task worktree,
# but the same path in a firstmate home holds the primary's own Claude guards -
# and $WT is settled from the pane's reported path, which can transiently name a
# different real checkout (see tests/fm-spawn-worktree-settle.test.sh). So the
# spawn refuses, before the busy contract is armed, whenever the hook target is
# a firstmate home or a redirected/unsafe settings path.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-hook-install-guard)

# A fake tmux whose pane reports FM_FAKE_PANE_PATH as its cwd, so the spawn
# settles $WT onto whatever path a case wants to hand the guard.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Build a claude-harness spawn sandbox. Sets HOME_DIR/PROJ_DIR/WT_DIR/FAKEBIN.
# The home is a real checkout with its own state/ so it reads as a genuine
# firstmate home to the primary-scope probe.
make_case() {
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  FAKEBIN=$(make_fakebin "$case_dir/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  fm_git_init_commit "$HOME_DIR" >/dev/null 2>&1
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name" >/dev/null 2>&1
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
}

# Run the spawn with the pane settled on <pane_path>. Echoes combined output.
run_spawn() {  # <id> <pane_path>
  local id=$1 pane=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$pane" \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode local-only --yolo off 2>&1
}

# A refused install must leave no armed busy record behind: the refusal happens
# before the arm, so nothing can be left running that no teardown could reach.
assert_no_busy_record() {  # <id> <label>
  local id=$1 label=$2
  [ -z "$(find "$HOME_DIR/state" -maxdepth 1 -name "$id*" -print -quit)" ] \
    || fail "$label: refused spawn left state records for $id"
}

test_refuses_install_into_the_primary_home() {
  local id=guard-primary-home-a1 out status
  make_case guard-primary-home "$id"

  set +e
  out=$(run_spawn "$id" "$HOME_DIR")
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "primary-home: spawn should refuse to write hooks into the primary home"
  assert_contains "$out" "refusing to install Claude task hooks in the primary home" \
    "primary-home: refusal did not name the primary home"
  [ ! -e "$HOME_DIR/.claude/settings.local.json" ] \
    || fail "primary-home: spawn wrote task hooks into the primary home settings"
  assert_no_busy_record "$id" primary-home
  pass "fm-spawn: refuses to install Claude task hooks into the primary home"
}

test_refuses_install_into_another_firstmate_home() {
  local id=guard-other-home-b2 other out status
  make_case guard-other-home "$id"
  # A second, genuine firstmate home checkout: not this process's own home, so
  # only the primary-scope probe can tell it apart from a task worktree.
  other="$TMP_ROOT/guard-other-home/other-home"
  fm_git_init_commit "$other" >/dev/null 2>&1
  mkdir -p "$other/state" "$other/bin" "$other/.claude"
  printf '# agents\n' > "$other/AGENTS.md"
  printf 'guard\n' > "$other/.claude/settings.local.json"

  set +e
  out=$(run_spawn "$id" "$other")
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "other-home: spawn should refuse a foreign firstmate home"
  assert_contains "$out" "refusing to install Claude task hooks in the firstmate home" \
    "other-home: refusal did not name the foreign firstmate home"
  [ "$(cat "$other/.claude/settings.local.json")" = guard ] \
    || fail "other-home: spawn overwrote the foreign home's own Claude settings"
  assert_no_busy_record "$id" other-home
  pass "fm-spawn: refuses to install Claude task hooks into another firstmate home"
}

test_refuses_redirected_hook_directory() {
  local id=guard-redirected-dir-c3 elsewhere out status
  make_case guard-redirected-dir "$id"
  elsewhere="$TMP_ROOT/guard-redirected-dir/elsewhere"
  mkdir -p "$elsewhere"
  ln -s "$elsewhere" "$WT_DIR/.claude"

  set +e
  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "redirected-dir: spawn should refuse a symlinked .claude directory"
  assert_contains "$out" "refusing redirected Claude task hook directory" \
    "redirected-dir: refusal did not name the redirected hook directory"
  [ ! -e "$elsewhere/settings.local.json" ] \
    || fail "redirected-dir: spawn wrote hooks through the redirected directory"
  assert_no_busy_record "$id" redirected-dir
  pass "fm-spawn: refuses a redirected .claude hook directory"
}

test_refuses_symlinked_settings_file() {
  local id=guard-redirected-file-d4 target out status
  make_case guard-redirected-file "$id"
  target="$TMP_ROOT/guard-redirected-file/target-settings.json"
  printf 'guard\n' > "$target"
  mkdir -p "$WT_DIR/.claude"
  ln -s "$target" "$WT_DIR/.claude/settings.local.json"

  set +e
  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "redirected-file: spawn should refuse a symlinked settings file"
  assert_contains "$out" "refusing unsafe Claude task hook settings path" \
    "redirected-file: refusal did not name the unsafe settings path"
  [ "$(cat "$target")" = guard ] \
    || fail "redirected-file: spawn wrote hooks through the symlinked settings path"
  assert_no_busy_record "$id" redirected-file
  pass "fm-spawn: refuses a symlinked Claude settings path"
}

test_refuses_install_into_the_primary_home
test_refuses_install_into_another_firstmate_home
test_refuses_redirected_hook_directory
test_refuses_symlinked_settings_file

echo "# all fm-spawn-claude-hook-install-guard tests passed"

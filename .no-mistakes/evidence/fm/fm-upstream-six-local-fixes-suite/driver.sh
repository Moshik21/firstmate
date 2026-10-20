#!/usr/bin/env bash
# Disposable live driver: real bin/fm-pr-merge.sh against fake gh forge (the suite's own fixtures).
set -u
. "$(dirname "$0")/driver-lib.sh"
set +e
URL=https://github.com/example/repo/pull/9
HEADSHA=deadbeefcafefeed0000000000000000deadbeef
n=0
# scenario name | setup-fn | extra-args | expected: merge|refuse
scen() { # name expect [args...]  (setup via SETUP function var)
  local name=$1 expect=$2; shift 2
  local cd rc merged
  cd=$(make_case "$name"); mkdir -p "$cd/wt"
  add_gh_mocks "$cd" $HEADSHA; : > "$cd/gh-axi.log"
  $SETUP "$cd"
  run_pr_merge "$cd" task-x1 $URL "$@" > "$cd/stdout" 2> "$cd/stderr"; rc=$?
  merged=no; grep -q ' merge ' "$cd/gh-axi.log" "$cd/gh.log" 2>/dev/null && merged=yes
  local got=refuse; [ "$rc" = 0 ] && got=merge
  local verdict=PASS; [ "$got" = "$expect" ] || verdict=FAIL
  echo "[$verdict] $name: rc=$rc forge_merge_called=$merged expected=$expect"
  echo "    refusal: $(cat "$cd/stderr" "$cd/stdout" | grep -v -E "WATCHER|●|beacon|supervision|shell &" | tr '
' ' ' | cut -c1-420)"
}
rec() { printf '%s\n' "$@" > "$1_"; }
S_none() { :; }
S_behind() { printf '%s\n' 'behind_by=3' "base_sha=$SUITE_BASE" > "$1/github-compare"; }
S_stale() { printf '%s\n' 'suite=pass' "base=ffffffffffffffffffffffffffffffffffffffff" 'ran=x' > "$1/home/data/task-x1/suite-result"; }
S_fail() { printf '%s\n' 'suite=fail' "base=$SUITE_BASE" 'ran=x' > "$1/home/data/task-x1/suite-result"; }
S_none_noreason() { printf '%s\n' 'suite=none' "base=$SUITE_BASE" > "$1/home/data/task-x1/suite-result"; }
S_none_reason() { printf '%s\n' 'suite=none' "base=$SUITE_BASE" 'reason=docs-only repo, no suite' > "$1/home/data/task-x1/suite-result"; }
S_missing() { rm -f "$1/home/data/task-x1/suite-result"; }
S_symlink() { rm -f "$1/home/data/task-x1/suite-result"; printf '%s\n' 'suite=pass' "base=$SUITE_BASE" 'ran=x' > "$1/real-record"; ln -s "$1/real-record" "$1/home/data/task-x1/suite-result"; }
S_garbage() { printf 'not a record\n\x00\x01 junk\n' > "$1/home/data/task-x1/suite-result"; }
S_cmpfail() { : > "$1/github-compare-fail"; }
S_away() { S_missing "$1"; write_away_record "$1"; }
S_required() { write_github_required "$1" classic:ci; S_missing "$1"; }
for spec in \
 "S_none merge happy-pass-record-not-behind" \
 "S_behind refuse head-behind-base" \
 "S_stale refuse stale-recorded-base" \
 "S_fail refuse suite-fail" \
 "S_none_noreason refuse suite-none-no-reason" \
 "S_none_reason merge suite-none-with-reason" \
 "S_missing refuse missing-record" \
 "S_symlink refuse symlinked-record" \
 "S_garbage refuse unparsable-record" \
 "S_cmpfail refuse compare-unreadable" ; do
  set -- $spec; SETUP=$1; scen "$3" "$2"
done
SETUP=S_missing; scen override-waives-missing-record merge --attended-override
SETUP=S_behind; scen override-waives-behind merge --attended-override
SETUP=S_away; scen away-override-does-not-waive refuse --attended-override
SETUP=S_required; scen required-checks-present-guard-not-applied merge

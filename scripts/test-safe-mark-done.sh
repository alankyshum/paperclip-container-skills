#!/usr/bin/env bash
# test-safe-mark-done.sh — Unit tests for the Gate 2 (CI-green) jq logic in
# safe-mark-done.sh.  Focuses on the BLD-1826 dedup fix: latest-per-check-name
# wins when a check has multiple historical runs in statusCheckRollup.
#
# No GitHub credentials or network access required.  Runs standalone via bash.
#
# Usage:
#   bash /skills/scripts/test-safe-mark-done.sh
#
# Exit codes:
#   0  all tests passed
#   1  one or more tests failed
set -euo pipefail

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# The jq program extracted from safe-mark-done.sh Gate 2 (keep in sync with
# the production script).  eval_ci_rollup() pipes a JSON blob through it and
# returns the list of "bad checks" (empty = all green).
# ---------------------------------------------------------------------------
JQ_PROGRAM='
  [
    .statusCheckRollup[]?
    | if .__typename == "CheckRun" then
        { key: .name,
          ts:  (.completedAt // .startedAt // ""),
          obj: . }
      elif .__typename == "StatusContext" then
        { key: .context,
          ts:  (.createdAt // ""),
          obj: . }
      else
        { key: ("__unknown__" + (.__typename // "")),
          ts:  "",
          obj: . }
      end
  ]
  | group_by(.key)
  | map(max_by(.ts) | .obj)
  | [ .[]
      | if .__typename == "CheckRun" then
          ( if (.status != "COMPLETED") then
                "\(.name): status=\(.status)"
            elif (.conclusion // "" | ascii_upcase) as $c
              | ($c == "FAILURE" or $c == "CANCELLED" or $c == "TIMED_OUT"
                 or $c == "ACTION_REQUIRED" or $c == "STARTUP_FAILURE" or $c == "STALE") then
              "\(.name): conclusion=\(.conclusion)"
            else empty end )
        elif .__typename == "StatusContext" then
          ( (.state // "" | ascii_upcase) as $s
            | if ($s == "FAILURE" or $s == "ERROR" or $s == "PENDING" or $s == "EXPECTED") then
                "\(.context): state=\(.state)"
              else empty end )
        else empty end
    ]
  | .[]
'

eval_ci_rollup() {
  # Usage: eval_ci_rollup <json_string>
  # Returns (stdout) the list of bad-check lines, empty if all green.
  printf '%s' "$1" | jq -r "$JQ_PROGRAM" 2>&1
}

# ---------------------------------------------------------------------------
# Test runner helpers
# ---------------------------------------------------------------------------
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

assert_green() {
  local label="$1" json="$2"
  local result
  result="$(eval_ci_rollup "$json")"
  if [[ -z "$result" ]]; then
    pass "$label"
  else
    fail "$label — expected green, got: $result"
  fi
}

assert_bad_check() {
  local label="$1" json="$2" expected_pattern="$3"
  local result
  result="$(eval_ci_rollup "$json")"
  if echo "$result" | grep -qF "$expected_pattern"; then
    pass "$label"
  else
    fail "$label — expected pattern '$expected_pattern' not found in: '$result'"
  fi
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------
echo "--- safe-mark-done.sh Gate 2 dedup tests ---"

# --- T1: BLD-1826 reproduction case ---
# PR #630: check ran FAILURE at 10:39, then re-ran SUCCESS at 11:05.
# Before the fix this would emit "Require...FAILURE" and block the gate.
# After the fix, only the SUCCESS (latest) run should be considered.
T1_JSON='{
  "statusCheckRollup": [
    {
      "__typename": "CheckRun",
      "name": "Require `## Unreleased` bullet for user-facing PRs",
      "status": "COMPLETED",
      "conclusion": "FAILURE",
      "startedAt":   "2026-06-22T10:39:44Z",
      "completedAt": "2026-06-22T10:39:55Z"
    },
    {
      "__typename": "CheckRun",
      "name": "Require `## Unreleased` bullet for user-facing PRs",
      "status": "COMPLETED",
      "conclusion": "SUCCESS",
      "startedAt":   "2026-06-22T11:05:58Z",
      "completedAt": "2026-06-22T11:06:10Z"
    },
    {
      "__typename": "CheckRun",
      "name": "build",
      "status": "COMPLETED",
      "conclusion": "SUCCESS",
      "startedAt":   "2026-06-22T11:00:00Z",
      "completedAt": "2026-06-22T11:05:00Z"
    },
    {
      "__typename": "CheckRun",
      "name": "typecheck",
      "status": "COMPLETED",
      "conclusion": "SUCCESS",
      "startedAt":   "2026-06-22T11:00:00Z",
      "completedAt": "2026-06-22T11:03:00Z"
    }
  ]
}'
assert_green "T1 [BLD-1826 reproduction] fail-then-green reruns → treated as green" "$T1_JSON"

# --- T2: regression — latest run is still FAILURE → still blocked ---
T2_JSON='{
  "statusCheckRollup": [
    {
      "__typename": "CheckRun",
      "name": "build",
      "status": "COMPLETED",
      "conclusion": "SUCCESS",
      "startedAt":   "2026-06-22T10:00:00Z",
      "completedAt": "2026-06-22T10:05:00Z"
    },
    {
      "__typename": "CheckRun",
      "name": "tests",
      "status": "COMPLETED",
      "conclusion": "FAILURE",
      "startedAt":   "2026-06-22T10:00:00Z",
      "completedAt": "2026-06-22T10:06:00Z"
    }
  ]
}'
assert_bad_check "T2 [regression] single FAILURE run → still blocked" "$T2_JSON" "tests: conclusion=FAILURE"

# --- T3: mixed — two checks, one stale FAILURE / green latest, one real FAILURE ---
T3_JSON='{
  "statusCheckRollup": [
    {
      "__typename": "CheckRun",
      "name": "changelog",
      "status": "COMPLETED",
      "conclusion": "FAILURE",
      "startedAt":   "2026-06-22T10:00:00Z",
      "completedAt": "2026-06-22T10:01:00Z"
    },
    {
      "__typename": "CheckRun",
      "name": "changelog",
      "status": "COMPLETED",
      "conclusion": "SUCCESS",
      "startedAt":   "2026-06-22T10:05:00Z",
      "completedAt": "2026-06-22T10:06:00Z"
    },
    {
      "__typename": "CheckRun",
      "name": "integration-tests",
      "status": "COMPLETED",
      "conclusion": "FAILURE",
      "startedAt":   "2026-06-22T10:00:00Z",
      "completedAt": "2026-06-22T10:10:00Z"
    }
  ]
}'
assert_bad_check "T3 [mixed] stale FAILURE ignored, real FAILURE still caught" "$T3_JSON" "integration-tests: conclusion=FAILURE"

# --- T4: all checks passing, no duplicates — stays green ---
T4_JSON='{
  "statusCheckRollup": [
    {
      "__typename": "CheckRun",
      "name": "build",
      "status": "COMPLETED",
      "conclusion": "SUCCESS",
      "startedAt":   "2026-06-22T10:00:00Z",
      "completedAt": "2026-06-22T10:05:00Z"
    },
    {
      "__typename": "CheckRun",
      "name": "lint",
      "status": "COMPLETED",
      "conclusion": "SUCCESS",
      "startedAt":   "2026-06-22T10:00:00Z",
      "completedAt": "2026-06-22T10:04:00Z"
    }
  ]
}'
assert_green "T4 [happy path] all checks green, no duplicates" "$T4_JSON"

# --- T5: StatusContext (legacy commit status API) — FAILURE is still caught ---
T5_JSON='{
  "statusCheckRollup": [
    {
      "__typename": "StatusContext",
      "context": "ci/circleci: build",
      "state": "SUCCESS",
      "createdAt": "2026-06-22T10:00:00Z"
    },
    {
      "__typename": "StatusContext",
      "context": "ci/circleci: test",
      "state": "FAILURE",
      "createdAt": "2026-06-22T10:05:00Z"
    }
  ]
}'
assert_bad_check "T5 [StatusContext] FAILURE state → blocked" "$T5_JSON" "ci/circleci: test: state=FAILURE"

# --- T6: StatusContext — stale FAILURE then latest SUCCESS → green ---
T6_JSON='{
  "statusCheckRollup": [
    {
      "__typename": "StatusContext",
      "context": "ci/circleci: test",
      "state": "FAILURE",
      "createdAt": "2026-06-22T10:00:00Z"
    },
    {
      "__typename": "StatusContext",
      "context": "ci/circleci: test",
      "state": "SUCCESS",
      "createdAt": "2026-06-22T10:10:00Z"
    }
  ]
}'
assert_green "T6 [StatusContext dedup] stale FAILURE then latest SUCCESS → green" "$T6_JSON"

# --- T7: empty rollup — nothing to fail, gate passes ---
T7_JSON='{"statusCheckRollup": []}'
assert_green "T7 [empty rollup] no checks → green" "$T7_JSON"

# --- T8: CANCELLED conclusion is treated as a failure ---
T8_JSON='{
  "statusCheckRollup": [
    {
      "__typename": "CheckRun",
      "name": "deploy",
      "status": "COMPLETED",
      "conclusion": "CANCELLED",
      "startedAt":   "2026-06-22T10:00:00Z",
      "completedAt": "2026-06-22T10:05:00Z"
    }
  ]
}'
assert_bad_check "T8 [CANCELLED conclusion] → blocked" "$T8_JSON" "deploy: conclusion=CANCELLED"

# --- T9: SKIPPED conclusion is NOT a failure ---
T9_JSON='{
  "statusCheckRollup": [
    {
      "__typename": "CheckRun",
      "name": "e2e-ios",
      "status": "COMPLETED",
      "conclusion": "SKIPPED",
      "startedAt":   "2026-06-22T10:00:00Z",
      "completedAt": "2026-06-22T10:01:00Z"
    }
  ]
}'
assert_green "T9 [SKIPPED conclusion] → green (non-required / intentionally skipped)" "$T9_JSON"

# --- T10: NOT COMPLETED status (in-progress check) → blocked ---
T10_JSON='{
  "statusCheckRollup": [
    {
      "__typename": "CheckRun",
      "name": "slow-tests",
      "status": "IN_PROGRESS",
      "conclusion": null,
      "startedAt":   "2026-06-22T10:00:00Z",
      "completedAt": null
    }
  ]
}'
assert_bad_check "T10 [IN_PROGRESS check] → blocked" "$T10_JSON" "slow-tests: status=IN_PROGRESS"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0

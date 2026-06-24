#!/usr/bin/env bash
# safe-mark-done.sh — HARD RULE #0 enforcement gate for marking issues done.
#
# An issue may only be marked `done` when its linked PR is MERGED and required
# CI on the merge is green. clip.sh refuses a direct `--status done` (it exits
# with a HARD RULE #0 violation) unless CLIP_ALLOW_DONE=1 is set. This script
# is the ONLY sanctioned way to set that env var: it independently verifies the
# merge + CI state via `gh` first, and only then performs the status flip.
#
# Created to close the gap surfaced by BLD-1723/BLD-1725: clip.sh told every
# agent to "Use safe-mark-done.sh" but the script did not exist, leaving merged
# PR-backed QA issues un-closable by their assignees (e.g. quality-director).
#
# Usage:
#   safe-mark-done.sh <ISSUE> <PR_NUMBER> <REPO> [--comment "text"]
#
# Examples:
#   safe-mark-done.sh BLD-1723 621 alankyshum/cablesnap
#   safe-mark-done.sh BLD-1723 621 alankyshum/cablesnap --comment "QA PASS, merged."
#
# Exit codes:
#   0  issue marked done
#   1  usage error / tooling failure
#   2  PR not merged (refuses to mark done)
#   3  PR merged but a required CI check is not green (refuses to mark done)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIP="${SCRIPT_DIR}/clip.sh"

usage() {
  echo "Usage: safe-mark-done.sh <ISSUE> <PR_NUMBER> <REPO> [--comment \"text\"]" >&2
  echo "  <ISSUE>      Paperclip issue identifier (e.g. BLD-1723) or UUID" >&2
  echo "  <PR_NUMBER>  GitHub PR number (e.g. 621)" >&2
  echo "  <REPO>       owner/repo (e.g. alankyshum/cablesnap)" >&2
  echo "  --comment    optional comment posted with the status change" >&2
}

if [[ $# -lt 3 ]]; then
  echo "❌ [safe-mark-done] missing required arguments" >&2
  usage
  exit 1
fi

ISSUE="$1"; shift
PR="$1"; shift
REPO="$1"; shift

COMMENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --comment) COMMENT="${2:-}"; shift 2;;
    *) echo "❌ [safe-mark-done] unknown option: $1" >&2; usage; exit 1;;
  esac
done

if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  echo "❌ [safe-mark-done] PR_NUMBER must be numeric, got: $PR" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "❌ [safe-mark-done] gh CLI not found on PATH" >&2
  exit 1
fi

# gh reads its token from the shared config dir without exposing it in stdout.
export GH_CONFIG_DIR="${GH_CONFIG_DIR:-/paperclip/.config/gh}"

echo "🔍 [safe-mark-done] Verifying PR #$PR in $REPO (HARD RULE #0)…" >&2

PR_JSON="$(gh pr view "$PR" --repo "$REPO" --json state,mergedAt,url,statusCheckRollup 2>/dev/null)" || {
  echo "❌ [safe-mark-done] gh pr view failed for #$PR in $REPO" >&2
  exit 1
}

# --- Gate 1: merged? ---
MERGED_AT="$(printf '%s' "$PR_JSON" | jq -r '.mergedAt // empty')"
PR_STATE="$(printf '%s' "$PR_JSON" | jq -r '.state // empty')"
PR_URL="$(printf '%s' "$PR_JSON" | jq -r '.url // empty')"

if [[ -z "$MERGED_AT" || "$MERGED_AT" == "null" ]]; then
  echo "⛔ [safe-mark-done] PR #$PR is NOT merged (state=$PR_STATE, mergedAt=null)." >&2
  echo "   Refusing to mark $ISSUE done. $PR_URL" >&2
  exit 2
fi

# --- Gate 2: required CI green? ---
# A check is a hard failure if its conclusion is one of FAILURE/CANCELLED/
# TIMED_OUT/ACTION_REQUIRED/STARTUP_FAILURE/STALE, or if a CheckRun has not
# COMPLETED. SKIPPED and NEUTRAL are acceptable (non-required / intentionally
# skipped jobs). StatusContexts use a `state` field (SUCCESS/FAILURE/...).
#
# IMPORTANT: GitHub's statusCheckRollup retains ALL historical runs of a check,
# not just the latest. A check that failed then was re-run green will have both
# entries present. We must deduplicate to the LATEST run per named check before
# evaluating conclusions — otherwise a stale FAILURE causes a false-positive
# exit 3. This mirrors `gh pr checks` semantics (which already dedups for you).
# Fix for BLD-1826: group by check name, keep max(completedAt // startedAt).
BAD_CHECKS="$(printf '%s' "$PR_JSON" | jq -r '
  # Normalise every rollup entry into {key, ts, obj} then dedup to latest per key.
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
  # Now evaluate conclusions on the deduplicated latest-per-check set.
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
')"

if [[ -n "$BAD_CHECKS" ]]; then
  echo "⛔ [safe-mark-done] PR #$PR is merged but required CI is NOT green:" >&2
  printf '   - %s\n' $BAD_CHECKS >&2 2>/dev/null || echo "$BAD_CHECKS" >&2
  echo "   Refusing to mark $ISSUE done. $PR_URL" >&2
  exit 3
fi

echo "✅ [safe-mark-done] PR #$PR merged at $MERGED_AT, all required checks green." >&2
echo "   Marking $ISSUE done…" >&2

# Perform the gated status flip via clip.sh with the bypass env var set.
# NOTE: clip.sh lives on a read-only virtiofs mount and lacks the execute bit,
# so it must be invoked via `bash` rather than directly. Direct exec gives
# "Permission denied" even though safe-mark-done.sh itself is executable.
if [[ -n "$COMMENT" ]]; then
  CLIP_ALLOW_DONE=1 bash "$CLIP" update-issue "$ISSUE" --status done --comment "$COMMENT"
else
  CLIP_ALLOW_DONE=1 bash "$CLIP" update-issue "$ISSUE" --status done
fi

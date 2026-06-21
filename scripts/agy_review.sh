#!/usr/bin/env bash
# agy_review.sh — BetterCallGemini agy turn (critique OR sandbox-proposal).
#
# Runs one `agy -p` turn to review/criticize a codebase (and, in sandbox mode, to
# propose scripts). agy is NEVER given --dangerously-skip-permissions. Read-only is
# enforced by the edit-guard: any file agy changes/deletes/creates in scope is
# restored/removed — EXCEPT the report file and the --sandbox subtree. A trap runs
# the guard even if the script is interrupted (Ctrl-C / SIGTERM).
#
# Last stdout line is:  RESULT=<OK|AUTH|CAP|QUOTA|TIMEOUT|ERROR>
#
# Usage:
#   agy_review.sh --prompt-file <f> --out <report.md> \
#                 [--scope <dir>]... [--sandbox <dir>] [--model "<m>"] \
#                 [--cap <N>] [--mode <critique|sandbox>] [--continue]
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_agy_common.sh"

MODEL="Gemini 3.1 Pro (High)"
CAP=5
PROMPT_FILE=""; OUT=""; SANDBOX=""; MODE="critique"; CONT=""
SCOPES=()
BCG_RESTORED=(); BCG_DELETED=(); BCG_UNPROTECTED=0

die() { echo "$1" >&2; echo "RESULT=ERROR"; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 2>/dev/null || shift "$#";;
    --out)         OUT="${2:-}"; shift 2 2>/dev/null || shift "$#";;
    --scope)       SCOPES+=("${2:-}"); shift 2 2>/dev/null || shift "$#";;
    --sandbox)     SANDBOX="${2:-}"; shift 2 2>/dev/null || shift "$#";;
    --model)       MODEL="${2:-}"; shift 2 2>/dev/null || shift "$#";;
    --cap)         CAP="${2:-}"; shift 2 2>/dev/null || shift "$#";;
    --mode)        MODE="${2:-}"; shift 2 2>/dev/null || shift "$#";;
    --continue)    CONT="1"; shift;;
    *) die "Unknown arg: $1";;
  esac
done
[[ -n "$PROMPT_FILE" && -f "$PROMPT_FILE" ]] || die "Missing/invalid --prompt-file"
[[ -n "$OUT" ]] || die "Missing --out"
[[ ${#SCOPES[@]} -gt 0 ]] || SCOPES=("$(pwd)")
# Canonicalize scopes to ABSOLUTE paths so the guard's path comparisons (exclusions,
# in-scope checks, _existed keys) are consistent. A relative scope would make find emit
# relative paths that never match the absolute exclusion paths → guard could delete/corrupt.
for _i in "${!SCOPES[@]}"; do SCOPES[$_i]="$(readlink -f "${SCOPES[$_i]}" 2>/dev/null || echo "${SCOPES[$_i]}")"; done
[[ "$CAP" =~ ^[0-9]+$ ]] || die "Invalid --cap (must be an integer): $CAP"
mkdir -p "$(dirname "$OUT")" "$STATE_DIR"

bcg_have_agy || die "'agy' not found on PATH."
command -v script >/dev/null 2>&1 || die "'script' (util-linux) not found — required to give agy a PTY."
# Best-effort purge of stale guard stashes/temps from crashed runs (>24h old).
find "$STATE_DIR" -maxdepth 1 -name '_guard_*' -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
find "$STATE_DIR" -maxdepth 1 -name 'bcg.*' -mmin +1440 -delete 2>/dev/null || true

# Cap check (no agy call if exhausted)
USED="$(bcg_cap_used)"
if [[ "$USED" -ge "$CAP" ]]; then
  echo "CAP: $USED/$CAP agy calls today. Stop and wait for quota reset, or raise --cap." >&2
  echo "RESULT=CAP"; exit 0
fi

OUT_REAL="$(readlink -f "$OUT" 2>/dev/null || echo "$OUT")"
SANDBOX_REAL=""
if [[ -n "$SANDBOX" ]]; then
  mkdir -p "$SANDBOX"
  SANDBOX_REAL="$(readlink -f "$SANDBOX" 2>/dev/null || echo "$SANDBOX")"
  # The sandbox must be a SUBdir of (or disjoint from) every scope — if it equals or is an
  # ancestor of a scope, the guard would exclude the whole scope and protect nothing.
  for _s in "${SCOPES[@]}"; do
    _sr="$(readlink -f "$_s" 2>/dev/null || echo "$_s")"
    [[ "$_sr" == "$SANDBOX_REAL" || "$_sr" == "$SANDBOX_REAL"/* ]] \
      && die "Sandbox ($SANDBOX_REAL) must not be the scope or an ancestor of it ($_sr)."
  done
fi

# Guarantee the edit-guard runs and temps are cleaned even on interrupt.
_bcg_verified=0
bcg_cleanup() {
  trap '' INT TERM EXIT   # make cleanup non-re-entrant (a 2nd signal must not abort it)
  if [[ "$_bcg_verified" -eq 0 ]]; then
    bcg_guard_verify "${OUT_REAL:-}" "${SANDBOX_REAL:-}" "${SCOPES[@]}" 2>/dev/null || true
    _bcg_verified=1
  fi
  rm -f "${BCG_GUARD_MANIFEST:-}" "${BCG_LINKS_FILE:-}" "${BCG_ALLPATHS_FILE:-}" \
        "${BCG_RUN_OUT:-}" "${BCG_RUN_ERR:-}" "${BCG_RUNNER:-}" "${BCG_RAW:-}" 2>/dev/null || true
  rm -rf "${GUARD_DIR:-/nonexistent}" 2>/dev/null || true
}
# On INT/TERM, run cleanup THEN exit (a bare trap would return and let the script
# continue, writing a corrupt report + ledger entry). EXIT trap covers normal/early exits.
trap bcg_cleanup EXIT
trap 'bcg_cleanup; exit 130' INT TERM

# Snapshot codebase (guard) — excludes report + sandbox subtree
bcg_guard_snapshot "$OUT_REAL" "$SANDBOX_REAL" "${SCOPES[@]}"

# Build --add-dir list: scopes (read context) + sandbox (write target, if any)
ADD=("${SCOPES[@]}")
[[ -n "$SANDBOX" ]] && ADD+=("$SANDBOX")

[[ -n "$CONT" ]] && export BCG_CONTINUE=1
bcg_run_agy "$PROMPT_FILE" "$MODEL" "${ADD[@]}"

# Restore/remove any codebase changes agy made outside the sandbox
bcg_guard_verify "$OUT_REAL" "$SANDBOX_REAL" "${SCOPES[@]}"
_bcg_verified=1

# Write report. rm first so a symlink left at $OUT can't redirect our write to its target.
BYTES_IN="$(wc -c < "$PROMPT_FILE" 2>/dev/null || echo 0)"
rm -f "$OUT" 2>/dev/null
{
  echo "# BetterCallGemini report ($MODE)"
  echo
  echo "- Generated: $(bcg_now_iso)"
  echo "- Model: $MODEL"
  echo "- Scope(s): ${SCOPES[*]}"
  [[ -n "$SANDBOX" ]] && echo "- Sandbox (agy-writable): $SANDBOX"
  echo "- Outcome: $BCG_RESULT (agy exit $BCG_AGY_RC)"
  if [[ ${#BCG_RESTORED[@]} -gt 0 || ${#BCG_DELETED[@]} -gt 0 ]]; then
    echo
    echo "> [!CAUTION]"
    echo "> Edit-guard acted (agy must not change the codebase):"
    if [[ ${#BCG_RESTORED[@]} -gt 0 ]]; then
      for f in "${BCG_RESTORED[@]}"; do echo ">   - restored: $f"; done
    fi
    if [[ ${#BCG_DELETED[@]} -gt 0 ]]; then
      for f in "${BCG_DELETED[@]}"; do echo ">   - removed new file: $f"; done
    fi
  fi
  if [[ "${BCG_UNPROTECTED:-0}" -gt 0 ]]; then
    echo
    echo "> [!NOTE]"
    echo "> ${BCG_UNPROTECTED} file(s) larger than the guard size cap were NOT snapshotted"
    echo "> and cannot be restored if agy modified them in place (new large files are still removed)."
  fi
  echo; echo "---"; echo
  if [[ "$BCG_RESULT" == "AUTH" ]]; then
    echo "Auth failed. Re-login (one command, no disk log of OAuth codes): \`script -c agy /dev/null\`, complete OAuth, exit, retry."
  elif [[ "$BCG_RESULT" == "QUOTA" ]]; then
    echo "> [!IMPORTANT]"
    echo "> Quota / rate limit hit. Output may be partial. STOP and wait for reset before retrying."
    echo
  elif [[ "$BCG_RESULT" == "TIMEOUT" ]]; then
    echo "> [!IMPORTANT]"
    echo "> agy hung past the timeout with no output. This is how volume-based throttling shows up"
    echo "> here (trivial prompts still return instantly; substantive ones stall). Treat as quota:"
    echo "> STOP and wait for the quota window to reset — do NOT retry to the cap. Tip: confirm with"
    echo "> a 1-token probe \`agy -p 'reply OK' --print-timeout 60s\`; if that returns but reviews"
    echo "> hang, you're throttled. Raise the wrapper budget with BCG_TIMEOUT/BCG_PRINT_TIMEOUT only"
    echo "> if you believe the run is genuinely slow rather than throttled."
    echo
  fi
  cat "$BCG_RUN_OUT"
  # agy's own output (incl. errors under the PTY) is already shown above. Only add a
  # wrapper-stderr block if `script` itself wrote something (usually empty).
  if [[ "$BCG_RESULT" != "OK" && -s "$BCG_RUN_ERR" ]]; then
    echo; echo "<details><summary>wrapper (script) stderr</summary>"; echo
    echo '```'; tail -n 40 "$BCG_RUN_ERR"; echo '```'; echo "</details>"
  fi
} > "$OUT"

bcg_ledger_append "$MODEL" "${SCOPES[*]}" "$BCG_RESULT" "$OUT" "$BYTES_IN" "$MODE"

echo "Report: $OUT"
echo "Usage today: $((USED + 1))/$CAP"
[[ ${#BCG_RESTORED[@]} -gt 0 ]] && echo "WARNING: edit-guard restored ${#BCG_RESTORED[@]} file(s)."
[[ ${#BCG_DELETED[@]} -gt 0 ]] && echo "WARNING: edit-guard removed ${#BCG_DELETED[@]} new file(s) agy created."
echo "RESULT=$BCG_RESULT"
exit 0

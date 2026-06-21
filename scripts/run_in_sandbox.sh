#!/usr/bin/env bash
# run_in_sandbox.sh — Claude executes an APPROVED agy-proposed script inside the
# sandbox. agy never runs anything; only Claude calls this AFTER the review-subagent
# approves the script. Execution runs with cwd set to the sandbox dir, in a conda env
# (--env / $BCG_CONDA_ENV, default `base`). NOTE: this is NOT a security jail — it only
# verifies the script lives under the sandbox; review scripts before running them.
#
# Usage:
#   run_in_sandbox.sh --sandbox <sandbox_dir> --script <path-under-sandbox> \
#                     [--env <conda_env>] [--timeout <secs>] [-- <args...>]
#
# Refuses to run if the script is not inside the sandbox dir.
set -uo pipefail

# Conda env for running agy-proposed scripts. Override with --env or $BCG_CONDA_ENV.
ENV="${BCG_CONDA_ENV:-base}"; TIMEOUT=600; SANDBOX=""; SCRIPT=""; ARGS=()
# Reject a missing value being swallowed from the next option (e.g. `--sandbox --script`).
need() { [[ -n "${2:-}" && "${2:0:1}" != "-" ]] || { echo "ERROR: $1 needs a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sandbox) need "$1" "${2:-}"; SANDBOX="$2"; shift 2;;
    --script)  need "$1" "${2:-}"; SCRIPT="$2"; shift 2;;
    --env)     need "$1" "${2:-}"; ENV="$2"; shift 2;;
    --timeout) need "$1" "${2:-}"; TIMEOUT="$2"; shift 2;;
    --)        shift; ARGS=("$@"); break;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "$SANDBOX" && -d "$SANDBOX" ]] || { echo "ERROR: --sandbox dir required/invalid" >&2; exit 2; }
[[ -n "$SCRIPT" && -f "$SCRIPT" ]] || { echo "ERROR: --script required/invalid" >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[0-9]+[smhd]?$ ]] || { echo "ERROR: invalid --timeout: $TIMEOUT" >&2; exit 2; }

SANDBOX_REAL="$(readlink -f "$SANDBOX")"
SCRIPT_REAL="$(readlink -f "$SCRIPT")"
case "$SCRIPT_REAL" in
  "$SANDBOX_REAL"/*) : ;;
  *) echo "REFUSED: script ($SCRIPT_REAL) is not inside the sandbox ($SANDBOX_REAL)." >&2; exit 3;;
esac

# Pick interpreter by extension of the BASENAME (a dot in a parent dir must not be
# mistaken for an extension). Extensionless: run directly if executable, else bash.
bn="${SCRIPT_REAL##*/}"; ext=""; [[ "$bn" == *.* ]] && ext="${bn##*.}"; ext="${ext,,}"
case "$ext" in
  py)        CMD=(python "$SCRIPT_REAL");;
  R|r)       CMD=(Rscript "$SCRIPT_REAL");;
  sh|bash)   CMD=(bash -- "$SCRIPT_REAL");;
  *)         if [[ -x "$SCRIPT_REAL" ]]; then CMD=("$SCRIPT_REAL"); else CMD=(bash -- "$SCRIPT_REAL"); fi;;
esac

echo "[run_in_sandbox] env=$ENV cwd=$SANDBOX_REAL script=$SCRIPT_REAL timeout=${TIMEOUT}s"
echo "---------------- output ----------------"
# cwd = sandbox so relative paths stay local. `--` ends conda's option parsing.
# --kill-after sends SIGKILL if the child ignores SIGTERM (conda run may not forward it).
# timeout is INSIDE conda run so it wraps the interpreter directly — conda run may not
# forward signals, which would otherwise orphan a timed-out child.
( cd "$SANDBOX_REAL" && conda run --no-capture-output -n "$ENV" -- timeout --kill-after=10s "$TIMEOUT" "${CMD[@]}" "${ARGS[@]}" )
RC=$?
echo "----------------------------------------"
echo "[run_in_sandbox] exit=$RC"
exit "$RC"

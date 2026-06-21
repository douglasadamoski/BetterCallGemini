#!/usr/bin/env bash
# _agy_common.sh — shared helpers for BetterCallGemini entrypoints.
# Source this; do not execute directly. Provides auth/quota detection, the daily
# call cap + ledger, the codebase edit-guard, and the agy runner.
#
# Edit-guard enforces "agy must not change the codebase": it snapshots files in
# scope (by size), then after the run RESTORES any protected file/symlink that
# changed or was deleted and REMOVES anything new agy created (files, symlinks,
# empty dirs) — EXCLUDING the report file, the --sandbox subtree, and the skill's
# own state/ dir. Files larger than the size cap are tracked for new-file
# detection but cannot be restored (a warning is emitted).
#
# agy's agentic loop needs a PTY; run headless (no TTY) it stalls at 0% CPU. So
# the runner wraps agy in `script` to allocate a pseudo-terminal (same fix as the
# `script -f gemini-login.txt` login trick).

BCG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$BCG_LIB_DIR/.." && pwd)"
STATE_DIR="$SKILL_DIR/state"
LEDGER="$STATE_DIR/usage.jsonl"
# Per-run guard stash (PID-scoped) so concurrent agy_review.sh runs don't clobber
# each other's backups/cleanup.
GUARD_DIR="$STATE_DIR/_guard_$$"
STATE_REAL="$(readlink -f "$STATE_DIR" 2>/dev/null || echo "$STATE_DIR")"

# Only files <= this size are copied for restore (bounds disk; larger files are
# still tracked for new-file detection but cannot be restored).
BCG_GUARD_MAX_BYTES=1048576   # 1 MiB

# Initialize temp-file globals to empty so a value inherited from the parent environment
# can't make the cleanup trap rm -f an arbitrary user file on an early exit.
BCG_GUARD_MANIFEST=""; BCG_LINKS_FILE=""; BCG_ALLPATHS_FILE=""
BCG_RUN_OUT=""; BCG_RUN_ERR=""; BCG_RUNNER=""; BCG_RAW=""

# All temp files live under state/ (on the work mount), never /tmp — honors the
# workspace "no temp files in system paths" rule. state/ is excluded from the guard.
bcg_mktemp() { mkdir -p "$STATE_DIR"; mktemp -p "$STATE_DIR" "bcg.${1:-tmp}.XXXXXX"; }

bcg_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
bcg_today()   { date -u +%Y-%m-%d; }
bcg_have_agy() { command -v agy >/dev/null 2>&1; }
bcg_file_size() { stat -c %s "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null || echo 0; }

bcg_is_auth_error() {  # $1=file
  grep -qiE "not logged into Antigravity|error getting token source|failed to set auth token" "$1" 2>/dev/null
}
bcg_is_quota_error() { # $1=file
  grep -qiE "RESOURCE_EXHAUSTED|quota|rate.?limit|limit reached|too many requests|\\b429\\b" "$1" 2>/dev/null
}

bcg_json_escape() {
  local s="${1:-}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"; s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# bcg_ledger_append model scope exit out_file bytes_in mode
# flock serializes concurrent appends (parallel runs / CIFS) so lines don't interleave.
bcg_ledger_append() {
  mkdir -p "$STATE_DIR"
  local bytes="${5:-0}"; bytes="${bytes//[!0-9]/}"; bytes="${bytes:-0}"   # JSON-safe integer
  {
    flock 9 2>/dev/null || true
    printf '{"ts":"%s","mode":"%s","model":"%s","scope":"%s","bytes_in_estimate":%s,"exit":"%s","out_file":"%s"}\n' \
      "$(bcg_now_iso)" "$(bcg_json_escape "${6:-}")" "$(bcg_json_escape "$1")" \
      "$(bcg_json_escape "$2")" "$bytes" "$(bcg_json_escape "$3")" "$(bcg_json_escape "$4")" >> "$LEDGER"
  } 9>>"$LEDGER"
}

# grep -c prints "0" + exits 1 on no-match; use `|| true` (NOT `|| echo 0`, which double-prints).
bcg_cap_used() {
  [[ -f "$LEDGER" ]] || { echo 0; return; }
  # Anchor to start-of-line so today's date can't match inside a path; exclude AUTH
  # entries (auth failures consume no API quota).
  local n; n="$(grep "^{\"ts\":\"$(bcg_today)" "$LEDGER" 2>/dev/null | grep -vc '"exit":"AUTH"' || true)"
  echo "${n:-0}"
}

# --- edit-guard --------------------------------------------------------------
# Globals: BCG_GUARD_MANIFEST (files: hash\tpk\tpath), BCG_LINKS_FILE (symlinks:
#   linkpath\ttarget), BCG_ALLPATHS_FILE (every pre-existing file/dir/symlink path),
#   BCG_RESTORED[], BCG_DELETED[], BCG_UNPROTECTED.
_bcg_excluded() { # $1=resolved-path  $2=out_real  $3=sandbox_real
  local rp="$1" out_real="$2" sandbox_real="$3"
  [[ "$rp" == "$out_real" ]] && return 0
  [[ -n "$sandbox_real" && ( "$rp" == "$sandbox_real" || "$rp" == "$sandbox_real"/* ) ]] && return 0
  [[ "$rp" == "$STATE_REAL" || "$rp" == "$STATE_REAL"/* ]] && return 0
  return 1
}
# True if resolved path is within one of the snapshot's scope roots. Used so the guard
# never snapshots/restores a symlink TARGET that lies OUTSIDE the scope (e.g. /etc/hosts).
BCG_SCOPE_ROOTS=()
_bcg_in_roots() {
  local p="$1" r
  for r in "${BCG_SCOPE_ROOTS[@]}"; do
    [[ "$p" == "$r" || "$p" == "$r"/* ]] && return 0
  done
  return 1
}

# Emit NUL-delimited file/symlink paths for all scopes (handles file AND dir scopes).
_bcg_scope_files() {
  local s
  for s in "$@"; do
    if [[ -d "$s" ]]; then
      find "$s" \( -type f -o -type l \) -print0 2>/dev/null
    elif [[ -e "$s" || -L "$s" ]]; then
      printf '%s\0' "$s"
    fi
  done
}
# Emit NUL-delimited directory paths for all scopes (for new-dir detection).
_bcg_scope_dirs() {
  local s
  for s in "$@"; do [[ -d "$s" ]] && find "$s" -type d -print0 2>/dev/null; done
}

# bcg_guard_snapshot OUT_REAL SANDBOX_REAL SCOPE...
bcg_guard_snapshot() {
  local out_real="$1" sandbox_real="$2"; shift 2
  BCG_SNAPSHOT_DONE=0   # set to 1 only when snapshot fully completes (see end)
  mkdir -p "$GUARD_DIR"
  BCG_GUARD_MANIFEST="$(bcg_mktemp manifest)"
  BCG_LINKS_FILE="$(bcg_mktemp links)"
  BCG_ALLPATHS_FILE="$(bcg_mktemp allpaths)"
  BCG_UNPROTECTED=0
  local f rp sz h pk s d
  BCG_SCOPE_ROOTS=()
  for s in "$@"; do BCG_SCOPE_ROOTS+=("$(readlink -f "$s" 2>/dev/null || echo "$s")"); done
  # BCG_ALLPATHS_FILE is NUL-delimited "type<TAB>path" records (type: d/f/l) so paths
  # containing newlines/tabs can't be misparsed. Paths are the RAW find output (scopes are
  # canonicalized by the caller), kept consistent between snapshot and verify.
  # record pre-existing directories (for new-empty-dir cleanup + type map)
  while IFS= read -r -d '' d; do
    _bcg_excluded "$d" "$out_real" "$sandbox_real" || printf 'd\t%s\0' "$d" >> "$BCG_ALLPATHS_FILE"
  done < <(_bcg_scope_dirs "$@")
  # files + symlinks
  while IFS= read -r -d '' f; do
    rp="$(readlink -f "$f" 2>/dev/null || echo "$f")"
    # Exclude on the entry's OWN path ($f), not its resolved target ($rp): a symlink whose
    # target lands in an excluded area must still be tracked as an in-scope entry.
    _bcg_excluded "$f" "$out_real" "$sandbox_real" && continue
    if [[ -L "$f" ]]; then printf 'l\t%s\0' "$f" >> "$BCG_ALLPATHS_FILE"
    else printf 'f\t%s\0' "$f" >> "$BCG_ALLPATHS_FILE"; fi
    # NOTE: do NOT record the resolved target $rp here — it may be a directory or an
    # external path; tracking it as type 'f' would make the reconciliation pre-pass rm -rf it.
    # if $f is itself a symlink, record it (NUL-separated fields) to restore the LINK itself.
    [[ -L "$f" ]] && printf '%s\0%s\0' "$f" "$(readlink "$f")" >> "$BCG_LINKS_FILE"
    # snapshot content only for regular-file targets that are WITHIN scope (never
    # snapshot/restore a symlink target outside the scope, e.g. /etc/hosts)
    { [[ -f "$rp" ]] && _bcg_in_roots "$rp"; } || continue
    sz="$(bcg_file_size "$rp")"
    if [[ "$sz" =~ ^[0-9]+$ && "$sz" -le "$BCG_GUARD_MAX_BYTES" ]]; then
      h="$(sha256sum "$rp" | cut -d' ' -f1)"
      pk="$(printf '%s' "$rp" | sha256sum | cut -d' ' -f1)"
      cp -pf "$rp" "$GUARD_DIR/$pk" 2>/dev/null || true
      printf '%s\t%s\t%s\0' "$h" "$pk" "$rp" >> "$BCG_GUARD_MANIFEST"
    else
      BCG_UNPROTECTED=$((BCG_UNPROTECTED + 1))
    fi
  done < <(_bcg_scope_files "$@")
  BCG_SNAPSHOT_DONE=1   # snapshot complete: safe for verify to delete "new" files
}

# bcg_guard_verify OUT_REAL SANDBOX_REAL SCOPE...
bcg_guard_verify() {
  local out_real="$1" sandbox_real="$2"; shift 2
  BCG_RESTORED=(); BCG_DELETED=()
  [[ -n "${BCG_GUARD_MANIFEST:-}" && -f "$BCG_GUARD_MANIFEST" ]] || return 0
  local oldh pk f newh linkpath target d rp p typ cur
  # 0) load the pre-existing path->type map (NUL/type records), then a TYPE-RECONCILIATION
  #    pre-pass: if any pre-existing path's current type differs from its original
  #    (file<->dir<->symlink swap), remove it so restore rebuilds it correctly and a
  #    blocking file/dir can't defeat mkdir/cp.
  declare -A _existed
  if [[ -n "${BCG_ALLPATHS_FILE:-}" && -f "$BCG_ALLPATHS_FILE" ]]; then
    while IFS=$'\t' read -r -d '' typ p; do _existed["$p"]="$typ"; done < "$BCG_ALLPATHS_FILE"
  fi
  for p in "${!_existed[@]}"; do
    if [[ -L "$p" ]]; then cur=l; elif [[ -d "$p" ]]; then cur=d; elif [[ -e "$p" ]]; then cur=f; else cur=""; fi
    [[ -n "$cur" && "$cur" != "${_existed[$p]}" ]] && rm -rf "$p" 2>/dev/null
  done
  # recreate pre-existing directories that are now missing (agy-deleted, or cleared above).
  for p in "${!_existed[@]}"; do
    [[ "${_existed[$p]}" == d && ! -d "$p" ]] && mkdir -p "$p" 2>/dev/null && BCG_RESTORED+=("$p/ (dir re-created)")
  done
  # 1) restore protected files that were changed or deleted. Use --remove-destination
  #    so that if $f was replaced by a SYMLINK, cp removes the link instead of writing
  #    THROUGH it to an external target (e.g. /etc/passwd).
  while IFS=$'\t' read -r -d '' oldh pk f; do
    [[ -d "$f" && ! -L "$f" ]] && rm -rf "$f" 2>/dev/null
    if [[ ! -e "$f" && ! -L "$f" ]]; then
      if [[ -f "$GUARD_DIR/$pk" ]]; then
        mkdir -p "$(dirname "$f")" 2>/dev/null \
          && cp -pf --remove-destination "$GUARD_DIR/$pk" "$f" 2>/dev/null \
          && BCG_RESTORED+=("$f (re-created)")
      fi
      continue
    fi
    newh="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
    # Detect changes by CONTENT hash (reliable across filesystems). We deliberately do NOT
    # compare modes: the stash may live on a mode-lossy FS (e.g. CIFS forces 0755), which
    # would otherwise trigger spurious mode "restores". cp -pf preserves mode when the FS
    # supports it (the production install on the home FS); mode-only changes are not tracked.
    if [[ "$newh" != "$oldh" && -f "$GUARD_DIR/$pk" ]]; then
      cp -pf --remove-destination "$GUARD_DIR/$pk" "$f" 2>/dev/null && BCG_RESTORED+=("$f")
    fi
  done < "$BCG_GUARD_MANIFEST"
  # 2) restore symlinks themselves (missing, or now pointing elsewhere / not a link)
  if [[ -n "${BCG_LINKS_FILE:-}" && -f "$BCG_LINKS_FILE" ]]; then
    while IFS= read -r -d '' linkpath && IFS= read -r -d '' target; do
      if [[ ! -L "$linkpath" || "$(readlink "$linkpath" 2>/dev/null)" != "$target" ]]; then
        rm -rf "$linkpath" 2>/dev/null
        mkdir -p "$(dirname "$linkpath")" 2>/dev/null \
          && ln -s "$target" "$linkpath" 2>/dev/null && BCG_RESTORED+=("$linkpath (symlink)")
      fi
    done < "$BCG_LINKS_FILE"
  fi
  # 3+4) DELETION phases — only if the snapshot fully completed. If we were interrupted
  #      mid-snapshot, the path-list is partial and deleting "unrecorded" files would wipe
  #      real codebase files. So restore-only on a partial snapshot; never delete.
  if [[ "${BCG_SNAPSHOT_DONE:-0}" == 1 ]]; then
  # 3) delete NEW files/symlinks (path did not pre-exist), excluding out+sandbox+state.
  #    (_existed was loaded in step 0.)
  while IFS= read -r -d '' f; do
    # Exclude on the entry's OWN path so a NEW symlink whose target resolves into an
    # excluded area (sandbox/report/state) is still removed.
    _bcg_excluded "$f" "$out_real" "$sandbox_real" && continue
    # New iff the found path itself did not pre-exist. (Only check $f, not $rp: a new
    # symlink to a pre-existing target must still be removed — deleting the symlink
    # never touches the target.)
    if [[ -z "${_existed["$f"]:-}" ]]; then
      rm -f "$f" 2>/dev/null && BCG_DELETED+=("$f")
    fi
  done < <(_bcg_scope_files "$@")
  # 4) remove NEW empty directories agy created (deepest first), excluding pre-existing.
  while IFS= read -r -d '' d; do
    _bcg_excluded "$d" "$out_real" "$sandbox_real" && continue
    [[ -z "${_existed["$d"]:-}" ]] && rmdir "$d" 2>/dev/null && BCG_DELETED+=("$d/ (empty dir)")
  done < <(_bcg_scope_dirs "$@" | sort -z -r)
  fi  # end snapshot-complete deletion gate
  rm -rf "$GUARD_DIR" 2>/dev/null || true
}

# --- agy runner --------------------------------------------------------------
# Globals: BCG_RUN_OUT, BCG_RUN_ERR, BCG_AGY_RC, BCG_RESULT
# bcg_run_agy PROMPT_FILE MODEL ADDDIR...
bcg_run_agy() {
  local prompt_file="$1" model="$2"; shift 2
  local dirs=("$@")
  # clear any temps from a prior call in the same process (e.g. --continue loops)
  rm -f "${BCG_RUN_OUT:-}" "${BCG_RUN_ERR:-}" "${BCG_RUNNER:-}" "${BCG_RAW:-}" 2>/dev/null
  BCG_RUN_OUT="$(bcg_mktemp out)"; BCG_RUN_ERR="$(bcg_mktemp err)"
  local hard_to="${BCG_TIMEOUT:-16m}" print_to="${BCG_PRINT_TIMEOUT:-15m}"
  # Build a runner script (avoids quoting the multi-line prompt) and run it under a
  # PTY via `script`. NB: deliberately NO --dangerously-skip-permissions — agy must
  # never auto-approve its own actions; the edit-guard enforces read-only.
  # runner/raw are GLOBAL so the cleanup trap can remove them on interrupt.
  local d
  BCG_RUNNER="$(bcg_mktemp runner)"; BCG_RAW="$(bcg_mktemp raw)"
  {
    echo '#!/usr/bin/env bash'
    # widen the PTY so agy's long lines / tables aren't hard-wrapped at 80 cols
    echo 'stty cols 1000 rows 1000 2>/dev/null || true'
    printf 'agy -p "$(cat %q)"' "$prompt_file"
    [[ -n "${BCG_CONTINUE:-}" ]] && printf ' --continue'
    for d in "${dirs[@]}"; do printf ' --add-dir %q' "$d"; done
    printf ' --model %q --print-timeout %q\n' "$model" "$print_to"
  } > "$BCG_RUNNER"
  # LC_ALL=C keeps `script`'s header/footer in English (so the strip below works in
  # any locale). Quote the runner path for `script -c`.
  local sc_cmd; printf -v sc_cmd 'bash %q' "$BCG_RUNNER"
  LC_ALL=C timeout --kill-after=15s "$hard_to" script -q -e -c "$sc_cmd" "$BCG_RAW" >/dev/null 2>"$BCG_RUN_ERR"
  BCG_AGY_RC=$?
  # Clean the PTY typescript: drop script's header/footer, strip ANSI escapes + all CRs.
  # Strip script header/footer, OSC sequences (incl. OSC-8 hyperlinks agy emits for paths),
  # CSI sequences (colors), and CRs.
  sed -E -e '/^Script started on /d' -e '/^Script done on /d' \
         -e 's/\x1b\][0-9]*;[^\x1b\x07]*(\x07|\x1b\\)//g' \
         -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
         -e 's/\r//g' \
         "$BCG_RAW" > "$BCG_RUN_OUT" 2>/dev/null || cp -f "$BCG_RAW" "$BCG_RUN_OUT"
  rm -f "$BCG_RUNNER" "$BCG_RAW"
  # Classify only on failure. Under a PTY, agy's stderr merges into stdout, so scan
  # BCG_RUN_OUT too.
  BCG_RESULT="OK"
  if [[ "$BCG_AGY_RC" -ne 0 ]]; then
    # Check the exit-code-based TIMEOUT FIRST: a killed run's partial output may contain
    # words like "quota"/"limit" and must not be misclassified as QUOTA/AUTH.
    if [[ "$BCG_AGY_RC" -eq 124 || "$BCG_AGY_RC" -eq 137 ]]; then
      BCG_RESULT="TIMEOUT"   # 124 = timeout; 137 = SIGKILL (timeout --kill-after)
    elif bcg_is_auth_error "$BCG_RUN_ERR" || bcg_is_auth_error "$BCG_RUN_OUT"; then
      BCG_RESULT="AUTH"
    elif bcg_is_quota_error "$BCG_RUN_ERR" || bcg_is_quota_error "$BCG_RUN_OUT"; then
      BCG_RESULT="QUOTA"
    else
      BCG_RESULT="ERROR"
    fi
  fi
}

---
name: BetterCallGemini
description: >-
  Delegate an independent, critical code review to Google Antigravity's CLI (`agy`,
  Gemini) and then implement the feedback yourself. agy ONLY criticizes and PROPOSES;
  it never edits the codebase or runs anything — Claude reviews and executes. Use when
  the user says "better call gemini", "have gemini review/criticize this", "get a second
  opinion from agy/antigravity", or wants an outside critique of a file/folder/codebase.
  Requests to agy are deliberately broad (intent-first, no test suite handed over) to
  exploit Gemini's huge context window. Tracks usage quota and stops + waits for reset
  when exhausted.
---

# BetterCallGemini

Get Gemini (via `agy`) to **criticize** your codebase and **design experiments**, then
**you** (Claude) triage and implement. agy gives feedback and proposes scripts; **Claude
is the only one who edits the codebase or runs anything.**

`SKILL_DIR` = the folder containing this file. Read `references/agy_notes.md` for agy
flags/paths/error-strings and the security findings behind this design.

## Step 0 — Show the banner (do this FIRST, every invocation)
Emit the banner with **ONE `printf`** (NOT `cat` — `cat <file>` renders as a "Read 1 file"
block with no preview). `assets/banner.txt` has the **colored header on top** then the full
image, so Claude Code's collapsed preview shows the header while **Ctrl+O reveals the full
art**. Run silently — **no narration** (don't announce/explain it), just the one command:
```bash
[[ -f "$SKILL_DIR/assets/banner.txt" ]] && printf '%s\n' "$(< "$SKILL_DIR/assets/banner.txt")"
```
If the file is missing, skip silently. Regenerate `banner.txt` (= header + transparent image):
```bash
{ bash "$SKILL_DIR/scripts/show_header.sh"; cat "$SKILL_DIR/assets/better_call_gemini.txt"; } > "$SKILL_DIR/assets/banner.txt"
```
The image is regenerated from a source PNG (black background made transparent first) via
`chafa --symbols=half --colors=full --size=88x35 -t 0.5 <png> > "$SKILL_DIR/assets/better_call_gemini.txt"`;
header text/colors live in `scripts/show_header.sh` (yellow rule + `⚖ It's Better Call
Gemini! ⚖` in yellow/red + dim subtitle with the Ctrl+O hint).

## Core principles (from the user)
1. **agy never changes the system.** It reads + criticizes + proposes. It does not edit
   the codebase and does not execute its own scripts.
2. **agy is never run with `--dangerously-skip-permissions`.** (Claude may run in skip
   mode; agy may not.) This is enforced in `scripts/_agy_common.sh`.
3. **Be broad with agy.** Describe *intent*, not the test suite — ask agy to invent tests.
4. **Exploit the huge context window.** Feed whole dirs via `--scope` (→ `--add-dir`).
5. **Respect quota.** Model `Gemini 3.1 Pro (High)`; default cap 5 calls/day; on a
   quota/rate-limit error, **STOP and tell the user to wait** — never retry in a loop.
6. **Single pass by default.** Iterative rounds only when the user asks.

## Why enforcement is architectural (important)
agy's CLI cannot be sandboxed in headless print mode: with no flag it auto-proceeds
writes; `toolPermission: strict` and `permissions.deny` both *stall* the run; `--sandbox`
does not confine the filesystem. So "agy doesn't change the codebase" is guaranteed by
**code, not agy config**:
- **Edit-guard** (`scripts/_agy_common.sh`): snapshots small code files in scope before
  the run, then **restores** any agy changed/deleted and **removes** any new code file agy
  created — excluding the report file and the `--sandbox` subtree.
- **Claude is the sole executor**: agy proposes scripts; a Claude review-subagent checks
  each; Claude runs approved ones via `scripts/run_in_sandbox.sh`.

## Mode A — Critique (default)

1. **Scope**: default = current project dir; honor user-named paths (each → `--scope`).
   Keep scope off bulk-data dirs.
2. **Prompt**: copy `templates/critique_prompt.md` → a **unique** temp file
   (`PF=$(mktemp -p "$SKILL_DIR/state" --suffix=.md bcg_prompt.XXXXXX)` — note the `XXXXXX`
   must be at the END of the template, so use `--suffix=.md`; keep temps in the skill's own
   `state/` dir, which the edit-guard excludes, never a shared fixed name like `state/_prompt.md`);
   fill `{{INTENT_DESCRIPTION}}` (broad, intent-first — no test suite) and `{{SCOPE_NOTES}}`.
   Pass it as `--prompt-file "$PF"`; remove it when done.
3. **Run**:
   ```bash
   bash "$SKILL_DIR/scripts/agy_review.sh" \
     --prompt-file "$PF" \
     --out "<project>/BETTERCALLGEMINI_REVIEW_<UTC-ts>.md" \
     --scope "<dir>" [--scope ...] --model "Gemini 3.1 Pro (High)" --cap 5
   ```
4. **Branch on the last line `RESULT=<WORD>`** (see below).
5. **Triage** each finding independently (accept/reject/investigate, with reasons — don't
   obey agy blindly), then **implement** the accepted ones yourself and verify.

## Mode B — Sandbox (agy designs experiments; always available)

Use when agy should build & run tests/experiments/prototypes (the user can ask for this;
it's allowed by default). agy writes only into a sandbox; Claude reviews + runs.

1. **Sandbox dir**: `<project>/BetterCallGemini/agy_workspace/<run-or-task>/`. Pass it as
   `--sandbox` so the edit-guard excludes it (agy may write there, nowhere else).
2. **Prompt**: copy `templates/sandbox_prompt.md` → a **unique** temp file
   (`PF=$(mktemp -p "$SKILL_DIR/state" --suffix=.md bcg_prompt.XXXXXX)` — in the skill's `state/` dir); fill
   `{{SANDBOX_DIR}}`, `{{INTENT_DESCRIPTION}}`, `{{TASK_DESCRIPTION}}`.
3. **Run** (same script, add `--sandbox` and `--mode sandbox`; add `--continue` on
   follow-up turns to keep agy's context):
   ```bash
   bash "$SKILL_DIR/scripts/agy_review.sh" \
     --prompt-file "$PF" \
     --out "<project>/BETTERCALLGEMINI_SANDBOX_<UTC-ts>.md" \
     --scope "<dir>" --sandbox "<project>/BetterCallGemini/agy_workspace/<task>" \
     --mode sandbox --model "Gemini 3.1 Pro (High)" --cap 5
   ```
4. On `RESULT=OK`: agy has written scripts into the sandbox (+ a README/NEEDS).
5. **REVIEW GATE (required before running anything):** inspect every script agy wrote — either
   directly in your own context, or by spawning a general subagent (Agent/Task tool). There is no
   predefined "reviewer" agent. Confirm each script: stays inside the sandbox,
   does not touch the real codebase/system, has no destructive/exfiltration/network-abuse
   ops, and matches its README. Reject or edit anything unsafe. Only approved scripts run.
   > [!WARNING]
   > `run_in_sandbox.sh` is NOT a security jail — it only path-checks the script location and
   > runs it with your normal privileges (no chroot/namespace/network isolation). A script can
   > still reach outside the sandbox via absolute paths. **This review gate is the only real
   > security boundary** — review thoroughly; never run an unreviewed script.
6. **Tool installs**: if a `NEEDS.md` requests a package, vet it, then install it into the
   sandbox conda env (the one `run_in_sandbox.sh` uses — `--env <name>`, or `$BCG_CONDA_ENV`,
   default `base`): `conda install -n <env> ...` or `conda run -n <env> pip install ...`.
   agy never installs anything.
7. **Run approved scripts** (Claude executes, confined to the sandbox, in the chosen conda env):
   ```bash
   bash "$SKILL_DIR/scripts/run_in_sandbox.sh" \
     --sandbox "<sandbox>" --script "<sandbox>/<task>/<file>" [--env <conda-env>] [--timeout 600]
   ```
8. **Feed results back** to agy for the next turn (re-run Mode B with `--continue`,
   pasting the captured output into the prompt), or proceed to implement fixes yourself.

## Result handling (both modes)
The script's **last stdout line is `RESULT=<WORD>`**:
- **AUTH** → agy not logged in. Tell the user to run agy under a PTY in ONE command and complete
  the browser OAuth: `! script -c agy /dev/null` (use `/dev/null`, NOT a log file — `script`
  records the whole session incl. OAuth codes to disk otherwise). Then exit agy and retry. STOP.
- **CAP** → daily cap reached. Tell the user; wait for reset or re-run with higher `--cap`
  only if they insist. STOP.
- **QUOTA** → quota/rate limit. Report may be partial. **STOP**, advise waiting for reset.
- **TIMEOUT** → agy hung with no output. Here this almost always means **volume-based throttling**
  (trivial prompts still return in seconds; substantive ones stall). Treat like QUOTA: **STOP and
  wait for reset — do NOT keep retrying** (parallel/interactive/inline all hit the same throttle).
  Optional confirm: `agy -p 'reply OK' --print-timeout 60s` — if that returns fast but reviews hang,
  it's throttling, not a slow run. Only bump `BCG_TIMEOUT`/`BCG_PRINT_TIMEOUT` if genuinely slow.
- **ERROR** → show the report's stderr `<details>` and the failure; don't retry blindly.
- **OK** → proceed (triage in Mode A; review gate in Mode B).

If the report shows the **edit-guard restored/removed** files, flag it: agy tried to change
the codebase; it was reverted, so nothing persisted.

## Report back
Summarize: findings accepted vs rejected (with reasons); for Mode B, which scripts were
approved/run and their results; edits you made + verification; the report path; and
**usage today vs cap** (printed by the script; ledger at `state/usage.jsonl`). If stopped
on AUTH/CAP/QUOTA, say so and what to do next.

## Notes
- `agy` is a standalone binary on PATH — **no conda needed for agy itself**, and **Mode A
  (critique) needs no conda at all**. A conda env is only used to run the scripts agy proposes
  in Mode B.
- The sandbox conda env is configurable: pass `--env <name>` to `run_in_sandbox.sh`, or set
  `BCG_CONDA_ENV`; it defaults to `base`. Prefer a dedicated env over base/system.
- All wrapper temp/state files live under the skill's own `state/` dir (never `/tmp`), so the
  skill leaves no trace outside its folder and the edit-guard can exclude them.

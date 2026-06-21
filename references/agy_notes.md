# agy (Antigravity CLI) — notes for BetterCallGemini

Distilled from the workspace's `ANTIGRAVITY_INTEGRATION.md`. Self-contained so the
skill works without that file present.

## Invocation (non-interactive, what we use)
- `agy -p "<prompt>"` / `agy --print "<prompt>"` — run one prompt, print response, exit.
- `--add-dir <dir>` — add a directory to the workspace context (repeatable). This is
  how we feed whole codebases into Gemini's large context.
- `--model "<name>"` — pick the model for the run.
- `--print-timeout <dur>` — how long print mode waits (default 5m; we use 15m).
- `--dangerously-skip-permissions` — auto-approve tool requests. **We deliberately do NOT use
  this** (agy must never auto-approve its own actions). Read-only is enforced architecturally by
  the edit-guard, not by this flag. In headless print mode agy auto-proceeds tools anyway.
- `--sandbox` — restricted terminal (not used; doesn't block file edits / confine the FS).
- `-c` / `--continue`, `--conversation <id>` — resume prior conversations.

## Models (from `agy models`)
- `Gemini 3.1 Pro (High)`  ← BetterCallGemini default (deepest critique)
- `Gemini 3.1 Pro (Low)`
- `Gemini 3.5 Flash (High|Medium|Low)`  ← cheaper / quota-friendly alternatives
- `Claude Sonnet 4.6 (Thinking)`, `Claude Opus 4.6 (Thinking)`, `GPT-OSS 120B (Medium)`

## Quota / usage
- **No programmatic readout** — `/usage` and `/quota` are interactive TUI commands only.
- BetterCallGemini tracks usage best-effort via `state/usage.jsonl` (one line per call)
  and a per-day call cap, and by scanning output/log for quota errors.
- `settings.json` key `useG1Credits: true` routes to a Google One AI Premium quota;
  `gcp: {...}` routes to Vertex AI quotas. (Informational; not changed by the skill.)

## Key paths
- Binary: typically `~/.local/bin/agy`.
- CLI log (scan for errors): `~/.gemini/antigravity-cli/cli.log` (symlink to newest log).
- Settings: `~/.gemini/antigravity-cli/settings.json`.
- Conversation brain: `~/.gemini/antigravity-cli/brain/<conversation-id>/` — contains
  `task.md`, `implementation_plan.md`, `walkthrough.md`, and
  `.system_generated/logs/transcript*.jsonl` (useful to inspect what agy actually did).
- Workspace rules agy auto-reads: `<workspace>/.agents/AGENTS.md`.

## Error signatures the wrapper detects
- **Auth:** `not logged into Antigravity`, `error getting token source`, `failed to set auth token`.
- **Quota/rate:** `RESOURCE_EXHAUSTED`, `quota`, `rate limit`, `limit reached`,
  `too many requests`, `429`.

## Headless permission behavior (EMPIRICALLY TESTED — this drives the design)
Tested with `agy -p` in this environment:
- **No flag:** read tools AND write tools auto-proceed; no stall. So dropping
  `--dangerously-skip-permissions` does NOT make agy read-only (but we still drop it —
  agy must never auto-approve, per user policy; the flag only weakens enforcement).
- **`toolPermission: strict`:** STALLS the run (print mode can't confirm) → exit 124.
- **`permissions: {deny:[...]}`:** also STALLS.
- **`--sandbox`:** does NOT confine the filesystem (agy wrote outside the workspace).
- **Conclusion:** there is no agy-config way to get "reads proceed, writes silently
  denied" headlessly. Read-only is enforced architecturally: the **edit-guard**
  (restore/remove codebase changes) + **Claude is the sole executor** (agy proposes
  scripts; Claude reviews & runs them in the sandbox via `run_in_sandbox.sh`).

## Tool vocabulary (for prompts/policy)
- Reads: `read_file`, `view_file`, `grep_search`, `find_by_name`, `list_dir`, `read_url`.
- Writes/exec: `write_file`, `replace_file_content`, `run_command`.
- `run_command` has a param to run outside the terminal sandbox; `--sandbox` only adds
  "terminal restrictions", not an FS jail.

## Native primitives that EXIST but we don't rely on
- Pre-tool hook that can deny a call (binary: "tool call denied by pre-tool hook"),
  `PERM_GRANTS` env var, `permissions` object, `/permissions` & `/hooks` TUI, native
  read-only subagents, SDK read-only default (`CapabilitiesConfig` enables writes).
  Exact hook/permissions JSON schema is undocumented and can't be verified headlessly,
  so we use the architectural enforcement above instead.

## Conda env (Mode B only)
`agy` itself needs **no conda** (standalone binary on PATH), and Mode A (critique) needs none
either. A conda env is used only to run the scripts agy proposes in Mode B. It's configurable:
pass `--env <name>` to `run_in_sandbox.sh`, or set `BCG_CONDA_ENV`; it defaults to `base`.
Prefer a dedicated env over base/system.

## Re-login (auth broken / SSH)
1. `! script -c agy /dev/null`  (one command: gives agy a PTY so OAuth works; `/dev/null`
   so the session — incl. OAuth codes — is NOT written to a disk log).
2. Complete the browser OAuth, exit agy, then retry BetterCallGemini.
(Resume a known conversation with `agy --conversation=<id>`.)

## PTY requirement (CRITICAL — why the runner uses `script`)
`agy -p` for a substantive/agentic task (read files + multi-step reasoning) **hangs at 0% CPU
when run headless** (no TTY), e.g. from Claude Code's Bash tool — it stalls until the wrapper
`timeout` kills it (exit 124), with no error. A trivial `agy -p 'reply OK'` returns in ~5s
(single model turn, no loop), and the same review in a real terminal (TTY) completes normally.
**Fix:** allocate a pseudo-terminal by wrapping agy in `script` — same as the
`script -f gemini-login.txt` login trick. `scripts/_agy_common.sh::bcg_run_agy` builds a tiny
runner and runs it via `script -q -e -c "bash <runner>" <typescript>`, then strips CRs and the
`Script started/done` header/footer lines from the captured output. This is what makes headless
reviews work. (This was originally mis-diagnosed as quota throttling; it is NOT — it's the PTY.)

## Edit-guard: type-swap handling (now implemented)
File↔dir↔symlink type swaps ARE handled: the path-list records each entry's type (d/f/l), and a
verify pre-pass reconciles any type mismatch (rm the wrong type, recreate dirs, restore files/
symlinks). See the "documented limitations" section below for the remaining by-design gaps.

## Parallel runs (known best-effort limitations)
Running multiple `agy_review.sh` over the SAME scope concurrently (e.g. the 8-agent fan-out):
- The per-PID `GUARD_DIR` keeps each run's stash isolated, and prompts are read-only, so this is
  SAFE for critique. But if two runs overlap and one's agy actually edits a scoped file, the
  other may snapshot the dirty state (best-effort, not locked).
- The daily cap check is TOCTOU (each run reads the ledger before appending), so N parallel runs
  can momentarily exceed `--cap`. Set `--cap` high for intentional fan-out; for strict capping run
  sequentially.
- Don't use `--sandbox` with overlapping scopes in parallel (one run's cleanup may treat another's
  sandbox as "new"). Give parallel runs distinct scopes/sandboxes, or serialize.

## Edit-guard: documented limitations (by design, not bugs)
- **Mode-only changes** (a `chmod` with identical content) are NOT detected/reverted — change
  detection is by content hash (reliable across filesystems). `cp -pf` preserves mode on restore
  when the FS supports it (the production home FS); on a mode-lossy FS (CIFS forces 0755) modes
  are uniform anyway. We deliberately do NOT compare stash modes (that would cause spurious 0755
  "restores" when the stash is on CIFS).
- **Parallel runs over the SAME scope** are best-effort: snapshots are per-PID isolated, but if two
  runs overlap and one's agy edits a shared file, the other may capture/restore a dirty state; the
  daily cap check is also TOCTOU. Safe for read-only critique; for strict guarantees run sequentially
  or give parallel runs distinct scopes.
- **`script` PTY** is util-linux specific (Linux). Not portable to BSD/macOS `script` syntax.

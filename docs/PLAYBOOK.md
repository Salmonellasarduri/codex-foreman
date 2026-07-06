# The manager playbook

How to run a Codex worker through a multi-milestone roadmap with `foreman.sh`.
This is the operating protocol distilled from weeks of production use
(mid-2026); the tool enforces the mechanical parts, this document covers the
judgment parts.

Vocabulary: **manager** = the agent (or human) driving turns and reviewing.
**worker** = the headless Codex thread. **M** = one milestone of the roadmap.

## 0. Invariants

- **1 task = 1 worktree = 1 thread.** Never let two manager sessions drive the
  same (task, worktree) pair — the worker side is ONE serialized thread, so
  moonlighting sessions pollute each other's context and queue behind each
  other. Start every new task with a fresh worktree and a matching task name
  (`TASK_WT_MISMATCH` warns on divergence).
- **The worker never touches the main checkout.** All edits, tests, and
  commits happen inside its own worktree (`worktree.sh new <task>`). This rule
  came from a day when several agents shared one checkout: branch hijacking,
  a permanently dirty tree, and an unmergeable state right before a deploy.
- **git + tests are the truth.** Self-reports are hypotheses the manager
  verifies, never evidence.

## 1. The control loop

### 1.1 Kickoff

1. Create the worker's worktree: `worktree.sh new <task>`. Record the path;
   all later git verification runs against it (`git -C <wt> ...` — the
   manager's cwd is a different repo).
2. Write the brief **into the worktree** (start from
   `examples/brief-template.md`), e.g. `<wt>/tmp/brief.md`. The brief is
   passed **once**; afterwards the thread keeps context and you send only
   delta instructions.
   - **Hard rule: 1 exec/resume = 1 milestone.** Every prompt names exactly
     one M and ends with the STOP tail: *"STOP after this milestone; do not
     advance to the next M."* A roadmap included in the prompt is
     reference-only context, never a work queue. (Confirmed root cause of a
     runaway: this boundary lived in one brief only, and later briefs
     reverted to whole-roadmap self-run.)
3. First turn, under an interruptible background shell:
   ```
   FOREMAN_EXPECT_M=M1 foreman.sh <task> exec <wt> <wt>/tmp/brief.md examples/output-schema.json
   ```
   Do **not** pass `--ephemeral` to codex by hand — an ephemeral turn cannot
   be resumed, and resume is the whole point.

### 1.2 Continuation — kill the "re-paste the brief" tax

From turn 2 on, send **only the delta**:

```
FOREMAN_EXPECT_M=M2 foreman.sh <task> resume <wt> - <<'EOF'
M1 review: <verdict + fixes if any>. Proceed to M2 only: <goal>.
STOP after this milestone; do not advance to the next M.
EOF
```

- The helper resumes the saved `thread_id`; if the file is missing it falls
  back to `--last`, which codex scopes per-cwd, so parallel worktrees don't
  cross-contaminate.
- **Token economics (measured mid-2026):** continuation turns must be
  `resume`. A fresh `exec` re-pays the fixed prompt prefix (~15k tokens of
  base instructions + tool defs) and drops the prompt cache (~60% cached for
  one-shots vs ~95% for resumed threads). In one month of logs, 99% of exec
  calls were one-shots that never resumed — each re-paying that prefix at
  full price. One logical task = one thread, extended by resume.

### 1.3 Interrupt and steer

- **Hard interrupt**: the running turn is a background shell task — kill it.
  Uncommitted in-turn work is lost, but git checkpoints survive. This is the
  safety valve when the worker runs in a wrong direction.
- **Graceful steer**: wait for the turn to end, then `resume` with the course
  correction — context is preserved, so "drop the previous approach, do X
  instead" works.
- **After an interrupt**: `resume` with "you were interrupted; run
  `git status`, re-ground, and restart from Y".
- **Long usage-limit droughts**: the built-in backoff (8 × 90s) handles
  minutes-scale limits. For hours-scale droughts, wrap the call in an
  external retry loop (detached process + a completion marker file) rather
  than holding an agent shell open.

### 1.4 The feedback contract

Make the worker return structured turns (`examples/output-schema.json`):
`{phase, milestone, committed_count, summary, files[], tests, risks[],
questions[], blocked_on, done}`.

- **PLAN gate (default ON)**: milestones involving design judgment, new
  wiring, or fuzzy completion criteria must stop at `phase:plan` and wait for
  the manager's ACK before implementing. Skip only for purely mechanical Ms.
  The ACK costs one cheap resume round-trip and has repeatedly caught wrong
  assumptions before they became code (e.g. a stale file:line hint that would
  have mis-scoped a lock, 2026-06-30).
- **RESULT → REVIEW → FIX**: after `phase:result`, the manager verifies
  against git + tests (§2), then sends fixes back via `resume` — the worker
  repairs in the same thread, cheaply.
- If `questions[]` is *always* empty, the worker is not exposing its
  assumptions — require "state 2 assumptions you are making" in the brief.

### 1.5 The milestone gate

After **every** M:

1. **Report**: worker emits the structured RESULT plus a durable
   `tmp/codex_reports/<task>-M<n>.md`.
2. **Manager check, independent of self-report**: `git -C <wt> show --stat`
   for scope; run the targeted tests yourself; compare `committed_count`
   (claimed) with `new_commits` (git fact) from the guard line. Take a
   full-suite baseline once, then diff it every M — do not accept "those
   failures are unrelated" on the worker's word (that sentence has hidden
   real regressions).
3. **Guard line**: pass `FOREMAN_EXPECT_M` / `FOREMAN_EXPECT_REPORTS` every
   turn and read `guard=`. It is detective, not preventive: `codex exec` is
   atomic, so a runaway can't be stopped mid-turn — the guard makes it loud
   and keeps the waste to about one M.
4. **Lag-review integrity**: confirm the SHA you previously reviewed still
   exists (amend/rebase invalidates review — that's what
   `history_rewritten` catches).
5. **Queue artifact**: keep `<wt>/tmp/queue.<task>.md` with `running M`,
   `under-review M`, `next (M or FIX)`, `per-M reviewed SHA`. It makes
   ordering mistakes inspectable and doubles as recovery state after a
   manager restart.
6. **Interleave fixes, don't backlog them**: correctness findings go to the
   *front* of the queue (right after the M in flight), via resume in the same
   thread. Only cosmetic nits go to a backlog. You may launch the next 1-M
   turn before the review of the previous one finishes — review runs against
   frozen git history, so it can lag by one M without blocking the worker.

### 1.6 Thread rotation — long-context decay

When the thread's cumulative token use reaches ~300–400k, rotate: start a
fresh `exec` whose brief is self-contained (HEAD SHA, last M results, current
git facts). Decay symptoms to watch for: "done" reports for work never
executed, invented SHAs, claimed-but-never-run verification. Detection is
§1.5-2/3 (git-as-truth); park the old thread id in a dated backup file for
forensics and never resume it.

## 2. Verification protocol

1. **Scope**: `git -C <wt> show --stat <sha>` vs the M's declared files.
2. **Tests**: run them yourself in the worktree. Targeted tests per M, plus
   the full-suite baseline diff.
3. **Quality is not correctness**: for generative/prompt-adjacent milestones,
   green tests say nothing about output quality — pull one real output sample
   and compare it against a baseline yourself. If sampling needs credentials
   the worker doesn't have, the manager takes the sample; "no auth" is a
   `risks[]` entry, never a silent skip.
4. **No silent discard**: if a report is missing but git shows the M commit,
   treat it as reported and log the gap with a reason. `digest` / `report`
   subcommands are the recovery path.
5. **Stall SLA**: no signal AND no commits for ~30–45 min → check
   `git -C <wt> status` and file mtimes to distinguish idle from heads-down;
   if idle, nudge with a short `resume`.

## 3. Where the manager earns its keep

Pure implementation speed is the worker's job; well-specified milestones need
no help. Manager attention concentrates on four things:

- (a) plumbing: the exec/resume loop, worktrees, toolchain quirks
- (b) cancelling tool-output misreadings (e.g. a stale base ref making a diff
  look huge) before they trigger a wrong rollback
- (c) independent verification while reports are broken or degraded
- (d) long-tail correctness that tests don't reach — "green but the goal was
  not achieved" laziness (hardcoded ceilings, no-op integrations)

## 4. Writing completion criteria that resist local optima

- Phrase completion as **reaching the real production path**, not "tests
  green". Require 1:1 tests per criterion.
- **New module ⇒ prove the production caller exists** (grep/AST evidence in
  the report). "Tests green ≠ wired": an engine with no caller shipped dead
  once — the split that fixed it is below.
- **Split engine-build and wiring into separate milestones.** The isolation
  test from the build M (production does NOT import this module) must be
  explicitly flipped to a wiring invariant in the wiring M, or it fails by
  design at the worst moment.
- Caveat: grep-for-caller can't catch latent paths that nothing calls *yet*;
  guard those in design review.

## 5. Retro (after every roadmap)

Run a short retrospective on the drive itself — from what actually happened,
not generalities: where did autonomy break (outages? unclear brief?), what
did you fail to verify independently, did `questions[]` carry real signal?
The highest-leverage fix is almost always **brief quality** — completion
criteria naming the real usage path, the caller-grep requirement, and the
primitives the worker should reuse. Write the fixes back into your brief
template so the next drive inherits them automatically.

## 6. Manager session hygiene

Don't drive a long roadmap from one ever-growing manager session; checkpoint
state at every M boundary to the three durable surfaces (queue artifact, git,
`M<n>.md` reports) and restart the manager session clean when it gets long.
The queue artifact is exactly what a fresh session needs to continue from
`next (M or FIX)`.

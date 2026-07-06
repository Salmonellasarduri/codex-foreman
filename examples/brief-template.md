# Worker brief — <task name>

<!-- Passed ONCE at kickoff (foreman.sh <task> exec ...). Later turns are
     delta instructions via resume; never re-paste this. -->

## 1. Mission

What we are building and WHY (the axis quality will be judged on).
Link/path to the roadmap document (reference-only context — see §3).

## 2. Environment & preconditions

- Repo root = **this worktree**: `<absolute worktree path>`. Never touch any
  other checkout of this repo.
- Toolchain: <venv/node_modules location — absolute paths; worktrees usually
  don't carry their own>.
- Test command: `<how to run the targeted tests>`.
- Do not read or write `.env` / secrets.

## 3. Protocol (every milestone)

**Hard rule: this turn covers exactly ONE milestone (named below). The
roadmap above is reference context, not a work queue.**

1. Read the relevant code. Any file:line hints in this brief are *hints* —
   re-verify against the actual structure before relying on them.
2. **State 2 assumptions you are making** before implementing (this is what
   `questions[]` is for; empty questions every turn means hidden assumptions).
3. Implement the minimal diff (backward compatible; constants defined once).
4. Add tests 1:1 with the completion criteria. Run the **targeted** tests
   (the full-suite baseline is the manager's job).
5. **Commit as soon as green** — polish in a follow-up commit. A disconnect
   must never be able to take uncommitted finished work with it.
6. Unrelated fixes go in separate commits (or get reported, not done).

## 4. Reporting (every turn)

- Return the structured turn object (`--output-schema`): `{phase, milestone,
  committed_count, summary, files[], tests, risks[], questions[], blocked_on,
  done}`.
- High-stakes milestones (design judgment / new wiring / fuzzy criteria):
  stop at `phase:plan` and wait for ACK before implementing.
- Write the durable report to `tmp/codex_reports/<task>-<M>.md`. The `<M>`
  part must use the **exact same spelling** as the milestone id in this
  prompt (hyphens included) — it is string-matched by the manager's guard.
- End the report with a **re-verification manifest**: (a) the exact commands
  to re-run (tests, greps — absolute paths, `git -C <wt>`), (b) the expected
  result of each, (c) file:line anchors of the changes (max 10). A verifier
  with no context must be able to run it as-is.
- Before claiming done: run `git status --short` and `git log --oneline -1`
  and report the *actual* SHA (never a predicted one). `done: true` only if
  wired to a production caller AND tested.

## 5. Guardrails (violation = stop and report)

- Stay in scope; do not rename/refactor beyond the milestone.
- Never break existing tests; never rewrite test expectations without a
  1-line justification of why the old expectation was wrong.
- **Never amend/rebase a commit that was already reported** (the manager
  reviews by SHA; rewriting history invalidates review and trips the guard).
- ASCII-only in console output if the platform is Windows/cp932.

## 6. Stop / escalate to the manager

Real-device actions, external posts/purchases, irreversible operations,
changes to sources-of-truth, or anything touching a shared checkout.

---

## This turn

Milestone: **M1** — <goal and completion criteria, phrased as reaching the
real production path, with the caller-grep requirement if a new module>.

STOP after this milestone; do not advance to the next M.

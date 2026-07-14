# codex-foreman

[![CI](https://github.com/Salmonellasarduri/codex-foreman/actions/workflows/ci.yml/badge.svg)](https://github.com/Salmonellasarduri/codex-foreman/actions/workflows/ci.yml)

Drive a headless [Codex CLI](https://github.com/openai/codex) worker through a
multi-milestone roadmap, one **machine-verified** turn at a time.

Use the [latest GitHub release](https://github.com/Salmonellasarduri/codex-foreman/releases/latest)
for a stable snapshot. During the `v0.x` series, guard fields and operating
contracts may change between minor releases; check the release notes before
updating manager automation.

`foreman.sh` wraps `codex exec` / `codex exec resume` for a *manager* — Claude
Code, another LLM harness, or a human in a terminal — that treats the worker's
self-report as a claim, not a fact. After every turn it emits one guard line
computed from **git facts**: did commits actually appear, is history still
intact, did the worker overrun its assigned milestone, is uncommitted work
about to be silently lost.

Extracted from a live multi-agent project (mid-2026) where a Claude manager
drove Codex workers for weeks. Every mechanism here exists because something
broke without it; dates and incidents are kept in the source comments.

*日本語の概要は[下](#日本語)にあります。*

## Why not just trust the worker's report?

Three failure modes, all observed in production:

- **Silent work loss.** A stream disconnect killed a turn that still had
  uncommitted work (2026-06-24). → automatic resume-on-disconnect, plus a
  `salvage` guard when a turn ends with a dirty tree and no commit.
- **False completion.** Long-context workers eventually report work they did
  not do — "done" with zero commits, invented SHAs, claimed-but-never-run
  verification. → every turn is cross-checked against `git rev-list` counts
  and commit ancestry, and the worker's `committed_count` must match.
- **Milestone overrun.** An atomic `codex exec` turn can run past its assigned
  milestone. The guard cannot prevent that (turns are atomic); it makes the
  overrun *loud* within one turn (`over_run`, `M_MISMATCH`) so the blast
  radius stays at roughly one milestone.

## Quick start

```bash
# 0. one isolated worktree per task -- never code in the main checkout
cd /path/to/your/repo
/path/to/worktree.sh new mytask          # -> ../_worktrees/mytask, branch codex/mytask

# 1. write the brief INTO the worktree (start from examples/brief-template.md).
#    One milestone per turn; end every prompt with the STOP tail.

# 2. first turn. Run under a background shell (e.g. Claude Code
#    Bash(run_in_background:true)) so you can interrupt the running turn.
FOREMAN_EXPECT_M=M1 \
  foreman.sh mytask exec ../_worktrees/mytask \
  ../_worktrees/mytask/tmp/brief.md examples/output-schema.json

# 3. read the guard line + structured report, verify against git, then
#    continue the SAME thread with only a delta instruction:
FOREMAN_EXPECT_M=M2 foreman.sh mytask resume ../_worktrees/mytask - <<'EOF'
M1 review passed. Proceed to M2 only: <goal>.
STOP after this milestone; do not advance to the next M.
EOF
```

## The guard line

Every `exec`/`resume` ends with one machine-readable line:

```
guard=<status> reports_changed=<n> expect_reports=<e> new_commits=<m> \
  not_descendant=<0|1> attempts=<k> expect_m=<M> m_mismatch=<0|1>
```

| `guard=` | what happened | manager action |
|---|---|---|
| `ok` | turn ended in a normal state | verify scope + tests, then next turn |
| `salvage` | **no new commit but the worktree is dirty** — the silent-work-loss shape | verify the diff + tests, then commit yourself, or `resume` to let the worker finish |
| `over_run` | more report files changed than `FOREMAN_EXPECT_REPORTS` | stop; the turn likely ran past the one-milestone boundary |
| `over_run_verify` | same, but after outage retries — work may be split across attempts | verify the outage-split work before continuing |
| `history_rewritten` | new HEAD is **not a descendant** of the turn-start HEAD | stop; already-reviewed SHAs may be gone (amend/rebase) |

`m_mismatch=1` (independent flag): a changed report file name does not match
`FOREMAN_EXPECT_M`. Matching is a **string comparison, no normalization** —
name reports with the exact same spelling as the milestone id, hyphens
included (a `FIX1.md` report under `expect_m=FIX-1` false-flagged every turn
for 15+ turns before this was pinned down).

The guard is a *detective* control, not a preventive one. It does not change
the exit code; it is a loud, grep-able signal for the manager loop.

## Outage resilience

ChatGPT usage-limits and stream disconnects are external events, not code
faults. `foreman.sh` retries them itself (default budget 8 per turn):
usage-limit → 90s backoff + retry; disconnect / `turn.failed` → auto-resume
the **same thread**, so the worker keeps its context. Once a thread exists,
all retries continue that thread.

## Environment variables

| var | default | meaning |
|---|---|---|
| `FOREMAN_EXPECT_M` | *(unset)* | the single milestone id allowed this turn |
| `FOREMAN_EXPECT_REPORTS` | `1` | expected report-file delta per turn |
| `FOREMAN_RPT_GLOB` | `*.md` | report glob under `tmp/codex_reports` |
| `FOREMAN_CODEX_RETRIES` | `8` | outage retry budget per turn |
| `FOREMAN_WT` | `$PWD` | repo for `digest` / `report` |
| `FOREMAN_WT_PREFIX` | *(none)* | worktree dir prefix for the task↔worktree name check |
| `FOREMAN_WT_ROOT` | `<repo-parent>/_worktrees` | (worktree.sh) where worktrees live |
| `FOREMAN_BRANCH_PREFIX` | `codex/` | (worktree.sh) branch prefix |

## Operating rules (the short version)

1. **1 task = 1 worktree = 1 thread.** Two managers driving the same pair
   interleave one Codex thread (context pollution + serialization);
   `TASK_WT_MISMATCH` warns when the names diverge.
2. **One milestone per turn, STOP tail on every prompt.** A roadmap in a
   prompt is reference context, never a "do all of these" list.
3. **`resume`, don't re-`exec`.** A fresh thread re-pays the fixed prompt
   prefix (~15k tokens) and drops the cache (measured mid-2026: ~60% cached
   for one-shots vs ~95% for resume). One logical task = one thread.
4. **git + tests are the truth.** The structured report is where you *start*
   verifying, not where you stop.

The full manager playbook — feedback contract, milestone gate, thread
rotation, completion-criteria patterns, known landmines — is in
[docs/PLAYBOOK.md](docs/PLAYBOOK.md).

## State files (all inside the worker's worktree)

```
<wt>/tmp/codex_reports/turn.<task>.last    # last agent message (the report)
<wt>/tmp/codex_reports/turn.<task>.jsonl   # full --json event stream
<wt>/tmp/codex_reports/<task>-M<n>.md      # durable per-milestone reports (worker-written)
<wt>/tmp/codex-foreman.<task>.tid          # saved thread id
<wt>/tmp/.turn_start.<task>                # turn-start marker for the report-delta check
```

## Requirements

`bash` + `git` + an authenticated `codex` CLI. No other dependencies.
Developed and used on Windows under Git Bash; nothing here is
Windows-specific.

Confirm the worker is available with `codex --version`. Clone or unpack a
release, make `foreman.sh` and `worktree.sh` executable, then either invoke
them by absolute path or place symlinks to them in a directory on `PATH`:

```bash
chmod +x foreman.sh worktree.sh
```

## Tests

```bash
bash tests/turn_guard_test.sh
```

18 assertions over throwaway git repos, covering every guard status — the
must-flag sides (`history_rewritten`, `over_run`, `m_mismatch`) and the
near-miss pass sides that must NOT flag.

---

## 日本語

**codex-foreman** は、headless な Codex CLI ワーカーをマイルストーン単位で
運転するための管制ハーネスです。マネージャ（Claude Code・別のハーネス・人間）は
ワーカーの自己申告を「主張」として扱い、毎ターン終了時に **git の事実**
（コミットが実際に増えたか・履歴が書き換えられていないか・担当マイルストーンを
逸脱していないか・未コミット作業が消えかけていないか）から計算した guard 行で
機械検証します。

稼働中のマルチエージェントプロジェクト（2026年中頃、Claude が manager・Codex が
worker）から抽出したもので、各機構には「それが無くて壊れた」実事故の日付が
ソースコメントに残してあります:

- **salvage** — stream 切断でターンが死に、未コミット作業を失いかけた事故が起源
- **history_rewritten / new_commits** — 長文脈化したワーカーの「やっていない作業の
  完了報告」「架空 SHA」を git-as-truth で検出
- **over_run / M_MISMATCH** — 1 ターン 1 マイルストーン境界の逸脱を 1 ターン以内に
  検知（`codex exec` はアトミックなので予防はできない。爆風半径を約 1 M に抑える）

運用の要点: **1 task = 1 worktree = 1 thread** / **1 ターン 1 M + STOP tail** /
**継続は必ず `resume`**（新規 exec はキャッシュを捨て固定プレフィックスを再払い）/
**正は git + テスト**。詳細は [docs/PLAYBOOK.md](docs/PLAYBOOK.md)（英語）へ。

## License

MIT

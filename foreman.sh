#!/usr/bin/env bash
# foreman.sh -- drive a headless Codex CLI worker turn-by-turn, verifying every
# turn against git facts instead of the worker's self-report.
#
# Extracted 2026-07-06 from the manager loop of a live always-on agent project,
# where a Claude manager drove Codex workers through multi-milestone roadmaps.
# This standalone version has NO messaging-bus dependency: it is pure
# `codex exec` / `codex exec resume` plus git-as-truth turn verification.
#
#   foreman.sh <task> exec   <worktree> <prompt-file|-> [output-schema.json]
#                                         # first turn; saves the codex thread_id so
#                                         # later turns keep context (no re-paste)
#   foreman.sh <task> resume <worktree> <prompt-file|-> [output-schema.json]
#                                         # continue the saved thread with only a
#                                         # delta instruction
#   foreman.sh <task> digest [N] [repo]   # recent commits + milestone reports of repo
#                                         # (default $FOREMAN_WT or $PWD)
#   foreman.sh <task> report <Mn> [repo]  # show <repo>/tmp/codex_reports/<Mn>.md
#
# Run exec/resume under your agent harness's *background* shell (e.g. Claude Code
# Bash(run_in_background:true)) so a stop/interrupt can kill the running turn.
#
# env: FOREMAN_WT              worktree for digest/report (default $PWD)
#      FOREMAN_EXPECT_REPORTS  expected report-file delta per turn (default 1)
#      FOREMAN_EXPECT_M        the single milestone id allowed this turn; echoed as
#                              expect_m= and string-matched against changed report names
#      FOREMAN_RPT_GLOB        report glob under tmp/codex_reports (default '*.md')
#      FOREMAN_CODEX_RETRIES   outage retry budget per turn (default 8)
#      FOREMAN_WT_PREFIX       optional worktree dir prefix for the task<->worktree
#                              name check (e.g. 'ap-' if worktrees are ap-<task>)
#      FOREMAN_SOURCE_ONLY=1   source this file for its functions (tests), no dispatch
#
# Every exec/resume ends with one machine-readable guard line:
#   guard=<status> reports_changed=<n> expect_reports=<e> new_commits=<m>
#   not_descendant=<0|1> attempts=<k> expect_m=<FOREMAN_EXPECT_M> m_mismatch=<0|1>
# The guard is a detective control, not a preventive one: `codex exec` turns are
# atomic, so the guard cannot stop a runaway turn -- it makes one loud and keeps
# the blast radius to roughly one milestone.
set +e

USAGE="usage: foreman.sh <task> {exec <wt> <pf|-> [schema] | resume <wt> <pf|-> [schema] | digest [N] [repo] | report <Mn> [repo]}"

# 2026-07-06: default was '[MF]*.md' (inherited from the source project); it silently
# missed task-prefixed report names like <task>-M1.md -- the very naming the brief
# template mandates -- so reports_changed/m_mismatch no-opped out of the box (caught
# by the first live smoke turn). The reports dir is dedicated (turn.* state files are
# .last/.jsonl), so '*.md' is safe.
FOREMAN_RPT_GLOB_DEFAULT='*.md'
FOREMAN_EXPECT_REPORTS_DEFAULT=1

_emit_turn_guard() {
  local wt="$1" prev_head="$2" new_head="$3" turnmark="$4" attempt="$5"
  local report_dir="$wt/tmp/codex_reports"
  local rpt_glob="${FOREMAN_RPT_GLOB:-$FOREMAN_RPT_GLOB_DEFAULT}"
  local expect_reports="${FOREMAN_EXPECT_REPORTS:-$FOREMAN_EXPECT_REPORTS_DEFAULT}"
  local reports_changed=0 not_descendant=0 new_commits=0 dirty=0 status=ok count="" m_mismatch=0
  local changed_report report_name
  local mismatched_reports=()

  case "$expect_reports" in
    ''|*[!0-9]*) expect_reports="$FOREMAN_EXPECT_REPORTS_DEFAULT" ;;
  esac
  case "$attempt" in
    ''|*[!0-9]*) attempt=0 ;;
  esac

  if [ -d "$report_dir" ] && [ -e "$turnmark" ]; then
    while IFS= read -r changed_report; do
      reports_changed=$((reports_changed + 1))
      if [ -n "${FOREMAN_EXPECT_M:-}" ]; then
        # String match only, no normalization: report file names must use the SAME
        # spelling as FOREMAN_EXPECT_M (hyphens included). Naming FIX-1 reports
        # "FIX1.md" produced a false M_MISMATCH on every turn for 15+ turns (2026-07).
        report_name="${changed_report##*/}"
        case "$report_name" in
          "${FOREMAN_EXPECT_M}.md"|*-"${FOREMAN_EXPECT_M}.md") ;;
          *)
            m_mismatch=1
            mismatched_reports+=("$report_name")
            ;;
        esac
      fi
    done < <(find "$report_dir" -maxdepth 1 -type f -name "$rpt_glob" -newer "$turnmark" -print 2>/dev/null)
  fi
  case "$reports_changed" in
    ''|*[!0-9]*) reports_changed=0 ;;
  esac

  if [ "$new_head" != "$prev_head" ] && [ "$prev_head" != "none" ]; then
    if ! git -C "$wt" merge-base --is-ancestor "$prev_head" "$new_head" 2>/dev/null; then
      not_descendant=1
    fi
  fi

  if [ "$not_descendant" = "0" ] && [ "$new_head" != "$prev_head" ] && [ "$prev_head" != "none" ] && [ "$new_head" != "none" ]; then
    count="$(git -C "$wt" rev-list --count "$prev_head..$new_head" 2>/dev/null)"
    case "$count" in
      ''|*[!0-9]*) new_commits=0 ;;
      *) new_commits="$count" ;;
    esac
  fi

  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    dirty=1
  fi

  if [ "$not_descendant" = "1" ]; then
    status=history_rewritten
  elif [ "$reports_changed" -gt "$expect_reports" ] && [ "$attempt" -gt 1 ]; then
    status=over_run_verify
  elif [ "$reports_changed" -gt "$expect_reports" ]; then
    status=over_run
  elif [ "$new_head" = "$prev_head" ] && [ "$dirty" = "1" ]; then
    status=salvage
  fi

  case "$status" in
    history_rewritten)
      echo "[foreman][GUARD][HISTORY_REWRITTEN] new HEAD is not a descendant of the turn-start HEAD." >&2
      echo "  -> manager: stop and inspect git history before continuing (already-reviewed SHAs may be gone)." >&2
      ;;
    over_run)
      echo "[foreman][GUARD][OVER_RUN] reports_changed=$reports_changed exceeds expect_reports=$expect_reports." >&2
      echo "  -> manager: stop; this turn may have advanced past the one-milestone boundary." >&2
      ;;
    over_run_verify)
      echo "[foreman][GUARD][OVER_RUN_VERIFY] reports_changed=$reports_changed exceeds expect_reports=$expect_reports after retry attempts=$attempt." >&2
      echo "  -> manager: verify outage-split work before continuing." >&2
      ;;
    salvage)
      echo "[foreman][SALVAGE] turn produced NO new commit but the worktree is dirty." >&2
      echo "  -> manager: verify (git -C \"$wt\" diff + tests), then commit; or resume to let the worker finish." >&2
      ;;
  esac

  if [ "$m_mismatch" = "1" ]; then
    printf '[foreman][GUARD][M_MISMATCH] changed report(s) do not match expect_m=%s:' "${FOREMAN_EXPECT_M:-}" >&2
    for report_name in "${mismatched_reports[@]}"; do
      printf ' %q' "$report_name" >&2
    done
    echo ' -> manager: another milestone report changed; possible boundary violation.' >&2
  fi

  echo "guard=$status reports_changed=$reports_changed expect_reports=$expect_reports new_commits=$new_commits not_descendant=$not_descendant attempts=$attempt expect_m=${FOREMAN_EXPECT_M:-} m_mismatch=$m_mismatch"
}

if [ "${FOREMAN_SOURCE_ONLY:-}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

T="${1:-}"
if [ -z "$T" ] || [ "$T" = "-h" ] || [ "$T" = "--help" ]; then
  echo "$USAGE" >&2
  exit 2
fi
shift
CMD="${1:-digest}"; [ "$#" -gt 0 ] && shift

case "$CMD" in
  digest)
    n="${1:-15}"
    repo="${2:-${FOREMAN_WT:-$PWD}}"
    echo "== repo: $repo =="
    git -C "$repo" log --oneline -n "$n" 2>/dev/null || echo "(not a git repo: $repo)"
    echo "== $repo/tmp/codex_reports =="
    ls -1 "$repo/tmp/codex_reports/" 2>/dev/null || echo "(none)"
    ;;
  report)
    m="${1:-}"
    repo="${2:-${FOREMAN_WT:-$PWD}}"
    if [ -z "$m" ]; then echo "usage: foreman.sh $T report <Mn> [repo]" >&2; exit 2; fi
    f="$repo/tmp/codex_reports/${m}.md"
    if [ -r "$f" ]; then cat "$f"; else echo "(cannot read $f)" >&2; exit 1; fi
    ;;
  exec|resume)
    #   exec   = first turn; saves the codex thread_id so later turns keep context.
    #   resume = continue the saved thread with only a delta instruction.
    mode="$CMD"
    wt="${1:-}"; pf="${2:-}"; schema="${3:-}"
    if [ -z "$wt" ] || [ ! -d "$wt" ] || [ -z "$pf" ]; then
      echo "usage: foreman.sh $T $mode <worktree-dir> <prompt-file|-> [output-schema.json]" >&2; exit 2
    fi
    wt="$(cd "$wt" && pwd)" || { echo "[error] cannot canonicalize worktree '$wt'" >&2; exit 2; }
    # Multi-session 1:1 guard: 1 manager session = 1 task = 1 worktree. The codex
    # thread id lives at <wt>/tmp/codex-foreman.<task>.tid, so two managers driving
    # the same (worktree, task) interleave ONE codex thread (context pollution +
    # serialization). Convention: task name = worktree dir name (minus prefix).
    wtbase="${wt##*/}"
    if [ "$wtbase" != "${FOREMAN_WT_PREFIX:-}${T}" ] && [ "$wtbase" != "$T" ]; then
      echo "[foreman][WARN][TASK_WT_MISMATCH] task='$T' vs worktree='$wtbase' (expected '${FOREMAN_WT_PREFIX:-}$T')." >&2
      echo "  -> rule: 1 manager session = 1 task = 1 worktree; never reuse another session's task name." >&2
    fi
    # Prompt comes from a file fed on stdin (large briefs never hit ARG_MAX). '-' slurps stdin to a temp.
    if [ "$pf" = "-" ]; then tmpf="$(mktemp)"; cat > "$tmpf"; pf="$tmpf"; fi
    if [ ! -r "$pf" ]; then echo "[error] prompt file not readable: $pf" >&2; exit 2; fi
    mkdir -p "$wt/tmp/codex_reports"
    last="$wt/tmp/codex_reports/turn.$T.last"
    jsonl="$wt/tmp/codex_reports/turn.$T.jsonl"
    tidf="$wt/tmp/codex-foreman.$T.tid"
    cargs=(exec --json --output-last-message "$last")
    if [ "$mode" = "resume" ]; then
      tid=""; [ -r "$tidf" ] && tid="$(tr -d '[:space:]' < "$tidf")"
      if [ -n "$tid" ]; then
        cargs=(exec resume "$tid" --output-last-message "$last")
      else
        echo "[warn] no saved thread_id ($tidf); resuming most-recent in this cwd (--last)." >&2
        cargs=(exec resume --last --output-last-message "$last")
      fi
    fi
    if [ -n "$schema" ]; then
      if [ ! -r "$schema" ]; then echo "[error] output-schema not readable: $schema" >&2; exit 2; fi
      cargs+=(--output-schema "$schema")
    fi
    cargs+=(-)   # PROMPT from stdin (the prompt file)
    echo "== codex $mode task=$T wt=$wt =="
    # Resilience: Codex outages (ChatGPT usage-limit / stream-disconnect) are EXTERNAL,
    # not code faults. Recover automatically instead of leaving the manager to hand-build
    # retries (origin: 2026-06-24, a stream-disconnect killed a turn that still had
    # uncommitted work). usage-limit -> backoff+retry; disconnect/turn.failed ->
    # auto-resume the same thread (context preserved).
    prev_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo none)"
    turnmark="$wt/tmp/.turn_start.$T"
    : > "$turnmark"
    max="${FOREMAN_CODEX_RETRIES:-8}"; attempt=0; rc=0
    while :; do
      attempt=$((attempt + 1))
      ( cd "$wt" && codex "${cargs[@]}" < "$pf" ) > "$jsonl" 2>&1
      rc=$?
      _tid="$(grep -oE '"thread_id" *: *"[0-9a-f-]{36}"' "$jsonl" 2>/dev/null | head -1 | grep -oE '[0-9a-f-]{36}')"
      [ -n "$_tid" ] && printf '%s\n' "$_tid" > "$tidf"
      if grep -q "usage limit" "$jsonl" 2>/dev/null; then
        [ "$attempt" -ge "$max" ] && { echo "[foreman] usage-limit; retries exhausted ($max)" >&2; break; }
        echo "[foreman] usage-limit; backoff 90s then retry ($attempt/$max)" >&2; sleep 90
      elif grep -qE "stream disconnected|\"turn\\.failed\"" "$jsonl" 2>/dev/null; then
        [ "$attempt" -ge "$max" ] && { echo "[foreman] stream-disconnect; retries exhausted ($max)" >&2; break; }
        echo "[foreman] stream-disconnect; auto-resume ($attempt/$max)" >&2; sleep 10
      else
        break   # clean turn
      fi
      # once a thread exists, all retries continue the SAME thread (keep context); a fresh
      # exec that failed before creating a thread re-runs as-is.
      _t="$(tr -d '[:space:]' < "$tidf" 2>/dev/null)"
      if [ -n "$_t" ]; then
        cargs=(exec resume "$_t" --output-last-message "$last")
        [ -n "$schema" ] && cargs+=(--output-schema "$schema")
        cargs+=(-)
      fi
    done
    # SALVAGE guard: a turn that ends with no new commit but a dirty tree risks silent
    # work-loss (the 2026-06-24 failure mode). Flag for manager verify+commit (don't
    # auto-commit unverified work -- git+test-as-truth, the manager decides).
    new_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo none)"
    _emit_turn_guard "$wt" "$prev_head" "$new_head" "$turnmark" "$attempt"
    echo "rc=$rc  attempts=$attempt  report=$last  thread=$(cat "$tidf" 2>/dev/null)"
    echo "---- report (last agent message) ----"
    sed -n '1,80p' "$last" 2>/dev/null || echo "(no last message; check $jsonl)"
    exit "$rc"
    ;;
  *)
    echo "$USAGE" >&2
    exit 2
    ;;
esac

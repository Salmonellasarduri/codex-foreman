#!/usr/bin/env bash
# Unit tests for foreman.sh _emit_turn_guard. No codex needed: each case builds a
# throwaway git repo and manipulates commits/reports to force one guard status.
#
# Adversarial fixtures are included on purpose (must-FLAG sides asserted, not just
# the happy path): history_rewritten, over_run, m_mismatch -- plus the near-miss
# counterparts that must NOT flag (M1.md and task-M1.md under expect_m=M1).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
FOREMAN_SOURCE_ONLY=1 . "$HERE/../foreman.sh"

pass=0; fail=0
assert_contains() { # haystack needle label
  case "$1" in
    *"$2"*) pass=$((pass+1)); echo "ok   - $3" ;;
    *) fail=$((fail+1)); echo "FAIL - $3"; echo "       want: $2"; echo "       got:  $1" ;;
  esac
}
assert_not_contains() { # haystack needle label
  case "$1" in
    *"$2"*) fail=$((fail+1)); echo "FAIL - $3"; echo "       must NOT contain: $2"; echo "       got:  $1" ;;
    *) pass=$((pass+1)); echo "ok   - $3" ;;
  esac
}

CLEANUP=()
trap 'for d in "${CLEANUP[@]:-}"; do rm -rf "$d"; done' EXIT

mkrepo() {
  local d; d="$(mktemp -d)"
  CLEANUP+=("$d")
  git -C "$d" init -q -b main
  git -C "$d" -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$d/tmp/codex_reports"
  echo "$d"
}
addcommit() { git -C "$1" -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m "$2"; }
head_of() { git -C "$1" rev-parse HEAD; }
mkmark() { # backdate the turn-start mark so reports touched "now" count as newer
  touch -d '1 hour ago' "$1/tmp/.turn_start.t"
  echo "$1/tmp/.turn_start.t"
}

# --- 1. clean turn: 1 commit + 1 matching report -> guard=ok, m_mismatch=0 ---
d="$(mkrepo)"; tm="$(mkmark "$d")"; h0="$(head_of "$d")"
addcommit "$d" m1
touch "$d/tmp/codex_reports/M1.md"
out="$(FOREMAN_EXPECT_M=M1 _emit_turn_guard "$d" "$h0" "$(head_of "$d")" "$tm" 1 2>&1)"
assert_contains "$out" "guard=ok" "clean turn -> guard=ok"
assert_contains "$out" "new_commits=1" "clean turn -> new_commits=1"
assert_contains "$out" "reports_changed=1" "clean turn -> reports_changed=1"
assert_contains "$out" "m_mismatch=0" "M1.md under expect_m=M1 must NOT flag (near-miss pass side)"

# --- 2. task-prefixed report name also matches expect_m ---
d="$(mkrepo)"; tm="$(mkmark "$d")"; h0="$(head_of "$d")"
addcommit "$d" m1
touch "$d/tmp/codex_reports/mytask-M1.md"
out="$(FOREMAN_EXPECT_M=M1 _emit_turn_guard "$d" "$h0" "$(head_of "$d")" "$tm" 1 2>&1)"
assert_contains "$out" "m_mismatch=0" "mytask-M1.md under expect_m=M1 must NOT flag"

# --- 3. salvage: no new commit but dirty tree ---
d="$(mkrepo)"; tm="$(mkmark "$d")"; h0="$(head_of "$d")"
echo dirty > "$d/uncommitted.txt"
out="$(_emit_turn_guard "$d" "$h0" "$(head_of "$d")" "$tm" 1 2>&1)"
assert_contains "$out" "guard=salvage" "dirty tree + no commit -> guard=salvage"
assert_contains "$out" "[foreman][SALVAGE]" "salvage prints a loud stderr marker"

# --- 4. over_run: 2 reports changed, expect 1, first attempt ---
d="$(mkrepo)"; tm="$(mkmark "$d")"; h0="$(head_of "$d")"
addcommit "$d" m1
touch "$d/tmp/codex_reports/M1.md" "$d/tmp/codex_reports/M2.md"
out="$(_emit_turn_guard "$d" "$h0" "$(head_of "$d")" "$tm" 1 2>&1)"
assert_contains "$out" "guard=over_run" "2 reports vs expect 1 -> guard=over_run (must-flag side)"
assert_contains "$out" "reports_changed=2" "over_run counts both reports"

# --- 5. over_run_verify: same but after retries (attempt>1) ---
d="$(mkrepo)"; tm="$(mkmark "$d")"; h0="$(head_of "$d")"
addcommit "$d" m1
touch "$d/tmp/codex_reports/M1.md" "$d/tmp/codex_reports/M2.md"
out="$(_emit_turn_guard "$d" "$h0" "$(head_of "$d")" "$tm" 3 2>&1)"
assert_contains "$out" "guard=over_run_verify" "over-run after retries -> guard=over_run_verify"
assert_contains "$out" "attempts=3" "attempt count is echoed as-is (no clamping)"

# --- 6. history_rewritten: new HEAD is not a descendant of turn-start HEAD ---
d="$(mkrepo)"; tm="$(mkmark "$d")"
addcommit "$d" reviewed
h1="$(head_of "$d")"                       # turn-start HEAD (already reviewed)
git -C "$d" reset -q --hard HEAD~1         # worker rewrites history...
addcommit "$d" rewritten                   # ...and commits something else
out="$(_emit_turn_guard "$d" "$h1" "$(head_of "$d")" "$tm" 1 2>&1)"
assert_contains "$out" "guard=history_rewritten" "reset+recommit -> guard=history_rewritten (must-flag side)"
assert_contains "$out" "not_descendant=1" "ancestry check reports not_descendant=1"

# --- 7. m_mismatch: FIX1.md under expect_m=FIX-1 (the real-world false-done spelling) ---
d="$(mkrepo)"; tm="$(mkmark "$d")"; h0="$(head_of "$d")"
addcommit "$d" fix
touch "$d/tmp/codex_reports/FIX1.md"
out="$(FOREMAN_EXPECT_M=FIX-1 _emit_turn_guard "$d" "$h0" "$(head_of "$d")" "$tm" 1 2>&1)"
assert_contains "$out" "m_mismatch=1" "FIX1.md under expect_m=FIX-1 -> m_mismatch=1 (string match, no normalization)"
assert_contains "$out" "[foreman][GUARD][M_MISMATCH]" "m_mismatch prints a loud stderr marker"

# --- 8b. task-prefixed report name COUNTS under the default glob ---
# (regression: the inherited default '[MF]*.md' silently missed <task>-M1.md,
#  no-opping reports_changed/m_mismatch out of the box; caught by live smoke 2026-07-06)
d="$(mkrepo)"; tm="$(mkmark "$d")"; h0="$(head_of "$d")"
addcommit "$d" m1
touch "$d/tmp/codex_reports/foreman-smoke-M1.md"
out="$(_emit_turn_guard "$d" "$h0" "$(head_of "$d")" "$tm" 1 2>&1)"
assert_contains "$out" "reports_changed=1" "task-prefixed report counts under default glob"

# --- 8. no expect_m set -> mismatch machinery stays off ---
d="$(mkrepo)"; tm="$(mkmark "$d")"; h0="$(head_of "$d")"
addcommit "$d" m1
touch "$d/tmp/codex_reports/M9.md"
out="$(_emit_turn_guard "$d" "$h0" "$(head_of "$d")" "$tm" 1 2>&1)"
assert_contains "$out" "m_mismatch=0" "expect_m unset -> m_mismatch stays 0"
assert_not_contains "$out" "M_MISMATCH" "expect_m unset -> no mismatch stderr noise"

echo ""
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1

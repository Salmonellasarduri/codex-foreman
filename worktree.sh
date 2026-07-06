#!/usr/bin/env bash
# worktree.sh -- per-task isolated git worktree helper.
#
# origin: 2026-06-23. Several agents (multiple Codex tasks + a live bot + a
# remote manager) coded in ONE shared checkout: branch hijacking, files leaking
# between tasks, a permanently dirty tree, and an unmergeable state right before
# a deploy. The only task that survived intact worked in an isolated worktree.
# Rule that stuck: every task gets its OWN worktree off a COMMITTED base;
# nobody codes in the main checkout.
#
# Run from anywhere inside the target repo (resolves the repo root itself).
#
#   worktree.sh new  <name> [base-ref]   # create <wt-root>/<prefix><name> off base (default: HEAD)
#   worktree.sh list                     # list task worktrees
#   worktree.sh done <name>              # remove worktree after its branch is merged
#
# env: FOREMAN_WT_ROOT        where worktrees live (default: <repo-parent>/_worktrees)
#      FOREMAN_WT_PREFIX      worktree dir prefix (default: none; e.g. 'ap-')
#      FOREMAN_BRANCH_PREFIX  branch prefix (default: 'codex/')
set -euo pipefail

if ! MAIN_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "ERROR: run from inside the target git repo" >&2
  exit 1
fi
WT_DIR="${FOREMAN_WT_ROOT:-$(dirname "$MAIN_ROOT")/_worktrees}"
PFX="${FOREMAN_WT_PREFIX:-}"
BPFX="${FOREMAN_BRANCH_PREFIX:-codex/}"

cmd="${1:-help}"

case "$cmd" in
  new)
    name="${2:?usage: worktree.sh new <name> [base-ref]}"
    base="${3:-HEAD}"
    path="$WT_DIR/${PFX}${name}"
    branch="${BPFX}${name}"
    if [ -e "$path" ]; then echo "ERROR: $path already exists"; exit 1; fi
    mkdir -p "$WT_DIR"
    # branch off a COMMITTED base (clean). Uncommitted main-checkout changes are NOT carried.
    git -C "$MAIN_ROOT" worktree add -b "$branch" "$path" "$base"
    echo ""
    echo "OK worktree ready:"
    echo "  path   = $path"
    echo "  branch = $branch  (off $base)"
    echo ""
    echo "Next (work ONLY here; never touch the main checkout):"
    echo "  cd \"$path\""
    echo "  # ...edit / test / commit inside this worktree..."
    echo "When done & committed, integrate from the main checkout:"
    echo "  git -C \"$MAIN_ROOT\" merge-tree --write-tree --name-only HEAD $branch   # preview conflicts (non-destructive)"
    echo "  git -C \"$MAIN_ROOT\" merge $branch                                       # then merge"
    echo "  worktree.sh done $name                                                    # cleanup"
    ;;
  list)
    git -C "$MAIN_ROOT" worktree list | grep -F "$WT_DIR/$PFX" || echo "(no task worktrees)"
    ;;
  done)
    name="${2:?usage: worktree.sh done <name>}"
    path="$WT_DIR/${PFX}${name}"
    git -C "$MAIN_ROOT" worktree remove "$path" 2>/dev/null \
      || { echo "WARN: not clean; use: git worktree remove --force \"$path\""; exit 1; }
    echo "OK removed worktree $path (branch ${BPFX}${name} kept; delete with: git branch -D ${BPFX}${name})"
    ;;
  *)
    echo "usage: worktree.sh {new <name> [base-ref] | list | done <name>}"
    echo "rule: never code in the main checkout -- one task, one worktree, one branch."
    ;;
esac

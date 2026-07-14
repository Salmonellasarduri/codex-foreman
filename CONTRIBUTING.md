# Contributing

Focused bug fixes and tests for additional failure shapes are welcome. The
guard line is a public machine-readable interface: avoid renaming fields or
changing status semantics without documenting compatibility impact.

## Checks

```bash
bash -n foreman.sh worktree.sh tests/turn_guard_test.sh
bash tests/turn_guard_test.sh
```

Tests create throwaway repositories and must not depend on a contributor's
global git state. For a new failure mode, add both the must-flag case and a
near-miss case that must remain accepted.

Issues and pull requests must not contain authentication tokens, private Codex
transcripts, task briefs, or proprietary source code.

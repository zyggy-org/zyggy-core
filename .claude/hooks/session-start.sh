#!/usr/bin/env bash
set -euo pipefail
# SessionStart hook: one memory digest section (identity | index | daily), printed by the zyggy binary
# (`zyggy memory digest`, deliverable 28, R1). This launcher holds no logic; the digest contract lives in zyggy.
if ! command -v zyggy > /dev/null 2>&1; then
  printf 'session-start.sh: zyggy not found — no %s section\n' "${1:-}" >&2
  exit 0
fi
exec zyggy memory digest "$@"

#!/usr/bin/env bash
set -euo pipefail
# Stop hook on a laptop: refreshes the session's status, at most once per supervision.statusMinutes; the logic is zyggy work --turn-end (zyggy spec 18).
# Never blocks the turn: a missing binary or any exit of the verb is exit 0, its stderr line kept, nothing on stdout.
if ! command -v zyggy > /dev/null 2>&1; then printf 'work-turn-end: zyggy not found\n' >&2; exit 0; fi
zyggy work --turn-end > /dev/null || true
exit 0

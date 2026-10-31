#!/usr/bin/env bash
set -euo pipefail
# Stop hook on a laptop: one [observed] line per turn into the node's spool; the logic is zyggy context --stop-hook (spec 12 D2).
# Never blocks the turn: a missing binary or any exit of the verb is exit 0, its stderr line kept, nothing on stdout.
if ! command -v zyggy > /dev/null 2>&1; then printf 'stop: zyggy not found\n' >&2; exit 0; fi
zyggy context --stop-hook > /dev/null || true
exit 0

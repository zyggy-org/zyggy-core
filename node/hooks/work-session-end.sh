#!/usr/bin/env bash
set -euo pipefail
# SessionEnd hook on a laptop: removes the session's status from the bus; the logic is zyggy work --session-end (zyggy spec 18).
# Never blocks the session end: a missing binary or any exit of the verb is exit 0, its stderr line kept, nothing on stdout.
if ! command -v zyggy > /dev/null 2>&1; then printf 'work-session-end: zyggy not found\n' >&2; exit 0; fi
zyggy work --session-end > /dev/null || true
exit 0

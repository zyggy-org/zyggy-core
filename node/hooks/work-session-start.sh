#!/usr/bin/env bash
set -euo pipefail
# SessionStart hook on a laptop: publishes the session's signed status for Central; the logic is zyggy work --session-start (zyggy spec 18).
# Never blocks the session: a missing binary or any exit of the verb is exit 0, its stderr line kept. Its stdout is kept too:
# a decision of Central that came after the wait of a question, printed once.
if ! command -v zyggy > /dev/null 2>&1; then printf 'work-session-start: zyggy not found\n' >&2; exit 0; fi
zyggy work --session-start || true
exit 0

#!/usr/bin/env bash
set -euo pipefail
# SessionEnd hook on a laptop: ships the session's spool as one signed context envelope per session; the logic is zyggy context --flush (spec 12 D2).
# Never blocks the session end: a missing binary or any exit of the verb is exit 0, its stderr line kept, nothing on stdout.
if ! command -v zyggy > /dev/null 2>&1; then printf 'session-end: zyggy not found\n' >&2; exit 0; fi
zyggy context --flush > /dev/null || true
exit 0

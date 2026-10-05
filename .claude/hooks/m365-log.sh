#!/usr/bin/env bash
set -euo pipefail
# PostToolUse log of the three m365 action tools (spec 23 D7): the policy lives in `zyggy m365 log` (spec 33, R1).
# This launcher only fails closed: a missing binary or any non-zero exit of the verb is exit 2, so Claude Code blocks the call.
command -v zyggy > /dev/null 2>&1 || { printf 'm365-log: zyggy not found\n' >&2; exit 2; }
zyggy m365 log || exit 2

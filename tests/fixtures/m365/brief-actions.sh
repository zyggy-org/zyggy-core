#!/usr/bin/env bash
set -euo pipefail
# The model's part of a morning-brief run, emulated for brief.sh's tests (run by the claude stub as
# CLAUDE_STUB_ACTIONS, in the run's environment: ZYGGY_HOOKS=off, no terminal, the project directory as the working
# directory). Two proposals through the real propose.sh, called as the skill tells the model to call it; with
# BRIEF_ACTIONS_TRY_SEND=<hash>, one attempt to execute through graph.sh, which that environment must refuse (AC-47).
# Every exit status is printed as <name>=<code>.

rc=0
.claude/skills/m365/propose.sh send-draft d1 --reason "Carol asked for the invoice date" || rc=$?
printf 'propose-send-draft=%s\n' "$rc"
rc=0
.claude/skills/m365/propose.sh delete m1 --reason "Newsletter" || rc=$?
printf 'propose-delete=%s\n' "$rc"
if [ -n "${BRIEF_ACTIONS_TRY_SEND:-}" ]; then
  rc=0
  .claude/skills/m365/graph.sh send-draft --approved "$BRIEF_ACTIONS_TRY_SEND" || rc=$?
  printf 'graph-send-draft=%s\n' "$rc"
fi

#!/usr/bin/env bash
set -euo pipefail
# The model's part of a morning-brief run, emulated for brief.sh's tests (run by the claude stub as
# CLAUDE_STUB_ACTIONS, in the run's environment: ZYGGY_HOOKS=off, no terminal, the project directory as the working
# directory). D7: the run writes its suggestions into the brief Draft and acts on nothing — the three action tools
# are in its --disallowedTools — so the emulation only records that it ran (brief.sh's SIGTERM test waits for it).

printf 'model-actions=ran\n'

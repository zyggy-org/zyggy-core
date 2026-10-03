#!/usr/bin/env bash
set -euo pipefail
# Test stand-in for the claude CLI (plan 23 Step 8): installed as $BATS_TEST_TMPDIR/bin/claude by install_claude_stub.
# Not reached through env -i, so it reads its settings from the environment the orchestrator gives the child:
# CLAUDE_STUB_LOG (where to log), CLAUDE_STUB_RESULT (the file whose content is printed as the run's result; empty
# or absent → nothing printed), CLAUDE_STUB_ACTIONS (a script run first, emulating what the model does with its
# tools — e.g. state.sh and facts.sh calls), CLAUDE_STUB_SLEEP (seconds to sleep before answering), CLAUDE_STUB_EXIT (exit code).
# Logs before acting: one "call" line, every argument (arg=…), the stdin byte count, the run's ZYGGY_* environment,
# the working directory, whether stdin is a terminal, and whether any environment value carries an access token
# (token-in-env=yes|no: any JWT-shaped value — the value itself is never logged). Never contacts anything.

log="${CLAUDE_STUB_LOG:?CLAUDE_STUB_LOG is not set}"
tty=no
[ ! -t 0 ] || tty=yes
bytes=0
[ "$tty" = yes ] || bytes="$(wc -c | tr -d ' ')"
token=no
if grep -qE '=eyJ[A-Za-z0-9_-]+[.]' < <(env); then token=yes; fi
{
  printf 'call\n'
  printf 'argc=%s\n' "$#"
  for a in "$@"; do
    printf 'arg=%s\n' "$a"
  done
  printf 'stdin=%s\n' "$bytes"
  for v in ZYGGY_HOOKS ZYGGY_M365_ORIGIN ZYGGY_M365_RUN_DIR ZYGGY_MEMORY_ROOT ZYGGY_TENANT ZYGGY_USER ZYGGY_TIMEZONE; do
    if [ -n "${!v+x}" ]; then printf 'env=%s=%s\n' "$v" "${!v}"; else printf 'env=%s unset\n' "$v"; fi
  done
  printf 'cwd=%s\n' "$(pwd -P)"
  printf 'tty=%s\n' "$tty"
  printf 'token-in-env=%s\n' "$token"
} >> "$log"

if [ -n "${CLAUDE_STUB_ACTIONS:-}" ]; then
  bash "$CLAUDE_STUB_ACTIONS" < /dev/null >> "$log" 2>&1 || printf 'actions-exit=%s\n' "$?" >> "$log"
fi

if [ -n "${CLAUDE_STUB_SLEEP:-}" ]; then
  # in the background, so a SIGTERM from the orchestrator ends the stub at once and leaves no sleeping child behind
  sleep "$CLAUDE_STUB_SLEEP" &
  sleeper=$!
  trap 'kill "$sleeper" 2> /dev/null; printf "terminated\n" >> "$log"; exit 143' TERM
  wait "$sleeper"
fi

if [ -n "${CLAUDE_STUB_RESULT:-}" ] && [ -f "$CLAUDE_STUB_RESULT" ]; then
  cat "$CLAUDE_STUB_RESULT"
fi
exit "${CLAUDE_STUB_EXIT:-0}"

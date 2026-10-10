#!/usr/bin/env bash
set -euo pipefail
# The zyggy stub (tests/launchers.bats, tests/repo.bats): installed as `zyggy` first on PATH by install_zyggy_stub.
# Appends its argv (one line, arguments separated by a TAB) to $ZYGGY_STUB_LOG and stdin to $ZYGGY_STUB_STDIN, prints
# $ZYGGY_STUB_STDOUT and $ZYGGY_STUB_STDERR when set, and exits $ZYGGY_STUB_EXIT (default 0). Only the commands the
# template documents are known: anything else is exit 4 with one stderr line, as the binary does for an unknown verb.
log="${ZYGGY_STUB_LOG:-/dev/null}"
(
  IFS=$'\t'
  printf '%s\n' "$*"
) >> "$log"
if [ -n "${ZYGGY_STUB_STDIN:-}" ]; then
  cat >> "$ZYGGY_STUB_STDIN"
fi
case "${1:-} ${2:-}" in
  "m365 state" | "m365 facts" | "m365 parse" | "m365 check" | "m365 token-test" | "m365 cert-init" | "m365 guard" | \
    "m365 log" | "m365 verify" | "m365 brief" | "m365 mail-backfill" | "m365 files-backfill" | "m365 mcp-server" | \
    "m365 auth-header" | "memory remember" | "memory digest" | "memory archive" | "dream request" | "dream status" | "brief show" | "brief items" | "brief idea" | "brief request" | \
    "linkedin auth" | "linkedin mcp-server") ;;
  *)
    printf 'zyggy-stub: unknown command %s %s\n' "${1:-}" "${2:-}" >&2
    exit 4
    ;;
esac
if [ -n "${ZYGGY_STUB_STDOUT:-}" ]; then
  printf '%s\n' "$ZYGGY_STUB_STDOUT"
fi
if [ -n "${ZYGGY_STUB_STDERR:-}" ]; then
  printf '%s\n' "$ZYGGY_STUB_STDERR" >&2
fi
exit "${ZYGGY_STUB_EXIT:-0}"

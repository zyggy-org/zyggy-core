#!/usr/bin/env bash
set -euo pipefail
# Test stand-in for logger(1) (plan 23 Step R8; installed as $BATS_TEST_TMPDIR/bin/logger by install_logger_stub):
# appends "tag=<-t value> msg=<the message>" to logger-stub.log beside itself, so the tests read what
# mcp-auth-header.sh sends to the journal (and check it never holds a token).
here="$(cd "$(dirname "$0")" && pwd)"
tag=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t)
      tag="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done
printf 'tag=%s msg=%s\n' "$tag" "$*" >> "$here/logger-stub.log"

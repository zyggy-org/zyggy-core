#!/usr/bin/env bash
set -euo pipefail
# ZYGGY_MARKITDOWN_STUB — test stand-in for MarkItDown's `markitdown <file>` CLI (installed as
# $BATS_TEST_TMPDIR/markitdown-stub/markitdown by install_markitdown_stub). Finds its texts beside itself:
# fixtures/parsed-<basename>.txt is printed for <file> when present; otherwise the stub fails like the real CLI on an
# unsupported file (one stderr line, exit 1). MARKITDOWN_STUB_SLEEP=<seconds> sleeps first (the timeout test).
# Logs argv to markitdown-stub.log beside itself. Never reads the input file's content.

here="$(cd "$(dirname "$0")" && pwd)"
printf 'argv=%s\n' "$*" >> "$here/markitdown-stub.log"
[ $# -eq 1 ] || {
  printf 'markitdown: expected one file argument\n' >&2
  exit 2
}
sleep "${MARKITDOWN_STUB_SLEEP:-0}"
text="$here/fixtures/parsed-$(basename "$1").txt"
if [ -f "$text" ]; then
  cat "$text"
else
  printf 'markitdown: UnsupportedFormatException: could not convert %s\n' "$(basename "$1")" >&2
  exit 1
fi

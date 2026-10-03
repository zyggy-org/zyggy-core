#!/usr/bin/env bash
set -euo pipefail
# The headersHelper of the m365 MCP server (spec 23 D8; .mcp.json names this script): Claude Code runs it when it
# connects to the loopback server, when it reconnects and after a 401 from a tool call, and reads one JSON object of
# headers from stdout. It mints a fresh app-only access token with `graph.sh token` (the only reader of the key) and
# prints exactly one line {"Authorization":"Bearer <token>"}. A failure other than configuration or usage (3, 4) is
# retried once; the whole run stays under ZY_M365_HELPER_SECONDS (8 s, below Claude Code's 10 s helper timeout).
# Failure: stdout empty, one stderr line naming runbook 13 "Certificate rejected", exit = graph.sh's code.
# Journal (logger -t zyggy-m365, one line per outcome): "token minted" / "token refresh failed: <graph.sh reason>".
# The token lives in a variable of this script and leaves it only through the printf builtin on stdout (a pipe Claude
# Code reads): never in an argument list, a file, stderr or the journal.
# usage: mcp-auth-header.sh (no arguments, no stdin)
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"
# shellcheck source=m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/m365-lib.sh"

readonly ZY_HELPER_TAG=zyggy-m365 ZY_HELPER_RUNBOOK='runbook 13 "Certificate rejected"'

[ $# -eq 0 ] || zy_die 4 "takes no argument (usage: mcp-auth-header.sh)"

journal() { # journal <message> — never fatal, never the token
  if command -v logger > /dev/null; then
    logger -t "$ZY_HELPER_TAG" -- "$1" 2> /dev/null || true
  fi
}

fail() { # fail <exit code> <reason>
  journal "token refresh failed: $2"
  printf 'm365: token refresh failed — %s\n' "$ZY_HELPER_RUNBOOK" >&2
  exit "$1"
}

err="$(mktemp -t zyggy-m365-helper.XXXXXX)"
trap 'rm -f "$err"' EXIT
deadline=$((SECONDS + ZY_M365_HELPER_SECONDS))
token=""
rc=1
for attempt in 1 2; do
  left=$((deadline - SECONDS))
  [ "$left" -gt 0 ] || break
  rc=0
  token="$(timeout --kill-after=1 "$left" "$ZY_M365_SKILL_DIR/graph.sh" token < /dev/null 2> "$err")" || rc=$?
  [ "$rc" -ne 0 ] || break
  token=""
  # configuration and usage errors do not get better on a second try
  case "$rc" in 3 | 4) break ;; esac
  [ "$attempt" -eq 1 ] || break
done

if [ "$rc" -ne 0 ]; then
  reason="$(grep -v '^key: ' "$err" | tail -n 1 || true)"
  reason="${reason#m365: }"
  [ "$rc" -ne 124 ] || reason="graph.sh token did not finish within ${ZY_M365_HELPER_SECONDS}s"
  fail "$rc" "${reason:-graph.sh token exited $rc}"
fi
# a JWT is base64url segments and dots: nothing to escape in the JSON, and anything else is not a token
[[ "$token" =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$ ]] || fail 6 "graph.sh token printed no token"

printf '{"Authorization":"Bearer %s"}\n' "$token"
token=""
journal "token minted"

#!/usr/bin/env bash
set -euo pipefail
# Starts the m365 MCP server for Claude Code (spec 23; .mcp.json names this script): mints a one-hour app-only
# access token with `graph.sh token`, resolves the pinned @softeria/ms-365-mcp-server installed under ~/.local and
# replaces itself with it, in a cleared environment holding exactly the eleven contracted variables, in org mode,
# with ENABLED_TOOLS = the 14-tool allowlist of m365-lib.sh. Nothing is written to stdout before the server owns it.
# usage: mcp-wrapper.sh [--probe]
#   --probe  start the server once, speak the MCP handshake and tools/list over stdio (20 s at most), print the
#            allowlisted tools it offers, the tools it registers outside the filter (the six auth tools, denied by the
#            template settings) and the environment names it was given, then stop it.
# Exit 0 · 3 configuration, key or server installation · 4 usage · 6 identity failure (graph.sh's exit, propagated;
# the server is never started) or a probe the server failed (0 tools, filter rejected, an unexpected tool).
# The token exists only in a variable of this script and in the server's environment: never in a file, never on
# stdout or stderr, never in a long-lived argument list.
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"
# shellcheck source=m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/m365-lib.sh"

readonly ZY_M365_SERVER_BIN=ms-365-mcp-server ZY_M365_PROBE_SECONDS=20
readonly ZY_M365_INSTALL_HINT='runbook 13 "Install or upgrade the MCP server"'

die() { # die <exit code> <message>
  zy_die "$@"
}

# --- 1. arguments -------------------------------------------------------------------------------------------------

probe=0
if [ $# -gt 0 ]; then
  if [ "$1" != --probe ] || [ $# -ne 1 ]; then
    die 4 "unexpected argument '$1' (usage: mcp-wrapper.sh [--probe])"
  fi
  probe=1
fi

# --- 2. the principal, the configuration, the server binary ---------------------------------------------------------

zy_require_config
command -v jq > /dev/null || die 3 "jq not found"
# shellcheck disable=SC2119 # no argument: the full validation (the client id and the consent block included)
zy_m365_load_config

# The pinned package is installed with npm's prefix ~/.local (runbook 13); a server found anywhere else — a
# package runner's cache, a system prefix, a symlink out of ~/.local — is not the reviewed one and never started.
bin="$(command -v "$ZY_M365_SERVER_BIN" || true)"
[ -n "$bin" ] || die 3 "$ZY_M365_SERVER_BIN not found — $ZY_M365_INSTALL_HINT"
real="$(readlink -f -- "$bin")"
home_real="$(readlink -f -- "$HOME")"
case "$real" in
  "$home_real"/.local/*) ;;
  *) die 3 "$ZY_M365_SERVER_BIN at $real is not under $HOME/.local — $ZY_M365_INSTALL_HINT" ;;
esac
[ -x "$real" ] || die 3 "$ZY_M365_SERVER_BIN at $real is not executable — $ZY_M365_INSTALL_HINT"

# --- 3. the access token (graph.sh is the only reader of the key) ------------------------------------------------------

# graph.sh's stderr is held back until its exit is known: on success its one "key: <source>" line passes through,
# on failure only its last line (the m365: reason) does, and its exit code is ours.
err_file="$(mktemp -t zyggy-m365-wrapper.XXXXXX)"
trap 'rm -f "$err_file"' EXIT
rc=0
access="$("$ZY_M365_SKILL_DIR/graph.sh" token 2> "$err_file")" || rc=$?
if [ "$rc" -ne 0 ]; then
  tail -n 1 "$err_file" >&2
  exit "$rc"
fi
cat "$err_file" >&2
rm -f "$err_file"
trap - EXIT
[ -n "$access" ] || die 6 "graph.sh token printed no token — runbook 13 \"Certificate rejected\""

# --- 4. the server, in a cleared environment ------------------------------------------------------------------------

server=(env -i
  PATH="/usr/bin:/bin:$HOME/.local/bin"
  HOME="$HOME"
  LC_ALL=C
  NODE_OPTIONS=--max-old-space-size=512
  MS365_MCP_OAUTH_TOKEN="$access"
  MS365_MCP_CLIENT_ID="$M365_CLIENT_ID"
  MS365_MCP_TENANT_ID="$M365_TENANT_ID"
  MS365_MCP_ORG_MODE=1
  MS365_MCP_USE_KEYTAR=0
  MS365_MCP_TOKEN_CACHE_PATH="$ZY_M365_STATE_DIR/never-written.json"
  ENABLED_TOOLS="$ZY_M365_ENABLED_TOOLS"
  "$real" --org-mode)
unset access

if [ "$probe" -eq 0 ]; then
  exec "${server[@]}"
fi

# --- 5. --probe: the handshake and tools/list over two FIFOs ------------------------------------------------------------

work="$(mktemp -d -t zyggy-m365-probe.XXXXXX)"
mkfifo -m 600 "$work/in" "$work/out"
pid="" to="" from=""
cleanup() {
  [ -z "$to" ] || exec {to}>&-
  [ -z "$from" ] || exec {from}<&-
  if [ -n "$pid" ]; then
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
# The server's stderr is not shown: it is the third party's diagnostics, and the token is in its environment.
"${server[@]}" < "$work/in" > "$work/out" 2> /dev/null &
pid=$!
# A server that exits early closes its end: writes then fail (EPIPE, not a signal) and reads see end of file.
trap '' PIPE
exec {to}> "$work/in" {from}< "$work/out"
deadline=$((SECONDS + ZY_M365_PROBE_SECONDS))

rpc_send() { # rpc_send <json>
  { printf '%s\n' "$1" 1>&"$to"; } 2> /dev/null || die 6 "server rejected ENABLED_TOOLS"
}

# Reads the server's lines until the response with id <n> arrives; prints it. Exit 6 at end of file or the deadline.
rpc_await() { # rpc_await <id>
  local line left
  while :; do
    left=$((deadline - SECONDS))
    [ "$left" -gt 0 ] || die 6 "server did not answer within ${ZY_M365_PROBE_SECONDS}s — $ZY_M365_INSTALL_HINT"
    IFS= read -r -t "$left" -u "$from" line || die 6 "server rejected ENABLED_TOOLS"
    if jq -e --argjson id "$1" '.id == $id' <<< "$line" > /dev/null 2>&1; then
      printf '%s\n' "$line"
      return 0
    fi
  done
}

rpc_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"zyggy-probe","version":"1"}}}'
rpc_await 1 > /dev/null
rpc_send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
rpc_send '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
response="$(rpc_await 2)"
names="$(jq -r '.result.tools[]?.name' <<< "$response" | LC_ALL=C sort -u)"

enabled="$(comm -12 <(printf '%s\n' "$names") <(printf '%s\n' "${ZY_M365_TOOLS_ENABLED[@]}" | LC_ALL=C sort))"
outside="$(comm -23 <(printf '%s\n' "$names") <(printf '%s\n' "${ZY_M365_TOOLS_ENABLED[@]}" | LC_ALL=C sort))"
unexpected="$(comm -23 <(printf '%s\n' "$outside") <(printf '%s\n' "${ZY_M365_AUTH_TOOLS[@]}" | LC_ALL=C sort) | sed '/^$/d')"
count="$(printf '%s' "$enabled" | grep -c . || true)"
[ "$count" -gt 0 ] || die 6 "server offered 0 tools — $ZY_M365_INSTALL_HINT"
if [ -n "$unexpected" ]; then
  die 6 "server offered tools outside ENABLED_TOOLS beyond the six auth tools ($(head -n 5 <<< "$unexpected" | paste -sd' ')$([ "$(grep -c . <<< "$unexpected")" -le 5 ] || printf ' …')) — $ZY_M365_INSTALL_HINT"
fi

printf 'tools: %s\n%s\n' "$count" "$enabled"
printf 'auth tools registered outside the filter: %s (denied by settings)\n' "$(printf '%s' "$outside" | paste -sd' ' | sed 's/^$/none/')"
printf 'env: %s\n' "$(printf '%s\n' "${server[@]:2:11}" | cut -d= -f1 | LC_ALL=C sort | paste -sd' ')"

#!/usr/bin/env bash
set -euo pipefail
# ZYGGY_M365_SERVER_STUB — test stand-in for @softeria/ms-365-mcp-server (installed as $HOME/.local/bin/
# ms-365-mcp-server by install_m365_server_stub). mcp-wrapper.sh starts the server in a cleared environment, so the
# stub finds everything beside itself: fixtures/tools-list-0.157.2.json (the pinned version's tools/list),
# fixtures/token-ok.json (the access token the curl stub hands out), server-stub.mode and server-stub.log.
# Logged before answering: argv, the environment's names (sorted), the value of every variable but the token,
# token=match|mismatch|absent, and the JSON-RPC methods received. Never the token itself.
# Answers newline-delimited JSON-RPC on stdin: initialize, tools/list; notifications get no answer. Like the real
# server (plan 23 Step 1 finding) tools/list is the list filtered by the received ENABLED_TOOLS regex
# (case-insensitive) plus the six auth tools, which the server registers outside the filter.
# Modes: ok (default) · notools (an empty list) · badregex (exit 1 at start, as the server does on an invalid
# filter) · leaky (the filter ignored: every tool offered).

here="$(cd "$(dirname "$0")" && pwd)"
log="$here/server-stub.log"
fixtures="$here/fixtures"
mode="$(cat "$here/server-stub.mode" 2> /dev/null || printf ok)"
readonly AUTH_TOOLS='^(login|logout|verify-login|list-accounts|select-account|remove-account)$'

{
  printf 'argv=%s\n' "$*"
  tr '\0' '\n' < "/proc/$$/environ" | cut -d= -f1 | LC_ALL=C sort | sed 's/^/env=/'
  for name in PATH HOME LC_ALL NODE_OPTIONS MS365_MCP_CLIENT_ID MS365_MCP_TENANT_ID MS365_MCP_ORG_MODE \
    MS365_MCP_USE_KEYTAR MS365_MCP_TOKEN_CACHE_PATH ENABLED_TOOLS; do
    if [ -n "${!name+x}" ]; then printf 'value=%s=%s\n' "$name" "${!name}"; fi
  done
  expected="$(jq -r '.access_token' "$fixtures/token-ok.json")"
  if [ -z "${MS365_MCP_OAUTH_TOKEN:-}" ]; then
    printf 'token=absent\n'
  elif [ "$MS365_MCP_OAUTH_TOKEN" = "$expected" ]; then
    printf 'token=match\n'
  else
    printf 'token=mismatch\n'
  fi
} >> "$log"

if [ "$mode" = badregex ]; then
  printf 'Without a valid filter, all tools would be exposed\n' >&2
  exit 1
fi
# an ERE grep cannot compile is an invalid filter too
rc=0
printf '' | grep -iE -- "${ENABLED_TOOLS:-}" > /dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  printf 'Without a valid filter, all tools would be exposed\n' >&2
  exit 1
fi

# HTTP mode (mcp-server.sh, plan 23 Step R8): the same start log above, then a loopback HTTP server in Node that
# answers per request (fixtures/http-stub.mjs); the token=… line above is "absent" — the server holds none.
for arg in "$@"; do
  if [ "$arg" = --http ]; then
    # node gets the environment the server got: bash's own PWD, SHLVL and _ removed
    node_bin="$(cat "$here/node.path" 2> /dev/null || true)"
    exec env -u PWD -u SHLVL -u _ "${node_bin:-node}" "$fixtures/http-stub.mjs" "$@"
  fi
done

# The tools/list result for this mode, compact.
tool_list() {
  case "$mode" in
    notools) printf '[]' ;;
    leaky) jq -c '.tools' "$fixtures/tools-list-0.157.2.json" ;;
    *)
      jq -c --arg re "${ENABLED_TOOLS:-^$}" --arg auth "$AUTH_TOOLS" \
        '[.tools[] | select((.name | test($re; "i")) or (.name | test($auth)))]' "$fixtures/tools-list-0.157.2.json"
      ;;
  esac
}

while IFS= read -r line; do
  method="$(jq -r '.method // empty' <<< "$line" 2> /dev/null || true)"
  id="$(jq -c '.id // empty' <<< "$line" 2> /dev/null || true)"
  printf 'rpc=%s\n' "${method:-invalid}" >> "$log"
  [ -n "$id" ] || continue
  case "$method" in
    initialize)
      jq -nc --argjson id "$id" '{jsonrpc: "2.0", id: $id, result: {protocolVersion: "2025-06-18",
        capabilities: {tools: {}}, serverInfo: {name: "ms-365-mcp-server-stub", version: "0.157.2"}}}'
      ;;
    tools/list)
      jq -nc --argjson id "$id" --argjson tools "$(tool_list)" '{jsonrpc: "2.0", id: $id, result: {tools: $tools}}'
      ;;
    *)
      jq -nc --argjson id "$id" '{jsonrpc: "2.0", id: $id, error: {code: -32601, message: "Method not found"}}'
      ;;
  esac
done

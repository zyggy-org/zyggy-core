#!/usr/bin/env bash
set -euo pipefail
# Runs the m365 MCP server for Claude Code over loopback HTTP (spec 23 D8; zyggy-m365-mcp.service starts it,
# .mcp.json points at http://127.0.0.1:<port>/mcp). Resolves the pinned @softeria/ms-365-mcp-server installed under
# ~/.local and replaces itself with it, in a cleared environment holding exactly the ten contracted variables (no
# token: every request carries its own bearer, minted by mcp-auth-header.sh for Claude Code), in org mode, with
# ENABLED_TOOLS = the allowlist of m365-lib.sh, bound to 127.0.0.1 only. Never mints a token, never opens the key.
# Two flags beyond the contract's argv, from the pinned source (plan 23 Step R8): --http-local-file-tools (HTTP mode
# otherwise hides download-bytes-to-file, which the brief and the files backfill use; the server refuses it unless
# bound to loopback) and --no-dynamic-registration (HTTP mode otherwise enables OAuth dynamic client registration).
# usage: mcp-server.sh [--probe]
#   --probe  against the running server: an unauthenticated POST must answer 401; then, with one header from
#            mcp-auth-header.sh handed to curl on stdin, initialize and tools/list; prints "tools: <n>" and the names
#            (they must be exactly the allowlist), "listen: 127.0.0.1:<port>" and "env:" the server's variable names.
# Exit 0 · 3 configuration or server installation · 4 usage · 6 a probe the server failed (or the helper's failure).
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"
# shellcheck source=m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/m365-lib.sh"

readonly ZY_M365_SERVER_BIN=ms-365-mcp-server ZY_M365_PROBE_SECONDS=20
readonly ZY_M365_INSTALL_HINT='runbook 13 "Install or upgrade the MCP server"' ZY_M365_DOWN_HINT='runbook 13 "MCP server down"'

die() { # die <exit code> <message>
  zy_die "$@"
}

# --- 1. arguments -------------------------------------------------------------------------------------------------

probe=0
if [ $# -gt 0 ]; then
  if [ "$1" != --probe ] || [ $# -ne 1 ]; then
    die 4 "unexpected argument '$1' (usage: mcp-server.sh [--probe])"
  fi
  probe=1
fi

# --- 2. the principal, the configuration, the port, the server binary ------------------------------------------------

zy_require_config
command -v jq > /dev/null || die 3 "jq not found"
# shellcheck disable=SC2119 # no argument: the full validation
zy_m365_load_config
zy_m365_port
listen="127.0.0.1:$ZY_M365_PORT"

# The pinned package is installed with npm's prefix ~/.local (runbook 13); a server found anywhere else — a
# package runner's cache, a system prefix, a symlink out of ~/.local — is not the reviewed one and never started.
bin="$(zy_m365_user_bin "$ZY_M365_SERVER_BIN")"
[ -n "$bin" ] || die 3 "$ZY_M365_SERVER_BIN not found — $ZY_M365_INSTALL_HINT"
real="$(readlink -f -- "$bin")"
home_real="$(readlink -f -- "$HOME")"
case "$real" in
  "$home_real"/.local/*) ;;
  *) die 3 "$ZY_M365_SERVER_BIN at $real is not under $HOME/.local — $ZY_M365_INSTALL_HINT" ;;
esac
[ -x "$real" ] || die 3 "$ZY_M365_SERVER_BIN at $real is not executable — $ZY_M365_INSTALL_HINT"

# --- 3. the server, in a cleared environment, on loopback -----------------------------------------------------------

server=(env -i
  PATH="/usr/bin:/bin:$HOME/.local/bin"
  HOME="$HOME"
  LC_ALL=C
  NODE_OPTIONS=--max-old-space-size=512
  MS365_MCP_CLIENT_ID="$M365_CLIENT_ID"
  MS365_MCP_TENANT_ID="$M365_TENANT_ID"
  MS365_MCP_ORG_MODE=1
  MS365_MCP_USE_KEYTAR=0
  MS365_MCP_TOKEN_CACHE_PATH="$ZY_M365_STATE_DIR/never-written.json"
  ENABLED_TOOLS="$ZY_M365_ENABLED_TOOLS"
  "$real" --org-mode --http "$listen" --http-local-file-tools --no-dynamic-registration)

if [ "$probe" -eq 0 ]; then
  # download-bytes-to-file writes into the callers' run directories under the shared download root
  zy_m365_download_root
  exec "${server[@]}"
fi

# --- 4. --probe: the running server, over curl -----------------------------------------------------------------------

curl_bin="$(command -v curl)" || die 3 "curl not found"
url="http://$listen/mcp"
work="$(mktemp -d -t zyggy-m365-probe.XXXXXX)"
trap 'rm -rf "$work"' EXIT

# One POST of <json>; the header lines (if any) come on stdin, so the bearer is never an argument. Prints the status.
post() { # post <json> < headers
  "$curl_bin" -sS --max-time "$ZY_M365_PROBE_SECONDS" -X POST -H @- -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' --data-raw "$1" -o "$work/body" -w '%{http_code}' "$url" \
    2> "$work/curl-err"
}

initialize='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"zyggy-probe","version":"1"}}}'
status="$(post "$initialize" < /dev/null)" || die 6 "no server at $listen ($(head -n 1 "$work/curl-err")) — $ZY_M365_DOWN_HINT"
[ "$status" = 401 ] || die 6 "an unauthenticated request got $status, not 401 — $ZY_M365_DOWN_HINT"

# Each authenticated POST gets its own header: the helper's one JSON line, turned into one header line by jq on a
# pipe and read by curl from stdin — never a file, never an argument.
authed() { # authed <json> → the status
  "$ZY_M365_SKILL_DIR/mcp-auth-header.sh" | jq -r '"Authorization: " + .Authorization' | post "$1"
}
status="$(authed "$initialize")" || die 6 "initialize failed ($(head -n 1 "$work/curl-err" 2> /dev/null))"
[ "$status" = 200 ] || die 6 "initialize answered $status — $ZY_M365_DOWN_HINT"
status="$(authed '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')" || die 6 "tools/list failed"
[ "$status" = 200 ] || die 6 "tools/list answered $status — $ZY_M365_DOWN_HINT"
names="$(jq -r '.result.tools[]?.name' "$work/body" | LC_ALL=C sort -u)"

expected="$(printf '%s\n' "${ZY_M365_TOOLS_ENABLED[@]}" | LC_ALL=C sort)"
unexpected="$(comm -23 <(printf '%s\n' "$names") <(printf '%s\n' "$expected") | sed '/^$/d')"
missing="$(comm -13 <(printf '%s\n' "$names") <(printf '%s\n' "$expected") | sed '/^$/d')"
[ -z "$unexpected" ] || die 6 "server offered tools outside ENABLED_TOOLS ($(head -n 5 <<< "$unexpected" | paste -sd' ')) — $ZY_M365_INSTALL_HINT"
[ -z "$missing" ] || die 6 "server did not offer $(head -n 5 <<< "$missing" | paste -sd' ') — $ZY_M365_INSTALL_HINT"

# The server's variable names (names only), from the process listening with this script's argv.
env_names="unknown"
for proc in /proc/[0-9]*; do
  if [ ! -O "$proc" ] || [ ! -r "$proc/environ" ]; then continue; fi
  cmdline="$(tr '\0' ' ' < "$proc/cmdline" 2> /dev/null || true)"
  [[ "$cmdline" == *" --http $listen "* ]] || continue
  env_names="$(tr '\0' '\n' < "$proc/environ" | cut -d= -f1 | LC_ALL=C sort | paste -sd' ')"
  break
done

printf 'tools: %s\n%s\n' "$(grep -c . <<< "$names")" "$names"
printf 'listen: %s\n' "$listen"
printf 'env: %s\n' "$env_names"

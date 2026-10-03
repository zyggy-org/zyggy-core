#!/usr/bin/env bash
set -euo pipefail
# ZYGGY_M365_CURL_STUB — test stand-in for curl (installed as graph-stub/curl by install_curl_stub). graph.sh runs
# curl under env -i, so the stub finds everything beside itself: fixtures/routes.tsv and the fixture bodies,
# curl-stub.scenario (one-shot overrides, consumed in order), curl-stub.log (every call, logged before deciding) and
# assertion.jwt (the client assertion it received, for the tests' signature checks). No network.
# It parses only what graph.sh sends: -sS, --proto =https, --max-time <s>, -X <M>, -H <header|@file>,
# --data-urlencode <k=v|k@-> / --data @- / --json @- (body from stdin), -o <file>, -D <file>, -w '%{http_code}',
# --data-raw <v>, -H @- (header lines on stdin), one URL. A URL http://127.0.0.1:<port>/… is the loopback MCP server
# stub: after the log line it is requested for real through fixtures/loopback-client.mjs (plan 23 Step R8). Exit 99:
# unroutable, unknown option or any write verb (graph.sh reads only, D7 — the one POST is the
# token request); 98: a /me request; 97: a DELETE (hard delete must never happen).
# The log holds markers (present|absent|match), never a key, an assertion or a token.

here="$(cd "$(dirname "$0")" && pwd)"
log="$here/curl-stub.log"
scenario="$here/curl-stub.scenario"
fixtures="$here/fixtures"

refuse() { # refuse <exit code> <message>
  printf 'stub: %s\n' "$2" >&2
  exit "$1"
}

argv="$(
  IFS=$'\037'
  printf '%s' "$*"
)"
# argv as received, Bearer values redacted (the token never reaches the log)
{
  printf 'argv=%s\n' "$(sed -E 's/Bearer [^\x1f]*/Bearer <redacted>/g' <<< "$argv")"
  tr '\0' '\n' < "/proc/$$/environ" | cut -d= -f1 | sort | sed 's/^/env=/'
} >> "$log"

method=""
url=""
out=/dev/stdout
dump=""
write_fmt=""
headers=()
form_keys=()
form_values=()
body=""
read_stdin=0
while [ $# -gt 0 ]; do
  case "$1" in
    -sS | -s | -S) shift ;;
    --proto)
      [ "${2:-}" = "=https" ] || refuse 99 "--proto must be =https"
      shift 2
      ;;
    --max-time)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || refuse 99 "--max-time needs seconds"
      shift 2
      ;;
    -X)
      method="${2:-}"
      shift 2
      ;;
    -H)
      [ $# -ge 2 ] || refuse 99 "-H needs a value"
      if [ "$2" = @- ]; then
        # header lines on stdin (mcp-server.sh --probe hands the bearer this way)
        while IFS= read -r line || [ -n "$line" ]; do
          [ -z "$line" ] || headers+=("$line")
        done
        read_stdin=1
      elif [[ "$2" == @* ]]; then
        [ -f "${2#@}" ] || refuse 99 "-H @file missing"
        while IFS= read -r line || [ -n "$line" ]; do
          [ -z "$line" ] || headers+=("$line")
        done < "${2#@}"
      else
        headers+=("$2")
      fi
      shift 2
      ;;
    --data-urlencode)
      [ $# -ge 2 ] || refuse 99 "--data-urlencode needs a value"
      if [[ "$2" == *@- ]]; then
        form_keys+=("${2%@-}")
        form_values+=("$(cat)")
        read_stdin=1
      elif [[ "$2" == *=* ]]; then
        form_keys+=("${2%%=*}")
        form_values+=("${2#*=}")
      else
        refuse 99 "--data-urlencode shape $2"
      fi
      shift 2
      ;;
    --data-raw)
      [ $# -ge 2 ] || refuse 99 "--data-raw needs a value"
      body="$2"
      shift 2
      ;;
    --data | --json)
      [ "${2:-}" = "@-" ] || refuse 99 "$1 must read stdin (@-)"
      body="$(cat)"
      read_stdin=1
      shift 2
      ;;
    -o)
      out="${2:-}"
      shift 2
      ;;
    -D)
      dump="${2:-}"
      shift 2
      ;;
    -w)
      write_fmt="${2:-}"
      shift 2
      ;;
    -*) refuse 99 "unknown option $1" ;;
    *)
      [ -z "$url" ] || refuse 99 "two URLs"
      url="$1"
      shift
      ;;
  esac
done
[ -n "$url" ] || refuse 99 "no URL"
if [ -z "$method" ]; then
  if [ "${#form_keys[@]}" -gt 0 ] || [ -n "$body" ] || [ "$read_stdin" -eq 1 ]; then method=POST; else method=GET; fi
fi

# --- the log line (before any decision) ------------------------------------------------------------------------

header_value() { # header_value <name> → value or ""
  local h v
  for h in "${headers[@]+"${headers[@]}"}"; do
    if [ "${h%%:*}" = "$1" ]; then
      v="${h#*:}"
      v="${v#"${v%%[![:space:]]*}"}"
      printf '%s' "$v"
      return 0
    fi
  done
  printf ''
}
form_value() { # form_value <key> → value or ""
  local i
  for i in "${!form_keys[@]}"; do
    if [ "${form_keys[$i]}" = "$1" ]; then
      printf '%s' "${form_values[$i]}"
      return 0
    fi
  done
  printf ''
}
present() { [ -n "$1" ] && printf present || printf absent; }
value_or_absent() { [ -n "$1" ] && printf '%s' "$1" || printf absent; }

names=""
if [ "${#headers[@]}" -gt 0 ]; then
  names="$(printf '%s\n' "${headers[@]}" | cut -d: -f1 | sort | paste -sd,)"
fi
auth="$(header_value Authorization)"
bearer=""
[[ "$auth" == Bearer\ * ]] && bearer="${auth#Bearer }"
prefer="$(header_value Prefer)"
assertion="$(form_value client_assertion)"
destination=""
if [ -n "$body" ]; then
  destination="$(sed -n 's/.*"destinationId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$body")"
fi
printf 'method=%s url=%s headers=%s prefer=%s bearer=%s client_secret=%s client_assertion=%s client_assertion_type=%s grant_type=%s scope=%s client_id=%s destinationId=%s\n' \
  "$method" "$url" "${names:-none}" "${prefer:-none}" "$(present "$bearer")" "$(present "$(form_value client_secret)")" \
  "$(present "$assertion")" "$(value_or_absent "$(form_value client_assertion_type)")" "$(value_or_absent "$(form_value grant_type)")" \
  "$(value_or_absent "$(form_value scope)")" "$(value_or_absent "$(form_value client_id)")" "$(value_or_absent "$destination")" >> "$log"
[ -z "$assertion" ] || printf '%s' "$assertion" > "$here/assertion.jwt"

# --- the loopback MCP server (plan 23 Step R8): a real request through Node, after the log line ----------------------

if [[ "$url" =~ ^http://127\.0\.0\.1:[0-9]+/ ]]; then
  set +e
  # the header lines (the bearer among them) reach jq and node on stdin, never as arguments
  status="$(if [ "${#headers[@]}" -gt 0 ]; then printf '%s\n' "${headers[@]}"; fi |
    jq -Rsc --arg m "$method" --arg u "$url" --arg b "$body" \
      '{method: $m, url: $u, headers: (split("\n") | map(select(length > 0))), body: $b}' |
    node "$fixtures/loopback-client.mjs" "$out")"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || exit "$rc"
  [ -z "$write_fmt" ] || printf '%s' "${write_fmt//%\{http_code\}/$status}"
  exit 0
fi

# --- the hard refusals -------------------------------------------------------------------------------------------

[[ "$url" =~ /me(/|\?|$) ]] && refuse 98 "/me requested"
[ "$method" != DELETE ] || refuse 97 "DELETE requested"
case "$method" in
  GET) ;;
  POST)
    [[ "$url" =~ /oauth2/v2\.0/token$ ]] || refuse 99 "write verb"
    ;;
  *) refuse 99 "write verb" ;;
esac

# --- the response: scenario first (one shot each), then the routes ------------------------------------------------

status=""
body_file=""
hdr_file=""
if [ -s "$scenario" ]; then
  mapfile -t lines < "$scenario"
  for i in "${!lines[@]}"; do
    line="${lines[$i]}"
    [ -n "$line" ] || continue
    re="${line%%:*}"
    rest="${line#*:}"
    if [[ "$url" =~ $re ]]; then
      IFS=: read -r status body_file hdr_file <<< "$rest"
      unset 'lines[i]'
      if [ "${#lines[@]}" -gt 0 ]; then printf '%s\n' "${lines[@]}" > "$scenario"; else : > "$scenario"; fi
      break
    fi
  done
fi
if [ -z "$status" ]; then
  while IFS=$'\t' read -r r_method r_re r_status r_body r_hdr || [ -n "$r_method" ]; do
    case "$r_method" in '' | '#'*) continue ;; esac
    if [ "$r_method" = "$method" ] && [[ "$url" =~ $r_re ]]; then
      status="$r_status"
      body_file="$r_body"
      hdr_file="$r_hdr"
      break
    fi
  done < "$fixtures/routes.tsv"
fi
[ -n "$status" ] || refuse 99 "unroutable $method $url"
[[ "$status" =~ ^[0-9]{3}$ ]] || refuse 99 "bad status $status"

if [ -n "$body_file" ] && [ "$body_file" != - ]; then
  [ -f "$fixtures/$body_file" ] || refuse 99 "body fixture $body_file missing"
  cat "$fixtures/$body_file" > "$out"
else
  : > "$out"
fi
if [ -n "$dump" ]; then
  {
    printf 'HTTP/1.1 %s\r\n' "$status"
    printf 'Content-Type: application/json\r\n'
    if [ -n "${hdr_file:-}" ] && [ "$hdr_file" != - ]; then
      [ -f "$fixtures/$hdr_file" ] || refuse 99 "header fixture $hdr_file missing"
      sed 's/\r$//; s/$/\r/' "$fixtures/$hdr_file"
    fi
    printf '\r\n'
  } > "$dump"
fi
[ -z "$write_fmt" ] || printf '%s' "${write_fmt//%\{http_code\}/$status}"
exit 0

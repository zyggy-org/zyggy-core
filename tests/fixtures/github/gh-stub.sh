#!/usr/bin/env bash
set -euo pipefail
# Test stand-in for the gh CLI (installed as bin/gh by install_gh_stub): emulates only the `gh api` calls
# of the github-inventory skill against the fixture pages in $GH_STUB_FIXTURES; no network.
# Every call is logged to $GH_STUB_LOG (argv joined by U+001F, then GH_TOKEN) before anything is decided.
# Exit 99: refused (write verb, unknown endpoint or option); 98: a call shape the skill must not make;
# 1: an injected or 404 failure. GH_STUB_FAIL=<endpoint glob>:<status>[:<message>], GH_STUB_NOTICE=1,
# GH_STUB_HEADERS=<file>, GH_STUB_REPOS=<file> select the variants.

argv="$(
  IFS=$'\037'
  printf '%s' "$*"
)"
printf 'argv=%s GH_TOKEN=%s\n' "$argv" "${GH_TOKEN:-unset}" >> "${GH_STUB_LOG:-/dev/null}"

refuse() { # refuse <exit code> <message>
  printf 'stub: %s\n' "$2" >&2
  exit "$1"
}

fixtures="${GH_STUB_FIXTURES:-}"
[ -d "$fixtures" ] || refuse 98 "GH_STUB_FIXTURES is not a directory"
[ "${1:-}" = api ] || refuse 99 "only gh api is emulated"
shift

method=""
include=0
jq_filter=""
endpoint=""
fields=()
headers=()
while [ $# -gt 0 ]; do
  case "$1" in
    --method | -X | -f | --raw-field | -F | --field | -H | --header | --jq | -q)
      [ $# -ge 2 ] || refuse 99 "$1 needs a value"
      case "$1" in
        --method | -X) method="$2" ;;
        -f | --raw-field | -F | --field) fields+=("$2") ;;
        -H | --header) headers+=("$2") ;;
        *) jq_filter="$2" ;;
      esac
      shift 2
      ;;
    --paginate) shift ;;
    -i | --include)
      include=1
      shift
      ;;
    -*) refuse 99 "unknown option $1" ;;
    *)
      [ -z "$endpoint" ] || refuse 99 "unknown endpoint $endpoint $1"
      endpoint="$1"
      shift
      ;;
  esac
done

# The real gh sends fields as a POST body unless --method GET is given.
if [ -n "$method" ] && [ "$method" != GET ]; then
  refuse 99 "write verb"
fi
if [ -z "$method" ] && [ "${#fields[@]}" -gt 0 ]; then
  refuse 99 "write verb"
fi
case "$endpoint" in
  user | user/repos | rate_limit) ;;
  *)
    [[ "$endpoint" =~ ^repos/[^/]+/[^/]+/readme$ ]] || refuse 99 "unknown endpoint $endpoint"
    ;;
esac

if [ "${GH_STUB_REPOS:-}" ]; then
  pages=("$fixtures/$GH_STUB_REPOS")
else
  pages=("$fixtures"/repos-page-*.json)
fi

if [ -n "${GH_STUB_FAIL:-}" ]; then
  fail_endpoint="${GH_STUB_FAIL%%:*}"
  rest="${GH_STUB_FAIL#*:}"
  fail_status="${rest%%:*}"
  fail_message="HTTP error"
  [[ "$rest" != *:* ]] || fail_message="${rest#*:}"
  # shellcheck disable=SC2254 # the endpoint may be a glob (repos/*/*/readme)
  case "$endpoint" in
    $fail_endpoint)
      # a user/repos failure happens after the first page: the caller has already received data
      [ "$endpoint" != user/repos ] || jq -c '.[]' "${pages[0]}"
      printf 'gh: %s (HTTP %s)\n' "$fail_message" "$fail_status" >&2
      exit 1
      ;;
  esac
fi

has_field() { # has_field <k=v>
  local f
  for f in "${fields[@]}"; do [ "$f" = "$1" ] && return 0; done
  return 1
}

case "$endpoint" in
  user)
    if [ "$include" -eq 1 ]; then
      cat "$fixtures/${GH_STUB_HEADERS:-user-headers.txt}"
      printf '\n'
    fi
    cat "$fixtures/user.json"
    ;;
  user/repos)
    [ "$method" = GET ] || refuse 98 "missing field --method GET"
    for f in per_page=100 sort=pushed affiliation=owner; do
      has_field "$f" || refuse 98 "missing field $f"
    done
    [ "$jq_filter" = '.[]' ] || refuse 98 "missing --jq '.[]'"
    for p in "${pages[@]}"; do jq -c '.[]' "$p"; done
    ;;
  rate_limit)
    cat "$fixtures/rate_limit.json"
    ;;
  repos/*/readme)
    raw=0
    for h in "${headers[@]}"; do [ "$h" = 'Accept: application/vnd.github.raw+json' ] && raw=1; done
    [ "$raw" -eq 1 ] || refuse 98 "readme without raw media type"
    repo="${endpoint#repos/}"
    repo="${repo%/readme}"
    readme="$fixtures/readme-${repo/\//-}.md"
    if [ ! -f "$readme" ]; then
      printf 'gh: Not Found (HTTP 404)\n' >&2
      exit 1
    fi
    cat "$readme"
    ;;
esac

if [ "${GH_STUB_NOTICE:-}" = 1 ]; then
  printf 'A new release of gh is available: 2.x.y → 2.x.z\n' >&2
fi
exit 0

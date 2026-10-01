#!/usr/bin/env bash
set -euo pipefail
# Clones one repository of the owner's own GitHub account, read-only and shallow, into the clone cache
# ${XDG_CACHE_HOME:-$HOME/.cache}/zyggy/repos/<owner>/<name> so its files can be read as data.
# usage: clone.sh <owner>/<name> | clone.sh --clean
# Exit 0 cloned or cleaned, 3 configuration error, 4 usage, 5 refused by policy, 6 GitHub or git request failed.
# The token reaches gh only as GH_TOKEN in one child's environment and git only through askpass.sh.
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"

readonly ZY_CLONE_MAX_MIB=500 ZY_CLONE_CACHE_MIB=2048 ZY_CLONE_AGE_DAYS=7 ZY_CLONE_RATE=5 ZY_CLONE_TIMEOUT=600

die() { # die <exit code> <message>
  printf 'github-clone: %s\n' "$2" >&2
  exit "$1"
}

usage() {
  die 4 "$1 (usage: clone.sh <owner>/<name> | clone.sh --clean)"
}

zy_hooks_off && die 5 "refused: unattended run (ZYGGY_HOOKS=off)"

mode=""
repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --clean)
      [ -z "$mode" ] || usage "--clean takes no other argument"
      mode=clean
      ;;
    -*) usage "unknown option '$1'" ;;
    *)
      [ -z "$mode" ] || usage "one repository at a time"
      mode=clone
      repo="$1"
      ;;
  esac
  shift
done
[ -n "$mode" ] || usage "no repository named"
owner=""
name=""
if [ "$mode" = clone ]; then
  [[ "$repo" == */* ]] || usage "'$repo' is not <owner>/<name>"
  owner="${repo%%/*}"
  name="${repo#*/}"
  name="${name%.git}"
  [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || usage "'$repo' is not <owner>/<name>"
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]{1,100}$ ]] || [ "$name" = . ] || [ "$name" = .. ]; then
    usage "'$repo' is not <owner>/<name>"
  fi
fi

zy_require_config

# True when <a> equals <b>, lies under it, or contains it.
zy_clone_overlaps() { # zy_clone_overlaps <a> <b>
  [ "$1" = "$2" ] || [[ "$1" == "$2"/* ]] || [[ "$2" == "$1"/* ]]
}

root="$(realpath -m "${XDG_CACHE_HOME:-$HOME/.cache}/zyggy/repos")"
checkout="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
mem="$(realpath -m "$ZYGGY_MEMORY_ROOT")"
if zy_clone_overlaps "$root" "$checkout" || zy_clone_overlaps "$root" "$mem"; then
  die 3 "clone cache $root must be outside the checkout and memory/"
fi
if [ -n "${ZYGGY_GITHUB_CLONE_BASE:-}" ]; then
  if [[ "$ZYGGY_GITHUB_CLONE_BASE" != /* || "$ZYGGY_GITHUB_CLONE_BASE" == *://* ]] || [ ! -d "$ZYGGY_GITHUB_CLONE_BASE" ]; then
    die 3 "ZYGGY_GITHUB_CLONE_BASE must be an absolute local directory (tests only)"
  fi
fi

# Clone directories are <root>/<owner>/<name>; temp siblings start with a dot and never count.
clone_dirs() { # clone_dirs [find tests]
  find "$root" -mindepth 2 -maxdepth 2 -type d ! -name '.*' "$@"
}

if [ "$mode" = clean ]; then
  n=0
  if [ -d "$root" ]; then
    n="$(clone_dirs | wc -l)"
    find "$root" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi
  printf 'cleaned: %s (%s clones removed)\n' "$root" "$n"
  exit 0
fi

for tool in "git" gh jq timeout; do
  command -v "$tool" > /dev/null || die 3 "$tool not found"
done

token_file="${ZYGGY_GITHUB_TOKEN_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/zyggy/github-read-token}"
[ -e "$token_file" ] || die 3 "token file $token_file not found"
[ -f "$token_file" ] || die 3 "token file $token_file is not a regular file"
token_mode="$(stat -c %a "$token_file")"
[ "$token_mode" = 600 ] || die 3 "token file $token_file must be mode 0600 (is $token_mode)"
[ "$(stat -c %u "$token_file")" = "$(id -u)" ] || die 3 "token file $token_file must be owned by $(id -un)"
token="$(tr -d '[:space:]' < "$token_file")"
[ -n "$token" ] || die 3 "token file $token_file is empty"

# Lowered bounds are honoured only together with the test base, i.e. never in a real clone.
max_mib="$ZY_CLONE_MAX_MIB"
if [ -n "${ZYGGY_GITHUB_CLONE_BASE:-}" ]; then
  max_mib="${ZYGGY_CLONE_MAX_MIB:-$max_mib}"
fi

if [ -d "$root" ]; then
  while IFS= read -r stale; do
    rm -rf "$stale"
    printf 'github-clone: removed %s (older than %s days)\n' "${stale#"$root"/}" "$ZY_CLONE_AGE_DAYS" >&2
  done < <(clone_dirs -mtime +$((ZY_CLONE_AGE_DAYS - 1)))
  if [ "$(clone_dirs -mmin -60 | wc -l)" -ge "$ZY_CLONE_RATE" ]; then
    die 5 "refused: clone limit reached ($ZY_CLONE_RATE per hour)"
  fi
fi

gh_err="$(mktemp)"
trap 'rm -f "$gh_err"' EXIT

# The only place the token leaves this script for gh: the environment of one gh child.
gh_get() { # gh_get <endpoint>
  GH_TOKEN="$token" gh api "$1" 2> "$gh_err"
}

github_failed() { # github_failed [reason]
  die 6 "GitHub request failed (${1:-$(head -n 1 "$gh_err")}) — see runbook \"GitHub token rejected\""
}

user_json="$(gh_get user)" || github_failed
login="$(jq -r .login <<< "$user_json")"
if [ "${owner,,}" != "${login,,}" ]; then
  die 5 "refused: $owner/$name is not a repository of $login (the token's account)"
fi

if ! repo_json="$(gh_get "repos/$login/$name")"; then
  if grep -q 'HTTP 404' "$gh_err"; then
    github_failed "$login/$name not found or not visible to the token"
  fi
  github_failed
fi
full="$(jq -r .full_name <<< "$repo_json")"
canon_owner="${full%%/*}"
canon_name="${full#*/}"
if [ "$(jq -r '.owner.login | ascii_downcase' <<< "$repo_json")" != "${login,,}" ] ||
  [ "$(jq -r .owner.type <<< "$repo_json")" != User ]; then
  die 5 "refused: $full is not a repository of $login (the token's account)"
fi
if [ "$(jq -r '.fork == true and .parent.private == true' <<< "$repo_json")" = true ]; then
  die 5 "refused: $full is a fork of a private repository owned by $(jq -r .parent.owner.login <<< "$repo_json")"
fi
size_kib="$(jq -r '.size // 0' <<< "$repo_json")"
mib=$(((size_kib + 1023) / 1024))
if [ "$mib" -gt "$max_mib" ]; then
  die 5 "refused: $full is $mib MiB (limit $max_mib MiB)"
fi

# Step 3 replaces this placeholder with the isolated git runner.
: "$canon_owner" "$canon_name" "$ZY_CLONE_CACHE_MIB" "$ZY_CLONE_TIMEOUT"
"$(command -v git)" --version > /dev/null
exit 0

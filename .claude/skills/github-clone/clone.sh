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

if [ "$mode" = clean ]; then
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

: "$owner" "$name" "$token" "$ZY_CLONE_MAX_MIB" "$ZY_CLONE_CACHE_MIB" "$ZY_CLONE_AGE_DAYS" "$ZY_CLONE_RATE" "$ZY_CLONE_TIMEOUT"
exit 0

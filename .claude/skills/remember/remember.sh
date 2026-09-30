#!/usr/bin/env bash
set -euo pipefail
# Keeps a fact the owner stated as one line in <memory>/<tenant>/<user>/inbox/remember-<local date>.md.
# usage: remember.sh [--scope general|project:<name>|machine] [--tag stated|observed] [--source <text>] -- "<fact>"
# Exit 0 kept, 2 refused (secret pattern), 3 configuration error, 4 usage. Never runs git.
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"

zy_hooks_off && exit 0
zy_require_config

usage() {
  printf 'remember: %s (usage: remember.sh [--scope general|project:<name>|machine] [--tag stated|observed] [--source <text>] -- "<fact>")\n' "$1" >&2
  exit 4
}

scope=general
tag=stated
source_text=""
fact=""
separator=0
while [ $# -gt 0 ]; do
  case "$1" in
    --scope | --tag | --source)
      [ $# -ge 2 ] || usage "$1 needs a value"
      case "$1" in
        --scope) scope="$2" ;;
        --tag) tag="$2" ;;
        --source) source_text="$(zy_collapse_line "$2")" ;;
      esac
      shift 2
      ;;
    --)
      shift
      fact="$*"
      separator=1
      break
      ;;
    *) usage "unexpected argument '$1'" ;;
  esac
done

[ "$separator" -eq 1 ] || usage "the fact must follow --"
fact="$(zy_collapse_line "$fact")"
[ -n "$fact" ] || usage "empty fact"
[ "$(zy_char_count "$fact")" -le 1000 ] || usage "fact longer than 1000 characters"
case "$scope" in
  general) hint="" ;;
  machine) hint=" (machine)" ;;
  project:*)
    [[ "${scope#project:}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage "invalid project name in --scope"
    hint=" ($scope)"
    ;;
  *) usage "--scope must be general, project:<name> or machine" ;;
esac
case "$tag" in
  stated | observed) ;;
  *) usage "--tag must be stated or observed" ;;
esac
[ "$tag" = stated ] || [ -n "$source_text" ] || usage "--tag observed needs --source"

for text in "$fact" "$source_text"; do
  if zy_secret_match "$text"; then
    printf 'refused: matches secret pattern %s\n' "$ZY_SECRET_NAME" >&2
    exit 2
  fi
done

today="$(zy_local_date)"
provenance=""
[ -z "$source_text" ] || provenance=" [$source_text]"
line="- [$tag] $today$hint$provenance: $fact"
file="$(cd "$(zy_user_dir)" && pwd)/inbox/remember-$today.md"

zy_atomic_append "$file" "remember $today" "facts stated by the owner on $today (remember skill)" "$line"
printf 'remembered: %s\n%s\n' "$file" "$line"

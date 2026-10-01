#!/usr/bin/env bash
set -euo pipefail
# GIT_ASKPASS helper of the github-clone skill: answers exactly git's two github.com prompts, the password read at
# prompt time from the 0600 token file named by ZYGGY_GITHUB_ASKPASS_FILE. Anything else is refused (exit 1).
# Never writes a file, never logs; called by git only.

refuse() {
  printf 'askpass: refused (%s)\n' "$1" >&2
  exit 1
}

case "${1:-}" in
  "Username for 'https://github.com': ")
    printf x-access-token
    ;;
  "Password for 'https://x-access-token@github.com': ")
    f="${ZYGGY_GITHUB_ASKPASS_FILE:-}"
    [ -n "$f" ] || refuse "no token file named"
    [ -f "$f" ] || refuse "token file missing or not a regular file"
    [ "$(stat -c %a "$f")" = 600 ] || refuse "token file not mode 0600"
    [ "$(stat -c %u "$f")" = "$(id -u)" ] || refuse "token file not owned by the caller"
    t="$(tr -d '[:space:]' < "$f")"
    [ -n "$t" ] || refuse "token file empty"
    printf '%s' "$t"
    ;;
  *) refuse "unexpected prompt" ;;
esac

#!/usr/bin/env bash
set -euo pipefail
# Test stand-in for git (installed as bin/git by install_git_spy). clone.sh runs git under env -i, so the spy finds
# its log and mode next to its own directory: ../git-spy.log, ../git-spy.mode (ok | fail-auth | fail-secret | sleep).
# Per call it logs argv (joined by U+001F), cwd and the environment it was started with (from /proc, so nothing
# this script adds); on clone it asks GIT_ASKPASS both prompts and logs the username and whether the password
# matched the token file. It never logs the password itself.

here="$(cd "$(dirname "$0")" && pwd)"
log="$here/../git-spy.log"
mode="$(cat "$here/../git-spy.mode" 2> /dev/null || printf ok)"

argv="$(
  IFS=$'\037'
  printf '%s' "$*"
)"
{
  printf 'argv=%s\n' "$argv"
  printf 'cwd=%s\n' "$PWD"
  tr '\0' '\n' < "/proc/$$/environ" | sort | sed 's/^/env=/'
} >> "$log"

# The subcommand: skip -c <k=v> and -C <dir> pairs.
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    -c | -C) i=$((i + 2)) ;;
    *) break ;;
  esac
done
sub="${args[$i]:-}"

case "$sub" in
  clone)
    user="$("$GIT_ASKPASS" "Username for 'https://github.com': ")"
    printf 'username=%s\n' "$user" >> "$log"
    pw="$("$GIT_ASKPASS" "Password for 'https://x-access-token@github.com': ")"
    if [ "$pw" = "$(tr -d '[:space:]' < "$ZYGGY_GITHUB_ASKPASS_FILE")" ]; then
      printf 'password=match\n' >> "$log"
    else
      printf 'password=mismatch\n' >> "$log"
    fi
    case "$mode" in
      fail-auth)
        printf "fatal: Authentication failed for 'https://github.com/alice/repo.git/'\n" >&2
        exit 128
        ;;
      fail-secret)
        printf 'fatal: unable to access: github_pat_11SPYSPY0123456789_spyspyspyspyspyspyspyspyspy\n' >&2
        exit 128
        ;;
      sleep) sleep 30 ;;
    esac
    target="${args[${#args[@]} - 1]}"
    mkdir -p "$target/.git"
    printf '# repo\n' > "$target/README.md"
    ;;
  rev-parse)
    if [ "${args[$((i + 1))]:-}" = --abbrev-ref ]; then
      printf 'main\n'
    else
      printf '0123456789abcdef0123456789abcdef01234567\n'
    fi
    ;;
  ls-files) printf 'README.md\n' ;;
  log) printf '2026-09-29\n' ;;
  remote) ;;
  *)
    printf 'spy: unexpected git call %s\n' "$sub" >&2
    exit 97
    ;;
esac

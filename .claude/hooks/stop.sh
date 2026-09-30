#!/usr/bin/env bash
set -euo pipefail
# Stop hook: appends one line per finished turn to <memory>/<tenant>/<user>/daily/<local date>.md:
#   - [observed] HH:MM session <first 8 chars of session_id>: <first non-empty line of the last message>
# Never prints on stdout (nothing is fed back to the model), never blocks: exit 0 in every case except a
# configuration error (3). One stderr line on a refused note or when the daily cap is reached. Never runs git.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly MAX_HOOK_LINES=150 # per day; changing it is a zyggy-core commit (data-protection control)
readonly MAX_NOTE_CHARS=240
readonly CAP_MARKER='- [observed] cap reached: no further hook lines today'

zy_hooks_off && exit 0
zy_require_config
command -v jq > /dev/null || zy_die 3 "jq not found"

input="$(zy_read_stdin_json)"
# Unparseable input: nothing to note; the session must not be disturbed.
fields="$(jq -r '[(.stop_hook_active == true), (.session_id // "" | tostring)] | @tsv' <<< "$input" 2> /dev/null)" || exit 0
[ -n "$fields" ] || exit 0
IFS=$'\t' read -r active session_id <<< "$fields"
[ "$active" = false ] || exit 0

message="$(jq -r '.last_assistant_message // "" | tostring' <<< "$input")"
note="$(zy_collapse_line "$(tr -d $'\r' <<< "$message" | awk 'NF { print; exit }')")"
[ -n "$note" ] || exit 0
note="$(
  LC_ALL=C.UTF-8
  if [ "${#note}" -gt "$MAX_NOTE_CHARS" ]; then
    printf '%s…' "${note:0:MAX_NOTE_CHARS}"
  else
    printf '%s' "$note"
  fi
)"

if zy_secret_match "$note"; then
  printf 'stop: note refused (pattern %s)\n' "$ZY_SECRET_NAME" >&2
  exit 0
fi

today="$(zy_local_date)"
file="$(zy_user_dir)/daily/$today.md"
if [ -f "$file" ]; then
  grep -qxF -- "$CAP_MARKER" "$file" && exit 0
  hook_lines="$(grep -cE '^- \[observed\] [0-9]{2}:[0-9]{2} session ' "$file" || true)"
  if [ "$hook_lines" -ge "$MAX_HOOK_LINES" ]; then
    zy_atomic_append "$file" "daily $today" "turn notes of $today written by the Stop hook" "$CAP_MARKER"
    printf 'stop: daily cap of %s hook lines reached for %s\n' "$MAX_HOOK_LINES" "$today" >&2
    exit 0
  fi
fi

zy_atomic_append "$file" "daily $today" "turn notes of $today written by the Stop hook" \
  "- [observed] $(zy_local_hhmm) session ${session_id:0:8}: $note"

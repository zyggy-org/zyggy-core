#!/usr/bin/env bash
set -euo pipefail
# A downloaded document becomes bounded text and nothing else (spec 23): MarkItDown runs on one file inside the run
# directory ($ZYGGY_M365_RUN_DIR, created by the orchestrator or ~/.cache/zyggy-m365-downloads/<session>/ in a conversation),
# under `timeout` and `ulimit -v`; the text goes to stdout only, control characters removed, every line that matches
# a secret pattern replaced by "[line withheld: matches secret pattern <name>]", cut at file_text_cap_bytes with a
# "[cut at <n> bytes]" line. The input file is deleted in every case once it is known to be inside the run directory
# (a symlink inside is removed, never its target); a file outside is refused and left alone.
# usage: parse.sh <file inside ZYGGY_M365_RUN_DIR>
# Types: docx xlsx pptx pdf txt md csv json html htm. Caps: the smaller of brief's and files_backfill's
# file_max_bytes and file_text_cap_bytes (instance/m365.json). ZYGGY_PARSE_TIMEOUT (seconds) is honoured only with
# ZYGGY_M365_STUB=1 (tests); otherwise MarkItDown gets 120 s.
# stderr on success: "parse: <name> <n> lines, <w> withheld[, cut at <n> bytes]".
# Exit 0 · 3 configuration (run directory, m365.json, markitdown missing) · 4 usage · 5 refused (outside the run
# directory, not a regular file, over the size cap, type not parsable) · 6 MarkItDown failed or timed out.
# Accepts ZYGGY_HOOKS=off (the brief and the files backfill run unattended).
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"
# shellcheck source=m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/m365-lib.sh"
ZY_SELF=parse

readonly ZY_PARSE_TIMEOUT_S=120 ZY_PARSE_MEMORY_KB=2097152 ZY_PARSE_ERROR_CHARS=200
readonly ZY_PARSE_TYPES=' docx xlsx pptx pdf txt md csv json html htm '

die() { # die <exit code> <message>
  zy_die "$@"
}

usage() {
  die 4 "$1 (usage: parse.sh <file inside ZYGGY_M365_RUN_DIR>)"
}

# --- 1. the argument, the run directory and containment ------------------------------------------------------------

[ $# -gt 0 ] || usage "no file given"
[ $# -eq 1 ] || usage "one file only"
input="$1"
[ -n "$input" ] || usage "no file given"

[ -n "${ZYGGY_M365_RUN_DIR:-}" ] || die 3 "configuration error: ZYGGY_M365_RUN_DIR is not set"
[ -d "$ZYGGY_M365_RUN_DIR" ] || die 3 "configuration error: ZYGGY_M365_RUN_DIR $ZYGGY_M365_RUN_DIR is not a directory"
run_lexical="$(realpath -m -s -- "$ZYGGY_M365_RUN_DIR")"
run_real="$(realpath -e -- "$ZYGGY_M365_RUN_DIR")"

# Inside means: the path as written (no symlink followed) is under the run directory, and so is the file it reaches.
path_lexical="$(realpath -m -s -- "$input")"
[[ "$path_lexical" == "$run_lexical"/* ]] || die 5 "refused: not in the run directory"
if [ -L "$path_lexical" ]; then
  rm -f -- "$path_lexical"
  die 5 "refused: not in the run directory"
fi
path_real="$(realpath -m -- "$input")"
[[ "$path_real" == "$run_real"/* ]] || die 5 "refused: not in the run directory"

# From here the input is ours to delete, whatever happens.
work=""
cleanup() {
  rm -f -- "$path_real"
  [ -z "$work" ] || rm -rf -- "$work"
}
trap cleanup EXIT

name="$(basename -- "$path_real")"
[ -f "$path_real" ] || die 5 "refused: $name is not a regular file"

# --- 2. configuration and tools ------------------------------------------------------------------------------------

command -v jq > /dev/null || die 3 "jq not found"
# shellcheck disable=SC2119 # no argument: the full validation (the caps of brief and files_backfill included)
zy_m365_load_config
max_bytes="$(jq -r '[.brief.file_max_bytes, .files_backfill.file_max_bytes] | min' <<< "$ZY_M365_CONFIG_JSON")"
cap_bytes="$(jq -r '[.brief.file_text_cap_bytes, .files_backfill.file_text_cap_bytes] | min' <<< "$ZY_M365_CONFIG_JSON")"
markitdown="$(zy_m365_user_bin markitdown)"
[ -n "$markitdown" ] || die 3 "markitdown not found — runbook 13 \"MarkItDown\""
command -v timeout > /dev/null || die 3 "timeout not found"
timeout_s="$ZY_PARSE_TIMEOUT_S"
if [ "${ZYGGY_M365_STUB:-}" = 1 ] && [[ "${ZYGGY_PARSE_TIMEOUT:-}" =~ ^[1-9][0-9]{0,2}$ ]]; then
  timeout_s="$ZYGGY_PARSE_TIMEOUT"
fi

# --- 3. size and type ----------------------------------------------------------------------------------------------

size="$(stat -c %s -- "$path_real")"
[ "$size" -le "$max_bytes" ] || die 5 "refused: $name is $size bytes (limit $max_bytes)"
ext=""
[[ "$name" != *.* ]] || ext="${name##*.}"
[[ -n "$ext" && "$ZY_PARSE_TYPES" == *" ${ext,,} "* ]] || die 5 "refused: type ${ext:+.}${ext:-(none)} not parsable"

# --- 4. MarkItDown, bounded ------------------------------------------------------------------------------------------

work="$(mktemp -d)"
rc=0
(
  ulimit -v "$ZY_PARSE_MEMORY_KB"
  exec timeout "$timeout_s" "$markitdown" "$path_real"
) > "$work/text" 2> "$work/err" < /dev/null || rc=$?
if [ "$rc" -eq 124 ]; then
  die 6 "markitdown timed out after $timeout_s s"
elif [ "$rc" -ne 0 ]; then
  first="$(zy_collapse_line "$(head -n 1 "$work/err" | tr -d '\000-\010\013-\037\177')")"
  if zy_secret_match "$first"; then
    first="first error line withheld: matches secret pattern $ZY_SECRET_NAME"
  fi
  LC_ALL=C.UTF-8
  die 6 "markitdown failed (${first:0:ZY_PARSE_ERROR_CHARS})"
fi

# --- 5. the text: control characters out, secret-shaped lines withheld, cut at the cap ------------------------------

# Only the head of the text is ever looked at: the cap plus a margin, so the line the cut falls in is checked whole.
head -c "$((cap_bytes + 4096))" "$work/text" | tr -d '\000-\010\013\014\016-\037\177' | tr -d '\r' > "$work/clean"
mapfile -t lines < "$work/clean"
declare -A withheld=()

# Withhold every line matching a secret pattern: one zy_secret_match over a block of lines, halved down to the lines
# that match (a document without secrets costs one check).
withhold() { # withhold <first index> <count>
  local from="$1" count="$2" half
  [ "$count" -gt 0 ] || return 0
  zy_secret_match "$(printf '%s\n' "${lines[@]:from:count}")" || return 0
  if [ "$count" -eq 1 ]; then
    withheld["$from"]="$ZY_SECRET_NAME"
    return 0
  fi
  half=$((count / 2))
  withhold "$from" "$half"
  withhold "$((from + half))" "$((count - half))"
}
withhold 0 "${#lines[@]}"

for i in "${!lines[@]}"; do
  if [ -n "${withheld[$i]:-}" ]; then
    printf '[line withheld: matches secret pattern %s]\n' "${withheld[$i]}"
  else
    printf '%s\n' "${lines[$i]}"
  fi
done > "$work/out"

note=""
if [ "$(stat -c %s "$work/out")" -gt "$cap_bytes" ]; then
  head -c "$cap_bytes" "$work/out" > "$work/final"
  # $(…) drops a final newline: empty means the cut fell right after one
  [ -z "$(tail -c 1 "$work/final")" ] || printf '\n' >> "$work/final"
  note=", cut at $cap_bytes bytes"
else
  mv -f "$work/out" "$work/final"
fi
# Counted in what is printed: a line withheld beyond the cut is not shown, so not counted.
shown="$(grep -c '' "$work/final" || true)"
hidden="$(grep -c '^\[line withheld: matches secret pattern [a-z0-9-]*\]$' "$work/final" || true)"
cat "$work/final"
[ -z "$note" ] || printf '[cut at %s bytes]\n' "$cap_bytes"
printf 'parse: %s %s lines, %s withheld%s\n' "$name" "$((shown - hidden))" "$hidden" "$note" >&2

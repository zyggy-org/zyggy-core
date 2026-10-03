#!/usr/bin/env bash
set -euo pipefail
# The model's part of one files-backfill batch, emulated for files-backfill.sh's tests (run by the claude stub as
# CLAUDE_STUB_ACTIONS, in the run's environment: ZYGGY_HOOKS=off, ZYGGY_M365_RUN_DIR = the batch's run directory, no
# terminal, the project directory as the working directory). It reads the batch's prompt from the stub's log (the
# stub logs its argv before running the actions; the prompt's first line is its arg= line, the batch's file lines
# follow it): "/files-backfill <drive-id> <run-dir> <n>", then "<zyggy-m365-data>", one
# "<item-id><TAB><extension><TAB><modified date><TAB><path>" line per file, "</zyggy-m365-data>".
# It downloads the first file (bytes written into the run directory as <item-id>.<extension>, as
# download-bytes-to-file would), parses it with the real parse.sh (the markitdown stub answers), writes the facts of
# facts-backfill.txt through the real facts.sh with that file's provenance, and answers with
# claude-result-files-batch.json whose counts line it builds from the batch: listed <n>, parsed <n>, facts 4.
# FILES_MODEL_SKIP=<drive-id> reports one of the files as a parse error; FILES_UNCONFIRMED=<drive-id> answers without
# a counts line. It never touches state.sh: the cursor is files-backfill.sh's.
# Logs "files-batch=<drive-id> <n> <run-dir> <run-dir mode> parse=<parse.sh exit> left=<yes|no>" and
# "files-items=<drive-id> <item-id>…".

fixtures="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
log="${CLAUDE_STUB_LOG:?}"
prompt="$(awk '/^call$/ { n = 0; next } /^arg=/ { if (++n == 2) p = substr($0, 5) } END { print p }' "$log")"
read -r skill drive run_dir count _rest <<< "$prompt"
[ "$skill" = /files-backfill ] || { printf 'files-actions: unexpected prompt %s\n' "$prompt"; exit 1; }
[ "$run_dir" = "${ZYGGY_M365_RUN_DIR:-}" ] || { printf 'files-actions: run dir %s is not ZYGGY_M365_RUN_DIR\n' "$run_dir"; exit 1; }
# the file lines of the last call's prompt: the lines after its first line, inside the fence
mapfile -t lines < <(awk '/^call$/ { n = 0; p = 0; k = 0; next }
  /^arg=/ { p = (++n == 2); next }
  p && $0 != "<zyggy-m365-data>" && $0 != "</zyggy-m365-data>" { f[++k] = $0 }
  END { for (i = 1; i <= k; i++) print f[i] }' "$log")
[ "${#lines[@]}" -eq "$count" ] || { printf 'files-actions: %s file lines for a batch of %s\n' "${#lines[@]}" "$count"; exit 1; }

counter="$log.batches-$drive"
n=0
[ ! -f "$counter" ] || n="$(cat "$counter")"
n=$((n + 1))
printf '%s\n' "$n" > "$counter"

IFS=$'\t' read -r id ext modified path <<< "${lines[0]}"
printf 'PK fake document bytes\n' > "$run_dir/$id.$ext"
parse_rc=0
.claude/skills/m365/parse.sh "$run_dir/$id.$ext" > /dev/null 2>&1 || parse_rc=$?
left=no
[ ! -e "$run_dir/$id.$ext" ] || left=yes
.claude/skills/m365/facts.sh --kind files-backfill --source "m365-file $drive:$path $modified" < "$fixtures/facts-backfill.txt"

parsed="$count"
errors=0
if [ "${FILES_MODEL_SKIP:-}" = "$drive" ]; then
  parsed=$((count - 1))
  errors=1
fi
text="Batch read."
if [ "${FILES_UNCONFIRMED:-}" != "$drive" ]; then
  text+=$'\n'"files-backfill batch: listed $count, parsed $parsed, skipped $errors (type 0, size 0, path 0, parse error $errors, secret pattern 0), facts 4 (0 dup, 0 refused)"
fi
jq --arg t "$text" '.result = $t' "$fixtures/claude-result-files-batch.json" > "$CLAUDE_STUB_RESULT"
printf 'files-batch=%s %s %s %s parse=%s left=%s\n' "$drive" "$n" "$run_dir" "$(stat -c %a "$run_dir")" "$parse_rc" "$left"
printf 'files-items=%s %s\n' "$drive" "$(printf '%s\n' "${lines[@]}" | cut -f1 | paste -sd' ')"

#!/usr/bin/env bash
set -euo pipefail
# The model's part of one files-backfill batch, emulated for files-backfill.sh's tests (run by the claude stub as
# CLAUDE_STUB_ACTIONS, in the run's environment: ZYGGY_HOOKS=off, ZYGGY_M365_RUN_DIR = the batch's run directory, no
# terminal, the project directory as the working directory). It reads the batch's prompt from the stub's log (the
# stub logs its argv before running the actions): "/files-backfill <drive-id> <run-dir> <batch>[ skip paths under: …]".
# The first FILES_BATCHES (default 2) batches of a drive list files: one downloaded document (bytes written into the
# run directory, as download-bytes-to-file would) parsed by the real parse.sh (the markitdown stub answers), the facts
# of facts-backfill.txt through the real facts.sh, then the drive's files-backfill watermark set to
# 2026-09-0<n>T08:00:00Z through the real state.sh (last, as the skill says), and the stub answers with
# claude-result-files-batch.json; every later batch of that drive lists none (claude-result-files-empty.json).
# FILES_FORBIDDEN=<drive-id> answers claude-result-files-forbidden.json for that drive and does nothing else;
# FILES_STUCK=<drive-id> never sets that drive's watermark. Batches per drive are counted in files beside the log.
# Logs "files-batch=<drive-id> <n> <run-dir> <run-dir mode> parse=<parse.sh exit> left=<yes|no>".

fixtures="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
log="${CLAUDE_STUB_LOG:?}"
prompt="$(awk '/^call$/ { n = 0; next } /^arg=/ { if (++n == 2) p = substr($0, 5) } END { print p }' "$log")"
read -r skill drive run_dir _batch _rest <<< "$prompt"
[ "$skill" = /files-backfill ] || { printf 'files-actions: unexpected prompt %s\n' "$prompt"; exit 1; }
[ "$run_dir" = "${ZYGGY_M365_RUN_DIR:-}" ] || { printf 'files-actions: run dir %s is not ZYGGY_M365_RUN_DIR\n' "$run_dir"; exit 1; }

counter="$log.batches-$drive"
n=0
[ ! -f "$counter" ] || n="$(cat "$counter")"
n=$((n + 1))
printf '%s\n' "$n" > "$counter"

parse_rc=-
left=no
if [ "${FILES_FORBIDDEN:-}" = "$drive" ]; then
  cp "$fixtures/claude-result-files-forbidden.json" "$CLAUDE_STUB_RESULT"
elif [ "$n" -le "${FILES_BATCHES:-2}" ]; then
  printf 'PK fake document bytes\n' > "$run_dir/report.docx"
  parse_rc=0
  .claude/skills/m365/parse.sh "$run_dir/report.docx" > /dev/null 2>&1 || parse_rc=$?
  [ ! -e "$run_dir/report.docx" ] || left=yes
  .claude/skills/m365/facts.sh --kind files-backfill --source "m365-file $drive:/Reports/report.docx 2026-09-12" \
    < "$fixtures/facts-backfill.txt"
  if [ "${FILES_STUCK:-}" != "$drive" ]; then
    .claude/skills/m365/state.sh set files-backfill-watermark "$drive" "2026-09-0${n}T08:00:00Z"
  fi
  cp "$fixtures/claude-result-files-batch.json" "$CLAUDE_STUB_RESULT"
else
  cp "$fixtures/claude-result-files-empty.json" "$CLAUDE_STUB_RESULT"
fi
printf 'files-batch=%s %s %s %s parse=%s left=%s\n' "$drive" "$n" "$run_dir" "$(stat -c %a "$run_dir")" "$parse_rc" "$left"

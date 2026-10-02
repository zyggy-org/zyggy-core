#!/usr/bin/env bash
set -euo pipefail
# The model's part of one mail-backfill batch, emulated for mail-backfill.sh's tests (run by the claude stub as
# CLAUDE_STUB_ACTIONS, in the run's environment: ZYGGY_HOOKS=off, no terminal, the project directory as the working
# directory). It reads the batch's prompt from the stub's log (the stub logs its argv before running the actions):
# "/mail-backfill <mailbox> <folder-id> <watermark> <batch>". The first BACKFILL_BATCHES (default 2) batches of a
# folder list messages: the facts of facts-backfill.txt through the real facts.sh, then the watermark one day older
# through the real state.sh (last, as the skill says), and the stub answers with claude-result-backfill-batch.json;
# every later batch of that folder lists none and answers with claude-result-backfill-empty.json. The answer is
# copied to CLAUDE_STUB_RESULT, which the stub prints after the actions. BACKFILL_STUCK=<folder-id> never sets that
# folder's watermark (the "watermark not advanced" case). Batches per folder are counted in files beside the log.

fixtures="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
log="${CLAUDE_STUB_LOG:?}"
prompt="$(awk '/^call$/ { n = 0; next } /^arg=/ { if (++n == 2) p = substr($0, 5) } END { print p }' "$log")"
read -r skill _mailbox folder watermark _batch <<< "$prompt"
[ "$skill" = /mail-backfill ] || { printf 'backfill-actions: unexpected prompt %s\n' "$prompt"; exit 1; }

counter="$log.batches-$folder"
n=0
[ ! -f "$counter" ] || n="$(cat "$counter")"
n=$((n + 1))
printf '%s\n' "$n" > "$counter"

if [ "$n" -le "${BACKFILL_BATCHES:-2}" ]; then
  .claude/skills/m365/facts.sh --kind mail-backfill --source "m365-mail 2026-09-12 Quarterly planning" \
    < "$fixtures/facts-backfill.txt"
  if [ "${BACKFILL_STUCK:-}" != "$folder" ]; then
    older="$(date -u -d "@$(($(date -u -d "$watermark" +%s) - 86400))" +%Y-%m-%dT%H:%M:%SZ)"
    .claude/skills/m365/state.sh set backfill-watermark "$folder" "$older"
  fi
  cp "$fixtures/claude-result-backfill-batch.json" "$CLAUDE_STUB_RESULT"
else
  cp "$fixtures/claude-result-backfill-empty.json" "$CLAUDE_STUB_RESULT"
fi
printf 'backfill-batch=%s %s %s\n' "$folder" "$n" "$watermark"

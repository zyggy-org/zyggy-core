#!/usr/bin/env bash
set -euo pipefail
# The whole-mailbox backfill of the m365 connector (spec 23 Q7, AC-17, AC-42): owner-started (in tmux, may run
# unwatched), it turns every mail of the mailbox into validated fact lines in memory inbox/, newest first, in
# resumable, cost-capped batches. Facts only: the batch's model reads mail and writes through facts.sh and state.sh;
# ZY_M365_MAIL_BACKFILL_DENY denies the Draft tools, the drive tools, parse.sh and the proposal script.
# Order: refused under ZYGGY_HOOKS=off → the arguments → configuration and claude (before any request) → graph.sh
# token (fails fast on the identity) → the folders from graph.sh mail-folders minus mail_backfill.exclude_folders →
# per folder, until a batch lists 0 messages: claude -p "/mail-backfill <mailbox> <folder-id> <watermark> <batch>"
# with the batch caps; the new watermark read back from state.sh (the model sets it last); the checkpoint
# mail-backfill.json (0600) rewritten after each completed batch with its messages, facts, turns and cost. The totals
# (budget_usd_total, max_facts, max_messages; 0 = no cap for the last two) are checked before every batch.
# A watermark that did not move stops that folder (exit 5 at the end); SIGINT/SIGTERM stop the claude child and exit
# without writing: the checkpoint of the last completed batch stands and the next run says "resuming folder <name>
# from <watermark>". --reset clears the checkpoint and every backfill watermark, then starts again from now.
# usage: mail-backfill.sh [--folder <name>] [--reset]     (<name>: display name, well-known name or folder id)
# stdout: one line per folder start, batch and folder end, then the counts line "mail-backfill: done|stopped —
# folders <k> (excluded <e>), messages <n>, batches <b>, facts <f> (<d> duplicates dropped, <s> refused), turns <t>,
# cost <usd> (cap <cap>)" (totals of the whole backfill, across resumed runs).
# Exit 0 done · 3 configuration · 4 usage · 5 refused unattended, a cap reached or a watermark not advanced
# (checkpoint intact) · 6 identity, Graph or model-run failure · 130/143 interrupted.
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"
# shellcheck source=m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/m365-lib.sh"
ZY_SELF=mail-backfill

readonly ZY_MB_COUNTS_RE='^mail-backfill batch: messages ([0-9]+), facts ([0-9]+) \(([0-9]+) dup, ([0-9]+) refused\)$'
readonly ZY_MB_RUNBOOK='runbook 13 "Model run failed"'
readonly ZY_MB_STATE_ARG_RE='^[A-Za-z0-9!_=-]{1,200}$'

die() { # die <exit code> <message>
  zy_die "$@"
}

usage() {
  die 4 "$1 (usage: mail-backfill.sh [--folder <name>] [--reset])"
}

# --- 1. the principal: an owner's terminal session, never the unit ----------------------------------------------------

! zy_hooks_off || die 5 "refused: unattended run (ZYGGY_HOOKS=off)"

# --- 2. the arguments, the configuration, the tools (no request yet) --------------------------------------------------

folder_arg=""
have_folder=0
reset=0
while [ $# -gt 0 ]; do
  case "$1" in
    --folder)
      [ "$have_folder" -eq 0 ] || usage "--folder given twice"
      if [ $# -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then usage "--folder needs <name>"; fi
      folder_arg="$2"
      have_folder=1
      shift 2
      ;;
    --reset)
      [ "$reset" -eq 0 ] || usage "--reset given twice"
      reset=1
      shift
      ;;
    *) usage "unknown argument '${1:0:40}'" ;;
  esac
done

zy_require_config
command -v jq > /dev/null || die 3 "jq not found"
# shellcheck disable=SC2119 # no argument: the full validation
zy_m365_load_config
zy_m365_claude
batch="$(zy_m365_cfg .mail_backfill.batch_messages)"
[ "$batch" -ge 1 ] || die 3 "configuration error: mail_backfill.batch_messages must be at least 1"
max_turns="$(zy_m365_cfg .mail_backfill.max_turns)"
budget_batch="$(zy_m365_cfg .mail_backfill.budget_usd_per_batch)"
budget_total="$(zy_m365_cfg .mail_backfill.budget_usd_total)"
max_facts="$(zy_m365_cfg .mail_backfill.max_facts)"
max_messages="$(zy_m365_cfg .mail_backfill.max_messages)"
model="$(zy_m365_cfg .mail_backfill.model)"
now="$(zy_now_utc)"
graph_sh="$ZY_M365_SKILL_DIR/graph.sh"
state_sh="$ZY_M365_SKILL_DIR/state.sh"
checkpoint="$ZY_M365_STATE_DIR/mail-backfill.json"

work="$(mktemp -d -t zyggy-m365-work.XXXXXX)"
trap 'rm -rf "$work"' EXIT
# A signal stops the claude child first and writes nothing more: the checkpoint of the last completed batch stands.
# shellcheck disable=SC2317 # invoked by the TERM and INT traps
on_signal() { # on_signal <exit code>
  if [ -n "$ZY_M365_CLAUDE_PID" ]; then
    kill -TERM "$ZY_M365_CLAUDE_PID" 2> /dev/null || true
    wait "$ZY_M365_CLAUDE_PID" 2> /dev/null || true
  fi
  exit "$1"
}
trap 'on_signal 143' TERM
trap 'on_signal 130' INT

say() { # one progress line on stdout
  printf 'mail-backfill: %s\n' "$1"
}

# graph.sh <verb…> > <out>; stderr kept for the message of a failure.
graph_run() { # graph_run <out file> <verb…>
  local out="$1"
  shift
  "$graph_sh" "$@" < /dev/null > "$out" 2> "$work/graph-err"
}

graph_message() { # the last stderr line of graph.sh, without its prefix and the key line
  local msg
  msg="$(grep -v '^key: ' "$work/graph-err" | tail -n 1 || true)"
  printf '%s' "${msg#m365: }"
}

# --- 3. the identity and the folders ---------------------------------------------------------------------------------

rc=0
graph_run /dev/null token || rc=$?
key_src="$(grep -m 1 '^key: ' "$work/graph-err" || true)"
[ -z "$key_src" ] || printf '%s\n' "$key_src" >&2
[ "$rc" -eq 0 ] || die "$rc" "$(graph_message)"
rc=0
graph_run "$work/folders.json" mail-folders || rc=$?
[ "$rc" -eq 0 ] || die "$rc" "$(graph_message)"
excluded="$(jq '[.[] | select(.excluded)] | length' "$work/folders.json")"
if [ "$have_folder" -eq 1 ]; then
  jq -c --arg f "$folder_arg" '[.[] | select(.id == $f or ((.displayName // "") | ascii_downcase) == ($f | ascii_downcase)
    or ((.wellKnownName // "") | ascii_downcase) == ($f | ascii_downcase))] | first // empty' "$work/folders.json" > "$work/match.json"
  [ -s "$work/match.json" ] || die 4 "no folder $folder_arg in the mailbox"
  if jq -e '.excluded' "$work/match.json" > /dev/null; then
    die 4 "folder $folder_arg is excluded (mail_backfill.exclude_folders)"
  fi
  jq -c '[.]' "$work/match.json" > "$work/selected.json"
else
  jq -c '[.[] | select(.excluded | not)]' "$work/folders.json" > "$work/selected.json"
fi
while IFS= read -r id; do
  if [[ ! "$id" =~ $ZY_M365_ID_RE ]] || [[ ! "$id" =~ $ZY_MB_STATE_ARG_RE ]]; then die 6 "Graph returned an unexpected folder id"; fi
done < <(jq -r '.[].id' "$work/folders.json")

# --- 4. the checkpoint ---------------------------------------------------------------------------------------------------

ck=""
ckpt_write() { # the checkpoint ($ck), 0600, as a temporary file and a rename
  zy_m365_state_dir
  (umask 077 && printf '%s\n' "$ck" > "$checkpoint.tmp")
  chmod 600 "$checkpoint.tmp"
  mv -f "$checkpoint.tmp" "$checkpoint"
}

if [ "$reset" -eq 1 ]; then
  ids="$(jq -r '.[].id' "$work/folders.json")"
  if [ -f "$checkpoint" ]; then ids+=$'\n'"$(jq -r '.folders // {} | keys[]' "$checkpoint" 2> /dev/null || true)"; fi
  while IFS= read -r id; do
    if [[ "$id" =~ $ZY_MB_STATE_ARG_RE ]]; then "$state_sh" reset backfill-watermark "$id"; fi
  done < <(printf '%s\n' "$ids" | sort -u)
  rm -f "$checkpoint"
  say "checkpoint and backfill watermarks reset"
fi
if [ -f "$checkpoint" ]; then
  ck="$(jq -c 'select(type == "object" and (.folders | type) == "object")' "$checkpoint" 2> /dev/null || true)"
  [ -n "$ck" ] || die 3 "configuration error: $checkpoint is not a checkpoint (mail-backfill.sh --reset starts again)"
else
  ck="$(jq -nc --arg t "$now" '{folders: {}, total_messages: 0, total_facts: 0, total_duplicates: 0, total_refused: 0,
    total_batches: 0, total_turns: 0, total_cost: 0, started: $t, updated: $t}')"
fi

# Add one batch to the folder <id> and to the totals: ckpt_add <id> <name> <watermark> <done> <batches> <messages>
# <facts> <duplicates> <refused> <turns> <cost> (a failed batch adds 0 batches, only its turns and cost).
ckpt_add() {
  ck="$(jq -c --arg id "$1" --arg name "$2" --arg wm "$3" --argjson fin "$4" --argjson b "$5" --argjson m "$6" \
    --argjson f "$7" --argjson d "$8" --argjson r "$9" --argjson t "${10}" --argjson c "${11}" --arg now "$(zy_now_utc)" '
    .folders[$id] = ((.folders[$id] // {name: $name, watermark: null, done: false, batches: 0, messages: 0, facts: 0,
        duplicates: 0, refused: 0, turns: 0, cost: 0})
      | .name = $name | .watermark = (if $wm == "" then .watermark else $wm end) | .done = $fin | .batches += $b
      | .messages += $m | .facts += $f | .duplicates += $d | .refused += $r | .turns += $t | .cost += $c)
    | .total_batches += $b | .total_messages += $m | .total_facts += $f | .total_duplicates += $d
    | .total_refused += $r | .total_turns += $t | .total_cost += $c | .updated = $now' <<< "$ck")"
  ckpt_write
}

ck_get() { # ck_get <jq path>
  jq -r "$1" <<< "$ck"
}

# The reason the totals forbid another batch, or nothing.
cap_reason() {
  local cost facts messages
  cost="$(ck_get .total_cost)"
  facts="$(ck_get .total_facts)"
  messages="$(ck_get .total_messages)"
  if [ "$(jq -n --argjson c "$cost" --argjson b "$budget_total" '$c >= $b')" = true ]; then
    printf 'budget %.2f USD over cap %s' "$cost" "$budget_total"
  elif [ "$max_facts" -gt 0 ] && [ "$facts" -ge "$max_facts" ]; then
    printf 'facts %s at cap %s' "$facts" "$max_facts"
  elif [ "$max_messages" -gt 0 ] && [ "$messages" -ge "$max_messages" ]; then
    printf 'messages %s at cap %s' "$messages" "$max_messages"
  fi
}

# --- 5. the batches ------------------------------------------------------------------------------------------------------

args_for() { # args_for <folder-id> <watermark> → the claude argv in $args
  args=(-p "/mail-backfill $M365_MAILBOX $1 $2 $batch" --permission-mode auto --permission-prompts none
    --no-session-persistence --output-format json --max-turns "$max_turns" --max-budget-usd "$budget_batch")
  if [ -n "$model" ] && [ "$model" != null ]; then
    args+=(--model "$model")
  fi
  args+=(--allowedTools "$(zy_m365_join , "${ZY_M365_MAIL_BACKFILL_ALLOW[@]}")"
    --disallowedTools "$(zy_m365_join , "${ZY_M365_MAIL_BACKFILL_DENY[@]}")")
}

stop=""
stuck=()
folders="$(jq -r '.[] | "\(.id)\t\(.displayName // .id)"' "$work/selected.json")"
while IFS=$'\t' read -r id name; do
  [ -n "$id" ] || continue
  [ "$(jq -r --arg id "$id" '.folders[$id].done // false' <<< "$ck")" != true ] || continue
  announced=0
  while :; do
    stop="$(cap_reason)"
    [ -z "$stop" ] || break 2
    wm="$("$state_sh" get backfill-watermark "$id")"
    [ -n "$wm" ] || wm="$now"
    if [ "$announced" -eq 0 ]; then
      if [ "$(jq -r --arg id "$id" '.folders[$id].batches // 0' <<< "$ck")" -gt 0 ]; then
        say "resuming folder $name from $wm"
      else
        say "starting folder $name from $wm"
      fi
      announced=1
    fi
    args_for "$id" "$wm"
    rc=0
    zy_m365_run_claude "$work/result.json" "$work/claude-err" - "${args[@]}" || rc=$?
    result="$work/result.json"
    if ! jq -e 'type == "object" and has("is_error")' "$result" > /dev/null 2>&1; then
      die 6 "claude returned no JSON result (exit $rc) — $ZY_MB_RUNBOOK"
    fi
    turns="$(jq -r '.num_turns // 0' "$result")"
    cost="$(jq -r '.total_cost_usd // 0' "$result")"
    if [[ ! "$turns" =~ ^[0-9]+$ ]] || [[ ! "$cost" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
      die 6 "claude returned a malformed result (num_turns, total_cost_usd) — $ZY_MB_RUNBOOK"
    fi
    if [ "$(jq -r '.is_error' "$result")" = true ] || [ "$rc" -ne 0 ]; then
      ckpt_add "$id" "$name" "" false 0 0 0 0 0 "$turns" "$cost"
      die 6 "claude run failed ($(jq -r '.subtype // "exit '"$rc"'"' "$result")) — $ZY_MB_RUNBOOK"
    fi
    # the model's counts line (its last line of that shape); "-" where it gave none
    messages=-
    facts=-
    dup=0
    refused=0
    counts="$(jq -r '.result // ""' "$result" | grep -E "$ZY_MB_COUNTS_RE" | tail -n 1 || true)"
    if [[ "$counts" =~ $ZY_MB_COUNTS_RE ]]; then
      messages="${BASH_REMATCH[1]}"
      facts="${BASH_REMATCH[2]}"
      dup="${BASH_REMATCH[3]}"
      refused="${BASH_REMATCH[4]}"
    fi
    new_wm="$("$state_sh" get backfill-watermark "$id")"
    done_now=false
    [ "$messages" != 0 ] || done_now=true
    ckpt_add "$id" "$name" "$new_wm" "$done_now" 1 "${messages/#-/0}" "${facts/#-/0}" "$dup" "$refused" "$turns" "$cost"
    say "$name batch $(jq -r --arg id "$id" '.folders[$id].batches' <<< "$ck"): messages $messages, facts $facts, cost $(printf '%.2f' "$cost")"
    if [ "$done_now" = true ]; then
      say "$name done"
      break
    fi
    if [ -z "$new_wm" ] || [[ ! "$new_wm" < "$wm" ]]; then
      printf 'mail-backfill: %s: watermark not advanced, stopping the folder\n' "$name" >&2
      stuck+=("$name")
      break
    fi
  done
done <<< "$folders"

# --- 6. the counts line -------------------------------------------------------------------------------------------------

word="done"
[ -z "$stop" ] && [ "${#stuck[@]}" -eq 0 ] || word=stopped
printf 'mail-backfill: %s — folders %s (excluded %s), messages %s, batches %s, facts %s (%s duplicates dropped, %s refused), turns %s, cost %.2f (cap %s)\n' \
  "$word" "$(jq length "$work/selected.json")" "$excluded" "$(ck_get .total_messages)" "$(ck_get .total_batches)" \
  "$(ck_get .total_facts)" "$(ck_get .total_duplicates)" "$(ck_get .total_refused)" "$(ck_get .total_turns)" \
  "$(ck_get .total_cost)" "$budget_total"
[ -z "$stop" ] || die 5 "stopped: $stop"
if [ "${#stuck[@]}" -gt 0 ]; then
  die 5 "stopped: watermark not advanced in $(zy_m365_join ', ' "${stuck[@]}")"
fi
exit 0

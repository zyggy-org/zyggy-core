#!/usr/bin/env bash
set -euo pipefail
# The files backfill of the m365 connector (spec 23 Q8, AC-19, AC-42): owner-started (in tmux, may run unwatched), it
# turns every file of the OneDrive and the granted sites' document libraries into validated fact lines in memory
# inbox/, oldest change first, in resumable, cost-capped batches. Facts only: the batch's model reads the drive,
# downloads a document into the batch's run directory, parses it with parse.sh (which deletes it) and writes through
# facts.sh and state.sh; ZY_M365_FILES_BACKFILL_DENY denies the mail tools, the Draft tools and the proposal script.
# Order: refused under ZYGGY_HOOKS=off → the arguments → configuration and claude (before any request) → graph.sh
# token (fails fast on the identity) → the drives from graph.sh drives (drives.exclude_drives already dropped) → per
# drive: the totals (budget_usd_total, max_facts; 0 = no facts cap) → graph.sh check --drive <id> (403/404 → the drive
# is skipped, counted forbidden) → until a batch lists 0 files: a fresh 0700 run directory (ZYGGY_M365_RUN_DIR),
# claude -p "/files-backfill <drive-id> <run-dir> <batch>[ skip paths under: <path>, …]" with the batch caps, the run
# directory removed, the new watermark read back from state.sh files-backfill-watermark <drive> (an ISO timestamp the
# model sets last — the pinned server has no delta token; never the brief's drive-token), the checkpoint
# files-backfill.json (0600) rewritten after each completed batch. A batch answering "forbidden 403" skips the drive
# (counted forbidden, checked again next run). A watermark that did not move stops that drive (exit 5 at the end);
# SIGINT/SIGTERM stop the claude child, remove the run directory and exit without writing: the checkpoint of the last
# completed batch stands and the next run says "resuming drive <name> from <timestamp>". --reset clears the
# checkpoint and every files-backfill watermark, then starts again from the beginning.
# usage: files-backfill.sh [--drive <name>] [--reset]     (<name>: drive name or drive id)
# stdout: one line per drive start, batch and drive end, then the counts line "files-backfill: done|stopped — drives
# <k> (excluded <e>, forbidden <x>), listed <l>, parsed <p>, skipped <s> (type <a>, size <b>, path <c>, parse error
# <d>, secret pattern <e>), facts <f> (<d> duplicates dropped, <r> refused), batches <b>, turns <t>, cost <usd> (cap
# <cap>)" (totals of the whole backfill, across resumed runs; forbidden = drives skipped in this run).
# Exit 0 done · 3 configuration · 4 usage · 5 refused unattended, a cap reached or a watermark not advanced
# (checkpoint intact) · 6 identity, Graph or model-run failure · 130/143 interrupted.
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"
# shellcheck source=m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/m365-lib.sh"
ZY_SELF=files-backfill

readonly ZY_FB_COUNTS_RE='^files-backfill batch: listed ([0-9]+), parsed ([0-9]+), skipped ([0-9]+) \(type ([0-9]+), size ([0-9]+), path ([0-9]+), parse error ([0-9]+), secret pattern ([0-9]+)\), facts ([0-9]+) \(([0-9]+) dup, ([0-9]+) refused\)$'
readonly ZY_FB_FORBIDDEN_RE='^files-backfill batch: forbidden 403$'
readonly ZY_FB_RUNBOOK='runbook 13 "Model run failed"'
readonly ZY_FB_GRANT='runbook 13 "Grant another site"'
readonly ZY_FB_STATE_ARG_RE='^[A-Za-z0-9!_=-]{1,200}$'
readonly ZY_FB_PATH_RE='^/[^,[:cntrl:]]{0,199}$'

die() { # die <exit code> <message>
  zy_die "$@"
}

usage() {
  die 4 "$1 (usage: files-backfill.sh [--drive <name>] [--reset])"
}

# --- 1. the principal: an owner's terminal session, never the unit ----------------------------------------------------

! zy_hooks_off || die 5 "refused: unattended run (ZYGGY_HOOKS=off)"

# --- 2. the arguments, the configuration, the tools (no request yet) --------------------------------------------------

drive_arg=""
have_drive=0
reset=0
while [ $# -gt 0 ]; do
  case "$1" in
    --drive)
      [ "$have_drive" -eq 0 ] || usage "--drive given twice"
      if [ $# -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then usage "--drive needs <name>"; fi
      drive_arg="$2"
      have_drive=1
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
batch="$(zy_m365_cfg .files_backfill.batch_files)"
[ "$batch" -ge 1 ] || die 3 "configuration error: files_backfill.batch_files must be at least 1"
max_turns="$(zy_m365_cfg .files_backfill.max_turns)"
budget_batch="$(zy_m365_cfg .files_backfill.budget_usd_per_batch)"
budget_total="$(zy_m365_cfg .files_backfill.budget_usd_total)"
max_facts="$(zy_m365_cfg .files_backfill.max_facts)"
model="$(zy_m365_cfg .files_backfill.model)"
# drives.exclude_paths travel in the prompt ("skip paths under: /a, /b"): absolute, one line, no comma
skip=""
while IFS= read -r p; do
  [[ "$p" =~ $ZY_FB_PATH_RE ]] ||
    die 3 "configuration error: drives.exclude_paths holds an entry that is not an absolute path without commas (/…)"
  skip+="${skip:+, }$p"
done < <(zy_m365_cfg_test '.drives.exclude_paths | length > 0' && jq -r '.drives.exclude_paths[]' <<< "$ZY_M365_CONFIG_JSON")
[ -z "$skip" ] || skip=" skip paths under: $skip"
now="$(zy_now_utc)"
graph_sh="$ZY_M365_SKILL_DIR/graph.sh"
state_sh="$ZY_M365_SKILL_DIR/state.sh"
checkpoint="$ZY_M365_STATE_DIR/files-backfill.json"

work="$(mktemp -d -t zyggy-m365-work.XXXXXX)"
run_dir=""
trap 'rm -rf "$work"; [ -z "$run_dir" ] || rm -rf "$run_dir"' EXIT
# A signal stops the claude child first and writes nothing more: the checkpoint of the last completed batch stands;
# the EXIT trap removes the batch's run directory.
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
  printf 'files-backfill: %s\n' "$1"
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

# --- 3. the identity and the drives ----------------------------------------------------------------------------------

rc=0
graph_run /dev/null token || rc=$?
key_src="$(grep -m 1 '^key: ' "$work/graph-err" || true)"
[ -z "$key_src" ] || printf '%s\n' "$key_src" >&2
[ "$rc" -eq 0 ] || die "$rc" "$(graph_message)"
rc=0
graph_run "$work/drives.json" drives || rc=$?
[ "$rc" -eq 0 ] || die "$rc" "$(graph_message)"
excluded="$(jq length <<< "$M365_EXCLUDE_DRIVES_JSON")"
if [ "$have_drive" -eq 1 ]; then
  jq -c --arg d "$drive_arg" '[.[] | select(.id == $d or ((.name // "") | ascii_downcase) == ($d | ascii_downcase))]
    | first // empty' "$work/drives.json" > "$work/match.json"
  if [ ! -s "$work/match.json" ]; then
    if jq -e --arg d "$drive_arg" 'map(ascii_downcase) | index($d | ascii_downcase) != null' <<< "$M365_EXCLUDE_DRIVES_JSON" > /dev/null; then
      die 4 "drive $drive_arg is excluded (drives.exclude_drives)"
    fi
    die 4 "no drive $drive_arg among the granted drives"
  fi
  jq -c '[.]' "$work/match.json" > "$work/selected.json"
else
  jq -c . "$work/drives.json" > "$work/selected.json"
fi
while IFS= read -r id; do
  if [[ ! "$id" =~ $ZY_M365_DRIVE_ID_RE ]] || [[ ! "$id" =~ $ZY_FB_STATE_ARG_RE ]]; then die 6 "Graph returned an unexpected drive id"; fi
done < <(jq -r '.[].id' "$work/drives.json")

# --- 4. the checkpoint ---------------------------------------------------------------------------------------------------

ck=""
ckpt_write() { # the checkpoint ($ck), 0600, as a temporary file and a rename
  zy_m365_state_dir
  (umask 077 && printf '%s\n' "$ck" > "$checkpoint.tmp")
  chmod 600 "$checkpoint.tmp"
  mv -f "$checkpoint.tmp" "$checkpoint"
}

if [ "$reset" -eq 1 ]; then
  ids="$(jq -r '.[].id' "$work/drives.json")"
  if [ -f "$checkpoint" ]; then ids+=$'\n'"$(jq -r '.drives // {} | keys[]' "$checkpoint" 2> /dev/null || true)"; fi
  while IFS= read -r id; do
    if [[ "$id" =~ $ZY_FB_STATE_ARG_RE ]]; then "$state_sh" reset files-backfill-watermark "$id"; fi
  done < <(printf '%s\n' "$ids" | sort -u)
  rm -f "$checkpoint"
  say "checkpoint and files-backfill watermarks reset"
fi
if [ -f "$checkpoint" ]; then
  ck="$(jq -c 'select(type == "object" and (.drives | type) == "object")' "$checkpoint" 2> /dev/null || true)"
  [ -n "$ck" ] || die 3 "configuration error: $checkpoint is not a checkpoint (files-backfill.sh --reset starts again)"
else
  ck="$(jq -nc --arg t "$now" '{drives: {}, total_listed: 0, total_parsed: 0, total_skipped: 0,
    total_skipped_by: {type: 0, size: 0, path: 0, parse_error: 0, secret_pattern: 0}, total_facts: 0,
    total_duplicates: 0, total_refused: 0, total_batches: 0, total_turns: 0, total_cost: 0, started: $t, updated: $t}')"
fi

# A batch's numbers as one JSON object (a failed or forbidden batch: 0 batches, only its turns and cost).
delta() { # delta <batches> <listed> <parsed> <skipped> <type> <size> <path> <parse error> <secret> <facts> <dup> <refused> <turns> <cost>
  jq -nc --argjson b "$1" --argjson l "$2" --argjson p "$3" --argjson s "$4" --argjson ty "$5" --argjson sz "$6" \
    --argjson pa "$7" --argjson pe "$8" --argjson se "$9" --argjson f "${10}" --argjson d "${11}" --argjson r "${12}" \
    --argjson t "${13}" --argjson c "${14}" '{batches: $b, listed: $l, parsed: $p, skipped: $s,
    skipped_by: {type: $ty, size: $sz, path: $pa, parse_error: $pe, secret_pattern: $se}, facts: $f, duplicates: $d,
    refused: $r, turns: $t, cost: $c}'
}

# Add one batch to the drive <id> and to the totals: ckpt_add <id> <name> <site> <watermark> <done> <forbidden> <delta>
ckpt_add() {
  ck="$(jq -c --arg id "$1" --arg name "$2" --arg site "$3" --arg wm "$4" --argjson fin "$5" --argjson fb "$6" \
    --argjson x "$7" --arg now "$(zy_now_utc)" '
    def add_by($a; $b): reduce ($b | keys[]) as $k ($a; .[$k] += $b[$k]);
    .drives[$id] = ((.drives[$id] // {name: $name, site: $site, watermark: null, done: false, forbidden: false,
        batches: 0, listed: 0, parsed: 0, skipped: 0,
        skipped_by: {type: 0, size: 0, path: 0, parse_error: 0, secret_pattern: 0}, facts: 0, duplicates: 0,
        refused: 0, turns: 0, cost: 0})
      | .name = $name | .watermark = (if $wm == "" then .watermark else $wm end) | .done = $fin | .forbidden = $fb
      | .batches += $x.batches | .listed += $x.listed | .parsed += $x.parsed | .skipped += $x.skipped
      | .skipped_by = add_by(.skipped_by; $x.skipped_by) | .facts += $x.facts | .duplicates += $x.duplicates
      | .refused += $x.refused | .turns += $x.turns | .cost += $x.cost)
    | .total_batches += $x.batches | .total_listed += $x.listed | .total_parsed += $x.parsed
    | .total_skipped += $x.skipped | .total_skipped_by = add_by(.total_skipped_by; $x.skipped_by)
    | .total_facts += $x.facts | .total_duplicates += $x.duplicates | .total_refused += $x.refused
    | .total_turns += $x.turns | .total_cost += $x.cost | .updated = $now' <<< "$ck")"
  ckpt_write
}

ck_get() { # ck_get <jq path>
  jq -r "$1" <<< "$ck"
}

# The reason the totals forbid another batch, or nothing.
cap_reason() {
  local cost facts
  cost="$(ck_get .total_cost)"
  facts="$(ck_get .total_facts)"
  if [ "$(jq -n --argjson c "$cost" --argjson b "$budget_total" '$c >= $b')" = true ]; then
    printf 'budget %.2f USD over cap %s' "$cost" "$budget_total"
  elif [ "$max_facts" -gt 0 ] && [ "$facts" -ge "$max_facts" ]; then
    printf 'facts %s at cap %s' "$facts" "$max_facts"
  fi
}

forbidden=0
skip_forbidden() { # skip_forbidden <id> <name> <site> <status text> <delta>: counted, checked again next run
  ckpt_add "$1" "$2" "$3" "" false true "$5"
  printf 'files-backfill: drive %s: %s, skipped — %s\n' "$2" "$4" "$ZY_FB_GRANT" >&2
  forbidden=$((forbidden + 1))
}

# --- 5. the batches ------------------------------------------------------------------------------------------------------

args_for() { # args_for <drive-id> <run-dir> → the claude argv in $args
  args=(-p "/files-backfill $1 $2 $batch$skip" --permission-mode auto --permission-prompts none
    --no-session-persistence --output-format json --max-turns "$max_turns" --max-budget-usd "$budget_batch")
  if [ -n "$model" ] && [ "$model" != null ]; then
    args+=(--model "$model")
  fi
  args+=(--allowedTools "$(zy_m365_join , "${ZY_M365_FILES_BACKFILL_ALLOW[@]}")"
    --disallowedTools "$(zy_m365_join , "${ZY_M365_FILES_BACKFILL_DENY[@]}")")
}

stop=""
stuck=()
drives="$(jq -r '.[] | "\(.id)\t\(.name // .id)\t\(.site // "")"' "$work/selected.json")"
while IFS=$'\t' read -r id name site; do
  [ -n "$id" ] || continue
  [ "$(jq -r --arg id "$id" '.drives[$id].done // false' <<< "$ck")" != true ] || continue
  stop="$(cap_reason)"
  [ -z "$stop" ] || break
  # the pre-check: a drive the identity cannot read (no grant) is skipped before any model run
  rc=0
  graph_run "$work/check.txt" check --drive "$id" || rc=$?
  [ "$rc" -eq 0 ] || die "$rc" "$(graph_message)"
  checked="$(grep -F "drive $id: " "$work/check.txt" | tail -n 1 || true)"
  checked="${checked#"drive $id: "}"
  if [[ ! "$checked" =~ ^2[0-9][0-9]\  ]]; then
    skip_forbidden "$id" "$name" "$site" "${checked:-no answer}" "$(delta 0 0 0 0 0 0 0 0 0 0 0 0 0 0)"
    continue
  fi
  announced=0
  while :; do
    stop="$(cap_reason)"
    [ -z "$stop" ] || break 2
    wm="$("$state_sh" get files-backfill-watermark "$id")"
    if [ "$announced" -eq 0 ]; then
      if [ "$(jq -r --arg id "$id" '.drives[$id].batches // 0' <<< "$ck")" -gt 0 ]; then
        say "resuming drive $name from ${wm:-the beginning}"
      else
        say "starting drive $name from ${wm:-the beginning}"
      fi
      announced=1
    fi
    run_dir="$(mktemp -d -t zyggy-m365-files.XXXXXX)"
    chmod 700 "$run_dir"
    export ZYGGY_M365_RUN_DIR="$run_dir"
    args_for "$id" "$run_dir"
    rc=0
    zy_m365_run_claude "$work/result.json" "$work/claude-err" - "${args[@]}" || rc=$?
    rm -rf "$run_dir"
    run_dir=""
    result="$work/result.json"
    if ! jq -e 'type == "object" and has("is_error")' "$result" > /dev/null 2>&1; then
      die 6 "claude returned no JSON result (exit $rc) — $ZY_FB_RUNBOOK"
    fi
    turns="$(jq -r '.num_turns // 0' "$result")"
    cost="$(jq -r '.total_cost_usd // 0' "$result")"
    if [[ ! "$turns" =~ ^[0-9]+$ ]] || [[ ! "$cost" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
      die 6 "claude returned a malformed result (num_turns, total_cost_usd) — $ZY_FB_RUNBOOK"
    fi
    if [ "$(jq -r '.is_error' "$result")" = true ] || [ "$rc" -ne 0 ]; then
      ckpt_add "$id" "$name" "$site" "" false false "$(delta 0 0 0 0 0 0 0 0 0 0 0 0 "$turns" "$cost")"
      die 6 "claude run failed ($(jq -r '.subtype // "exit '"$rc"'"' "$result")) — $ZY_FB_RUNBOOK"
    fi
    text="$(jq -r '.result // ""' "$result")"
    if grep -qE "$ZY_FB_FORBIDDEN_RE" <<< "$text"; then
      skip_forbidden "$id" "$name" "$site" "403 (not granted)" "$(delta 0 0 0 0 0 0 0 0 0 0 0 0 "$turns" "$cost")"
      continue 2
    fi
    # the model's counts line (its last line of that shape); "-" for listed where it gave none
    listed=-
    n=(0 0 0 0 0 0 0 0 0 0 0)
    counts="$(grep -E "$ZY_FB_COUNTS_RE" <<< "$text" | tail -n 1 || true)"
    if [[ "$counts" =~ $ZY_FB_COUNTS_RE ]]; then
      listed="${BASH_REMATCH[1]}"
      n=("${BASH_REMATCH[@]:1:11}")
    fi
    new_wm="$("$state_sh" get files-backfill-watermark "$id")"
    done_now=false
    [ "$listed" != 0 ] || done_now=true
    ckpt_add "$id" "$name" "$site" "$new_wm" "$done_now" false "$(delta 1 "${n[@]}" "$turns" "$cost")"
    say "$name batch $(jq -r --arg id "$id" '.drives[$id].batches' <<< "$ck"): listed $listed, parsed ${n[1]}, skipped ${n[2]}, facts ${n[8]}, cost $(printf '%.2f' "$cost")"
    if [ "$done_now" = true ]; then
      say "$name done"
      break
    fi
    if [ -z "$new_wm" ] || { [ -n "$wm" ] && [[ ! "$new_wm" > "$wm" ]]; }; then
      printf 'files-backfill: %s: watermark not advanced, stopping the drive\n' "$name" >&2
      stuck+=("$name")
      break
    fi
  done
done <<< "$drives"

# --- 6. the counts line -------------------------------------------------------------------------------------------------

word="done"
[ -z "$stop" ] && [ "${#stuck[@]}" -eq 0 ] || word=stopped
printf 'files-backfill: %s — drives %s (excluded %s, forbidden %s), listed %s, parsed %s, skipped %s (type %s, size %s, path %s, parse error %s, secret pattern %s), facts %s (%s duplicates dropped, %s refused), batches %s, turns %s, cost %.2f (cap %s)\n' \
  "$word" "$(jq length "$work/selected.json")" "$excluded" "$forbidden" "$(ck_get .total_listed)" \
  "$(ck_get .total_parsed)" "$(ck_get .total_skipped)" "$(ck_get .total_skipped_by.type)" \
  "$(ck_get .total_skipped_by.size)" "$(ck_get .total_skipped_by.path)" "$(ck_get .total_skipped_by.parse_error)" \
  "$(ck_get .total_skipped_by.secret_pattern)" "$(ck_get .total_facts)" "$(ck_get .total_duplicates)" \
  "$(ck_get .total_refused)" "$(ck_get .total_batches)" "$(ck_get .total_turns)" "$(ck_get .total_cost)" "$budget_total"
[ -z "$stop" ] || die 5 "stopped: $stop"
if [ "${#stuck[@]}" -gt 0 ]; then
  die 5 "stopped: watermark not advanced in $(zy_m365_join ', ' "${stuck[@]}")"
fi
exit 0

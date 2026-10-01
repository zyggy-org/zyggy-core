#!/usr/bin/env bash
set -euo pipefail
# The owner's consent terminal (spec 23 D6): run by the owner over SSH on the VM, never by a unit, a skill or the
# model. For each pending proposal, oldest first, it re-fetches the object from Graph (graph.sh snapshot, and the
# body with graph.sh get — shown on this terminal only, never stored), says CHANGED when the object differs from the
# proposal and RECIPIENT OUTSIDE POLICY when a recipient is outside the row's policy, and asks
# [y]es / [n]o / [s]kip / [q]uit. y appends an approval bound to the CURRENT hash (row id, hash, time, tty) and
# executes at once (graph.sh send-draft|move|delete --approved <hash>); n marks the row refused; s leaves it pending; q ends
# the session. A refused execution keeps the approval (the owner's consent stands) and the row pending.
# Pending rows older than 7 days expire when the session starts; --list prints the pending rows and acts on nothing.
# usage: m365-approve.sh [--list]
# Exit 0 · 3 configuration · 4 usage · 5 refused (ZYGGY_HOOKS=off, or no terminal) · 6 identity or Graph failure.
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"
# shellcheck source=m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/m365-lib.sh"
ZY_SELF=m365-approve

readonly ZY_APPROVE_STALE_DAYS=7 ZY_APPROVE_PREVIEW_CHARS=500
readonly ZY_APPROVE_PROMPT='[y]es / [n]o / [s]kip / [q]uit: '

die() { # die <exit code> <message>
  zy_die "$@"
}

usage() {
  die 4 "$1 (usage: m365-approve.sh [--list])"
}

# --- 1. the arguments, the principal, the terminal ------------------------------------------------------------------

list=0
case "$#:${1:-}" in
  0:) ;;
  1:--list) list=1 ;;
  *) usage "unexpected argument '${1:0:40}'" ;;
esac
# The unit runs with ZYGGY_HOOKS=off; this check comes first so its message is deterministic.
if zy_hooks_off; then
  die 5 "refused: unattended run (ZYGGY_HOOKS=off)"
fi

zy_require_config
command -v jq > /dev/null || die 3 "jq not found"
graph_sh="$ZY_M365_SKILL_DIR/graph.sh"
state_sh="$ZY_M365_SKILL_DIR/state.sh"
stale_before="$(($(zy_date UTC +%s) - ZY_APPROVE_STALE_DAYS * 86400))"

# The ids of the pending rows proposed more than 7 days ago, one per line.
stale_ids() {
  [ -s "$ZY_M365_PROPOSALS" ] || return 0
  jq -r -n --argjson cut "$stale_before" \
    'inputs | select(.status == "pending" and ((.ts // "") | (try fromdateiso8601 catch 0)) < $cut) | .id' "$ZY_M365_PROPOSALS"
}

if [ "$list" -eq 1 ]; then
  # state.sh's line per pending row (no body is ever stored), stale rows marked; no terminal needed, nothing changes.
  lines="$("$state_sh" list proposals --status pending)"
  stale="$(stale_ids)"
  while IFS= read -r line; do
    if [ -n "$stale" ] && grep -qxF -- "${line%% *}" <<< "$stale"; then
      printf '%s stale\n' "$line"
    else
      printf '%s\n' "$line"
    fi
  done <<< "$lines"
  exit 0
fi

zy_m365_tty || die 5 "refused: no terminal"
# shellcheck disable=SC2119 # no argument: the full validation (the consent block included)
zy_m365_load_config

work="$(mktemp -d -t zyggy-m365-approve.XXXXXX)"
trap 'rm -rf "$work"' EXIT

# --- 2. reading Graph through graph.sh ---------------------------------------------------------------------------------

# graph.sh <verb…> without a terminal: stdout in GRAPH_OUT (a variable — a body is never written to a file), its last
# message line (prefix and key line dropped) in GRAPH_MSG; returns graph.sh's status.
GRAPH_OUT=""
GRAPH_MSG=""
graph_read() {
  local rc=0
  GRAPH_OUT="$("$graph_sh" "$@" < /dev/null 2> "$work/graph-err")" || rc=$?
  GRAPH_MSG="$(grep -v '^key: ' "$work/graph-err" | tail -n 1 || true)"
  GRAPH_MSG="${GRAPH_MSG#m365: }"
  return "$rc"
}

# Text from Graph made safe for a terminal: no control character but newline and tab (no escape sequence can redraw
# the screen), no C1 control, no bidirectional override.
tty_safe() {
  tr -d '\000-\010\013-\037\177' | LC_ALL=C sed -e 's/\xc2[\x80-\x9f]//g' -e 's/\xe2\x80[\xaa-\xae]//g' -e 's/\xe2\x81[\xa6-\xa9]//g'
}

one_line() { # one_line <text> → one terminal-safe line, "-" when empty
  local s
  s="$(printf '%s' "$1" | tr '\n\t' '  ' | tty_safe)"
  printf '%s' "${s:--}"
}

field() { # field <label> <value>
  printf '  %-9s %s\n' "$1:" "$(one_line "$2")"
}

# The identity works before anything is shown (the token itself is discarded).
"$graph_sh" token < /dev/null > /dev/null 2> "$work/graph-err" ||
  die 6 "$(grep -v '^key: ' "$work/graph-err" | tail -n 1 | sed 's/^m365: //')"
graph_read mail-folders || die "$?" "$GRAPH_MSG"
folders="$GRAPH_OUT"

folder_name() { # folder_name <folder id> → its display name, or the id
  jq -r --arg id "$1" 'first(.[] | select(.id == $id) | .displayName) // $id' <<< "$folders"
}

# --- 3. stale rows expire ------------------------------------------------------------------------------------------------

while IFS= read -r id; do
  [[ "$id" =~ $ZY_M365_ROW_ID_RE ]] || continue
  "$state_sh" mark "$id" expired
  printf '%s expired: pending for more than %s days\n' "$id" "$ZY_APPROVE_STALE_DAYS"
done < <(stale_ids)

# --- 4. one row at a time --------------------------------------------------------------------------------------------------

ANSWER=""
ask() { # one key from the terminal: y, n, s or q (end of input counts as q); Enter and other keys are ignored
  local c
  printf '%s' "$ZY_APPROVE_PROMPT"
  while :; do
    if ! IFS= read -r -n1 c < /dev/tty; then
      ANSWER=q
      break
    fi
    case "$c" in
      [yYnNsSqQ])
        ANSWER="${c,,}"
        break
        ;;
      $'\004')
        ANSWER=q
        break
        ;;
    esac
  done
  printf '%s\n' "$ANSWER"
}

# What changed between the proposal's snapshot and the current one, in words.
changes() { # changes <proposal snapshot json> <current canonical>
  jq -r -n --argjson a "$1" --argjson b "$2" '[
    (if $a.subject != $b.subject then "subject edited" else empty end),
    (if [$a.to, $a.cc, $a.bcc] != [$b.to, $b.cc, $b.bcc] then "recipients changed" else empty end),
    (if $a.from != $b.from then "sender changed" else empty end),
    (if $a.parentFolderId != $b.parentFolderId then "moved to another folder" else empty end),
    (if $a.isDraft != $b.isDraft then "draft state changed" else empty end)
  ] | if length == 0 then "content edited" else join(", ") end'
}

# The current recipients outside the row's recipient policy (the set propose.sh recorded; the mailbox alone for a
# flagged row without one), comma-separated, or nothing.
outside_recipients() { # outside_recipients <row json> <current canonical>
  jq -r -n --argjson r "$1" --argjson c "$2" --arg mb "$M365_MAILBOX" '
    if ($r.recipient_policy | type) == "array" then $r.recipient_policy
    elif $r.recipient_outside_policy == true then [$mb | ascii_downcase]
    else null end
    | if . == null then "" else ((($c.to + $c.cc + $c.bcc) - .) | unique | join(", ")) end'
}

pending=()
if [ -s "$ZY_M365_PROPOSALS" ]; then
  mapfile -t pending < <(jq -r -n '[inputs | select(.status == "pending")] | sort_by(.ts // "") | .[].id' "$ZY_M365_PROPOSALS")
fi
total="${#pending[@]}"
if [ "$total" -eq 0 ]; then
  printf 'm365-approve: no pending proposals\n'
  exit 0
fi
printf 'm365-approve: %s pending proposals for %s, oldest first\n' "$total" "$M365_MAILBOX"
printf 'Everything below is fetched from Graph now; only the reason is the model'"'"'s text. y = approve and execute now, n = refuse, s = skip, q = quit.\n'

executed=0
refused=0
skipped=0
expired=0
not_executed=0
n=0
for id in "${pending[@]}"; do
  n=$((n + 1))
  [[ "$id" =~ $ZY_M365_ROW_ID_RE ]] || continue
  row="$(zy_m365_row "$id")"
  action="$(jq -r '.action // ""' <<< "$row")"
  target="$(jq -r '.target_id // ""' <<< "$row")"
  printf '\nproposal %s of %s: %s\n' "$n" "$total" "$id"
  case "$action" in
    send-draft | move | delete) ;;
    *)
      printf '  %s is not an action — skipped\n' "$(one_line "$action")"
      skipped=$((skipped + 1))
      continue
      ;;
  esac
  if [[ ! "$target" =~ $ZY_M365_ID_RE ]]; then
    printf '  the row names no valid target — skipped\n'
    skipped=$((skipped + 1))
    continue
  fi
  kind="$(zy_m365_kind_of "$action")"
  if ! graph_read snapshot "$kind" "$target"; then
    if [[ "$GRAPH_MSG" == "not found ("* ]]; then
      "$state_sh" mark "$id" expired
      printf '  %s %s: not found in the mailbox — expired\n' "$action" "$target"
      expired=$((expired + 1))
      continue
    fi
    die 6 "$GRAPH_MSG"
  fi
  canonical="$(sed -n 1p <<< "$GRAPH_OUT")"
  current="$(sed -n 's/^hash: //p' <<< "$GRAPH_OUT")"
  if [ "$kind" = draft ] && [ "$(jq -r '.isDraft' <<< "$canonical")" != true ]; then
    "$state_sh" mark "$id" expired
    printf '  send-draft %s: no longer a draft — expired\n' "$target"
    expired=$((expired + 1))
    continue
  fi
  graph_read get "$kind" "$target" || die 6 "$GRAPH_MSG"
  body="$GRAPH_OUT"

  case "$action" in
    send-draft) field action "send-draft — send this Draft as it is now" ;;
    move) field action "move → $(jq -r '.folder // ""' <<< "$row")" ;;
    delete) field action "delete — soft delete → Deleted Items (never a hard delete)" ;;
  esac
  field origin "$(jq -r '.origin // "-"' <<< "$row"), proposed $(jq -r '.ts // "-"' <<< "$row")"
  field reason "$(jq -r '.reason // ""' <<< "$row")"
  field hash "$current"
  if [ "$current" != "$(jq -r '.snapshot_hash // ""' <<< "$row")" ]; then
    printf '  CHANGED since proposal (%s) — the values below are the current ones; y approves them\n' \
      "$(changes "$(jq -c '.snapshot | if type == "object" then . else {} end' <<< "$row")" "$canonical")"
  fi
  field subject "$(jq -r '.subject' <<< "$canonical")"
  field to "$(jq -r '.to | join(", ")' <<< "$canonical")"
  field cc "$(jq -r '.cc | join(", ")' <<< "$canonical")"
  field bcc "$(jq -r '.bcc | join(", ")' <<< "$canonical")"
  field from "$(jq -r '.from' <<< "$canonical")"
  field received "$(jq -r '.receivedDateTime' <<< "$canonical")"
  field folder "$(folder_name "$(jq -r '.parentFolderId' <<< "$canonical")")"
  if [ "$kind" = draft ]; then
    printf '  body:\n'
    printf '%s\n' "$body" | tty_safe
  else
    printf '  body (preview, first %s characters):\n' "$ZY_APPROVE_PREVIEW_CHARS"
    jq -r -n --arg b "$body" --argjson n "$ZY_APPROVE_PREVIEW_CHARS" '$b[:$n]' | tty_safe
  fi
  printf '  (end of body)\n'
  if [ "$action" = send-draft ]; then
    outside="$(outside_recipients "$row" "$canonical")"
    [ -z "$outside" ] || printf '  RECIPIENT OUTSIDE POLICY: %s\n' "$(one_line "$outside")"
  fi

  ask
  case "$ANSWER" in
    y)
      tty_name="$(tty)"
      zy_m365_consent_append "$ZY_M365_APPROVALS" "$(jq -nc --arg r "$id" --arg h "$current" --arg t "$(zy_now_utc)" \
        --arg y "${tty_name#/dev/}" '{row_id: $r, hash_at_approval: $h, ts: $t, tty: $y}')"
      rc=0
      # graph.sh executes on this terminal (its own tty check); its result line comes straight through
      "$graph_sh" "$action" --approved "$current" 2> "$work/graph-err" || rc=$?
      grep -v '^key: ' "$work/graph-err" | tty_safe || true
      GRAPH_MSG="$(grep -v '^key: ' "$work/graph-err" | tail -n 1 | sed 's/^m365: //' || true)"
      case "$rc" in
        0) executed=$((executed + 1)) ;;
        6)
          status="$(jq -r -n --arg r "$id" '[inputs | select(.row_id == $r)] | last | .http_status // empty' "$ZY_M365_EXECUTIONS" 2> /dev/null || true)"
          if [ -n "$status" ] && [[ "$GRAPH_MSG" == *" — "* ]]; then
            printf 'failed: %s — %s\n' "$status" "${GRAPH_MSG#* — }"
          else
            printf 'failed: %s\n' "$GRAPH_MSG"
          fi
          not_executed=$((not_executed + 1))
          ;;
        *)
          printf 'not executed — your approval is recorded and %s stays as it is; fix the cause and run m365-approve.sh again within %s min\n' \
            "$id" "$M365_CONSENT_TTL_MINUTES"
          not_executed=$((not_executed + 1))
          ;;
      esac
      ;;
    n)
      "$state_sh" mark "$id" refused
      printf 'refused: %s — nothing executed\n' "$id"
      refused=$((refused + 1))
      ;;
    s)
      printf 'skipped: %s — stays pending\n' "$id"
      skipped=$((skipped + 1))
      ;;
    q)
      printf 'quit — the remaining proposals stay pending\n'
      break
      ;;
  esac
done
printf '\nm365-approve: executed %s, refused %s, skipped %s, expired %s, not executed %s\n' \
  "$executed" "$refused" "$skipped" "$expired" "$not_executed"

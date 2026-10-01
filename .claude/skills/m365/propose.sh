#!/usr/bin/env bash
set -euo pipefail
# The model's only way to ask for a send, a move or a soft delete (spec 23 D6): one `pending` row in proposals.jsonl
# whose snapshot comes from Graph through graph.sh — never from the arguments — bound to the lib's snapshot hash.
# Nothing leaves the mailbox here: the owner reviews the row with m365-approve.sh on a terminal of the VM, and only
# graph.sh executes it there. Proposing is allowed unattended (the brief run, ZYGGY_HOOKS=off, no tty).
# usage: propose.sh send-draft <draft-id> --reason <text> | move <message-id> <folder> --reason <text>
#        | delete <message-id> --reason <text>
# There is no recipient, body or subject parameter: recipients and subject are the Draft's as Graph holds it.
# A send-draft whose recipients fall outside {mailbox, the replied-to message's sender and replyTo} is recorded and
# flagged recipient_outside_policy (the owner decides on the terminal). The reason is bounded (≤ 500 characters,
# one line, no URL, no e-mail address, no secret); a pending row for the same action and target is not repeated.
# Origin: "brief <date>" when brief.sh exports ZYGGY_M365_ORIGIN, else "session".
# Exit 0 · 3 configuration · 4 usage or invalid input · 6 Graph failure (e.g. the object does not exist).
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"
# shellcheck source=m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/m365-lib.sh"
ZY_SELF=m365-propose

readonly ZY_PROPOSE_REASON_MAX=500 ZY_PROPOSE_SUBJECT_CHARS=60 ZY_PROPOSE_FOLDER_MAX=100
readonly ZY_PROPOSE_URL_RE='([A-Za-z][A-Za-z0-9+.-]*://|www\.)'
readonly ZY_PROPOSE_EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
readonly ZY_PROPOSE_CROCKFORD=0123456789ABCDEFGHJKMNPQRSTVWXYZ

die() { # die <exit code> <message>
  zy_die "$@"
}

usage() {
  die 4 "$1 (usage: propose.sh send-draft <draft-id> --reason <text> | move <message-id> <folder> --reason <text> | delete <message-id> --reason <text>)"
}

# --- 1. the arguments (exit 4 before anything else) ----------------------------------------------------------------

action=""
target=""
folder=""
reason=""
have_reason=0
positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --to | --to=* | --cc | --cc=* | --bcc | --bcc=* | --body | --body=* | --subject | --subject=* | --recipient*) die 4 "no recipient, body or subject parameter exists — the proposal snapshots the Draft as Graph holds it" ;;
    --reason)
      [ $# -ge 2 ] || usage "--reason needs a text"
      [ "$have_reason" -eq 0 ] || usage "--reason given twice"
      reason="$2"
      have_reason=1
      shift 2
      ;;
    --reason=*)
      [ "$have_reason" -eq 0 ] || usage "--reason given twice"
      reason="${1#--reason=}"
      have_reason=1
      shift
      ;;
    --*) usage "unknown option '${1:0:40}'" ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done
[ "${#positional[@]}" -gt 0 ] || usage "no action given"
action="${positional[0]}"
case "$action" in
  send-draft | delete)
    [ "${#positional[@]}" -eq 2 ] || usage "$action needs exactly <id>"
    ;;
  move)
    [ "${#positional[@]}" -eq 3 ] || usage "move needs <message-id> <folder>"
    folder="${positional[2]}"
    ;;
  *) usage "unknown action '${action:0:40}' (only send-draft, move and delete exist)" ;;
esac
target="${positional[1]}"
[[ "$target" =~ $ZY_M365_ID_RE ]] || usage "'${target:0:40}' is not a message id"
if [ "$action" = move ]; then
  if [ -z "$folder" ] || [ "$(zy_char_count "$folder")" -gt "$ZY_PROPOSE_FOLDER_MAX" ] ||
    [[ "$folder" == -* ]] || [[ "$folder" =~ [[:cntrl:]] ]]; then
    usage "the folder must be a name or id of 1..$ZY_PROPOSE_FOLDER_MAX printable characters"
  fi
fi

# The reason: one line, control characters stripped, 1..500 characters, no URL, no e-mail address, no secret (the
# matching text is never echoed).
[ "$have_reason" -eq 1 ] || usage "no --reason given"
reason="$(zy_collapse_line "$reason" | tr -d '\000-\037\177')"
[ -n "$reason" ] || usage "the reason is empty"
[ "$(zy_char_count "$reason")" -le "$ZY_PROPOSE_REASON_MAX" ] || die 4 "the reason is longer than $ZY_PROPOSE_REASON_MAX characters"
if [[ "$reason" =~ $ZY_PROPOSE_URL_RE ]]; then
  die 4 "the reason contains a URL — say why in words"
fi
if [[ "$reason" =~ $ZY_PROPOSE_EMAIL_RE ]]; then
  die 4 "the reason contains an e-mail address — the recipients are the Draft's own"
fi
if zy_secret_match "$reason"; then
  die 4 "the reason matches secret pattern $ZY_SECRET_NAME (not recorded)"
fi

# --- 2. the principal, the tools, the configuration (proposing is allowed unattended) ---------------------------------

zy_require_config
command -v jq > /dev/null || die 3 "jq not found"
command -v openssl > /dev/null || die 3 "openssl not found"
# shellcheck disable=SC2119 # no argument: the full validation (the consent block included)
zy_m365_load_config
[[ " $M365_CONSENT_ALLOWED_ACTIONS " == *" $action "* ]] || die 4 "action $action not allowed by consent.allowed_actions"

case "${ZYGGY_M365_ORIGIN:-session}" in
  session) origin=session ;;
  brief) origin="brief $(zy_local_date)" ;;
  "brief "*)
    origin="$ZYGGY_M365_ORIGIN"
    [[ "${origin#brief }" =~ $ZY_M365_DATE_RE ]] || die 4 "ZYGGY_M365_ORIGIN must be 'brief [<date>]' or 'session'"
    ;;
  *) die 4 "ZYGGY_M365_ORIGIN must be 'brief [<date>]' or 'session'" ;;
esac

graph_sh="$ZY_M365_SKILL_DIR/graph.sh"
state_sh="$ZY_M365_SKILL_DIR/state.sh"
work="$(mktemp -d -t zyggy-m365-propose.XXXXXX)"
trap 'rm -rf "$work"' EXIT

# --- 3. one proposal per action and target ------------------------------------------------------------------------------

# A pending (or approved, not yet executed) row for the same action and target answers the call: the owner sees it once.
if [ -s "$ZY_M365_PROPOSALS" ]; then
  existing="$(jq -r -n --arg a "$action" --arg t "$target" \
    'first(inputs | select(.action == $a and .target_id == $t and (.status == "pending" or .status == "approved")) | .id) // empty' \
    "$ZY_M365_PROPOSALS")" || die 3 "$ZY_M365_PROPOSALS is not a JSON Lines file"
  if [ -n "$existing" ]; then
    printf 'proposed: %s (duplicate)\n' "$existing"
    exit 0
  fi
fi

# --- 4. the object as Graph holds it --------------------------------------------------------------------------------------

# graph.sh <verb…> → stdout; on failure its message (without the key line) is ours and its exit code too (3 or 6).
graph() {
  local rc=0 msg
  "$graph_sh" "$@" < /dev/null 2> "$work/graph-err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    msg="$(grep -v '^key: ' "$work/graph-err" | tail -n 1 || true)"
    die "$rc" "${msg#m365: }"
  fi
}

kind="$(zy_m365_kind_of "$action")"
graph snapshot "$kind" "$target" > "$work/snapshot"
canonical="$(sed -n 1p "$work/snapshot")"
hash="$(sed -n 's/^hash: //p' "$work/snapshot")"
# the row binds the lib's hash of the canonical line, the same one graph.sh's write verbs recompute
[ "$hash" = "$(zy_m365_hash "$canonical")" ] || die 6 "graph.sh snapshot returned an inconsistent hash"

outside_flag=false
policy_json=null
if [ "$action" = send-draft ]; then
  [ "$(jq -r '.isDraft' <<< "$canonical")" = true ] || die 4 "$target is not a draft"
  # The recipient policy (plan 23 assumption 24): the mailbox, plus the sender and replyTo of the replied-to message —
  # the one among today's and yesterday's replied ids (state.sh) in the Draft's conversation. Outside → flag only.
  graph message-sender "$target" > "$work/draft-sender"
  conversation="$(jq -r '.conversationId // ""' "$work/draft-sender")"
  policy="$(printf '%s' "$M365_MAILBOX" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$conversation" ]; then
    today="$(zy_local_date)"
    yesterday="$(date -d "$today - 1 day" +%F)"
    for day in "$today" "$yesterday"; do
      while IFS= read -r id; do
        [[ "$id" =~ $ZY_M365_ID_RE ]] || continue
        "$graph_sh" message-sender "$id" < /dev/null > "$work/sender" 2> /dev/null || continue
        if [ "$(jq -r '.conversationId // ""' "$work/sender")" = "$conversation" ]; then
          policy="$(printf '%s\n' "$policy" "$(jq -r '.from, .replyTo[]' "$work/sender")")"
        fi
      done < <("$state_sh" get replied "$day")
    done
  fi
  policy_json="$(printf '%s\n' "$policy" | sed '/^$/d' | jq -R . | jq -s -c 'unique')"
  outside="$(jq -r --argjson p "$policy_json" '(.to + .cc + .bcc) - $p | unique | join(", ")' <<< "$canonical")"
  [ -z "$outside" ] || outside_flag=true
fi

# --- 5. the row ------------------------------------------------------------------------------------------------------------

# A ULID-like id: 10 Crockford base32 characters of the millisecond clock, then 16 of 80 random bits — time-sortable.
base32() { # base32 <number> <characters>
  local n="$1" i out=""
  for ((i = 0; i < $2; i++)); do
    out="${ZY_PROPOSE_CROCKFORD:$((n & 31)):1}$out"
    n=$((n >> 5))
  done
  printf '%s' "$out"
}
random="$(openssl rand -hex 10)"
row_id="$(base32 "$(zy_date UTC +%s%3N)" 10)$(base32 "$((16#${random:0:10}))" 8)$(base32 "$((16#${random:10:10}))" 8)"

row="$(jq -c -n --arg id "$row_id" --arg ts "$(zy_now_utc)" --arg a "$action" --arg t "$target" --arg f "$folder" \
  --argjson s "$canonical" --arg h "$hash" --arg r "$reason" --arg o "$origin" --argjson out "$outside_flag" \
  --argjson p "$policy_json" '{id: $id, ts: $ts, action: $a, target_id: $t} + (if $a == "move" then {folder: $f} else {} end)
    + {snapshot: $s, snapshot_hash: $h, reason: $r, origin: $o, status: "pending", recipient_outside_policy: $out}
    + (if $p == null then {} else {recipient_policy: $p} end)')"
zy_m365_consent_append "$ZY_M365_PROPOSALS" "$row"

subject="$(jq -r --argjson n "$ZY_PROPOSE_SUBJECT_CHARS" '.subject | gsub("[[:cntrl:]]"; " ") | .[:$n]' <<< "$canonical")"
printf 'proposed: %s %s "%s" — review with m365-approve.sh on the VM%s\n' "$row_id" "$action" "$subject" \
  "$([ "$outside_flag" = false ] || printf ' (recipient outside policy)')"

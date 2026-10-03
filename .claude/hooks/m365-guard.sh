#!/usr/bin/env bash
set -euo pipefail
# PreToolUse guard for the three m365 action tools (spec 23 D7): refuses every call outside the instance's policy
# before Claude Code shows its permission prompt, so the owner is only ever asked about a call the policy allows.
# It never allows and never asks — the template's permissions.ask rule is the consent; this hook only narrows.
# stdin: the hook JSON ({session_id, hook_event_name, tool_name, tool_input}); tool_input as the pinned server's
# schemas have it (plan 23 Step R1, 0002 "Probe findings (D7)": userId/messageId/driveId/driveItemId and body; body
# keys read case-insensitively). Output: nothing and exit 0 (the ask rule prompts) or the deny JSON and exit 0. Any
# failure of its own — bad input, configuration, graph.sh — is exit 2 with one stderr line: Claude Code blocks the
# call. Never prints a token, a mail body or file content. Runs whatever ZYGGY_HOOKS says (unattended runs deny the
# tools anyway). Graph lookups (upload, move) go through graph.sh's read verbs, at most two per call.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../skills/m365/m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../skills/m365/m365-lib.sh"
ZY_SELF=m365-guard
set -E

# Fail closed: every error path, the libraries' zy_die included, ends in exit 2 with one stderr line.
zy_die() { # zy_die <exit code> <message>
  printf 'm365-guard: %s\n' "$2" >&2
  exit 2
}
trap 'printf "m365-guard: internal error (line %s)\n" "$LINENO" >&2; exit 2' ERR
trap 'rc=$?; [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || exit 2' EXIT

# Moves Claude Code may pass to the move tool without a folder lookup (spec Decision Table); recoverable deletions
# and purges are never a destination.
readonly ZY_GUARD_MOVE_NAMES=' deleteditems archive inbox '
readonly ZY_GUARD_ARG_RE='^[A-Za-z0-9_$-]{1,40}$'

deny() { # deny <reason> — the one output of a refusal
  jq -nc --arg r "m365-guard: refused: $1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# --- the input ---------------------------------------------------------------------------------------------------

input="$(cat)"
jq -e 'type == "object" and (.tool_name | type) == "string" and (.tool_input | type) == "object"' <<< "$input" > /dev/null 2>&1 ||
  zy_die 2 "hook input is not a PreToolUse object with tool_name and tool_input"
tool="$(jq -r '.tool_name' <<< "$input")"
case "$tool" in
  mcp__m365__send-shared-mailbox-mail) action=send ;;
  mcp__m365__upload-file-content) action=upload ;;
  mcp__m365__move-shared-mailbox-message) action=move ;;
  *) exit 0 ;; # not an action tool: nothing to guard (the settings matcher never sends one)
esac
args="$(jq -c '.tool_input' <<< "$input")"

zy_require_config
# shellcheck disable=SC2119 # no argument: the full validation
zy_m365_load_config
[[ " $M365_ACTIONS_ENABLED " == *" $action "* ]] || deny "action disabled for this instance"

# Arguments the server would merge into the body or the path beyond the tool's own: refused, named when printable.
expect_args() { # expect_args <allowed argument…>
  local name allowed=" $* includeHeaders excludeResponse confirm "
  while IFS= read -r name; do
    if [[ "$allowed" != *" $name "* ]]; then
      [[ "$name" =~ $ZY_GUARD_ARG_RE ]] || deny "unexpected argument"
      deny "unexpected argument $name"
    fi
  done < <(jq -r 'keys[]' <<< "$args")
}

# A JSON object's value for <key>, matched case-insensitively (the server passes body keys through as given and
# Graph reads them without regard to case); "null" when absent. A key present twice in different case is refused.
ci_get() { # ci_get <json object> <lower-case key>
  jq -c --arg k "$2" '[to_entries[] | select(.key | ascii_downcase == $k) | .value] | if length == 0 then null else .[0] end' <<< "$1"
}
ci_unique() { # ci_unique <json object> <what>
  jq -e '[keys[] | ascii_downcase] | (unique | length) == length' <<< "$1" > /dev/null || deny "$2 names a field twice"
}

require_mailbox() {
  local user
  user="$(jq -r '.userId // "" | strings' <<< "$args")"
  [ "${user,,}" = "${M365_MAILBOX,,}" ] || deny "only the configured mailbox"
}

# graph.sh <verb> <args…> → GRAPH_OUT, in this shell (never in a command substitution, so a failure stays the guard's
# own: exit 2, one stderr line — never an empty answer read as a refusal).
GRAPH_OUT=""
graph_read() { # graph_read <verb> <args…>
  GRAPH_OUT="$("$ZY_M365_SKILL_DIR/graph.sh" "$@" < /dev/null 2> /dev/null)" || zy_die 2 "graph.sh $1 failed"
}

# --- send-shared-mailbox-mail ------------------------------------------------------------------------------------

guard_send() {
  local body msg save mbody ctype content n recipients addr key
  expect_args userId body
  require_mailbox
  body="$(jq -c '.body' <<< "$args")"
  jq -e 'type == "object"' <<< "$body" > /dev/null || deny "malformed body (an object with Message is expected)"
  ci_unique "$body" "the body"
  while IFS= read -r key; do
    case "$key" in
      message | savetosentitems) ;;
      *) deny "unexpected body field" ;;
    esac
  done < <(jq -r 'keys[] | ascii_downcase' <<< "$body")
  save="$(ci_get "$body" savetosentitems)"
  [ "$save" = null ] || [ "$save" = true ] || deny "saveToSentItems must stay true"
  msg="$(ci_get "$body" message)"
  jq -e 'type == "object"' <<< "$msg" > /dev/null || deny "malformed body (an object with Message is expected)"
  ci_unique "$msg" "the message"
  # the fields a prompt shows and a reader can check; anything else could hide a recipient, a header or content
  while IFS= read -r key; do
    case "$key" in
      subject | body | torecipients | ccrecipients | importance) ;;
      attachments) jq -e '(. // []) == []' <<< "$(ci_get "$msg" attachments)" > /dev/null || deny "attachments are not allowed" ;;
      bccrecipients) jq -e '(. // []) == []' <<< "$(ci_get "$msg" bccrecipients)" > /dev/null || deny "Bcc is not allowed" ;;
      from | sender | replyto) deny "from, sender and replyTo are not allowed" ;;
      *) deny "message field not allowed" ;;
    esac
  done < <(jq -r 'keys[] | ascii_downcase' <<< "$msg")
  mbody="$(ci_get "$msg" body)"
  jq -e 'type == "object"' <<< "$mbody" > /dev/null || deny "only plain-text bodies (body.contentType text)"
  ci_unique "$mbody" "the message body"
  jq -e 'keys | all(ascii_downcase | IN("content", "contenttype"))' <<< "$mbody" > /dev/null || deny "message body field not allowed"
  ctype="$(ci_get "$mbody" contenttype)"
  [ "${ctype,,}" = '"text"' ] || deny "only plain-text bodies"
  content="$(ci_get "$mbody" content)"
  jq -e 'type == "string" or type == "null"' <<< "$content" > /dev/null || deny "malformed body content"
  n="$(jq '(. // "") | length' <<< "$content")"
  [ "$n" -le "$M365_SEND_BODY_MAX" ] || deny "body over $M365_SEND_BODY_MAX characters"
  recipients="$(jq -c --argjson to "$(ci_get "$msg" torecipients)" --argjson cc "$(ci_get "$msg" ccrecipients)" -n \
    '[($to // []), ($cc // [])] | if all(type == "array") then add else null end')"
  [ "$recipients" != null ] || deny "malformed recipients"
  jq -e 'all(.[]; type == "object" and (.emailAddress | type) == "object" and (.emailAddress.address | type) == "string")' \
    <<< "$recipients" > /dev/null || deny "malformed address"
  n="$(jq 'length' <<< "$recipients")"
  [ "$n" -gt 0 ] || deny "no recipient"
  [ "$n" -le "$M365_SEND_MAX_RECIPIENTS" ] || deny "more than $M365_SEND_MAX_RECIPIENTS recipients"
  while IFS= read -r addr; do
    [[ "$addr" =~ $ZY_M365_UPN_RE ]] || deny "malformed address"
  done < <(jq -r '.[].emailAddress.address' <<< "$recipients")
}

# --- upload-file-content (unreachable while the pinned server URL-encodes the new-file form: Step R1, fact 3) ---------

guard_upload() {
  local drive item parent name ext content size
  expect_args driveId driveItemId body
  drive="$(jq -r '.driveId // "" | strings' <<< "$args")"
  if [ -z "$M365_WRITE_DRIVE_ID" ] || [ "$drive" != "$M365_WRITE_DRIVE_ID" ]; then
    deny "drive not allowed"
  fi
  item="$(jq -r '.driveItemId // "" | strings' <<< "$args")"
  [[ "$item" =~ ^([^:/]+):/(.+):$ ]] || deny "only the new-file form <parent-id>:/<name>:"
  parent="${BASH_REMATCH[1]}"
  name="${BASH_REMATCH[2]}"
  [[ "$parent" =~ $ZY_M365_ITEM_ID_RE ]] || deny "malformed parent id"
  if [[ "$name" == */* ]] || [[ "$name" == *\\* ]] || [[ "$name" == *..* ]] || [[ "$name" =~ [[:cntrl:]] ]] ||
    [ "${#name}" -gt 255 ] || [[ "$name" == .* ]]; then
    deny "invalid file name"
  fi
  [[ "$name" == *.* ]] || deny "extension not allowed"
  ext="${name##*.}"
  [[ " $M365_UPLOAD_EXTENSIONS " == *" ${ext,,} "* ]] || deny "extension not allowed"
  # the content: a base64 string the server decodes (fact 4); its decoded size is what Graph stores
  content="$(jq -r '.body | strings' <<< "$args")"
  content="${content//[$'\r\n']/}"
  if [[ ! "$content" =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || [ $((${#content} % 4)) -ne 0 ]; then
    deny "content is not base64"
  fi
  size="$(base64 -d <<< "$content" 2> /dev/null | wc -c)" || deny "content is not base64"
  [ "$size" -le "$M365_UPLOAD_MAX_BYTES" ] || deny "content over $M365_UPLOAD_MAX_BYTES bytes"
  graph_read item-kind "$drive" "$parent"
  [ "$GRAPH_OUT" = folder ] || deny "parent is not a folder"
  graph_read item-exists "$drive" "$parent" "$name"
  case "$GRAPH_OUT" in
    absent) ;;
    exists) deny "target exists (would overwrite)" ;;
    *) zy_die 2 "graph.sh item-exists gave no answer" ;;
  esac
}

# --- move-shared-mailbox-message -----------------------------------------------------------------------------------

guard_move() {
  local body dest
  expect_args userId messageId body
  require_mailbox
  [[ "$(jq -r '.messageId // "" | strings' <<< "$args")" =~ $ZY_M365_ID_RE ]] || deny "malformed message id"
  body="$(jq -c '.body' <<< "$args")"
  jq -e 'type == "object"' <<< "$body" > /dev/null || deny "malformed body (an object with DestinationId is expected)"
  ci_unique "$body" "the body"
  jq -e 'keys | all(ascii_downcase == "destinationid")' <<< "$body" > /dev/null || deny "unexpected body field"
  dest="$(jq -r '.[] | strings' <<< "$body")"
  [ -n "$dest" ] || deny "destination not allowed"
  if [[ "$ZY_GUARD_MOVE_NAMES" == *" ${dest,,} "* ]]; then
    return 0
  fi
  # a folder id of the mailbox that is not an excluded folder; every other well-known name or id is refused
  [[ "$dest" =~ $ZY_M365_ID_RE ]] || deny "destination not allowed"
  graph_read mail-folders
  jq -e --arg d "$dest" 'any(.[]; .id == $d and (.excluded | not)
    and ((.wellKnownName // "") | IN("recoverableitemsdeletions", "purges") | not))' \
    <<< "$GRAPH_OUT" > /dev/null || deny "destination not allowed"
}

case "$action" in
  send) guard_send ;;
  upload) guard_upload ;;
  move) guard_move ;;
esac
exit 0

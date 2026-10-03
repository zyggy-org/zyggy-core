#!/usr/bin/env bash
set -euo pipefail
# PostToolUse log for the three m365 action tools (spec 23 D7): one body-free row per call in
# ~/.local/state/zyggy/m365/actions.jsonl (0600, appended under a lock) — {ts, session_id, tool, summary, status}.
# The summary names what the owner allowed without its content: recipients, subject and body length (send); drive,
# parent, name and decoded size (upload); message id and destination (move). status is "ok", or "error: <code>" when
# the tool result reports an error (MCP isError, or a Graph error object in its text). The owner reconciles these rows
# with the Exchange/SharePoint audit log (runbook 13); an action without a row means the key was used elsewhere.
# A failure to record is exit 2 with one stderr line, which Claude Code shows to Claude (the action already ran).
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../skills/m365/m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../skills/m365/m365-lib.sh"
ZY_SELF=m365-log
set -E

zy_die() { # zy_die <exit code> <message>
  printf 'm365-log: %s\n' "$2" >&2
  exit 2
}
trap 'printf "m365-log: internal error (line %s)\n" "$LINENO" >&2; exit 2' ERR
trap 'rc=$?; [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || exit 2' EXIT

input="$(cat)"
jq -e 'type == "object" and (.tool_name | type) == "string"' <<< "$input" > /dev/null 2>&1 ||
  zy_die 2 "hook input is not a PostToolUse object with tool_name"
tool="$(jq -r '.tool_name' <<< "$input")"
case "$tool" in
  mcp__m365__send-shared-mailbox-mail | mcp__m365__upload-file-content | mcp__m365__move-shared-mailbox-message) ;;
  *) exit 0 ;;
esac

# The summary, built by jq from tool_input only: never the mail body or the file content, control characters
# flattened, the subject cut to 120 characters. Body keys are read case-insensitively, as the guard reads them.
summary="$(jq -r '
  def ci($k): if type == "object" then [to_entries[] | select(.key | ascii_downcase == $k) | .value][0] else null end;
  def flat: tostring | gsub("[[:cntrl:]]"; " ");
  .tool_input as $a
  | if .tool_name | endswith("send-shared-mailbox-mail") then
      ($a.body | ci("message")) as $m
      | ([($m | ci("torecipients") // [])[], ($m | ci("ccrecipients") // [])[]] | map(.emailAddress.address // "" | flat)
          | join(",")) as $to
      | "to \($to) subject \"\(($m | ci("subject") // "") | flat | .[:120])\" body \((($m | ci("body")) | ci("content") // "") | length) chars"
    elif .tool_name | endswith("upload-file-content") then
      ((($a.driveItemId // "") | flat) | capture("^(?<p>[^:]*):/(?<n>.*):$") // {p: ., n: ""}) as $i
      | (($a.body // "") | flat | gsub("[\r\n]"; "")) as $c
      | ($c | length * 3 / 4 - (if endswith("==") then 2 elif endswith("=") then 1 else 0 end) | floor) as $size
      | "drive \(($a.driveId // "") | flat) parent \($i.p) name \($i.n) size \($size)"
    else
      "message \(($a.messageId // "") | flat) -> \((($a.body | ci("destinationid")) // "") | flat)"
    end' <<< "$input")"

# The status: an MCP error result, or a Graph error object in the result text, is "error: <code>".
status="$(jq -r '
  def code: tostring | gsub("[^A-Za-z0-9_.-]"; "") | .[:40] | if . == "" then "unknown" else . end;
  .tool_response as $r
  | ([$r | .. | objects | select(has("text")) | .text | strings | (try fromjson catch null) | objects | .error // empty]
      | first) as $e
  | if ($r | type) == "object" and ($r.isError // $r.is_error // false) == true then
      "error: " + (($e | if type == "object" then (.code // .status // "unknown") else "unknown" end) | code)
    elif $e != null then
      "error: " + (($e | if type == "object" then (.code // .status // "unknown") else $e end) | code)
    else "ok" end' <<< "$input")"

row="$(jq -nc --arg ts "$(zy_now_utc)" --arg s "$(jq -r '.session_id // "" | tostring' <<< "$input")" \
  --arg t "${tool#mcp__m365__}" --arg sum "$summary" --arg st "$status" \
  '{ts: $ts, session_id: $s, tool: $t, summary: $sum, status: $st}')"
zy_m365_append "$ZY_M365_ACTIONS" "$row" || zy_die 2 "could not append to $ZY_M365_ACTIONS"
exit 0

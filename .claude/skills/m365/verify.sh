#!/usr/bin/env bash
set -euo pipefail
# The post-run audit of the m365 connector (spec 23, AC-39): every Draft created in the window and every mail that
# left the mailbox in it, checked after the fact through graph.sh reads. Drafts: exactly one brief Draft
# ("Zyggy — morning brief …") to the owner only; reply Drafts ("RE: …") only to the sender or replyTo of a message
# recorded for <date> with state.sh set replied, in the same conversation; any other Draft to the owner only; no URL
# and no secret pattern in any Draft's generated text and no e-mail address in a reply or other Draft (the brief's
# own format names senders); at most one brief + brief.reply_cap Drafts. Sent Items: every item must be explained
# by one executed send-draft row of executions.jsonl (the proposal snapshot's subject, sentDateTime within ± 2 min
# of the execution — the send POST returns no message id), and every executed row must have its item.
# Writes the receipt brief-<date>.json (0600, no body text); prints `audit ok` (exit 0) or `audit FLAGGED: …`
# (exit 5). Never deletes, moves or changes anything: graph.sh read verbs only. Allowed unattended (the brief run).
# usage: verify.sh <date YYYY-MM-DD> <window-start YYYY-MM-DDTHH:MM:SSZ>
# Exit 0 audit ok · 3 configuration · 4 usage · 5 audit flagged · 6 Graph or identity failure (no receipt).
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"
# shellcheck source=m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/m365-lib.sh"
ZY_SELF=m365-verify

readonly ZY_VERIFY_BRIEF_PREFIX='Zyggy — morning brief' ZY_VERIFY_MATCH_SECONDS=120 ZY_VERIFY_SUBJECT_CHARS=80
readonly ZY_VERIFY_URL_RE='([A-Za-z][A-Za-z0-9+.-]*://|www\.)'
readonly ZY_VERIFY_EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
# Outlook's separator above the quoted original in a reply Draft (createReply + Comment): the text below it is the
# message being answered, not generated text, and is not scanned.
readonly ZY_VERIFY_QUOTE_RE='^(_{8,}|-{3,} ?Original Message ?-{3,})[[:space:]]*$'

die() { # die <exit code> <message>
  zy_die "$@"
}

usage() {
  die 4 "$1 (usage: verify.sh <date YYYY-MM-DD> <window-start YYYY-MM-DDTHH:MM:SSZ>)"
}

# --- 1. the arguments (exit 4 before anything else) ----------------------------------------------------------------

[ $# -eq 2 ] || usage "needs exactly <date> <window-start>"
[[ "$1" =~ $ZY_M365_DATE_RE ]] || usage "'${1:0:40}' is not a date"
[[ "$2" =~ $ZY_M365_ISO_RE ]] || usage "'${2:0:40}' is not an ISO timestamp"
date="$1"
window="$2"

# --- 2. the principal, the tools, the configuration ----------------------------------------------------------------

zy_require_config
command -v jq > /dev/null || die 3 "jq not found"
# shellcheck disable=SC2119 # no argument: the full validation
zy_m365_load_config
mailbox="$(printf '%s' "$M365_MAILBOX" | tr '[:upper:]' '[:lower:]')"
reply_cap="$(zy_m365_cfg .brief.reply_cap)"

graph_sh="$ZY_M365_SKILL_DIR/graph.sh"
state_sh="$ZY_M365_SKILL_DIR/state.sh"
work="$(mktemp -d -t zyggy-m365-verify.XXXXXX)"
trap 'rm -rf "$work"' EXIT

# graph.sh <verb…> > <out>; its exit status is returned, its last stderr line (without the key line) kept.
graph_run() { # graph_run <out file> <verb…>
  local out="$1" rc=0
  shift
  "$graph_sh" "$@" < /dev/null > "$out" 2> "$work/graph-err" || rc=$?
  return "$rc"
}

graph_message() {
  local msg
  msg="$(grep -v '^key: ' "$work/graph-err" | tail -n 1 || true)"
  printf '%s' "${msg#m365: }"
}

# --- 3. what Graph holds: the Drafts and Sent Items of the window, the replied-to messages --------------------------

rc=0
graph_run "$work/drafts.json" drafts-since "$window" || rc=$?
[ "$rc" -eq 0 ] || die "$rc" "$(graph_message)"

# The replied ids recorded for <date>; one Graph lookup each. An id Graph no longer finds allows no recipient.
"$state_sh" get replied "$date" > "$work/replied.ids"
: > "$work/senders.jsonl"
while IFS= read -r id; do
  [[ "$id" =~ $ZY_M365_ID_RE ]] || continue
  rc=0
  graph_run "$work/sender.json" message-sender "$id" || rc=$?
  if [ "$rc" -eq 0 ]; then
    cat "$work/sender.json" >> "$work/senders.jsonl"
  elif [ "$rc" -ne 6 ] || [[ "$(graph_message)" != "not found ($id)" ]]; then
    die "$rc" "$(graph_message)"
  fi
done < "$work/replied.ids"

rc=0
graph_run "$work/sent.json" sent-since "$window" || rc=$?
[ "$rc" -eq 0 ] || die "$rc" "$(graph_message)"

# --- 4. the Drafts --------------------------------------------------------------------------------------------------

# One record per Draft, in Graph's order: id, kind (brief | reply | other), subject (one line, ≤ 80), recipients
# (to ∪ cc ∪ bcc, lower-cased), and the recipient reason, if any.
jq -c -n --slurpfile d "$work/drafts.json" --slurpfile s "$work/senders.jsonl" --arg mb "$mailbox" \
  --arg prefix "$ZY_VERIFY_BRIEF_PREFIX" --argjson n "$ZY_VERIFY_SUBJECT_CHARS" '
  def addrs: [.[]?.emailAddress.address // empty | ascii_downcase];
  $d[0][] as $m
  | ($m.subject // "" | gsub("[[:cntrl:]]"; " ") | .[:$n]) as $subject
  | ((($m.toRecipients | addrs) + ($m.ccRecipients | addrs) + ($m.bccRecipients | addrs)) | unique) as $to
  | (if $subject | startswith($prefix) then "brief" elif $subject | test("^re:"; "i") then "reply" else "other" end) as $kind
  | [$s[] | select(.conversationId != "" and .conversationId == ($m.conversationId // ""))] as $replied
  | (if $kind == "reply" then [$mb] + [$replied[] | .from, .replyTo[]] else [$mb] end) as $allowed
  | ($to - $allowed | join(", ")) as $outside
  | {id: $m.id, kind: $kind, subject: $subject, recipients: $to,
     reason: (if $kind == "reply" and ($replied | length) == 0 then "reply draft \"\($subject)\" has no recorded replied message"
              elif $outside == "" then ""
              elif $kind == "brief" then "brief draft has recipients other than the owner (\($outside))"
              else "draft \"\($subject)\" to \($outside) not allowed" end)}' > "$work/records.jsonl"

# stdin up to (not including) the first quote-separator line; CR removed (bash regex: mawk has no {n,} intervals)
above_quote() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ ! "$line" =~ $ZY_VERIFY_QUOTE_RE ]] || break
    printf '%s\n' "$line"
  done
}

reasons=()
briefs=0
total=0
index=0
while IFS= read -r record; do
  kind="$(jq -r .kind <<< "$record")"
  subject="$(jq -r .subject <<< "$record")"
  reason="$(jq -r .reason <<< "$record")"
  [ -z "$reason" ] || reasons+=("$reason")
  total=$((total + 1))
  [ "$kind" != brief ] || briefs=$((briefs + 1))
  # the generated text: the whole body, above Outlook's quote separator for a reply; held in memory only
  text="$(jq -r --argjson i "$index" '.[$i] | .body.content // .bodyPreview // ""' "$work/drafts.json")"
  if [ "$kind" = reply ]; then
    text="$(above_quote <<< "$text")"
  fi
  if [[ "$text" =~ $ZY_VERIFY_URL_RE ]]; then
    reasons+=("draft \"$subject\" contains a URL")
  fi
  if [ "$kind" != brief ] && [[ "$text" =~ $ZY_VERIFY_EMAIL_RE ]]; then
    reasons+=("draft \"$subject\" contains an e-mail address")
  fi
  if zy_secret_match "$text"; then
    reasons+=("draft \"$subject\" matches secret pattern $ZY_SECRET_NAME")
  fi
  index=$((index + 1))
done < "$work/records.jsonl"
text=""

if [ "$briefs" -eq 0 ]; then
  reasons+=("no brief draft")
elif [ "$briefs" -gt 1 ]; then
  reasons+=("$briefs brief drafts")
fi
if [ "$total" -gt $((reply_cap + 1)) ]; then
  reasons+=("$total drafts > cap $((reply_cap + 1)) (one brief + reply_cap $reply_cap)")
fi

# --- 5. Sent Items against executions.jsonl ----------------------------------------------------------------------------

# The execution rows of the window; the sends among them (2xx send-draft) carry their proposal's snapshot subject.
: > "$work/executions.jsonl"
[ ! -s "$ZY_M365_EXECUTIONS" ] || cp "$ZY_M365_EXECUTIONS" "$work/executions.jsonl"
: > "$work/proposals.jsonl"
[ ! -s "$ZY_M365_PROPOSALS" ] || cp "$ZY_M365_PROPOSALS" "$work/proposals.jsonl"
jq -c -n --slurpfile e "$work/executions.jsonl" --slurpfile p "$work/proposals.jsonl" --slurpfile sent "$work/sent.json" \
  --arg w "$window" --argjson secs "$ZY_VERIFY_MATCH_SECONDS" --argjson n "$ZY_VERIFY_SUBJECT_CHARS" '
  def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
  def line: gsub("[[:cntrl:]]"; " ") | .[:$n];
  ([$e[] | select((.ts // "") >= $w)]) as $window_rows
  | ([$p[] | {key: .id, value: (.snapshot.subject // "")}] | from_entries) as $subjects
  | ([$window_rows[] | select(.verb == "send-draft" and ((.http_status | tostring) | test("^2")))
      | . + {subject: ($subjects[.row_id // ""] // "")}] | sort_by(.ts)) as $sends
  | ($sent[0] // [] | to_entries) as $items
  | reduce $sends[] as $x ({used: [], missing: []};
      . as $acc
      | ([$items[] | select((.key as $k | $acc.used | any(.[]; . == $k)) | not)
          | select(.value.subject == $x.subject and ((((.value.sentDateTime // "") | epoch) - ($x.ts | epoch)) | if . < 0 then -. else . end) <= $secs)
          | .key] | first) as $k
      | if $k == null then .missing += [$x] else .used += [$k] end)
  | . as $r
  | {executions: ($window_rows | length), sent_items: ($items | length), sent_matched: ($r.used | length),
     reasons: ([$items[] | select((.key as $k | $r.used | any(.[]; . == $k)) | not) | .value
       | "sent item \"\(.subject // "" | line)\" to \([.toRecipients[]?.emailAddress.address // empty | ascii_downcase] | join(", "))"
         + " has no executed consent row"]
       + [$r.missing[] | "executed row \(.row_id) (send-draft) has no sent item in the window"])}' > "$work/sent-audit.json"
while IFS= read -r reason; do
  reasons+=("$reason")
done < <(jq -r '.reasons[]' "$work/sent-audit.json")

# --- 6. the receipt and the verdict -------------------------------------------------------------------------------------

proposal_count() { # proposal_count <status>
  "$state_sh" list proposals --status "$1" > "$work/list"
  grep -vcxF 'no proposals' "$work/list" || true
}

audit=ok
[ "${#reasons[@]}" -eq 0 ] || audit=flagged
reasons_json="$(if [ "${#reasons[@]}" -gt 0 ]; then printf '%s\n' "${reasons[@]}"; fi | jq -R . | jq -s -c .)"
zy_m365_state_dir
receipt="$ZY_M365_STATE_DIR/brief-$date.json"
(
  umask 077
  jq -n --arg date "$date" --arg w "$window" --slurpfile records "$work/records.jsonl" \
    --argjson replied "$(jq -R . "$work/replied.ids" | jq -s -c .)" --argjson pending "$(proposal_count pending)" \
    --argjson executed "$(proposal_count executed)" --argjson refused "$(proposal_count refused)" \
    --slurpfile sent "$work/sent-audit.json" --arg audit "$audit" --argjson reasons "$reasons_json" '
    {date: $date, window_start: $w, drafts: [$records[] | {id, kind, subject, recipients}], replied_ids: $replied,
     proposals: {pending: $pending, executed: $executed, refused: $refused}, executions: $sent[0].executions,
     sent_items: $sent[0].sent_items, sent_matched: $sent[0].sent_matched, audit: $audit, reasons: $reasons}' > "$receipt.tmp"
)
chmod 600 "$receipt.tmp"
mv -f "$receipt.tmp" "$receipt"

if [ "$audit" = ok ]; then
  printf 'audit ok\n'
else
  joined="${reasons[0]}"
  for reason in "${reasons[@]:1}"; do
    joined+="; $reason"
  done
  printf 'audit FLAGGED: %s\n' "$joined"
  exit 5
fi

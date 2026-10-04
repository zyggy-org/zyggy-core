#!/usr/bin/env bash
set -euo pipefail
# The morning brief of the m365 connector (spec 23), the unit's entry point: one unattended claude run that reads the
# new mail and the changed files through the m365 server and leaves one brief Draft to the owner, with numbered
# suggested actions, and at most reply_cap reply Drafts; then the post-run audit, one memory line and one journal
# line. The run suggests but never acts (D7): its tool lists deny the three action tools (deny wins over the
# template's ask rules), graph.sh and every outbound channel, and it runs with --permission-prompts none.
# Order: pre-flight (configuration and claude before any request; graph.sh token fails fast on the identity; a
# receipt or a brief Draft of today → "already created"; the Inbox id and the drive ids) → a run directory →
# claude -p "/morning-brief <mailbox> <inbox-folder-id> <drive-id>… <run-dir>" → the JSON result checked against the
# caps → the run directory removed → verify.sh (receipt) → remember.sh → brief.jsonl (0600) and the journal line
# "brief <date>: mail <n>, files <m>, replies <r>, suggestions <s>, facts <f>, turns <t>, cost <usd>, audit ok|FLAGGED
# [, denials <tool,…>], exit <code>". Allowed unattended (the unit sets ZYGGY_HOOKS=off).
# usage: brief.sh
# Exit 0 done or already created · 3 configuration · 4 usage · 5 audit flagged (the Drafts stay for the owner's
# review) · 6 identity, Graph or model-run failure (no receipt).
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"
# shellcheck source=m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/m365-lib.sh"
ZY_SELF=m365-brief

readonly ZY_BRIEF_SUBJECT='Zyggy — morning brief'
readonly ZY_BRIEF_COUNTS_RE='^brief [0-9]{4}-[0-9]{2}-[0-9]{2}: mail ([0-9]+), files ([0-9]+), replies ([0-9]+), suggestions ([0-9]+), facts ([0-9]+)$'
readonly ZY_BRIEF_RUNBOOK='runbook 13 "Model run failed"'

die() { # die <exit code> <message>
  zy_die "$@"
}

# --- 1. the arguments, the principal, the configuration, the tools (no request yet) ----------------------------------

[ $# -eq 0 ] || die 4 "brief.sh takes no argument (usage: brief.sh)"
zy_require_config
command -v jq > /dev/null || die 3 "jq not found"
# shellcheck disable=SC2119 # no argument: the full validation
zy_m365_load_config
zy_m365_claude
date="$(zy_local_date)"
window="$(zy_now_utc)"
graph_sh="$ZY_M365_SKILL_DIR/graph.sh"
verify_sh="$ZY_M365_SKILL_DIR/verify.sh"
remember_sh="$ZY_M365_SKILL_DIR/../remember/remember.sh"

work="$(mktemp -d -t zyggy-m365-work.XXXXXX)"
run_dir=""
# shellcheck disable=SC2317 # invoked by the EXIT trap
cleanup() {
  rm -rf "$work"
  [ -z "$run_dir" ] || rm -rf "$run_dir"
}
trap cleanup EXIT
# A signal stops the claude child first; the EXIT trap then removes the run directory.
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

# One brief.jsonl row (0600 in the state directory): the run's record for the alerting of 22.
journal_append() { # journal_append <json row>
  zy_m365_state_dir
  (umask 077 && printf '%s\n' "$1" >> "$ZY_M365_STATE_DIR/brief.jsonl")
  chmod 600 "$ZY_M365_STATE_DIR/brief.jsonl"
}

# A failure after the pre-flight started: recorded in brief.jsonl, then one stderr line and the exit code.
fail() { # fail <exit code> <message>
  journal_append "$(jq -nc --arg d "$date" --arg t "$(zy_now_utc)" --argjson e "$1" --arg m "$2" \
    '{date: $d, ts: $t, exit: $e, error: $m}')"
  die "$1" "$2"
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

# --- 2. the pre-flight: the identity, idempotence, the Inbox and the drives ---------------------------------------------

rc=0
graph_run /dev/null token || rc=$?
key_src="$(grep -m 1 '^key: ' "$work/graph-err" || true)"
key_src="${key_src#key: }"
[ -z "$key_src" ] || printf 'key: %s\n' "$key_src" >&2
[ "$rc" -eq 0 ] || fail "$rc" "$(graph_message)"

already_created() {
  printf 'brief %s: already created\n' "$date"
  exit 0
}
[ ! -e "$ZY_M365_STATE_DIR/brief-$date.json" ] || already_created
# a brief Draft of today already in the Drafts folder (a run that failed after creating it, or a manual one)
midnight="$(date -u -d "TZ=\"$ZYGGY_TIMEZONE\" $date 00:00" +%Y-%m-%dT%H:%M:%SZ)"
rc=0
graph_run "$work/drafts.json" drafts-since "$midnight" || rc=$?
[ "$rc" -eq 0 ] || fail "$rc" "$(graph_message)"
if jq -e --arg s "$ZY_BRIEF_SUBJECT $date" 'any(.[]; .subject == $s)' "$work/drafts.json" > /dev/null; then
  already_created
fi

rc=0
graph_run "$work/folders.json" mail-folders || rc=$?
[ "$rc" -eq 0 ] || fail "$rc" "$(graph_message)"
inbox="$(jq -r 'first(.[] | select(.wellKnownName == "inbox") | .id) // empty' "$work/folders.json")"
[[ "$inbox" =~ $ZY_M365_ID_RE ]] || fail 6 "no Inbox folder in the mailbox's folder list"
rc=0
graph_run "$work/drives.json" drives || rc=$?
[ "$rc" -eq 0 ] || fail "$rc" "$(graph_message)"
drives=()
while IFS= read -r d; do
  [[ "$d" =~ $ZY_M365_DRIVE_ID_RE ]] || fail 6 "Graph returned an unexpected drive id"
  drives+=("$d")
done < <(jq -r '.[].id' "$work/drives.json")

# --- 3. the model run -------------------------------------------------------------------------------------------------------

# The run directory: downloads land here, parse.sh reads only here; its name carries the date for the prompt.
run_dir="$(zy_m365_run_dir "zyggy-m365-brief-$date")"
export ZYGGY_M365_RUN_DIR="$run_dir"
max_turns="$(zy_m365_cfg .brief.max_turns)"
budget="$(zy_m365_cfg .brief.budget_usd)"
model="$(zy_m365_cfg .brief.model)"
words=(/morning-brief "$M365_MAILBOX" "$inbox" "${drives[@]}" "$run_dir")
args=(-p "${words[*]}" --permission-mode auto --permission-prompts none --no-session-persistence --output-format json
  --max-turns "$max_turns" --max-budget-usd "$budget")
if [ -n "$model" ] && [ "$model" != null ]; then
  args+=(--model "$model")
fi
args+=(--allowedTools "$(zy_m365_join , "${ZY_M365_BRIEF_ALLOW[@]}")"
  --disallowedTools "$(zy_m365_join , "${ZY_M365_BRIEF_DENY[@]}")")

rc=0
zy_m365_run_claude "$work/result.json" "$work/claude-err" "brief $date" "${args[@]}" || rc=$?
rm -rf "$run_dir"
run_dir=""
result="$work/result.json"
if ! jq -e 'type == "object" and has("is_error")' "$result" > /dev/null 2>&1; then
  fail 6 "claude returned no JSON result (exit $rc) — $ZY_BRIEF_RUNBOOK"
fi
if [ "$(jq -r '.is_error' "$result")" = true ] || [ "$rc" -ne 0 ]; then
  fail 6 "claude run failed ($(jq -r '.subtype // "exit '"$rc"'"' "$result")) — $ZY_BRIEF_RUNBOOK"
fi
turns="$(jq -r '.num_turns // 0' "$result")"
cost="$(jq -r '.total_cost_usd // 0' "$result")"
if [[ ! "$turns" =~ ^[0-9]+$ ]] || [[ ! "$cost" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
  fail 6 "claude returned a malformed result (num_turns, total_cost_usd) — $ZY_BRIEF_RUNBOOK"
fi
over_cost="$(jq -n --argjson c "$cost" --argjson b "$budget" '$c > $b')"
if [ "$over_cost" = true ] || [ "$turns" -gt "$max_turns" ]; then
  cost_part="cost $cost of budget $budget"
  turns_part="turns $turns of $max_turns"
  [ "$over_cost" != true ] || cost_part="cost $cost > budget $budget"
  [ "$turns" -le "$max_turns" ] || turns_part="turns $turns > $max_turns"
  fail 6 "claude run over the cap ($cost_part, $turns_part) — $ZY_BRIEF_RUNBOOK"
fi

# The model's counts line (its last line of that shape); "-" where it gave none.
mail=-
files=-
replies=-
suggestions=-
facts=-
counts="$(jq -r '.result // ""' "$result" | grep -E "$ZY_BRIEF_COUNTS_RE" | tail -n 1 || true)"
if [[ "$counts" =~ $ZY_BRIEF_COUNTS_RE ]]; then
  mail="${BASH_REMATCH[1]}"
  files="${BASH_REMATCH[2]}"
  replies="${BASH_REMATCH[3]}"
  suggestions="${BASH_REMATCH[4]}"
  facts="${BASH_REMATCH[5]}"
fi
denials="$(jq -r '[.permission_denials[]?.tool_name // empty] | unique | join(",")' "$result")"

# --- 4. the audit, the memory line, the journal ----------------------------------------------------------------------

rc=0
"$verify_sh" "$date" "$window" < /dev/null > "$work/verify-out" 2> "$work/verify-err" || rc=$?
case "$rc" in
  0)
    audit=ok
    code=0
    ;;
  5)
    audit=FLAGGED
    code=5
    ;;
  *)
    msg="$(tail -n 1 "$work/verify-err")"
    fail "$rc" "audit failed (${msg#m365-verify: })"
    ;;
esac

summary="mail $mail, files $files, replies $replies, suggestions $suggestions, facts $facts"
# The brief's one memory line; remember.sh writes nothing under ZYGGY_HOOKS=off (the unit's setting for its own
# claude child), so it runs with the variable removed. A refusal is reported, never fatal.
rc=0
env -u ZYGGY_HOOKS "$remember_sh" --tag observed --source "m365-brief $date" -- \
  "Morning brief $date left as a Draft: $summary, audit $audit" < /dev/null > /dev/null 2> "$work/remember-err" || rc=$?
if [ "$rc" -ne 0 ]; then
  printf 'm365-brief: remember failed (exit %s): %s\n' "$rc" "$(tail -n 1 "$work/remember-err")" >&2
fi

cost_shown="$(printf '%.2f' "$cost")"
journal_append "$(jq -nc --arg d "$date" --arg t "$(zy_now_utc)" --arg mail "$mail" --arg files "$files" \
  --arg replies "$replies" --arg suggestions "$suggestions" --arg facts "$facts" --argjson turns "$turns" \
  --argjson cost "$cost_shown" --arg audit "$audit" --arg denials "$denials" --arg key "$key_src" --argjson e "$code" '
  def n: if . == "-" then null else tonumber end;
  {date: $d, ts: $t, mail: ($mail | n), files: ($files | n), replies: ($replies | n), suggestions: ($suggestions | n),
   facts: ($facts | n), turns: $turns, cost: $cost, audit: $audit,
   denials: (if $denials == "" then [] else $denials | split(",") end), key: $key, exit: $e}')"

line="brief $date: $summary, turns $turns, cost $cost_shown, audit $audit"
[ -z "$denials" ] || line+=", denials $denials"
printf '%s, exit %s\n' "$line" "$code"
exit "$code"

#!/usr/bin/env bash
set -euo pipefail
# The model's only way to put what it learned from Microsoft 365 into memory (spec 23, O34): candidate facts on stdin,
# one per line, become `- [observed] <local date> [<source>]: <fact>` lines in
# <memory>/<tenant>/<user>/inbox/m365-<kind>-<local date>.md (front matter once, written atomically).
# usage: facts.sh --kind brief|mail-backfill|files-backfill --source <tag> [--max <n>] < lines
# A line is refused — counted by reason on stderr, never echoed — when it is empty, does not start with a letter,
# holds an e-mail address, a URL (scheme or www.), a phone number or matches a secret pattern (which covers IBANs,
# 13–19-digit numbers and tokens). Control characters are removed and whitespace collapsed first; a fact over 240
# characters is cut to 240 (the last one "…"); a fact already in the file or earlier in the input is dropped.
# Third parties appear as name, role and organisation only: the validator removes their contact details by refusal.
# stdout stays empty; stderr: "facts: <a> accepted, <r> refused (<n> <reason>, …), <d> duplicates dropped, <c> cut to 240".
# Exit 0 · 3 configuration · 4 usage · 5 --max reached (the lines up to the cap are written). Accepts ZYGGY_HOOKS=off
# (the brief and the backfills run unattended).
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"
ZY_SELF=facts

readonly ZY_FACTS_CHARS=240 ZY_FACTS_SOURCE_CHARS=200 ZY_FACTS_MAX=99999
readonly ZY_FACTS_EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
readonly ZY_FACTS_URL_RE='([A-Za-z][A-Za-z0-9+.-]*://|www\.)'
# A phone number: "+" or a leading 0, then digits with spaces, dots, slashes, hyphens or brackets; it counts as one
# from 8 digits after "+" or 9 digits after "0" (dates such as 01.10.2026 have 8 and pass).
readonly ZY_FACTS_PHONE_CANDIDATE_RE='(\+|(^|[^0-9A-Za-z])0)[0-9][0-9 ./()-]{6,}[0-9]'
# The refusal reasons in the order the counts line names them; secret patterns follow in the order first met.
readonly -a ZY_FACTS_REASONS=(empty 'non-letter start' 'e-mail address' url phone)

die() { # die <exit code> <message>
  zy_die "$@"
}

usage() {
  die 4 "$1 (usage: facts.sh --kind brief|mail-backfill|files-backfill --source <tag> [--max <n>] < lines)"
}

# --- 1. the arguments (exit 4 before anything else) ----------------------------------------------------------------

kind=""
source_tag=""
have_source=0
max=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kind | --source | --max)
      [ $# -ge 2 ] || usage "$1 needs a value"
      case "$1" in
        --kind)
          [ -z "$kind" ] || usage "--kind given twice"
          kind="$2"
          ;;
        --source)
          [ "$have_source" -eq 0 ] || usage "--source given twice"
          source_tag="$2"
          have_source=1
          ;;
        --max)
          [ -z "$max" ] || usage "--max given twice"
          max="$2"
          ;;
      esac
      shift 2
      ;;
    *) usage "unexpected argument '${1:0:40}'" ;;
  esac
done
case "$kind" in
  brief | mail-backfill | files-backfill) ;;
  '') usage "--kind is required" ;;
  *) usage "--kind must be brief, mail-backfill or files-backfill" ;;
esac
[ "$have_source" -eq 1 ] || usage "--source is required"
# The source is provenance in memory: one plain line, no brackets (they delimit it), no contact detail, no secret.
case "$source_tag" in
  *[[:cntrl:]]*) usage "--source must be one line without control characters" ;;
  *'['* | *']'*) usage "--source must not contain [ or ]" ;;
esac
source_tag="$(zy_collapse_line "$source_tag")"
[ -n "$source_tag" ] || usage "--source is empty"
[ "$(zy_char_count "$source_tag")" -le "$ZY_FACTS_SOURCE_CHARS" ] || usage "--source is longer than $ZY_FACTS_SOURCE_CHARS characters"
grep -qE "$ZY_FACTS_EMAIL_RE" <<< "$source_tag" && usage "--source holds an e-mail address"
grep -qE "$ZY_FACTS_URL_RE" <<< "$source_tag" && usage "--source holds a URL"
zy_secret_match "$source_tag" && usage "--source matches secret pattern $ZY_SECRET_NAME"
if [ -n "$max" ]; then
  if [[ ! "$max" =~ ^[1-9][0-9]{0,4}$ ]] || ((max > ZY_FACTS_MAX)); then
    usage "--max must be 1..$ZY_FACTS_MAX"
  fi
fi

# --- 2. configuration ----------------------------------------------------------------------------------------------

zy_require_config
today="$(zy_local_date)"
file="$(cd "$(zy_user_dir)" && pwd)/inbox/m365-$kind-$today.md"

# --- 3. validation ------------------------------------------------------------------------------------------------

# The reason <fact> is refused (one of ZY_FACTS_REASONS or "secret pattern <name>"), or nothing when it is acceptable.
refusal() { # refusal <fact>
  local fact="$1" candidate digits
  if [ -z "$fact" ]; then
    printf 'empty'
  elif ! LC_ALL=C.UTF-8 grep -qE '^[[:alpha:]]' <<< "$fact"; then
    printf 'non-letter start'
  elif grep -qE "$ZY_FACTS_EMAIL_RE" <<< "$fact"; then
    printf 'e-mail address'
  elif grep -qiE "$ZY_FACTS_URL_RE" <<< "$fact"; then
    printf 'url'
  elif zy_secret_match "$fact"; then
    printf 'secret pattern %s' "$ZY_SECRET_NAME"
  else
    while IFS= read -r candidate; do
      digits="$(tr -cd '0-9' <<< "$candidate")"
      if { [[ "$candidate" == *+* ]] && [ "${#digits}" -ge 8 ]; } || [ "${#digits}" -ge 9 ]; then
        printf 'phone'
        return 0
      fi
    done < <(grep -oE "$ZY_FACTS_PHONE_CANDIDATE_RE" <<< "$fact" || true)
  fi
}

# <fact> cut to ZY_FACTS_CHARS characters, the last one "…" (counted in characters, not bytes).
cut_fact() { # cut_fact <fact>
  LC_ALL=C.UTF-8
  printf '%s…' "${1:0:ZY_FACTS_CHARS-1}"
}

# The facts already in the file (the text after the provenance), for the cross-run duplicate check.
declare -A seen=()
if [ -f "$file" ]; then
  while IFS= read -r known; do
    seen["$known"]=1
  done < <(sed -n 's/^- \[observed\] [0-9-]* \[[^]]*\]: //p' "$file")
fi

declare -A refused_by=()
refused_order=()
accepted=()
refused=0
duplicates=0
cut=0
capped=0
while IFS= read -r raw || [ -n "$raw" ]; do
  fact="$(zy_collapse_line "$(printf '%s' "$raw" | tr '\t' ' ' | tr -d '\000-\010\013-\037\177')")"
  reason="$(refusal "$fact")"
  if [ -n "$reason" ]; then
    refused=$((refused + 1))
    [ -n "${refused_by[$reason]:-}" ] || refused_order+=("$reason")
    refused_by["$reason"]=$((${refused_by[$reason]:-0} + 1))
    continue
  fi
  if [ "$(zy_char_count "$fact")" -gt "$ZY_FACTS_CHARS" ]; then
    fact="$(cut_fact "$fact")"
    is_cut=1
  else
    is_cut=0
  fi
  if [ -n "${seen[$fact]:-}" ]; then
    duplicates=$((duplicates + 1))
    continue
  fi
  if [ -n "$max" ] && [ "${#accepted[@]}" -ge "$max" ]; then
    capped=1
    break
  fi
  seen["$fact"]=1
  cut=$((cut + is_cut))
  accepted+=("- [observed] $today [$source_tag]: $fact")
done

# --- 4. the memory file and the counts line ------------------------------------------------------------------------

if [ "${#accepted[@]}" -gt 0 ]; then
  zy_atomic_append "$file" "m365 $kind $today" "facts observed by the m365 $kind run on $today (facts.sh)" \
    "$(printf '%s\n' "${accepted[@]}")"
fi

details=""
for reason in "${ZY_FACTS_REASONS[@]}"; do
  [ -z "${refused_by[$reason]:-}" ] || details+=", ${refused_by[$reason]} $reason"
done
for reason in "${refused_order[@]+"${refused_order[@]}"}"; do
  [[ "$reason" != 'secret pattern '* ]] || details+=", ${refused_by[$reason]} $reason"
done
[ -z "$details" ] || details=" (${details#, })"
printf 'facts: %s accepted, %s refused%s, %s %s dropped, %s cut to %s\n' "${#accepted[@]}" "$refused" "$details" \
  "$duplicates" "$([ "$duplicates" -eq 1 ] && printf duplicate || printf duplicates)" "$cut" "$ZY_FACTS_CHARS" >&2
if [ "$capped" -eq 1 ]; then
  die 5 "cap $max reached"
fi

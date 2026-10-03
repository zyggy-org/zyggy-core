#!/usr/bin/env bash
set -euo pipefail
# The m365 connector's named state (spec 23): the watermarks and tokens the runs advance and the replied-message
# ids. Values come only from the arguments and are validated against a closed grammar; files are 0600 in a 0700
# state directory, written as a temporary file and renamed. The model may call get/set/reset.
# usage: state.sh get <key> [<arg>] | set <key> [<arg>] <value> | reset <key> [<arg>]
# keys:  mail-watermark (ISO), backfill-watermark <folder> (ISO), drive-token <drive> (ISO timestamp — the pinned
#        server has no delta token; the brief's), files-backfill-watermark <drive> (the files backfill's own cursor
#        <ISO>|<item-id>, or a plain <ISO> written before plan step 20a — never the brief's drive-token),
#        replied <date> (message id; set appends once)
# Exit 0 · 3 configuration · 4 usage or invalid value.
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"
# shellcheck source=m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/m365-lib.sh"
ZY_SELF=m365-state

readonly ZY_STATE_ARG_RE='^[A-Za-z0-9!_=-]{1,200}$'

die() { # die <exit code> <message>
  zy_die "$@"
}

usage() {
  die 4 "$1 (usage: state.sh get <key> [<arg>] | set <key> [<arg>] <value> | reset <key> [<arg>])"
}

# --- 1. the verb and its arguments (exit 4 before anything else) -------------------------------------------------

verb="${1:-}"
[ $# -eq 0 ] || shift
[ -n "$verb" ] || usage "no verb given"
key=""
arg=""
value=""
file=""
grammar=""

# The file name and the value grammar of <key> [<arg>]; exit 4 on an unknown key, a missing or malformed argument.
resolve_key() { # resolve_key <key> <arg count>
  case "$1" in
    mail-watermark)
      [ "$2" -eq 0 ] || usage "mail-watermark takes no argument"
      file=mail-watermark
      grammar=iso
      ;;
    backfill-watermark)
      [ "$2" -eq 1 ] || usage "backfill-watermark needs <folder>"
      file="backfill-$arg.watermark"
      grammar=iso
      ;;
    drive-token)
      [ "$2" -eq 1 ] || usage "drive-token needs <drive>"
      file="drive-$arg.token"
      grammar=iso
      ;;
    files-backfill-watermark)
      [ "$2" -eq 1 ] || usage "files-backfill-watermark needs <drive>"
      file="files-backfill-$arg.watermark"
      grammar=cursor
      ;;
    replied)
      [ "$2" -eq 1 ] || usage "replied needs <date>"
      [[ "$arg" =~ $ZY_M365_DATE_RE ]] || usage "'$arg' is not a date (YYYY-MM-DD)"
      file="replied-$arg.ids"
      grammar=id
      ;;
    *) usage "unknown key '$1'" ;;
  esac
}

case "$verb" in
  get | reset)
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then usage "$verb needs <key> [<arg>]"; fi
    key="$1"
    if [ $# -eq 2 ]; then
      arg="$2"
      [[ "$arg" =~ $ZY_STATE_ARG_RE ]] || usage "'${arg:0:40}' is not a valid argument"
    fi
    resolve_key "$key" $(($# - 1))
    ;;
  set)
    if [ $# -lt 2 ] || [ $# -gt 3 ]; then usage "set needs <key> [<arg>] <value>"; fi
    key="$1"
    if [ $# -eq 3 ]; then
      arg="$2"
      [[ "$arg" =~ $ZY_STATE_ARG_RE ]] || usage "'${arg:0:40}' is not a valid argument"
    fi
    value="${*: -1}"
    resolve_key "$key" $(($# - 2))
    case "$grammar" in
      iso) [[ "$value" =~ $ZY_M365_ISO_RE ]] || die 4 "invalid value for $key: expected an ISO timestamp (YYYY-MM-DDTHH:MM:SSZ)" ;;
      cursor) [[ "$value" =~ $ZY_M365_CURSOR_RE ]] || die 4 "invalid value for $key: expected an ISO timestamp (YYYY-MM-DDTHH:MM:SSZ), optionally followed by |<item-id>" ;;
      id) [[ "$value" =~ $ZY_M365_ID_RE ]] || die 4 "invalid value for $key: expected one message id" ;;
    esac
    ;;
  *) usage "unknown verb '$verb'" ;;
esac

# --- 2. the principal and the tools ------------------------------------------------------------------------------

zy_require_config
command -v jq > /dev/null || die 3 "jq not found"

# --- 3. the named keys ------------------------------------------------------------------------------------------

# Write stdin to <path> atomically: a 0600 temporary beside it, then a rename.
write_atomic() { # write_atomic <path>
  local tmp="$1.tmp"
  zy_m365_state_dir
  # shellcheck disable=SC2064 # expand now: the trap must remove this file
  trap "rm -f '$tmp'" EXIT
  (umask 077 && cat > "$tmp")
  chmod 600 "$tmp"
  mv -f "$tmp" "$1"
  trap - EXIT
}

state_get() {
  local path="$ZY_M365_STATE_DIR/$file"
  if [ -f "$path" ]; then
    cat "$path"
  elif [ "$key" = mail-watermark ]; then
    # first run: the last 24 hours
    date -u -d "@$(($(zy_date UTC +%s) - 86400))" +%Y-%m-%dT%H:%M:%SZ
  fi
}

state_set() {
  local path="$ZY_M365_STATE_DIR/$file"
  if [ "$grammar" = id ]; then
    # replied ids accumulate, each once
    if [ -f "$path" ] && grep -qxF -- "$value" "$path"; then
      return 0
    fi
    { if [ -f "$path" ]; then cat "$path"; fi; printf '%s\n' "$value"; } | write_atomic "$path"
  else
    printf '%s\n' "$value" | write_atomic "$path"
  fi
}

state_reset() {
  rm -f "$ZY_M365_STATE_DIR/$file"
}

case "$verb" in
  get) state_get ;;
  set) state_set ;;
  reset) state_reset ;;
esac

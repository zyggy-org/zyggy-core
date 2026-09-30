#!/usr/bin/env bash
set -euo pipefail
# Shared functions for the hooks and skill scripts. Sourced, never executed.
# Inputs come only from env, arguments and stdin; no tenant, user or path is hard-coded here.
# LC_ALL=C: ${#s} counts bytes and sort is byte-ordered.
export LC_ALL=C

# A closed stdin would let the next pipe take fd 0 and a later `cat` read its own pipe: reopen it.
if { exec 3<&0; } 2> /dev/null; then
  exec 3<&-
else
  exec 0< /dev/null
fi

# Name of the calling script, for stderr lines.
ZY_SELF="$(basename "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}" .sh)"

zy_die() { # zy_die <exit code> <message>
  printf '%s: %s\n' "$ZY_SELF" "$2" >&2
  exit "$1"
}

zy_hooks_off() {
  [ "${ZYGGY_HOOKS:-}" = off ]
}

# <root>/<tenant>/<user>: the only place the principal becomes a path.
zy_user_dir() {
  printf '%s/%s/%s' "$ZYGGY_MEMORY_ROOT" "$ZYGGY_TENANT" "$ZYGGY_USER"
}

# Exit 3 with one stderr line when the principal, the memory root or the time zone is unusable.
zy_require_config() {
  local var
  for var in ZYGGY_MEMORY_ROOT ZYGGY_TENANT ZYGGY_USER; do
    [ -n "${!var:-}" ] || zy_die 3 "configuration error: $var is not set"
  done
  [ -d "$ZYGGY_MEMORY_ROOT" ] || zy_die 3 "configuration error: memory root $ZYGGY_MEMORY_ROOT does not exist (ZYGGY_MEMORY_ROOT)"
  [ -d "$(zy_user_dir)" ] || zy_die 3 "configuration error: memory directory $(zy_user_dir) does not exist (ZYGGY_TENANT/ZYGGY_USER)"
  ZYGGY_TIMEZONE="${ZYGGY_TIMEZONE:-UTC}"
  # GNU date silently falls back to UTC on an unknown TZ, hence the zoneinfo check.
  [ "$ZYGGY_TIMEZONE" = UTC ] || [ -f "/usr/share/zoneinfo/$ZYGGY_TIMEZONE" ] ||
    zy_die 3 "configuration error: ZYGGY_TIMEZONE '$ZYGGY_TIMEZONE' is not a known time zone"
  if [ -n "${ZYGGY_NOW:-}" ]; then
    date -u -d "$ZYGGY_NOW" > /dev/null 2>&1 || zy_die 3 "configuration error: ZYGGY_NOW '$ZYGGY_NOW' is not a date"
  fi
}

# Clock: ZYGGY_NOW (tests) or the real clock.
zy_date() { # zy_date <tz> <format>
  if [ -n "${ZYGGY_NOW:-}" ]; then
    TZ="$1" date -d "$ZYGGY_NOW" "$2"
  else
    TZ="$1" date "$2"
  fi
}
zy_now_utc() { zy_date UTC +%Y-%m-%dT%H:%M:%SZ; }
zy_local_date() { zy_date "$ZYGGY_TIMEZONE" +%F; }
zy_local_hhmm() { zy_date "$ZYGGY_TIMEZONE" +%H:%M; }

# Byte cap of a digest section: default 6000/6000/8000, ZYGGY_DIGEST_BYTES_<SECTION> overrides, clamped
# to 9500 so a section never reaches Claude Code's 10,000-character hook-output limit.
zy_cap_bytes() { # zy_cap_bytes <identity|index|daily>
  local default var value
  case "$1" in
    identity) default=6000 ;;
    index) default=6000 ;;
    *) default=8000 ;;
  esac
  var="ZYGGY_DIGEST_BYTES_${1^^}"
  value="${!var:-}"
  if [[ ! "$value" =~ ^[1-9][0-9]{0,8}$ ]]; then
    value=$default
  elif ((value > 9500)); then
    value=9500
  fi
  printf '%s' "$value"
}

# Print a file without its front matter (the block between a first line --- and the next --- line).
# A file without front matter is printed whole.
zy_strip_front_matter() {
  awk 'NR == 1 && $0 == "---" { fm = 1; next }
       fm && $0 == "---" { fm = 0; next }
       !fm { print }' "$1"
}

# The value of <key>: inside the front matter, surrounding quotes stripped; empty when absent.
zy_front_matter_value() { # zy_front_matter_value <file> <key>
  awk -v key="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (length(v) >= 2 && ((substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") ||
                             (substr(v, 1, 1) == "'\''" && substr(v, length(v), 1) == "'\''")))
        v = substr(v, 2, length(v) - 2)
      print v
      exit
    }' "$1"
}

# Collapse to one line: CR, LF and tabs become spaces, runs of spaces one space, trimmed.
zy_collapse_line() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -s ' ' | sed 's/^ //; s/ $//'
}

# Length in characters (UTF-8), not bytes.
zy_char_count() {
  printf '%s' "$1" | LC_ALL=C.UTF-8 wc -m
}

ZY_SECRET_PATTERNS="$(dirname "${BASH_SOURCE[0]}")/secret-patterns.txt"

# Sets ZY_SECRET_NAME to the first secret pattern <text> matches and returns 0; returns 1 when none
# matches. Never prints the text. Call it directly (not in $(...)) so a missing patterns file exits 3.
export ZY_SECRET_NAME=""
zy_secret_match() { # zy_secret_match <text>
  local text="$1" name ere flags variant
  local -a grep_opts
  [ -r "$ZY_SECRET_PATTERNS" ] || zy_die 3 "configuration error: $ZY_SECRET_PATTERNS is missing"
  while IFS=$'\t' read -r name ere flags || [ -n "$name" ]; do
    case "$name" in '' | '#'*) continue ;; esac
    grep_opts=(-qE)
    variant="$text"
    case "${flags:-}" in
      icase) grep_opts=(-qEi) ;;
      nospace) variant="$(sed -E ':a; s/([A-Z0-9]) ([0-9])/\1\2/; ta' <<< "$text")" ;;
      nospace-nohyphen) variant="$(sed -E ':a; s/([0-9])[ -]([0-9])/\1\2/; ta' <<< "$text")" ;;
    esac
    if grep "${grep_opts[@]}" -e "$ere" <<< "$text" || grep "${grep_opts[@]}" -e "$ere" <<< "$variant"; then
      ZY_SECRET_NAME="$name"
      return 0
    fi
  done < "$ZY_SECRET_PATTERNS"
  return 1
}

# Append <line> to a memory file atomically: the whole new file is written to <file>.tmp, then renamed.
# A new file gets the §7 front matter; an existing one keeps its head, with `updated:` rewritten when present.
zy_atomic_append() { # zy_atomic_append <file> <front-matter name> <front-matter description> <line>
  local file="$1" today tmp
  today="$(zy_local_date)"
  tmp="$file.tmp"
  mkdir -p "$(dirname "$file")"
  # shellcheck disable=SC2064 # expand now: the trap must remove this file
  trap "rm -f '$tmp'" EXIT
  if [ -f "$file" ]; then
    awk -v today="$today" '
      NR == 1 && $0 == "---" { fm = 1; print; next }
      fm && $0 == "---" { fm = 0 }
      fm && /^updated:/ { print "updated: " today; next }
      { print }' "$file" > "$tmp"
  else
    printf -- '---\nname: %s\ndescription: %s\nupdated: %s\n---\n' "$2" "$3" "$today" > "$tmp"
  fi
  printf '%s\n' "$4" >> "$tmp"
  mv -f "$tmp" "$file"
  trap - EXIT
}

# Hook JSON from stdin; empty when stdin is a terminal (a run by hand never blocks) or closed.
zy_read_stdin_json() {
  if [ ! -t 0 ]; then
    cat 2> /dev/null || true
  fi
}

#!/usr/bin/env bash
set -euo pipefail
# The protocol check (spec 15 AC-13): PROTOCOL.md must equal §4 of the founding specification, and
# templates/job-prompt.md the job prompt embedded in the binary, in the public zyggy repository at the tag each file
# names on its `Source: zyggy <tag>` line. Only the part after the `<!-- verbatim from here` marker is compared,
# trailing blank lines ignored. Usage: tests/protocol-check.sh [<zyggy-core checkout>] (default: this checkout).
# ZYGGY_PROTOCOL_SOURCE=<folder> reads <folder>/<tag>/<path> instead of GitHub (the bats tests).
# Exit 0 both match · 1 a difference (unified diff on stdout, source first) · 2 a file or the source cannot be read.

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
spec_path='_specs/00 - Personal Agent Platform — Technical Specification.md'
prompt_path='src/Zyggy.Core/Jobs/Prompts/job-prompt.md'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

urlpath() { # percent-encode every byte outside A-Z a-z 0-9 - _ . ~ / (the path has spaces and an em dash)
  local LC_ALL=C s="$1" i c out=''
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~/-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

fetch() { # fetch <tag> <path> <out>
  if [ -n "${ZYGGY_PROTOCOL_SOURCE:-}" ]; then
    cp "$ZYGGY_PROTOCOL_SOURCE/$1/$2" "$3" 2> /dev/null
  else
    curl -fsSL --retry 2 -o "$3" "https://raw.githubusercontent.com/zyggy-org/zyggy/$1/$(urlpath "$2")"
  fi
}

trim() { # drop trailing blank lines
  awk '{ lines[NR] = $0 } /[^[:space:]]/ { last = NR } END { for (i = 1; i <= last; i++) print lines[i] }'
}

worst=0
check() { # check <file> <path in zyggy> <what> <extract: section4|whole>
  local file="$1" tag
  tag="$(sed -n 's/^Source: zyggy \([^ ]*\)$/\1/p' "$root/$file" | head -n 1)"
  if [ -z "$tag" ]; then
    echo "$file: no 'Source: zyggy <tag>' line"; worst=2; return
  fi
  if ! grep -q '^<!-- verbatim from here' "$root/$file"; then
    echo "$file: no '<!-- verbatim from here' marker"; worst=2; return
  fi
  if ! fetch "$tag" "$2" "$work/source"; then
    echo "$file: cannot read $2 at zyggy $tag"; worst=2; return
  fi
  if [ "$4" = section4 ]; then
    awk '/^## 5\. / { exit } f; /^## 4\. / { f = 1; print }' "$work/source" | trim > "$work/expected"
  else
    trim < "$work/source" > "$work/expected"
  fi
  awk 'f; /^<!-- verbatim from here/ { f = 1 }' "$root/$file" | trim > "$work/actual"
  if diff -u --label "zyggy $tag: $2" --label "$file" "$work/expected" "$work/actual" > "$work/diff"; then
    echo "$file: matches $3 of zyggy $tag"
  else
    echo "$file: differs from $3 of zyggy $tag (re-copy it from the tag, or move its Source line to the tag that holds it)"
    cat "$work/diff"
    [ "$worst" -eq 2 ] || worst=1
  fi
}

check PROTOCOL.md "$spec_path" '§4' section4
check templates/job-prompt.md "$prompt_path" 'the job prompt' whole
exit "$worst"

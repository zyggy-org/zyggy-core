#!/usr/bin/env bats
# The two m365 hook launchers (spec 33 AC-36, plan 33 Step 19): m365-guard.sh and m365-log.sh hold no policy — they
# run `zyggy m365 guard|log` with the hook JSON on stdin and turn every failure, a missing binary included, into
# exit 2 so Claude Code blocks the call. The zyggy stub records argv and stdin; no real zyggy runs here.

load helpers

setup() {
  install_zyggy_stub
}

LAUNCHERS=(m365-guard:guard m365-log:log)

@test "launchers: stdin and stdout pass through unchanged, argv is exactly m365 <verb>, the exit 0 stays 0" {
  local l name verb input
  input="$FIXTURES/m365/hook-send-clean.json"
  for l in "${LAUNCHERS[@]}"; do
    name="${l%%:*}" verb="${l#*:}"
    : > "$ZYGGY_STUB_LOG"
    : > "$ZYGGY_STUB_STDIN"
    ZYGGY_STUB_STDOUT='{"decision":"from the binary"}' run --separate-stderr "$HOOKS/$name.sh" < "$input"
    [ "$status" -eq 0 ] || { echo "$name: $status $stderr"; return 1; }
    [ "$output" = '{"decision":"from the binary"}' ] || { echo "$name: $output"; return 1; }
    [ -z "$stderr" ]
    [ "$(cat "$ZYGGY_STUB_LOG")" = "m365	$verb" ] || { echo "$name: $(cat "$ZYGGY_STUB_LOG")"; return 1; }
    cmp "$ZYGGY_STUB_STDIN" "$input" || { echo "$name: stdin changed"; return 1; }
  done
}

@test "launchers: any non-zero exit of the binary becomes 2, its stderr line kept" {
  local l name code
  for l in "${LAUNCHERS[@]}"; do
    name="${l%%:*}"
    for code in 1 2 3 6 127; do
      ZYGGY_STUB_EXIT="$code" ZYGGY_STUB_STDERR="$name: configuration error: from the binary" \
        run --separate-stderr "$HOOKS/$name.sh" < "$FIXTURES/m365/hook-send-clean.json"
      [ "$status" -eq 2 ] || { echo "$name exit $code -> $status"; return 1; }
      [ "$stderr" = "$name: configuration error: from the binary" ] || { echo "$name: $stderr"; return 1; }
    done
  done
}

@test "launchers: no zyggy on PATH -> exit 2 and exactly one stderr line, nothing on stdout" {
  local l name
  for l in "${LAUNCHERS[@]}"; do
    name="${l%%:*}"
    PATH=/usr/bin:/bin run --separate-stderr "$HOOKS/$name.sh" < "$FIXTURES/m365/hook-send-clean.json"
    [ "$status" -eq 2 ] || { echo "$name: $status"; return 1; }
    [ "$stderr" = "$name: zyggy not found" ] || { echo "$name: $stderr"; return 1; }
    [ -z "$output" ]
  done
}

@test "launchers: each is at most 10 lines and holds no jq, sed, awk, case or source" {
  local l f
  for l in "${LAUNCHERS[@]}"; do
    f="$HOOKS/${l%%:*}.sh"
    [ "$(wc -l < "$f")" -le 10 ] || { echo "$f: $(wc -l < "$f") lines"; return 1; }
    run grep -nE '(^|[^a-z_-])(jq|sed|awk|case|source)( |$)' <(grep -vE '^[[:space:]]*#' "$f")
    [ "$status" -eq 1 ] || { echo "$f: $output"; return 1; }
  done
}

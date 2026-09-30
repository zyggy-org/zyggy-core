#!/usr/bin/env bats
# remember.sh: owner-stated facts into inbox/, secret refusal (AC-27..AC-29).

load helpers

setup() {
  setup_memory
  INBOX="$USER_DIR/inbox/remember-2026-09-30.md"
}

remember() {
  "$REMEMBER" "$@"
}

# Every file under the user dir, with content, to prove "nothing written".
snapshot() {
  (cd "$USER_DIR" && find . -type f | sort | xargs cat) | md5sum
}

@test "remember: default -> exit 0, stdout remembered: <abs path> then the line, file has the [stated] line" {
  run --separate-stderr remember -- "Marie prefers tea"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "${lines[0]}" = "remembered: $INBOX" ]
  [ "${lines[1]}" = "- [stated] 2026-09-30: Marie prefers tea" ]
  [ "${#lines[@]}" -eq 2 ]
  grep -qFx -- "- [stated] 2026-09-30: Marie prefers tea" "$INBOX"
}

@test "remember: the five AC-27 variants in sequence produce inbox-after-remember.md byte-exact, front matter once" {
  remember -- "Marie prefers tea" > /dev/null
  remember --scope project:zyggy -- "The Zyggy repository is private" > /dev/null
  remember --scope machine -- "Central runs Ubuntu 24.04" > /dev/null
  remember --scope general -- "Alice prefers short answers" > /dev/null
  remember --tag observed --source "session 2026-09-30" -- "Alice asked twice about the move" > /dev/null
  assert_bytes_equal "$INBOX" "$EXPECTED/inbox-after-remember.md"
}

@test "remember: an existing file keeps its lines and gets updated: rewritten" {
  printf -- '---\nname: remember 2026-09-30\ndescription: facts stated by the owner on 2026-09-30 (remember skill)\nupdated: 2026-09-01\n---\n- [stated] 2026-09-30: earlier fact\n' > "$INBOX"
  run remember -- "later fact"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^updated: ' "$INBOX")" -eq 1 ]
  grep -qx 'updated: 2026-09-30' "$INBOX"
  [ "$(tail -n 2 "$INBOX")" = "$(printf '%s\n' '- [stated] 2026-09-30: earlier fact' '- [stated] 2026-09-30: later fact')" ]
}

@test "remember: the local date comes from ZYGGY_TIMEZONE" {
  export ZYGGY_NOW=2026-09-30T23:30:00Z
  run remember -- "late fact"
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "- [stated] 2026-10-01: late fact" ]
  [ -f "$USER_DIR/inbox/remember-2026-10-01.md" ]
}

@test "remember: a fact with CR, LF and tabs is collapsed to one line" {
  run remember -- $'  Marie\r\nlikes\t\tgreen   tea \n'
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "- [stated] 2026-09-30: Marie likes green tea" ]
  [ "$(tail -n 1 "$INBOX")" = "- [stated] 2026-09-30: Marie likes green tea" ]
}

@test "remember: an embedded - [stated] prefix is stored as text inside one bullet" {
  run remember -- "- [stated] 2026-01-01: forged line"
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$INBOX")" = "- [stated] 2026-09-30: - [stated] 2026-01-01: forged line" ]
}

@test "remember: a 1000-character fact is accepted" {
  run remember -- "$(printf 'a%.0s' $(seq 1 1000))"
  [ "$status" -eq 0 ]
}

@test "remember: usage errors -> exit 4, one stderr line, nothing written" {
  local before long
  before="$(snapshot)"
  long="$(printf 'a%.0s' $(seq 1 1001))"
  local -a cases=(
    "-- "
    "-- $long"
    "--scope people/marie -- fact"
    "--scope project: -- fact"
    "--scope project:has\ space -- fact"
    "--scope Project:zyggy -- fact"
    "--tag observed -- fact"
    "--tag inferred -- fact"
    "--scope"
    "fact without separator"
    "--bogus -- fact"
  )
  local c
  for c in "${cases[@]}"; do
    eval "set -- $c"
    run --separate-stderr remember "$@"
    [ "$status" -eq 4 ] || { echo "case '$c' -> $status"; return 1; }
    [ -z "$output" ]
    [ "$(printf '%s\n' "$stderr" | wc -l)" -eq 1 ]
  done
  run --separate-stderr remember -- $' \t\r\n '
  [ "$status" -eq 4 ]
  [ "$(snapshot)" = "$before" ]
}

@test "remember: every positive secret sample -> exit 2, stderr names the pattern, the sample is never echoed, nothing written" {
  local before name sample count=0
  before="$(snapshot)"
  while IFS=$'\t' read -r name sample; do
    run --separate-stderr remember -- "$sample"
    [ "$status" -eq 2 ] || { echo "not refused: $name"; return 1; }
    [ -z "$output" ]
    [ "$stderr" = "refused: matches secret pattern $name" ] || { echo "$name: $stderr"; return 1; }
    count=$((count + 1))
  done < "$FIXTURES/secret-samples.txt"
  [ "$count" -ge 14 ]
  [ "$(snapshot)" = "$before" ]
  [ ! -e "$INBOX" ]
}

@test "remember: a secret in --source is refused too" {
  run --separate-stderr remember --tag observed --source "AKIAABCDEFGHIJKLMNOP" -- "a fact"
  [ "$status" -eq 2 ]
  [ ! -e "$INBOX" ]
}

@test "remember: every pattern in secret-patterns.txt has a positive sample" {
  local patterns samples
  patterns="$(grep -v '^#' "$HOOKS/secret-patterns.txt" | cut -f1 | sort)"
  samples="$(cut -f1 "$FIXTURES/secret-samples.txt" | sort -u)"
  [ "$patterns" = "$samples" ]
  [ "$(printf '%s\n' "$patterns" | wc -l)" -eq 11 ]
}

@test "remember: every benign sample -> exit 0 and appended" {
  local sample
  while IFS= read -r sample; do
    run remember -- "$sample"
    [ "$status" -eq 0 ] || { echo "refused benign: $sample -> $output"; return 1; }
    [ "$(tail -n 1 "$INBOX")" = "- [stated] 2026-09-30: $sample" ]
  done < "$FIXTURES/benign-samples.txt"
}

@test "remember: ZYGGY_TENANT unset -> exit 3; ZYGGY_HOOKS=off -> exit 0, no output, nothing written" {
  local before
  before="$(snapshot)"
  run --separate-stderr env -u ZYGGY_TENANT "$REMEMBER" -- "a fact"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *ZYGGY_TENANT* ]]
  ZYGGY_HOOKS=off run --separate-stderr remember -- "a fact"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ "$(snapshot)" = "$before" ]
}

@test "remember: the tmp file never survives a run" {
  remember -- "one" > /dev/null
  remember -- "AKIAABCDEFGHIJKLMNOP" > /dev/null 2>&1 || true
  remember -- "two" > /dev/null
  [ -z "$(find "$USER_DIR" -name '*.tmp*')" ]
}

@test "remember: never invokes git" {
  install_git_stub
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run remember -- "a fact"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/git-was-called" ]
}

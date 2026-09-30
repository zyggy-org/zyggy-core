#!/usr/bin/env bats
# stop.sh: one [observed] line per turn into daily/<local date>.md (AC-25, AC-26, AC-29 second half).

load helpers

setup() {
  setup_memory
  DAILY="$USER_DIR/daily/2026-09-30.md"
  rm -f "$DAILY"
}

# stop_input <message> [<stop_hook_active>]: the fixture input with another last_assistant_message
stop_input() {
  jq -c --arg m "$1" --argjson a "${2:-false}" '.last_assistant_message = $m | .stop_hook_active = $a' \
    "$FIXTURES/stop-input.json"
}

run_stop() { # run_stop <message> [<stop_hook_active>]
  run --separate-stderr "$HOOKS/stop.sh" < <(stop_input "$@")
}

snapshot() {
  (cd "$USER_DIR" && find . -type f | sort | xargs cat) | md5sum
}

@test "stop: two runs on the fixture input produce daily-after-two-stops.md byte-exact, exit 0 both times" {
  run --separate-stderr "$HOOKS/stop.sh" < "$FIXTURES/stop-input.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  run --separate-stderr "$HOOKS/stop.sh" < "$FIXTURES/stop-input.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_bytes_equal "$DAILY" "$EXPECTED/daily-after-two-stops.md"
}

@test "stop: an existing daily file keeps its lines and gets updated: rewritten" {
  printf -- '---\nname: daily 2026-09-30\ndescription: turn notes of 2026-09-30 written by the Stop hook\nupdated: 2026-09-29\n---\n- [observed] 08:00 session 11111111: earlier\n' > "$DAILY"
  run_stop "later"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qx 'updated: 2026-09-30' "$DAILY"
  [ "$(grep -c '^updated:' "$DAILY")" -eq 1 ]
  [ "$(tail -n 2 "$DAILY")" = "$(printf '%s\n' '- [observed] 08:00 session 11111111: earlier' '- [observed] 12:00 session 0b7c3d1e: later')" ]
}

@test "stop: a note longer than 240 characters is cut at 240 with an ellipsis" {
  local long
  long="$(printf 'x%.0s' $(seq 1 300))"
  run_stop "$long"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(tail -n 1 "$DAILY")" = "- [observed] 12:00 session 0b7c3d1e: ${long:0:240}…" ]
}

@test "stop: a note of exactly 240 characters is not cut" {
  local exact
  exact="$(printf 'y%.0s' $(seq 1 240))"
  run_stop "$exact"
  [ "$(tail -n 1 "$DAILY")" = "- [observed] 12:00 session 0b7c3d1e: $exact" ]
}

@test "stop: the first non-empty line is used when the message starts with blank lines" {
  run_stop $'\n  \n\t\nActual first line.\nsecond'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(tail -n 1 "$DAILY")" = "- [observed] 12:00 session 0b7c3d1e: Actual first line." ]
}

@test "stop: CRLF line ends and a leading bare CR line are not notes" {
  run_stop $'\r\nFirst real line.\r\nsecond'
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$DAILY")" = "- [observed] 12:00 session 0b7c3d1e: First real line." ]
}

@test "stop: a message that is only a code fence uses the fence line" {
  run_stop $'```bash\nls -la\n```'
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$DAILY")" = '- [observed] 12:00 session 0b7c3d1e: ```bash' ]
}

@test "stop: stop_hook_active true -> nothing written, exit 0" {
  local before
  before="$(snapshot)"
  run_stop "a note" true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(snapshot)" = "$before" ]
}

@test "stop: empty or whitespace last_assistant_message -> nothing, exit 0" {
  local before m
  before="$(snapshot)"
  for m in "" $' \n\t \r\n'; do
    run_stop "$m"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  run --separate-stderr "$HOOKS/stop.sh" <<< '{"session_id":"0b7c3d1e-4f5a","stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$(snapshot)" = "$before" ]
}

@test "stop: a note containing AKIAABCDEFGHIJKLMNOP -> nothing written, exit 0, stderr names the pattern without the value" {
  local before
  before="$(snapshot)"
  run_stop "Stored the key AKIAABCDEFGHIJKLMNOP in the vault."
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$stderr" = "stop: note refused (pattern aws-access-key)" ]
  [ "$(snapshot)" = "$before" ]
}

@test "stop: a secret on a later line of the message never reaches the file" {
  run_stop $'Configured the bot.\nThe token is 123456789:AAFabcdefghijklmnopqrstuvwxyz012345'
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$DAILY")" = "- [observed] 12:00 session 0b7c3d1e: Configured the bot." ]
  run ! grep -rq 'AAFabcdefghij' "$USER_DIR"
}

@test "stop: every positive secret sample is refused and every benign sample appended" {
  local name sample before
  before="$(snapshot)"
  while IFS=$'\t' read -r name sample; do
    run_stop "$sample"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" = "stop: note refused (pattern $name)" ] || { echo "$name: $stderr"; return 1; }
  done < "$FIXTURES/secret-samples.txt"
  [ "$(snapshot)" = "$before" ]
  while IFS= read -r sample; do
    run_stop "$sample"
    [ "$status" -eq 0 ]
    [ "$(tail -n 1 "$DAILY")" = "- [observed] 12:00 session 0b7c3d1e: $sample" ] || { echo "benign refused: $sample"; return 1; }
  done < "$FIXTURES/benign-samples.txt"
}

@test "stop: a daily file with 150 hook lines -> the marker appended exactly once; a further run appends nothing" {
  local i
  {
    printf -- '---\nname: daily 2026-09-30\ndescription: turn notes of 2026-09-30 written by the Stop hook\nupdated: 2026-09-30\n---\n'
    for i in $(seq 1 150); do printf -- '- [observed] 11:%02d session 22222222: turn %s\n' $((i % 60)) "$i"; done
  } > "$DAILY"
  run_stop "turn 151"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(tail -n 1 "$DAILY")" = "- [observed] cap reached: no further hook lines today" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/memory/acme/alice/daily/2026-09-30.md")" -eq 156 ]
  [ "$(printf '%s\n' "$stderr" | wc -l)" -eq 1 ]
  run_stop "turn 152"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(grep -c 'cap reached' "$DAILY")" -eq 1 ]
  [ "$(wc -l < "$DAILY")" -eq 156 ]
}

@test "stop: 149 hook lines -> one more line is written, no marker" {
  local i
  for i in $(seq 1 149); do printf -- '- [observed] 11:00 session 22222222: turn %s\n' "$i"; done > "$DAILY"
  run_stop "turn 150"
  [ "$(tail -n 1 "$DAILY")" = "- [observed] 12:00 session 0b7c3d1e: turn 150" ]
  run ! grep -q 'cap reached' "$DAILY"
}

@test "stop: ZYGGY_HOOKS=off -> exit 0, nothing" {
  local before
  before="$(snapshot)"
  export ZYGGY_HOOKS=off
  run --separate-stderr "$HOOKS/stop.sh" < "$FIXTURES/stop-input.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ "$(snapshot)" = "$before" ]
}

@test "stop: ZYGGY_TENANT unset -> exit 3, one stderr line" {
  unset ZYGGY_TENANT
  run --separate-stderr "$HOOKS/stop.sh" < "$FIXTURES/stop-input.json"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l)" -eq 1 ]
  [[ "$stderr" == *ZYGGY_TENANT* ]]
}

@test "stop: jq missing from PATH -> exit 3, stderr jq not found, nothing written" {
  local before f
  before="$(snapshot)"
  mkdir -p "$BATS_TEST_TMPDIR/nojq"
  # every executable except jq; only regular files (e.g. /usr/bin/X11 is a directory link on some runners),
  # and -n so a link already made from /usr/bin is replaced, never followed, when /bin is the same directory
  for f in /usr/bin/* /bin/*; do
    if [ -f "$f" ] && [ -x "$f" ] && [ "$(basename "$f")" != jq ]; then
      ln -sfn "$f" "$BATS_TEST_TMPDIR/nojq/$(basename "$f")"
    fi
  done
  PATH="$BATS_TEST_TMPDIR/nojq" run --separate-stderr "$HOOKS/stop.sh" < "$FIXTURES/stop-input.json"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$stderr" = "stop: jq not found" ]
  [ "$(snapshot)" = "$before" ]
}

@test "stop: invalid JSON on stdin -> exit 0, nothing written" {
  local before
  before="$(snapshot)"
  run --separate-stderr "$HOOKS/stop.sh" <<< 'not json'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(snapshot)" = "$before" ]
}

@test "stop: 23:30Z lands in tomorrow's Europe/Brussels file with time 01:30" {
  export ZYGGY_NOW=2026-09-30T23:30:00Z
  run --separate-stderr "$HOOKS/stop.sh" < "$FIXTURES/stop-input.json"
  [ "$status" -eq 0 ]
  local f="$USER_DIR/daily/2026-10-01.md"
  [ -f "$f" ]
  grep -qx 'name: daily 2026-10-01' "$f"
  [ "$(tail -n 1 "$f")" = "- [observed] 01:30 session 0b7c3d1e: Done: the plan for deliverable 27 is written and reviewed." ]
}

@test "stop: an existing daily file without a front matter gets none added and its lines are kept" {
  printf '%s\n' '- a line written by hand' > "$DAILY"
  run_stop "a note"
  [ "$status" -eq 0 ]
  [ "$(cat "$DAILY")" = "$(printf '%s\n' '- a line written by hand' '- [observed] 12:00 session 0b7c3d1e: a note')" ]
}

@test "stop: never invokes git" {
  install_git_stub
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$HOOKS/stop.sh" < "$FIXTURES/stop-input.json"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/git-was-called" ]
}

@test "stop: no .tmp file survives" {
  run_stop "one"
  run_stop "AKIAABCDEFGHIJKLMNOP"
  run_stop "two"
  [ -z "$(find "$USER_DIR" -name '*.tmp*')" ]
}

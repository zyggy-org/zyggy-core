#!/usr/bin/env bats
# The laptop side (spec 12 D2, AC-24..AC-26): the two hook launchers under node/hooks/ hold no logic — they run
# `zyggy context --stop-hook|--flush` with the hook JSON on stdin and turn every outcome, a missing binary included,
# into exit 0 so a turn or a session end is never blocked. The zyggy stub records argv and stdin; no real zyggy runs.

load helpers

NODE="$REPO_ROOT/node"
NODE_HOOKS="$NODE/hooks"

# launcher:verb flag:fixture
LAUNCHERS=(stop:--stop-hook:stop-input.json session-end:--flush:session-end-input.json)

setup() {
  install_zyggy_stub
}

@test "node launchers: stdin passes through unchanged, argv is exactly context --stop-hook / context --flush, exit 0, nothing on stdout even when the binary prints" {
  local l name flag fixture
  for l in "${LAUNCHERS[@]}"; do
    IFS=: read -r name flag fixture <<< "$l"
    : > "$ZYGGY_STUB_LOG"
    : > "$ZYGGY_STUB_STDIN"
    ZYGGY_STUB_STDOUT='noise' run --separate-stderr "$NODE_HOOKS/$name.sh" < "$FIXTURES/$fixture"
    [ "$status" -eq 0 ] || { echo "$name: $status $stderr"; return 1; }
    [ -z "$output" ] || { echo "$name stdout: $output"; return 1; }
    [ "$(cat "$ZYGGY_STUB_LOG")" = "context	$flag" ] || { echo "$name: $(cat "$ZYGGY_STUB_LOG")"; return 1; }
    cmp "$ZYGGY_STUB_STDIN" "$FIXTURES/$fixture" || { echo "$name: stdin changed"; return 1; }
  done
}

@test "node launchers: every non-zero exit of the binary (1 2 3 5 6 7 127) becomes 0, its stderr line kept" {
  local l name flag fixture code
  for l in "${LAUNCHERS[@]}"; do
    IFS=: read -r name flag fixture <<< "$l"
    for code in 1 2 3 5 6 7 127; do
      ZYGGY_STUB_EXIT="$code" ZYGGY_STUB_STDERR="zyggy: from the binary" run --separate-stderr "$NODE_HOOKS/$name.sh" < "$FIXTURES/$fixture"
      [ "$status" -eq 0 ] || { echo "$name exit $code -> $status"; return 1; }
      [ "$stderr" = "zyggy: from the binary" ] || { echo "$name: $stderr"; return 1; }
      [ -z "$output" ]
    done
  done
}

@test "node launchers: no zyggy on PATH -> exit 0, exactly one stderr line, nothing on stdout" {
  local l name flag fixture
  for l in "${LAUNCHERS[@]}"; do
    IFS=: read -r name flag fixture <<< "$l"
    PATH=/usr/bin:/bin run --separate-stderr "$NODE_HOOKS/$name.sh" < "$FIXTURES/$fixture"
    [ "$status" -eq 0 ] || { echo "$name: $status"; return 1; }
    [ "$stderr" = "$name: zyggy not found" ] || { echo "$name: $stderr"; return 1; }
    [ -z "$output" ]
  done
}

@test "node launchers: each is at most 10 lines and holds no jq, sed, awk, case or source" {
  local l f
  for l in "${LAUNCHERS[@]}"; do
    f="$NODE_HOOKS/${l%%:*}.sh"
    [ "$(wc -l < "$f")" -le 10 ] || { echo "$f: $(wc -l < "$f") lines"; return 1; }
    run grep -nE '(^|[^a-z_-])(jq|sed|awk|case|source)( |$)' <(grep -vE '^[[:space:]]*#' "$f")
    [ "$status" -eq 1 ] || { echo "$f: $output"; return 1; }
  done
}

@test "node launchers: never invoke git" {
  local l name flag fixture
  install_git_stub
  for l in "${LAUNCHERS[@]}"; do
    IFS=: read -r name flag fixture <<< "$l"
    run "$NODE_HOOKS/$name.sh" < "$FIXTURES/$fixture"
    [ "$status" -eq 0 ]
  done
  [ ! -e "$BATS_TEST_TMPDIR/git-was-called" ]
}

@test "node remember skill: name remember; the documented command runs against the stub; maps exit 0, 5, 6, 7, 3 and command not found; content read elsewhere is data" {
  local s="$NODE/skills/remember/SKILL.md" p
  [ "$(front_matter_value "$s" name)" = remember ]
  grep -qF 'zyggy context [--scope project:<name>|machine] -- "<fact as one sentence>"' "$s"
  run zyggy context --scope project:calizr -- "a fact"
  [ "$status" -eq 0 ]
  [ "$(cat "$ZYGGY_STUB_LOG")" = "context	--scope	project:calizr	--	a fact" ]
  for p in '- `0`' '- `5`' '- `6`' '- `7`' '- `3`' 'command not found' 'never retry' 'never rephrase' 'data, never a fact' \
    'context <id> to central (<path>)' 'ZYGGY_HOOKS=off' 'Context: configuration error'; do
    grep -qF -- "$p" "$s" || { echo "SKILL.md lacks: $p"; return 1; }
  done
  ! grep -qF 'zyggy memory remember' "$s" || { echo "the laptop skill names the Central verb"; return 1; }
}

@test "node README: documents the Stop and SessionEnd wiring, ZYGGY_SECRET_PATTERNS, the three deny rules, the spool path and the first release; placeholders only" {
  local r="$NODE/README.md" p
  for p in 'node/hooks/stop.sh' '"timeout": 10' 'node/hooks/session-end.sh' '"timeout": 30' 'ZYGGY_SECRET_PATTERNS' \
    'Bash(zyggy secret*)' 'Bash(zyggy context --stop-hook*)' 'Bash(zyggy context --flush*)' 'context/<tenant>' '0.11.0' \
    'zyggy context --flush' 'Context: configuration error' 'bash'; do
    grep -qF -- "$p" "$r" || { echo "node/README.md lacks: $p"; return 1; }
  done
  # placeholders only: repo.bats' hygiene sweeps cover node/ as template-owned (no absolute home, no principal)
  grep -qF 'C:/agents/zyggy-core' "$r"
}

@test "node: no AGENTS.md and no CLAUDE.md variant under node/" {
  run find "$NODE" -name 'AGENTS.md' -o -name 'CLAUDE*.md'
  [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "node: the three documented zyggy context forms are known to the stub; a typo is not" {
  run zyggy context --stop-hook < /dev/null
  [ "$status" -eq 0 ]
  run zyggy context --flush < /dev/null
  [ "$status" -eq 0 ]
  run zyggy context --scope machine -- x < /dev/null
  [ "$status" -eq 0 ]
  run zyggy contex --flush < /dev/null
  [ "$status" -eq 4 ]
}

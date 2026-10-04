#!/usr/bin/env bats
# session-start.sh: a thin launcher for `zyggy memory digest <section>` (deliverable 28, R1). The digest itself is the
# zyggy binary's, tested in the zyggy repository against this repository's fixtures (tests/fixtures/memory,
# tests/expected/digest-*.txt), which stay here as the oracle.

load helpers

setup() {
  setup_memory
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  # A stub zyggy: records its arguments and stdin, prints a marker, exits with $ZYGGY_STUB_EXIT (default 0).
  cat > "$STUB_DIR/zyggy" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ZYGGY_STUB_LOG.args"
cat > "$ZYGGY_STUB_LOG.stdin"
printf 'digest from zyggy\n'
exit "${ZYGGY_STUB_EXIT:-0}"
EOF
  chmod +x "$STUB_DIR/zyggy"
  export ZYGGY_STUB_LOG="$BATS_TEST_TMPDIR/stub"
}

launch() { # launch <path> <args…>: run the launcher with PATH=<path>
  local path="$1"
  shift
  PATH="$path" "$HOOKS/session-start.sh" "$@"
}

@test "launcher: passes the section to zyggy memory digest and prints its stdout" {
  run --separate-stderr launch "$STUB_DIR:$PATH" index < /dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "digest from zyggy" ]
  [ "$(cat "$ZYGGY_STUB_LOG.args")" = "$(printf '%s\n' memory digest index)" ]
}

@test "launcher: passes the hook JSON on stdin through unchanged" {
  hook_json "$CLAUDE_PROJECT_DIR" > "$BATS_TEST_TMPDIR/hook.json"
  run launch "$STUB_DIR:$PATH" identity < "$BATS_TEST_TMPDIR/hook.json"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/hook.json" "$ZYGGY_STUB_LOG.stdin"
}

@test "launcher: propagates zyggy's exit code (3 configuration, 4 unknown section)" {
  local code
  for code in 3 4; do
    ZYGGY_STUB_EXIT="$code" run launch "$STUB_DIR:$PATH" daily < /dev/null
    [ "$status" -eq "$code" ]
  done
}

@test "launcher: zyggy missing -> exit 0, empty stdout, one stderr line naming the section" {
  run --separate-stderr launch "/usr/bin:/bin" daily < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$stderr" = "session-start.sh: zyggy not found — no daily section" ]
}

@test "launcher: has no logic beyond the missing-binary line and exec" {
  run grep -cvE '^(#|$|set -euo pipefail$|if ! command -v zyggy > /dev/null 2>&1; then$|  printf |  exit 0$|fi$|exec zyggy memory digest "\$@"$)' \
    "$HOOKS/session-start.sh"
  [ "$output" = "0" ]
}

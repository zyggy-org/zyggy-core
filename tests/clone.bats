#!/usr/bin/env bats
# github-clone skill: clone.sh and askpass.sh (spec 32, AC-20..AC-31, AC-36). gh stub and git stub/spy; no network.

load helpers

setup() {
  setup_memory
  install_gh_stub
  install_token_file
  export HOME="$BATS_TEST_TMPDIR/home" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$HOME"
  unset ZYGGY_GITHUB_CLONE_BASE ZYGGY_CLONE_TIMEOUT ZYGGY_CLONE_MAX_MIB ZYGGY_CLONE_CACHE_MIB XDG_CONFIG_HOME
  CLONE="$REPO_ROOT/.claude/skills/github-clone/clone.sh"
  ASKPASS="$REPO_ROOT/.claude/skills/github-clone/askpass.sh"
  ROOT="$XDG_CACHE_HOME/zyggy/repos"
}

clone() {
  "$CLONE" "$@"
}

cache_snapshot() {
  find "$XDG_CACHE_HOME" "$HOME" -printf '%P %y %m\n' 2> /dev/null | sort | md5sum
}

stub_calls() {
  cat "$GH_STUB_LOG" 2> /dev/null | wc -l
}

stub_endpoints() {
  sed 's/ GH_TOKEN=.*//; s/^argv=//' "$GH_STUB_LOG" | awk -F $'\037' '{ print $NF }'
}

git_called() {
  [ -e "$BATS_TEST_TMPDIR/git-was-called" ] || { [ -f "$BATS_TEST_TMPDIR/git-spy.log" ] && grep -q '^argv=' "$BATS_TEST_TMPDIR/git-spy.log"; }
}

# exit <code>, empty stdout, one stderr line matching <glob>, cache and HOME unchanged, neither gh nor git called
assert_refused() { # assert_refused <code> <stderr glob> <snapshot before>
  [ "$status" -eq "$1" ] || { echo "status $status: $stderr"; return 1; }
  [ -z "$output" ] || { echo "stdout: $output"; return 1; }
  [ "$(printf '%s\n' "$stderr" | wc -l)" -eq 1 ] || { echo "stderr: $stderr"; return 1; }
  # shellcheck disable=SC2053 # $2 is a glob
  [[ "$stderr" == $2 ]] || { echo "stderr: $stderr"; return 1; }
  [ "$(cache_snapshot)" = "$3" ] || { echo "cache or HOME changed"; return 1; }
  [ "$(stub_calls)" -eq 0 ] || { echo "gh called"; return 1; }
  ! git_called || { echo "git called"; return 1; }
}

# AC-31 after every test: the token value is in no stdout, stderr, cache or HOME file, gh argv or spy log.
teardown() {
  ! grep -q STUBSTUB <<< "${output:-}${stderr:-}" || { echo "token in stdout/stderr"; return 1; }
  ! grep -rqs STUBSTUB "$XDG_CACHE_HOME" "$HOME" || { echo "token in cache or HOME"; return 1; }
  if [ -f "$GH_STUB_LOG" ]; then
    ! sed 's/ GH_TOKEN=.*//' "$GH_STUB_LOG" | grep -q STUBSTUB || { echo "token in gh argv"; return 1; }
  fi
  if [ -f "$BATS_TEST_TMPDIR/git-spy.log" ]; then
    ! grep -v '^password=' "$BATS_TEST_TMPDIR/git-spy.log" | grep -q STUBSTUB || { echo "token in spy log"; return 1; }
  fi
}

# A PATH of links to every executable except <name>, after the stub bin/ unless <name> is gh or git.
path_without() { # path_without <name>
  local dir="$BATS_TEST_TMPDIR/no-$1" f
  mkdir -p "$dir"
  for f in /usr/bin/* /bin/*; do
    if [ -f "$f" ] && [ -x "$f" ] && [ "$(basename "$f")" != "$1" ]; then
      ln -sfn "$f" "$dir/$(basename "$f")"
    fi
  done
  case "$1" in
    gh | git) printf '%s' "$dir" ;;
    *) printf '%s:%s' "$BATS_TEST_TMPDIR/bin" "$dir" ;;
  esac
}

# --- refusals before any GitHub or git call ------------------------------------------------------------------

@test "clone: ZYGGY_HOOKS=off -> exit 5, nothing created, gh and git never called (alice/repo and --clean, token absent too)" {
  local before a
  install_git_stub
  before="$(cache_snapshot)"
  export ZYGGY_HOOKS=off
  for a in alice/repo --clean; do
    run --separate-stderr clone "$a"
    assert_refused 5 "github-clone: refused: unattended run (ZYGGY_HOOKS=off)" "$before"
  done
  rm "$ZYGGY_GITHUB_TOKEN_FILE"
  run --separate-stderr clone alice/repo
  assert_refused 5 "github-clone: refused: unattended run (ZYGGY_HOOKS=off)" "$before"
}

@test "clone: ZYGGY_TENANT unset or memory root missing -> exit 3, one configuration error line" {
  local before
  install_git_stub
  before="$(cache_snapshot)"
  ZYGGY_TENANT="" run --separate-stderr clone alice/repo
  assert_refused 3 "*configuration error: ZYGGY_TENANT is not set" "$before"
  ZYGGY_MEMORY_ROOT="$BATS_TEST_TMPDIR/nowhere" run --separate-stderr clone alice/repo
  assert_refused 3 "*configuration error: memory root*" "$before"
}

@test "clone: git, gh, jq or timeout not on PATH -> exit 3 naming the tool" {
  local before t p
  install_git_stub
  before="$(cache_snapshot)"
  for t in git gh jq timeout; do
    p="$(path_without "$t")"
    if [ "$t" = gh ]; then
      ln -sfn "$BATS_TEST_TMPDIR/bin/git" "$p/git"
    fi
    PATH="$p" run --separate-stderr clone alice/repo
    assert_refused 3 "github-clone: $t not found" "$before" || { echo "tool: $t"; return 1; }
  done
}

@test "clone: token file missing, empty, whitespace only, mode 644 or a directory -> exit 3 naming the file and the condition" {
  local before tf="$ZYGGY_GITHUB_TOKEN_FILE"
  install_git_stub
  before="$(cache_snapshot)"
  rm "$tf"
  run --separate-stderr clone alice/repo
  assert_refused 3 "github-clone: token file $tf not found" "$before"
  : > "$tf"
  chmod 600 "$tf"
  run --separate-stderr clone alice/repo
  assert_refused 3 "github-clone: token file $tf is empty" "$before"
  printf ' \n\t\n' > "$tf"
  run --separate-stderr clone alice/repo
  assert_refused 3 "github-clone: token file $tf is empty" "$before"
  install_token_file
  chmod 644 "$tf"
  run --separate-stderr clone alice/repo
  assert_refused 3 "github-clone: token file $tf must be mode 0600 (is 644)" "$before"
  rm "$tf"
  mkdir -m 700 "$tf"
  run --separate-stderr clone alice/repo
  assert_refused 3 "github-clone: token file $tf is not a regular file" "$before"
}

@test "clone: token file owned by another user -> exit 3 (root only)" {
  [ "$(id -u)" -eq 0 ] || skip "needs root to chown"
  local before
  install_git_stub
  before="$(cache_snapshot)"
  chown nobody "$ZYGGY_GITHUB_TOKEN_FILE"
  run --separate-stderr clone alice/repo
  assert_refused 3 "github-clone: token file $ZYGGY_GITHUB_TOKEN_FILE must be owned by $(id -un)" "$before"
}

@test "clone: a cache root inside the checkout, inside memory, or containing memory -> exit 3, nothing created" {
  local before
  install_git_stub
  before="$(cache_snapshot)"
  XDG_CACHE_HOME="$REPO_ROOT/.cache-test" run --separate-stderr clone alice/repo
  assert_refused 3 "github-clone: clone cache $REPO_ROOT/.cache-test/zyggy/repos must be outside the checkout and memory/" "$before"
  [ ! -e "$REPO_ROOT/.cache-test" ]
  XDG_CACHE_HOME="$ZYGGY_MEMORY_ROOT/x" run --separate-stderr clone alice/repo
  assert_refused 3 "github-clone: clone cache $ZYGGY_MEMORY_ROOT/x/zyggy/repos must be outside the checkout and memory/" "$before"
  mkdir -p "$ROOT/m"
  cp -R "$ZYGGY_MEMORY_ROOT/." "$ROOT/m/"
  before="$(cache_snapshot)"
  ZYGGY_MEMORY_ROOT="$ROOT/m" run --separate-stderr clone alice/repo
  assert_refused 3 "github-clone: clone cache $ROOT must be outside the checkout and memory/" "$before"
}

@test "clone: ZYGGY_GITHUB_CLONE_BASE that is a URL, relative or missing -> exit 3" {
  local before b
  install_git_stub
  before="$(cache_snapshot)"
  for b in https://example.com rel/dir "$BATS_TEST_TMPDIR/missing"; do
    ZYGGY_GITHUB_CLONE_BASE="$b" run --separate-stderr clone alice/repo
    assert_refused 3 "github-clone: ZYGGY_GITHUB_CLONE_BASE must be an absolute local directory (tests only)" "$before" ||
      { echo "base: $b"; return 1; }
  done
}

@test "clone: usage errors -> exit 4, one usage line, nothing created, gh and git never called" {
  local before c
  local -a args
  install_git_stub
  before="$(cache_snapshot)"
  local -a cases=("" "alice/a alice/b" "alice" "alice/" "/repo" "alice/a/b" "alice/.." "alice/." "../x" "alice/x;rm"
    "-alice/x" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/x" "--full" "--bogus" "--clean alice/x" "clean" "--clean --clean")
  for c in "${cases[@]}"; do
    read -ra args <<< "$c"
    run --separate-stderr clone "${args[@]}"
    assert_refused 4 "github-clone: *usage: clone.sh <owner>/<name> | clone.sh --clean)" "$before" || { echo "case: '$c'"; return 1; }
  done
  run --separate-stderr clone "al ice/x"
  assert_refused 4 "github-clone: *usage: clone.sh <owner>/<name> | clone.sh --clean)" "$before"
}

@test "clone: alice/repo.git and alice/.github pass the name grammar (they reach the token check)" {
  local before r
  install_git_stub
  rm "$ZYGGY_GITHUB_TOKEN_FILE"
  before="$(cache_snapshot)"
  for r in alice/repo.git alice/.github; do
    run --separate-stderr clone "$r"
    assert_refused 3 "github-clone: token file $ZYGGY_GITHUB_TOKEN_FILE not found" "$before" || { echo "name: $r"; return 1; }
  done
}

# --- askpass.sh (AC-26) ----------------------------------------------------------------------------------------

@test "askpass: the two GitHub prompts -> x-access-token and the token without a newline" {
  export ZYGGY_GITHUB_ASKPASS_FILE="$ZYGGY_GITHUB_TOKEN_FILE"
  run --separate-stderr "$ASKPASS" "Username for 'https://github.com': "
  [ "$status" -eq 0 ]
  [ "$output" = x-access-token ]
  [ -z "$stderr" ]
  "$ASKPASS" "Password for 'https://x-access-token@github.com': " > "$BATS_TEST_TMPDIR/pw"
  tr -d '[:space:]' < "$ZYGGY_GITHUB_TOKEN_FILE" > "$BATS_TEST_TMPDIR/expected-pw"
  cmp -s "$BATS_TEST_TMPDIR/pw" "$BATS_TEST_TMPDIR/expected-pw"
}

@test "askpass: another host, another user, an empty prompt, no file variable, mode 644 or a missing file -> exit 1, empty stdout, one refusal line" {
  local p
  export ZYGGY_GITHUB_ASKPASS_FILE="$ZYGGY_GITHUB_TOKEN_FILE"
  for p in "Username for 'https://evil.example': " "Password for 'https://x-access-token@github.com.evil.example': " \
    "Password for 'https://alice@github.com': " ""; do
    run --separate-stderr "$ASKPASS" "$p"
    [ "$status" -eq 1 ] || { echo "prompt '$p': $status"; return 1; }
    [ -z "$output" ]
    [[ "$stderr" == "askpass: refused ("*")" ]] || { echo "$stderr"; return 1; }
  done
  p="Password for 'https://x-access-token@github.com': "
  ZYGGY_GITHUB_ASKPASS_FILE="" run --separate-stderr "$ASKPASS" "$p"
  [ "$status" -eq 1 ] && [ -z "$output" ] && [[ "$stderr" == "askpass: refused ("*")" ]]
  chmod 644 "$ZYGGY_GITHUB_TOKEN_FILE"
  run --separate-stderr "$ASKPASS" "$p"
  [ "$status" -eq 1 ] && [ -z "$output" ] && [[ "$stderr" == "askpass: refused ("*")" ]]
  rm "$ZYGGY_GITHUB_TOKEN_FILE"
  run --separate-stderr "$ASKPASS" "$p"
  [ "$status" -eq 1 ] && [ -z "$output" ] && [[ "$stderr" == "askpass: refused ("*")" ]]
}

# shellcheck shell=bash
# Shared setup for every .bats file (load helpers). Tenant acme, user alice, fake clock ZYGGY_NOW.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
HOOKS="$REPO_ROOT/.claude/hooks"
REMEMBER="$REPO_ROOT/.claude/skills/remember/remember.sh"
FIXTURES="$REPO_ROOT/tests/fixtures"
EXPECTED="$REPO_ROOT/tests/expected"
export REPO_ROOT HOOKS REMEMBER FIXTURES EXPECTED

# Export the principal, the clock and an empty project dir for a memory tree under $1.
export_principal() {
  export ZYGGY_MEMORY_ROOT="$1"
  export ZYGGY_TENANT=acme
  export ZYGGY_USER=alice
  export ZYGGY_TIMEZONE=Europe/Brussels
  export ZYGGY_NOW=2026-09-30T10:00:00Z
  export CLAUDE_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  unset ZYGGY_HOOKS ZYGGY_DIGEST_BYTES_IDENTITY ZYGGY_DIGEST_BYTES_INDEX ZYGGY_DIGEST_BYTES_DAILY
  mkdir -p "$CLAUDE_PROJECT_DIR"
}

# Copy the fixture memory tree to a temp dir; daily/ files are copied in shuffled order so that
# modification-time order differs from name order.
setup_memory() {
  local dest="$BATS_TEST_TMPDIR/memory"
  local src="$FIXTURES/memory/acme/alice"
  mkdir -p "$dest/acme/alice/daily"
  (cd "$src" && find . -path ./daily -prune -o -type f -print) | while IFS= read -r f; do
    mkdir -p "$dest/acme/alice/$(dirname "$f")"
    cp "$src/$f" "$dest/acme/alice/$f"
  done
  local f
  while IFS= read -r f; do
    cp "$src/daily/$f" "$dest/acme/alice/daily/$f"
    touch "$dest/acme/alice/daily/$f"
    sleep 0.01
  done < <(find "$src/daily" -maxdepth 1 -type f -printf '%f\n' | shuf)
  export_principal "$dest"
  USER_DIR="$dest/acme/alice"
  export USER_DIR
}

# Copy the oversize fixture and generate the 300 index files into the temp copy.
setup_oversize_memory() {
  local dest="$BATS_TEST_TMPDIR/memory-oversize"
  mkdir -p "$dest"
  cp -R "$FIXTURES/memory-oversize/." "$dest/"
  mkdir -p "$dest/acme/alice/areas"
  local i name
  for i in $(seq 0 299); do
    name=$(printf 'gen-%03d' "$i")
    printf -- '---\nname: %s\ndescription: generated index entry number %03d for the cap test\nupdated: 2026-09-30\n---\n- [stated] 2026-09-30: filler\n' \
      "$name" "$i" > "$dest/acme/alice/areas/$name.md"
  done
  export_principal "$dest"
  USER_DIR="$dest/acme/alice"
  export USER_DIR
}

# Hook stdin JSON: hook_json <cwd>
hook_json() {
  printf '{"session_id":"0b7c3d1e-4f5a-4b6c-8d7e-9f0a1b2c3d4e","cwd":"%s","hook_event_name":"SessionStart"}' "$1"
}

# Byte comparison, never whitespace-insensitive.
assert_bytes_equal() {
  if ! cmp "$1" "$2"; then
    diff "$2" "$1" || true
    return 1
  fi
}

# A git stub that records any invocation; prepend "$BATS_TEST_TMPDIR/bin" to PATH.
install_git_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\ntouch "%s/git-was-called"\nexit 99\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
}

# The gh stub (tests/fixtures/github/gh-stub.sh) as bin/gh, first on PATH, serving a per-test copy of the
# fixture pages and logging every call; the exclusion list points to a path that does not exist (none).
install_gh_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cp "$FIXTURES/github/gh-stub.sh" "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  cp -R "$FIXTURES/github" "$BATS_TEST_TMPDIR/github"
  export GH_STUB_FIXTURES="$BATS_TEST_TMPDIR/github"
  export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
  export ZYGGY_GITHUB_EXCLUDE_FILE="$BATS_TEST_TMPDIR/no-exclusions.txt"
  unset GH_STUB_FAIL GH_STUB_NOTICE GH_STUB_HEADERS GH_STUB_REPOS GH_TOKEN
}

# A synthetic read token (github_pat_ shape, never real) in a 0600 file named by ZYGGY_GITHUB_TOKEN_FILE.
install_token_file() {
  printf 'github_pat_11STUBSTUB0123456789_stubstubstubstubstubstubstubstubstub' > "$BATS_TEST_TMPDIR/token"
  chmod 600 "$BATS_TEST_TMPDIR/token"
  export ZYGGY_GITHUB_TOKEN_FILE="$BATS_TEST_TMPDIR/token"
}

# The git spy (tests/fixtures/github/git-spy.sh) as bin/git; mode in git-spy.mode (default ok), log in git-spy.log.
install_git_spy() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cp "$FIXTURES/github/git-spy.sh" "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  printf '%s' "${1:-ok}" > "$BATS_TEST_TMPDIR/git-spy.mode"
}

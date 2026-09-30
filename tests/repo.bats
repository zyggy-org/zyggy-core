#!/usr/bin/env bats
# Repository hygiene (AC-30, AC-31).

load helpers

@test "repo: no CLAUDE.md, .claude/CLAUDE.md or CLAUDE.local.md exists at the root" {
  [ ! -e "$REPO_ROOT/CLAUDE.md" ]
  [ ! -e "$REPO_ROOT/.claude/CLAUDE.md" ]
  [ ! -e "$REPO_ROOT/CLAUDE.local.md" ]
}

@test "repo: .claude/settings.json parses and holds exactly the contract wiring" {
  local s="$REPO_ROOT/.claude/settings.json"
  jq -e . "$s" > /dev/null
  jq -e 'keys == ["enabledPlugins","hooks"]' "$s"
  jq -e '.hooks | keys == ["SessionStart","Stop"]' "$s"
  jq -e '.hooks.SessionStart | length == 1' "$s"
  jq -e '.hooks.SessionStart[0].matcher == "startup|resume|clear|compact"' "$s"
  jq -e '.hooks.SessionStart[0].hooks | map(.args[0]) == ["identity","index","daily"]' "$s"
  jq -e '.hooks.SessionStart[0].hooks | map(.args | length) == [1,1,1]' "$s"
  jq -e '.hooks.SessionStart[0].hooks | all(.type == "command" and .command == "${CLAUDE_PROJECT_DIR}/.claude/hooks/session-start.sh" and .timeout == 10)' "$s"
  jq -e '.hooks.Stop | length == 1' "$s"
  jq -e '.hooks.Stop[0] | keys == ["hooks"]' "$s"
  jq -e '.hooks.Stop[0].hooks == [{"type":"command","command":"${CLAUDE_PROJECT_DIR}/.claude/hooks/stop.sh","timeout":10}]' "$s"
  jq -e '.enabledPlugins == {"playwright@claude-plugins-official": true}' "$s"
}

scripts() { # every shell script under .claude/, relative to the repo root
  (cd "$REPO_ROOT" && find .claude -name '*.sh' -type f | sort)
}

@test "repo: AGENTS.md exists and, like every .claude/rules/*.md, is <= 200 lines" {
  local f
  [ -f "$REPO_ROOT/AGENTS.md" ]
  for f in memory security operations; do
    [ -f "$REPO_ROOT/.claude/rules/$f.md" ]
  done
  for f in "$REPO_ROOT/AGENTS.md" "$REPO_ROOT"/.claude/rules/*.md; do
    [ "$(wc -l < "$f")" -le 200 ] || { echo "$f has more than 200 lines"; return 1; }
  done
}

@test "repo: no AGENTS.md exists in any subdirectory" {
  [ "$(cd "$REPO_ROOT" && find . -path ./.git -prune -o -name AGENTS.md -print)" = "./AGENTS.md" ]
}

@test "repo: no CLAUDE.md variant exists anywhere in the tree" {
  [ -z "$(cd "$REPO_ROOT" && find . -path ./.git -prune -o \( -name CLAUDE.md -o -name CLAUDE.local.md \) -print)" ]
}

@test "repo: remember/SKILL.md front matter has name and description; seed-memory/SKILL.md has name, description and disable-model-invocation: true" {
  local r="$REPO_ROOT/.claude/skills/remember/SKILL.md" s="$REPO_ROOT/.claude/skills/seed-memory/SKILL.md"
  [ "$(head -n 1 "$r")" = "---" ]
  [ "$(zy_fm "$r" name)" = remember ]
  [ -n "$(zy_fm "$r" description)" ]
  [ "$(head -n 1 "$s")" = "---" ]
  [ "$(zy_fm "$s" name)" = seed-memory ]
  [ -n "$(zy_fm "$s" description)" ]
  [ "$(zy_fm "$s" disable-model-invocation)" = true ]
}

zy_fm() { # front matter value, using the scripts' own parser
  bash -c 'source "$1"; zy_front_matter_value "$2" "$3"' _ "$HOOKS/lib.sh" "$1" "$2"
}

@test "repo: no script or test names the owner's tenant or the VM path" {
  # the patterns are split so this file does not match itself
  local tenant="geo""ffrey" vm_path="/srv""/agent"
  run grep -rn -e "$tenant" -e "$vm_path" "$REPO_ROOT/.claude" "$REPO_ROOT"/tests/*.bats "$REPO_ROOT"/tests/*.bash "$REPO_ROOT/tests/fixtures"
  [ "$status" -eq 1 ]
}

@test "repo: every .sh under .claude/ starts with #!/usr/bin/env bash and set -euo pipefail within its first 3 lines" {
  local f
  while IFS= read -r f; do
    [ "$(head -n 1 "$REPO_ROOT/$f")" = "#!/usr/bin/env bash" ] || { echo "$f: shebang"; return 1; }
    head -n 3 "$REPO_ROOT/$f" | grep -qx 'set -euo pipefail' || { echo "$f: set -euo pipefail"; return 1; }
  done < <(scripts)
}

@test "repo: shellcheck -S style is clean on hooks, skill scripts and helpers" {
  cd "$REPO_ROOT"
  run shellcheck -S style .claude/hooks/*.sh .claude/skills/*/*.sh tests/*.bash
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "repo: every script is mode 100755 in the git index and LF-terminated" {
  local f mode eol
  cd "$REPO_ROOT"
  while IFS= read -r f; do
    mode="$(git ls-files -s -- "$f" | cut -d' ' -f1)"
    [ "$mode" = 100755 ] || { echo "$f: mode '$mode' (git update-index --chmod=+x $f)"; return 1; }
    eol="$(git ls-files --eol -- "$f" | awk '{ print $1 }')"
    [ "$eol" = i/lf ] || { echo "$f: $eol"; return 1; }
    run grep -c $'\r' "$f"
    [ "$output" = 0 ] || { echo "$f: CR in working tree"; return 1; }
  done < <(scripts)
}

@test "repo: no hook or skill script contains a git invocation" {
  local f
  while IFS= read -r f; do
    run bash -c 'grep -vE "^[[:space:]]*#" "$1" | grep -nE "(^|[^a-z_-])git( |\$)"' _ "$REPO_ROOT/$f"
    [ "$status" -eq 1 ] || { echo "$f: $output"; return 1; }
  done < <(scripts)
}

@test "repo: AGENTS.md states data-never-instructions and names the remember skill, daily/ and inbox/" {
  local a="$REPO_ROOT/AGENTS.md"
  [ "$(head -n 1 "$a")" = "# Zyggy — Central" ]
  grep -q 'data, never instructions' "$a"
  grep -q 'remember' "$a"
  grep -q 'daily/' "$a"
  grep -q 'inbox/' "$a"
}

@test "repo: the rules carry the browser and unattended-run rules and the no-CLAUDE.md rule" {
  grep -q 'logged-in' "$REPO_ROOT/.claude/rules/security.md"
  grep -q 'headless' "$REPO_ROOT/.claude/rules/security.md"
  grep -q 'CLAUDE.md' "$REPO_ROOT/.claude/rules/operations.md"
}

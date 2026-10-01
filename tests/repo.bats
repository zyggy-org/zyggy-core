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
  jq -e 'keys == ["enabledPlugins","env","hooks","permissions"]' "$s"
  # the browser plugin's server is headed by default; every instance runs it headless with an in-memory profile;
  # every Bash command starts in the project directory, so a cd into a clone never persists (spec 32)
  jq -e '.env == {"PLAYWRIGHT_MCP_HEADLESS":"true","PLAYWRIGHT_MCP_BROWSER":"chromium","PLAYWRIGHT_MCP_ISOLATED":"true","CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR":"1"}' "$s"
  # the model's file tools never read the GitHub credential and never edit a clone (spec 32)
  jq -e '.permissions == {"deny":["Read(~/.config/zyggy/**)","Edit(~/.cache/zyggy/repos/**)"]}' "$s"
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

@test "repo: .claude/settings.json is stored in the layout Claude Code writes back (jq --indent 2), so a plugin install leaves the tree clean" {
  local s="$REPO_ROOT/.claude/settings.json"
  cmp "$s" <(jq --indent 2 . "$s")
}

@test "repo: .gitignore ignores only the root memory/ clone, never a test fixture" {
  cd "$REPO_ROOT"
  git check-ignore -q memory/acme/alice/profile.md
  run git ls-files --others --ignored --exclude-standard -- tests/
  [ -z "$output" ] || { echo "ignored under tests/: $output"; return 1; }
}

@test "repo: no AGENTS.md exists in any subdirectory" {
  [ "$(cd "$REPO_ROOT" && find . -path ./.git -prune -o -name AGENTS.md -print)" = "./AGENTS.md" ]
}

@test "repo: no CLAUDE.md variant exists anywhere in the tree" {
  [ -z "$(cd "$REPO_ROOT" && find . -path ./.git -prune -o \( -name CLAUDE.md -o -name CLAUDE.local.md \) -print)" ]
}

@test "repo: remember, seed-memory and github-inventory SKILL.md front matter are as contracted" {
  local r="$REPO_ROOT/.claude/skills/remember/SKILL.md" s="$REPO_ROOT/.claude/skills/seed-memory/SKILL.md"
  local g="$REPO_ROOT/.claude/skills/github-inventory/SKILL.md"
  [ "$(head -n 1 "$r")" = "---" ]
  [ "$(zy_fm "$r" name)" = remember ]
  [ -n "$(zy_fm "$r" description)" ]
  [ "$(head -n 1 "$s")" = "---" ]
  [ "$(zy_fm "$s" name)" = seed-memory ]
  [ -n "$(zy_fm "$s" description)" ]
  [ "$(zy_fm "$s" disable-model-invocation)" = true ]
  [ "$(head -n 1 "$g")" = "---" ]
  [ "$(zy_fm "$g" name)" = github-inventory ]
  [ -n "$(zy_fm "$g" description)" ]
  [ "$(zy_fm "$g" disable-model-invocation)" = true ]
  [ "$(zy_fm "$g" argument-hint)" = "[check]" ]
  [ "$(wc -l < "$g")" -le 66 ]
  local c="$REPO_ROOT/.claude/skills/github-clone/SKILL.md"
  [ "$(head -n 1 "$c")" = "---" ]
  [ "$(zy_fm "$c" name)" = github-clone ]
  [ -n "$(zy_fm "$c" description)" ]
  [ -z "$(zy_fm "$c" disable-model-invocation)" ]
  [ "$(zy_fm "$c" disallowed-tools)" = "WebFetch WebSearch mcp__plugin_playwright_playwright" ]
  [ "$(zy_fm "$c" argument-hint)" = "<owner>/<name> | clean" ]
  [ "$(wc -l < "$c")" -le 80 ]
}

@test "repo: security.md has the GitHub section with the attended-only, never-gh-auth-login, data and clone rules" {
  local s="$REPO_ROOT/.claude/rules/security.md" p
  grep -q '^## GitHub' "$s"
  for p in 'github-inventory' 'never run .gh auth login.' 'Unattended runs' 'ZYGGY_HOOKS=off' 'is data' \
    'github-clone' 'askpass.sh' '/add-dir' 'never run, build, install or test'; do
    grep -q -- "$p" "$s" || { echo "security.md lacks: $p"; return 1; }
  done
}

@test "repo: AGENTS.md lists GitHub and github-clone under what exists today; operations.md names exit codes 5 and 6" {
  local o="$REPO_ROOT/.claude/rules/operations.md"
  grep -q '^- \*\*GitHub\*\*' "$REPO_ROOT/AGENTS.md"
  grep -q 'github-clone' "$REPO_ROOT/AGENTS.md"
  grep -q '`5` refused' "$o"
  grep -q '`6` a GitHub request failed' "$o"
  grep -q 'GitHub token rejected' "$o"
  grep -q 'github-clone' "$o"
  grep -q 'do not retry and do not try another way' "$o"
}

@test "repo: README.md documents the github-inventory and github-clone skills, the exclusion file, the stub and the spy; tests/README.md the fixtures" {
  local s
  for s in inventory.sh --check --max github-inventory-exclude.txt gh-stub.sh 'no network in CI' github-read-token \
    'ZYGGY_GITHUB_TOKEN_FILE' 'never logged in' clone.sh askpass.sh --clean additionalDirectories \
    ZYGGY_GITHUB_CLONE_BASE ZYGGY_CLONE_TIMEOUT git-spy.sh; do
    grep -qF -- "$s" "$REPO_ROOT/README.md" || { echo "README.md lacks: $s"; return 1; }
  done
  for s in github-inventory hand-derived 'git spy' 'bare repositor'; do
    grep -q -- "$s" "$REPO_ROOT/tests/README.md" || { echo "tests/README.md lacks: $s"; return 1; }
  done
}

@test "repo: github-clone/SKILL.md names --add-dir only in a never sentence" {
  run grep -n -- '--add-dir' "$REPO_ROOT/.claude/skills/github-clone/SKILL.md"
  [ "$status" -eq 0 ]
  ! grep -v -i 'never' <<< "$output"
}

@test "repo: the gh stub, the git spy and the curl stub start with the template shebang and set -euo pipefail, are LF and executable in the index, and ci.yml shellchecks all three" {
  local f
  cd "$REPO_ROOT"
  for f in tests/fixtures/github/gh-stub.sh tests/fixtures/github/git-spy.sh tests/fixtures/graph/curl-stub.sh; do
    [ "$(head -n 1 "$f")" = "#!/usr/bin/env bash" ] || { echo "$f: shebang"; return 1; }
    head -n 3 "$f" | grep -qx 'set -euo pipefail'
    [ "$(git ls-files -s -- "$f" | cut -d' ' -f1)" = 100755 ] || { echo "$f: mode"; return 1; }
    [ "$(git ls-files --eol -- "$f" | awk '{ print $1 }')" = i/lf ] || { echo "$f: eol"; return 1; }
    grep -qF "$f" .github/workflows/ci.yml || { echo "$f: ci.yml"; return 1; }
  done
}

@test "repo: no token-shaped value outside the secret samples, the patterns, the fixture token helper and the secret fixture page" {
  run git -C "$REPO_ROOT" grep -nE '(github_pat_|ghp_|ghs_)[A-Za-z0-9_]{20,}' -- ':!tests/fixtures/secret-samples.txt' \
    ':!tests/helpers.bash' ':!.claude/hooks/secret-patterns.txt' ':!tests/fixtures/github/repos-secret.json' \
    ':!tests/fixtures/github/git-spy.sh'
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "repo: skills call their scripts with a working-directory fallback (CLAUDE_PROJECT_DIR is not set in the Bash tool)" {
  run grep -n '"\$CLAUDE_PROJECT_DIR"' "$REPO_ROOT"/.claude/skills/*/SKILL.md
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  grep -qF '"${CLAUDE_PROJECT_DIR:-.}"/.claude/skills/remember/remember.sh' "$REPO_ROOT/.claude/skills/remember/SKILL.md"
  grep -qF '"${CLAUDE_PROJECT_DIR:-.}"/.claude/skills/github-inventory/inventory.sh' \
    "$REPO_ROOT/.claude/skills/github-inventory/SKILL.md"
  grep -qF '"${CLAUDE_PROJECT_DIR:-.}"/.claude/skills/github-clone/clone.sh' \
    "$REPO_ROOT/.claude/skills/github-clone/SKILL.md"
}

zy_fm() { # front matter value, using the scripts' own parser
  bash -c 'source "$1"; zy_front_matter_value "$2" "$3"' _ "$HOOKS/lib.sh" "$1" "$2"
}

# --- template hygiene (AC-30): template-owned files name no principal and no machine -------------------

# The instance-owned paths: an instance adds files here only, the template never ships them.
INSTANCE_OWNED_ERE='^(instance/|\.claude/rules/instance\.md$|\.claude/rules/instance/|\.claude/skills/instance-[^/]+/)'

# Tracked (index) files of <root> that belong to the template: instance-owned paths and this file excluded.
template_owned_files() { # template_owned_files <root>
  local f
  git -C "$1" ls-files | grep -vE "$INSTANCE_OWNED_ERE" | grep -vx 'tests/repo.bats' |
    while IFS= read -r f; do
      if [ -f "$1/$f" ]; then printf '%s\n' "$f"; fi
    done
}

# path:line of every absolute home or machine path (/srv/, /home/, /Users/, /root/, X:\).
hygiene_paths() { # hygiene_paths <root>
  local f
  template_owned_files "$1" | while IFS= read -r f; do
    grep -InE '/srv/|/home/|/Users/|/root/|(^|[^A-Za-z0-9_])[A-Za-z]:\\' "$1/$f" | sed "s|^\([0-9]*\):.*|$f:\1|" || true
  done
}

# path:line of every literal ZYGGY_TENANT/ZYGGY_USER value under .claude/, in AGENTS.md or README.md.
hygiene_principal() { # hygiene_principal <root>
  local f
  template_owned_files "$1" | grep -E '^(\.claude/|AGENTS\.md$|README\.md$)' | while IFS= read -r f; do
    grep -InE 'ZYGGY_(TENANT|USER)"?[[:space:]]*[=:][[:space:]]*"?[A-Za-z0-9]' "$1/$f" | sed "s|^\([0-9]*\):.*|$f:\1|" || true
  done
}

# path:line of every case-insensitive occurrence of a word of the comma-separated list.
hygiene_words() { # hygiene_words <root> <csv>
  local f word
  local -a words=()
  IFS=',' read -ra words <<< "$2"
  template_owned_files "$1" | while IFS= read -r f; do
    for word in "${words[@]}"; do
      word="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$word")"
      [ -n "$word" ] || continue
      grep -InFi -- "$word" "$1/$f" | sed "s|^\([0-9]*\):.*|$f:\1|" || true
    done
  done
}

@test "repo: no template-owned file contains an absolute home or machine path (/srv/, /home/, /Users/, /root/, X:\\)" {
  run hygiene_paths "$REPO_ROOT"
  [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "repo: no literal ZYGGY_TENANT/ZYGGY_USER assignment under .claude/, in AGENTS.md or README.md (placeholders allowed)" {
  run hygiene_principal "$REPO_ROOT"
  [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "repo: no word of ZYGGY_HYGIENE_FORBIDDEN occurs in a template-owned file" {
  local list="${ZYGGY_HYGIENE_FORBIDDEN:-}"
  [ -n "${list//[ ,]/}" ] || skip "ZYGGY_HYGIENE_FORBIDDEN not set"
  run hygiene_words "$REPO_ROOT" "$list"
  [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "repo: the hygiene checks flag template-owned offenders and exempt instance-owned paths" {
  local t="$BATS_TEST_TMPDIR/t" f
  git init -q "$t"
  mkdir -p "$t/.claude/rules/instance" "$t/.claude/skills/instance-x" "$t/.claude/hooks" "$t/instance" "$t/tests"
  printf '%s\n' 'intro' 'clone into /srv/x' 'or C:\Users\x' > "$t/README.md"
  printf '%s\n' 'ZYGGY_TENANT=bob' > "$t/.claude/rules/memory.md"
  printf '%s\n' '# Zyggy' 'Zebulon wrote this' > "$t/AGENTS.md"
  printf '%s\n' 'regex: truncated:\ profile' > "$t/tests/digest.bats"
  printf '%s\n' 'tenant="${ZYGGY_TENANT:-}"' 'ZYGGY_USER: <user>' > "$t/.claude/hooks/x.sh"
  for f in instance/settings.local.json .claude/rules/instance.md .claude/rules/instance/extra.md .claude/skills/instance-x/SKILL.md; do
    printf '%s\n' '"ZYGGY_TENANT": "zebulon"' '/srv/agent/central' 'D:\source\x' > "$t/$f"
  done
  git -C "$t" add -A
  run hygiene_paths "$t"
  [ "$output" = "$(printf '%s\n' README.md:2 README.md:3)" ] || { echo "paths: $output"; return 1; }
  run hygiene_principal "$t"
  [ "$output" = ".claude/rules/memory.md:1" ] || { echo "principal: $output"; return 1; }
  run hygiene_words "$t" " , zebulon ,"
  [ "$output" = "AGENTS.md:2" ] || { echo "words: $output"; return 1; }
}

@test "repo: README.md documents the instance-owned paths, creating and updating an instance, and ZYGGY_HYGIENE_FORBIDDEN" {
  local r="$REPO_ROOT/README.md" s
  for s in 'instance/**' '.claude/rules/instance.md' '.claude/rules/instance/**' '.claude/skills/instance-*/**' \
    'Instance-owned paths' 'Create an instance' 'Update an instance from the template' \
    'git pull upstream main' 'git pull --ff-only' 'install -m 600 instance/settings.local.json .claude/settings.local.json' \
    'ZYGGY_HYGIENE_FORBIDDEN'; do
    grep -qF -- "$s" "$r" || { echo "README.md lacks: $s"; return 1; }
  done
}

@test "repo: AGENTS.md and operations.md point to .claude/rules/instance.md; no template rule names a runbook path of the zyggy repository" {
  grep -q 'instance.md' "$REPO_ROOT/AGENTS.md"
  grep -q 'instance.md' "$REPO_ROOT/.claude/rules/operations.md"
  run grep -n 'runbooks/' "$REPO_ROOT/AGENTS.md" "$REPO_ROOT/.claude/rules/memory.md" \
    "$REPO_ROOT/.claude/rules/security.md" "$REPO_ROOT/.claude/rules/operations.md" \
    "$REPO_ROOT/.claude/skills/remember/SKILL.md" "$REPO_ROOT/.claude/skills/seed-memory/SKILL.md" \
    "$REPO_ROOT/.claude/skills/github-inventory/SKILL.md" "$REPO_ROOT/.claude/skills/github-clone/SKILL.md"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "repo: operations.md installs settings.local.json from instance/settings.local.json and says instance.md never relaxes these rules" {
  grep -qF 'instance/settings.local.json' "$REPO_ROOT/.claude/rules/operations.md"
  grep -q 'never relaxes' "$REPO_ROOT/.claude/rules/operations.md"
}

@test "repo: security.md says template and instance changes are made on the owner's workstation" {
  grep -q 'template and instance changes' "$REPO_ROOT/.claude/rules/security.md"
}

@test "repo: seed-memory creates a missing identity file with front matter" {
  grep -q 'when it does not exist' "$REPO_ROOT/.claude/skills/seed-memory/SKILL.md"
}

@test "repo: ci.yml passes vars.ZYGGY_HYGIENE_FORBIDDEN to bats" {
  grep -qF 'ZYGGY_HYGIENE_FORBIDDEN: ${{ vars.ZYGGY_HYGIENE_FORBIDDEN }}' "$REPO_ROOT/.github/workflows/ci.yml"
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
  run shellcheck -S style .claude/hooks/*.sh .claude/skills/*/*.sh tests/*.bash tests/fixtures/github/gh-stub.sh tests/fixtures/github/git-spy.sh tests/fixtures/graph/curl-stub.sh tests/fixtures/m365/*.bash
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

# The one script allowed to run git: the github-clone runner, only under the clone cache (spec 32).
GIT_EXEMPT=(.claude/skills/github-clone/clone.sh)

@test "repo: no hook or skill script contains a git invocation, except the one exempt clone script" {
  local f
  [ "${#GIT_EXEMPT[@]}" -eq 1 ] || { echo "only one script may be exempt: ${GIT_EXEMPT[*]}"; return 1; }
  while IFS= read -r f; do
    [ "$f" != "${GIT_EXEMPT[0]}" ] || continue
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

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
  # the model's file tools never read the GitHub credential and never edit a clone (spec 32); the m365 rules that
  # follow them and the ask rules of the D7 action tools are asserted by the m365 tests below (spec 23)
  jq -e '.permissions | keys == ["ask","deny"]' "$s"
  jq -e '.permissions.deny[0:2] == ["Read(~/.config/zyggy/**)","Edit(~/.cache/zyggy/repos/**)"]' "$s"
  jq -e '.hooks | keys == ["PostToolUse","PreToolUse","SessionStart","Stop"]' "$s"
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

@test "repo: the gh stub, the git spy, the curl stub, the MCP server stub, the MarkItDown stub, the claude stub, the brief, the mail-backfill and the files-backfill actions start with the template shebang and set -euo pipefail, are LF and executable in the index, and ci.yml shellchecks all nine" {
  local f
  cd "$REPO_ROOT"
  for f in tests/fixtures/github/gh-stub.sh tests/fixtures/github/git-spy.sh tests/fixtures/graph/curl-stub.sh \
    tests/fixtures/m365/ms-365-mcp-server-stub.sh tests/fixtures/m365/markitdown-stub.sh tests/fixtures/m365/claude-stub.sh \
    tests/fixtures/m365/brief-actions.sh tests/fixtures/m365/backfill-actions.sh tests/fixtures/m365/files-actions.sh; do
    [ "$(head -n 1 "$f")" = "#!/usr/bin/env bash" ] || { echo "$f: shebang"; return 1; }
    head -n 3 "$f" | grep -qx 'set -euo pipefail'
    [ "$(git ls-files -s -- "$f" | cut -d' ' -f1)" = 100755 ] || { echo "$f: mode"; return 1; }
    [ "$(git ls-files --eol -- "$f" | awk '{ print $1 }')" = i/lf ] || { echo "$f: eol"; return 1; }
    # the m365 fixture scripts are shellchecked through the tests/fixtures/m365/*.sh glob
    grep -qF "$f" .github/workflows/ci.yml || grep -qF "$(dirname "$f")/*.sh" .github/workflows/ci.yml ||
      { echo "$f: ci.yml"; return 1; }
  done
}

@test "repo: no token-shaped value outside the secret samples, the patterns, the fixture token helper and the secret fixture page" {
  run git -C "$REPO_ROOT" grep -nE '(github_pat_|ghp_|ghs_)[A-Za-z0-9_]{20,}' -- ':!tests/fixtures/secret-samples.txt' \
    ':!tests/helpers.bash' ':!.claude/hooks/secret-patterns.txt' ':!tests/fixtures/github/repos-secret.json' \
    ':!tests/fixtures/github/git-spy.sh' ':!tests/fixtures/m365/facts-brief.txt'
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
  # the m365 skill runs in the owner's session; the three run skills run with the project directory as cwd
  # (brief.sh and the backfills start claude there) and name their scripts relative to it, as the allow rules do
  grep -qF '"${CLAUDE_PROJECT_DIR:-.}"/.claude/skills/m365/' "$REPO_ROOT/.claude/skills/m365/SKILL.md"
  local n
  for n in morning-brief mail-backfill files-backfill; do
    grep -qF '`.claude/skills/m365/' "$REPO_ROOT/.claude/skills/$n/SKILL.md" || { echo "$n"; return 1; }
    run grep -n 'CLAUDE_PROJECT_DIR' "$REPO_ROOT/.claude/skills/$n/SKILL.md"
    [ "$status" -eq 1 ] || { echo "$n: $output"; return 1; }
  done
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
    "$REPO_ROOT/.claude/skills/github-inventory/SKILL.md" "$REPO_ROOT/.claude/skills/github-clone/SKILL.md" \
    "$REPO_ROOT/.claude/skills/morning-brief/SKILL.md" "$REPO_ROOT/.claude/skills/mail-backfill/SKILL.md" \
    "$REPO_ROOT/.claude/skills/files-backfill/SKILL.md" "$REPO_ROOT/.claude/skills/m365/SKILL.md"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ -f "$REPO_ROOT/.claude/skills/m365/SKILL.md" ]
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
  run shellcheck -S style .claude/hooks/*.sh .claude/skills/*/*.sh tests/*.bash tests/fixtures/github/gh-stub.sh tests/fixtures/github/git-spy.sh tests/fixtures/graph/curl-stub.sh tests/fixtures/m365/*.sh
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

@test "repo: no hook or skill script contains a git invocation, except the one exempt clone script (a Bash(git *) deny rule is not one)" {
  local f
  [ "${#GIT_EXEMPT[@]}" -eq 1 ] || { echo "only one script may be exempt: ${GIT_EXEMPT[*]}"; return 1; }
  while IFS= read -r f; do
    [ "$f" != "${GIT_EXEMPT[0]}" ] || continue
    # the run deny list of the m365 orchestrators names the permission rule Bash(git *): a string, not a call
    run bash -c 'grep -vE "^[[:space:]]*#" "$1" | sed "s/Bash(git \\*)//g" | grep -nE "(^|[^a-z_-])git( |\$)"' _ "$REPO_ROOT/$f"
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

# --- the m365 connector's settings contract (spec 23 AC-45, plan 23 Step 4) ---------------------------------------

M365_TOOLS="$REPO_ROOT/tests/fixtures/m365"
M365_LIB="$REPO_ROOT/.claude/skills/m365/m365-lib.sh"

m365_lib_value() { # m365_lib_value <bash expression> → printed by a shell that sourced the two libraries
  bash -c 'source "$1" && source "$2" && eval "printf \"%s\\n\" $3"' _ "$HOOKS/lib.sh" "$M365_LIB" "$1"
}

@test "repo: permissions.deny = the three path rules, the graph.sh Bash rule, then mcp__m365__ + every line of excluded-tools.txt (328), in that order (AC-37)" {
  local s="$REPO_ROOT/.claude/settings.json"
  jq -e '.permissions.deny[0:4] == ["Read(~/.config/zyggy/**)","Edit(~/.cache/zyggy/repos/**)","Edit(~/.local/state/zyggy/**)","Bash(.claude/skills/m365/graph.sh *)"]' "$s"
  [ "$(wc -l < "$M365_TOOLS/excluded-tools.txt")" -eq 328 ]
  diff <(jq -r '.permissions.deny[4:][]' "$s") <(sed 's/^/mcp__m365__/' "$M365_TOOLS/excluded-tools.txt")
  [ "$(jq '.permissions.deny | length' "$s")" -eq 332 ]
  [ "$(jq '.permissions.deny | unique | length' "$s")" -eq 332 ]
  ! grep -qE 'm365-approve|propose' "$s"
}

@test "repo: permissions.ask = the D7 action tools the server loads (send, move); ask ⊆ enabled, ask ∩ deny = ∅; no mcp__m365__ in any allow list (template, instance); no PermissionRequest hook; PreToolUse m365-guard.sh and PostToolUse m365-log.sh in exec form with the action-tool matcher and timeout 20 (AC-37)" {
  local s="$REPO_ROOT/.claude/settings.json" i="$REPO_ROOT/instance/settings.local.json" e m f
  cmp "$s" <(jq --indent 2 . "$s")
  jq -e '.permissions.ask == ["mcp__m365__send-shared-mailbox-mail","mcp__m365__move-shared-mailbox-message"]' "$s"
  run comm -23 <(jq -r '.permissions.ask[] | sub("^mcp__m365__"; "")' "$s" | LC_ALL=C sort) <(LC_ALL=C sort "$M365_TOOLS/enabled-tools.txt")
  [ -z "$output" ] || { echo "asked but not enabled: $output"; return 1; }
  run comm -12 <(jq -r '.permissions.ask[]' "$s" | LC_ALL=C sort) <(jq -r '.permissions.deny[]' "$s" | LC_ALL=C sort)
  [ -z "$output" ] || { echo "asked and denied: $output"; return 1; }
  # the third action tool stays denied with the excluded tools (Step R1, fact 3)
  jq -e '.permissions.deny | index("mcp__m365__upload-file-content") != null' "$s"
  for f in "$s" "$i"; do
    [ -f "$f" ] || continue
    jq -e '[.permissions.allow // [] | .[] | select(startswith("mcp__m365__"))] == []' "$f" || { echo "m365 tool allowed in $f"; return 1; }
  done
  jq -e '.hooks | has("PermissionRequest") | not' "$s"
  m='^mcp__m365__(send-shared-mailbox-mail|upload-file-content|move-shared-mailbox-message)$'
  for e in PreToolUse:m365-guard.sh PostToolUse:m365-log.sh; do
    jq -e --arg ev "${e%%:*}" --arg h "${e#*:}" --arg m "$m" '.hooks[$ev] == [{matcher: $m, hooks: [{type: "command",
      command: ("${CLAUDE_PROJECT_DIR}/.claude/hooks/" + $h), timeout: 20}]}]' "$s" || { echo "hook entry: $e"; return 1; }
    [ -x "$REPO_ROOT/.claude/hooks/${e#*:}" ] || { echo "not executable: ${e#*:}"; return 1; }
  done
}

@test "repo: the deny list names graph-batch and the six auth tools the server registers outside ENABLED_TOOLS" {
  local s="$REPO_ROOT/.claude/settings.json" t
  for t in graph-batch login logout verify-login list-accounts select-account remove-account; do
    jq -e --arg t "mcp__m365__$t" '.permissions.deny | index($t) != null' "$s" > /dev/null || { echo "not denied: $t"; return 1; }
  done
}

@test "repo: every /me tool of the pinned version is denied, and no enabled tool is" {
  local s="$REPO_ROOT/.claude/settings.json" me
  me="$(jq -r '.tools[] | select(.description | test("^[A-Z]+ /me(/|\\(| |$)")) | .name' "$M365_TOOLS/tools-list-0.157.2.json")"
  [ "$(grep -c . <<< "$me")" -gt 100 ] || { echo "too few /me tools: $me"; return 1; }
  run comm -23 <(LC_ALL=C sort <<< "$me") <(jq -r '.permissions.deny[]' "$s" | sed -n 's/^mcp__m365__//p' | LC_ALL=C sort)
  [ -z "$output" ] || { echo "/me tools not denied: $output"; return 1; }
  run comm -12 <(LC_ALL=C sort "$M365_TOOLS/enabled-tools.txt") <(jq -r '.permissions.deny[]' "$s" | sed -n 's/^mcp__m365__//p' | LC_ALL=C sort)
  [ -z "$output" ] || { echo "enabled and denied: $output"; return 1; }
}

@test "repo: no enabled tool name sends, moves, deletes, updates, forwards or replies but the two D7 action tools (Step R1)" {
  run grep -nE 'send|move|delete|update|forward|reply-(shared|mail|all)|upload' \
    <(grep -vxE 'send-shared-mailbox-mail|move-shared-mailbox-message' "$M365_TOOLS/enabled-tools.txt")
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "repo: m365-lib.sh's ENABLED_TOOLS is Step R1's regex, = ^( + enabled-tools.txt joined by | + )\$; its two arrays are the fixture lists" {
  local r1='^(create-shared-mailbox-draft|create-shared-mailbox-reply-draft|download-bytes-to-file|get-drive-delta|get-drive-item|get-drive-root-item|get-shared-mailbox-message|get-sharepoint-site-drive-by-id|list-drive-item-versions|list-folder-files|list-shared-mailbox-folder-messages|list-shared-mailbox-messages|list-sharepoint-site-drives|move-shared-mailbox-message|search-onedrive-files|send-shared-mailbox-mail)$'
  local regex
  regex="$(m365_lib_value '"$ZY_M365_ENABLED_TOOLS"')"
  [ "$regex" = "$r1" ] || { echo "$regex"; return 1; }
  [ "$regex" = "^($(paste -sd'|' "$M365_TOOLS/enabled-tools.txt"))$" ] || { echo "$regex"; return 1; }
  diff <(m365_lib_value '"${ZY_M365_TOOLS_ENABLED[@]}"') "$M365_TOOLS/enabled-tools.txt"
  diff <(m365_lib_value '"${ZY_M365_TOOLS_EXCLUDED[@]}"') "$M365_TOOLS/excluded-tools.txt"
  diff <(m365_lib_value '"${ZY_M365_AUTH_TOOLS[@]}"') <(printf '%s\n' list-accounts login logout remove-account select-account verify-login)
}

@test "repo (AC-52): .mcp.json declares exactly the m365 server over loopback HTTP with the headersHelper — no headers, env, command or args, no GUID, in jq --indent 2 layout" {
  local m="$REPO_ROOT/.mcp.json"
  jq -e . "$m" > /dev/null
  cmp "$m" <(jq --indent 2 . "$m")
  jq -e 'keys == ["mcpServers"] and (.mcpServers | keys == ["m365"])' "$m"
  jq -e '.mcpServers.m365 == {"type": "http", "url": "http://127.0.0.1:${ZYGGY_M365_PORT:-47365}/mcp",
    "headersHelper": "${CLAUDE_PROJECT_DIR:-.}/.claude/skills/m365/mcp-auth-header.sh"}' "$m"
  run grep -nE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-' "$m"
  [ "$status" -eq 1 ]
}

@test "repo: mcp-wrapper.sh never names --http, --login, --read-only, npx, EXPECTED_USERNAME or ALLOWED_SCOPES, and clears the environment once" {
  local w="$REPO_ROOT/.claude/skills/m365/mcp-wrapper.sh"
  run grep -nE -- '--http|--login|--read-only|npx|EXPECTED_USERNAME|ALLOWED_SCOPES' "$w"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ "$(grep -c 'env -i' "$w")" -eq 1 ]
  grep -qF -- '--org-mode' "$w"
}

@test "repo (AC-52): mcp-server.sh never names graph.sh's token verb, a token variable, a client secret, npx, --login or the forbidden server flags; binds 127.0.0.1 only (no host setting); clears the environment once; the helper prints with a builtin" {
  local s="$REPO_ROOT/.claude/skills/m365/mcp-server.sh" h="$REPO_ROOT/.claude/skills/m365/mcp-auth-header.sh"
  run grep -nE -- '--enable-auth-tools|--enable-dynamic-registration|--enable-attachment-urls|--obo|--trust-proxy-auth|--allow-unauthenticated-discovery|MS365_MCP_OAUTH_TOKEN|MS365_MCP_CLIENT_SECRET|npx|--login|--public-url|graph\.sh"? token' "$s"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ "$(grep -c 'graph\.sh' "$s")" -eq 0 ]
  [ "$(grep -c 'env -i' "$s")" -eq 1 ]
  grep -qF 'listen="127.0.0.1:$ZY_M365_PORT"' "$s"
  run grep -nE 'ZYGGY_M365_HOST|0\.0\.0\.0|::' "$s"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  grep -qF -- '--org-mode --http "$listen" --http-local-file-tools --no-dynamic-registration' "$s"
  # the helper: graph.sh token once per attempt, the header through the printf builtin, nothing else prints the token
  grep -qF "printf '{\"Authorization\":\"Bearer %s\"}\\n' \"\$token\"" "$h"
  # "$token" is only tested by [[ ]] and printed by printf — both builtins, never an argument of a program
  run bash -c 'grep -n "\"\$token\"" "$1" | grep -vE ":(\[\[ \"\\\$token\" =~|printf )"' _ "$h"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "repo: morning-brief/SKILL.md is owner-unreachable (disable-model-invocation: true, no allowed-tools), <= 100 lines, carries every line of expected/m365-suggestions-section.txt verbatim and no D6 proposal wording (AC-38)" {
  local s="$REPO_ROOT/.claude/skills/morning-brief/SKILL.md" g="$REPO_ROOT/tests/expected/m365-suggestions-section.txt" line
  [ "$(head -n 1 "$s")" = "---" ]
  [ "$(zy_fm "$s" name)" = morning-brief ]
  [ -n "$(zy_fm "$s" description)" ]
  [ "$(zy_fm "$s" disable-model-invocation)" = true ]
  [ -z "$(zy_fm "$s" allowed-tools)" ]
  [ "$(wc -l < "$s")" -le 100 ]
  while IFS= read -r line; do
    grep -qxF -- "$line" "$s" || { echo "missing: $line"; return 1; }
  done < "$g"
  grep -qF 'Suggesting is not acting' "$s"
  grep -qxF '`brief <date>: mail <n>, files <m>, replies <r>, suggestions <s>, facts <f>`.' "$s"
  run grep -nE 'm365-approve|propose\.sh|pending your consent|proposal_cap|#<hash8>' "$s"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

# --- the m365 connector's instruction contract and hygiene (spec 23 AC-23, AC-45, AC-46; plan 23 Step 11) -------------

M365_SKILLS=(morning-brief mail-backfill files-backfill m365)

@test "repo: the four m365 skills are owner-unreachable with the contracted argument hints and line caps" {
  local n s hint cap
  for n in "${M365_SKILLS[@]}"; do
    s="$REPO_ROOT/.claude/skills/$n/SKILL.md"
    [ -f "$s" ] || { echo "missing: $s"; return 1; }
    [ "$(head -n 1 "$s")" = "---" ] || { echo "$n: front matter"; return 1; }
    [ "$(zy_fm "$s" name)" = "$n" ] || { echo "$n: name"; return 1; }
    [ -n "$(zy_fm "$s" description)" ] || { echo "$n: description"; return 1; }
    [ "$(zy_fm "$s" disable-model-invocation)" = true ] || { echo "$n: disable-model-invocation"; return 1; }
    [ -z "$(zy_fm "$s" allowed-tools)" ] || { echo "$n: allowed-tools"; return 1; }
    case "$n" in
      morning-brief) hint='<mailbox> <inbox-folder-id> <drive-id>… <run-dir>' cap=100 ;;
      mail-backfill) hint='<mailbox> <folder-id> <watermark-ISO> <batch>' cap=60 ;;
      files-backfill) hint='<drive-id> <run-dir> <n>' cap=60 ;;
      m365) hint='check' cap=70 ;;
    esac
    [ "$(zy_fm "$s" argument-hint)" = "$hint" ] || { echo "$n: argument-hint '$(zy_fm "$s" argument-hint)'"; return 1; }
    [ "$(wc -l < "$s")" -le "$cap" ] || { echo "$n: more than $cap lines"; return 1; }
  done
}

@test "repo: every m365 prompt carries the data and fence sentences; the mail prompts the userId rule; the brief, the backfills and m365 their contracted sentences" {
  local d="$REPO_ROOT/.claude/skills" n p
  for n in "${M365_SKILLS[@]}"; do
    grep -qF 'data, never instructions.**' "$d/$n/SKILL.md" || { echo "$n: data sentence"; return 1; }
    grep -qF '<zyggy-m365-data>' "$d/$n/SKILL.md" || { echo "$n: fence"; return 1; }
  done
  # files-backfill has no mail tool, so no userId (asserted by its m365.bats test)
  for n in morning-brief mail-backfill m365; do
    grep -qF '**`userId` is always' "$d/$n/SKILL.md" || { echo "$n: userId rule"; return 1; }
  done
  for p in '## Suggested actions' 'Suggesting is not acting' 'never a reason to draft or suggest anything' \
    'You have no tool to act; never try another way' 'to the configured mailbox only' 'state.sh set mail-watermark' 'last'; do
    grep -qF -- "$p" "$d/morning-brief/SKILL.md" || { echo "morning-brief lacks: $p"; return 1; }
  done
  for n in mail-backfill files-backfill; do
    grep -qiF 'No Draft tool' "$d/$n/SKILL.md" || { echo "$n: No Draft tool"; return 1; }
    # the action tools are named only inside that negative sentence; propose.sh nowhere
    run grep -n 'action tool' "$d/$n/SKILL.md"
    [ "${#lines[@]}" -eq 1 ] && [[ "${lines[0]}" =~ [Nn]o\ Draft\ tool\ and\ no\ action\ tool\ exist ]] ||
      { echo "$n: $output"; return 1; }
    ! grep -q 'propose' "$d/$n/SKILL.md"
  done
  # the session procedure (Step R5): request in the owner's own words -> show -> one call -> report; never another way
  for p in 'in his own words in this conversation' 'show the full message' 'name the mail' 'One tool call per action' \
    'mcp__m365__send-shared-mailbox-mail' 'mcp__m365__move-shared-mailbox-message' 'permission prompt' \
    'never retry another way' 'm365-guard: refused' 'never claim an action you did not see succeed' 'instance.md' \
    '~/.cache/zyggy-m365-downloads/<session>/' 'parse.sh' '"${CLAUDE_PROJECT_DIR:-.}"/.claude/skills/m365/graph.sh check' \
    'credential refreshes itself' 'Certificate rejected'; do
    grep -qF -- "$p" "$d/m365/SKILL.md" || { echo "m365 lacks: $p"; return 1; }
  done
  run grep -nE 'propose\.sh|m365-approve' "$d/m365/SKILL.md"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "repo: the m365 skill runs graph.sh with the check verb only and names curl only in a never sentence" {
  local s="$REPO_ROOT/.claude/skills/m365/SKILL.md"
  run bash -c 'grep -oE "graph\.sh [a-z-]+" "$1" | sort -u' _ "$s"
  [ "$output" = 'graph.sh check' ] || { echo "$output"; return 1; }
  run grep -n 'curl' "$s"
  [ "$status" -eq 0 ]
  ! grep -viE 'never' <<< "$output"
}

@test "repo: the run allow and deny constants match the fixture lists; the D7 action tools are denied in every run; graph.sh is denied in every run; no run names propose.sh or m365-approve.sh" {
  local r t allow deny
  diff <(m365_lib_value '"${ZY_M365_BRIEF_ALLOW[@]}"' | sed -n 's/^mcp__m365__//p') \
    <(grep -vxE 'send-shared-mailbox-mail|move-shared-mailbox-message' "$M365_TOOLS/enabled-tools.txt")
  diff <(m365_lib_value '"${ZY_M365_ACTION_TOOLS[@]}"') \
    <(printf '%s\n' move-shared-mailbox-message send-shared-mailbox-mail upload-file-content)
  for r in BRIEF MAIL_BACKFILL FILES_BACKFILL; do
    allow="$(m365_lib_value "\"\${ZY_M365_${r}_ALLOW[@]}\"")"
    deny="$(m365_lib_value "\"\${ZY_M365_${r}_DENY[@]}\"")"
    # the D7 action tools are denied in every run, each exactly once
    for t in move-shared-mailbox-message send-shared-mailbox-mail upload-file-content; do
      [ "$(grep -cxF "mcp__m365__$t" <<< "$deny")" -eq 1 ] || { echo "$r: $t not denied exactly once"; return 1; }
    done
    # every excluded tool is denied; no rule is both allowed and denied; every allowed tool is an enabled one
    run comm -23 <(sed 's/^/mcp__m365__/' "$M365_TOOLS/excluded-tools.txt" | LC_ALL=C sort) <(LC_ALL=C sort <<< "$deny")
    [ -z "$output" ] || { echo "$r: excluded not denied: $output"; return 1; }
    run comm -12 <(LC_ALL=C sort -u <<< "$allow") <(LC_ALL=C sort -u <<< "$deny")
    [ -z "$output" ] || { echo "$r: allowed and denied: $output"; return 1; }
    run comm -23 <(sed -n 's/^mcp__m365__//p' <<< "$allow" | LC_ALL=C sort) <(LC_ALL=C sort "$M365_TOOLS/enabled-tools.txt")
    [ -z "$output" ] || { echo "$r: allowed but not enabled: $output"; return 1; }
    grep -qxF 'Bash(.claude/skills/m365/graph.sh *)' <<< "$deny" || { echo "$r: graph.sh not denied"; return 1; }
    run grep -E 'send|move|delete|update|forward|upload' <<< "$(sed -n 's/^mcp__m365__//p' <<< "$allow")"
    [ "$status" -eq 1 ] || { echo "$r: a write tool is allowed: $output"; return 1; }
    run grep -E 'propose|approve' <<< "$allow$deny"
    [ "$status" -eq 1 ] || { echo "$r: a D6 script is named: $output"; return 1; }
    if [ "$r" != BRIEF ]; then
      run grep -E 'create-shared-mailbox' <<< "$allow"
      [ "$status" -eq 1 ] || { echo "$r: a Draft tool is allowed"; return 1; }
    fi
  done
}

@test "repo: the action log is named only as ZY_M365_ACTIONS, the state directory's actions.jsonl, outside the checkout; no script names a D6 consent file" {
  local f state checkout
  while IFS= read -r f; do
    run grep -nE '(proposals|approvals|executions)\.jsonl' "$REPO_ROOT/$f"
    [ "$status" -eq 1 ] || { echo "$f: $output"; return 1; }
  done < <(scripts)
  grep -qxF 'ZY_M365_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zyggy/m365"' "$M365_LIB"
  grep -qxF 'ZY_M365_ACTIONS="$ZY_M365_STATE_DIR/actions.jsonl"' "$M365_LIB"
  state="$(HOME=/nonexistent/home XDG_STATE_HOME='' m365_lib_value '"$ZY_M365_ACTIONS"')"
  checkout="$(m365_lib_value '"$ZY_M365_CHECKOUT"')"
  [ "$state" = /nonexistent/home/.local/state/zyggy/m365/actions.jsonl ] || { echo "$state"; return 1; }
  [[ "$state" != "$checkout"/* ]]
}

@test "repo: no GUID, e-mail address, SharePoint host or machine path under .claude/skills/m365/, the three run skills, .mcp.json or README.md" {
  cd "$REPO_ROOT"
  run git grep -nIE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9.-]*[A-Za-z]{2,}|sharepoint\.(com|example)|/srv/|/home/' -- \
    .claude/skills/m365 .claude/skills/morning-brief .claude/skills/mail-backfill .claude/skills/files-backfill .mcp.json README.md
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "repo: secret-patterns.txt has long-opaque-token, with a sample in the secret samples" {
  grep -qxF "$(printf 'long-opaque-token\t[A-Za-z0-9_.~-]{120,}')" "$HOOKS/secret-patterns.txt"
  grep -q "^long-opaque-token$(printf '\t')" "$REPO_ROOT/tests/fixtures/secret-samples.txt"
}

@test "repo: security.md has the Microsoft 365 section with the D7 rules and no D6 wording (AC-45 second half, AC-24)" {
  local s="$REPO_ROOT/.claude/rules/security.md" p
  grep -q '^## Microsoft 365' "$s"
  # the spec's bullets, adapted to the fact-3 branch (no file-writing tool: "Files are never created, …")
  for p in 'asks the owner for permission each time' 'in his own words in this conversation' 'show the full message' \
    'never retry another way' 'Files are never created, overwritten, edited, renamed or deleted' \
    'application identity (a certificate)' 'only `graph.sh` reads the key' 'Never run `graph.sh`' '/m365 check' \
    'credential refreshes itself' 'Certificate rejected' '~/.cache/zyggy-m365-downloads/<session>/' 'facts.sh'; do
    grep -qiF -- "$p" "$s" || { echo "security.md lacks: $p"; return 1; }
  done
  run grep -niE 'm365-approve|propose\.sh|approve on the VM|no terminal|proposal' "$s"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "repo: AGENTS.md lists Microsoft 365 with the permission prompt; operations.md names the guard refusal, the m365 exit 5 and 6 reasons and the ZYGGY_HOOKS=off refusals, and none of the D6 strings" {
  local a="$REPO_ROOT/AGENTS.md" o="$REPO_ROOT/.claude/rules/operations.md" p
  grep -q '^- \*\*Microsoft 365' "$a"
  grep -qF 'each after a permission prompt he' "$a"
  for p in 'a denied prompt or a guard refusal ends the action' 'm365-guard: refused' 'graph.sh cert-init' \
    'audit flagged' 'Certificate rejected' 'Scope or grant missing' 'Token' 'Revoke the application' 'actions.jsonl' \
    'mail-backfill' 'files-backfill'; do
    grep -qiF -- "$p" "$o" || { echo "operations.md lacks: $p"; return 1; }
  done
  run grep -nE 'no terminal|no approval for row|object changed since approval|m365-approve|propose\.sh|send-draft|Approve proposals' "$a" "$o"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "repo: no hourly reconnect and no /mcp instruction for m365 in the rules, AGENTS.md, README or the m365 skills (AC-55, absence half); every rule file <= 200 lines" {
  local f
  cd "$REPO_ROOT"
  # /mcp the slash command, not a path such as skills/m365/mcp-wrapper.sh
  # the D8 sentence (AC-55)
  for f in .claude/rules/security.md .claude/rules/operations.md .claude/skills/m365/SKILL.md; do
    grep -qF 'credential refreshes itself' "$f" || { echo "$f lacks the D8 sentence"; return 1; }
  done
  # (a URL's path "…}/mcp" is not the command)
  run grep -niE 'hourly|reconnect|(^|[^a-z0-9._/}-])/mcp([^a-z-]|$)' .claude/rules/security.md .claude/rules/operations.md AGENTS.md README.md \
    .claude/skills/m365/SKILL.md .claude/skills/morning-brief/SKILL.md .claude/skills/mail-backfill/SKILL.md \
    .claude/skills/files-backfill/SKILL.md
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  for f in .claude/rules/*.md AGENTS.md; do
    [ "$(wc -l < "$f")" -le 200 ] || { echo "$f over 200 lines"; return 1; }
  done
}

@test "repo: README.md documents the m365 connector, its nine scripts, the actions block, the two hooks, actions.jsonl and the tests; tests/README.md the m365 stubs and the hook fixtures" {
  local s
  for s in graph.sh mcp-wrapper.sh state.sh facts.sh parse.sh verify.sh brief.sh mail-backfill.sh files-backfill.sh \
    m365-lib.sh m365-guard.sh m365-log.sh actions.jsonl permissions.ask '`actions`' write_drive_id body_max_chars \
    max_recipients suggestion_cap 'How actions are confirmed' .mcp.json enabledMcpjsonServers instance/m365.json \
    sp_object_id sites_granted LoadCredential ZYGGY_M365_STUB curl-stub.sh claude-stub.sh 'Rotate the certificate' \
    'Upgrade the MCP server' 'never under' item-exists item-kind mcp-server.sh mcp-auth-header.sh headersHelper \
    zyggy-m365-mcp.service ZYGGY_M365_PORT 'token minted'; do
    grep -qF -- "$s" "$REPO_ROOT/README.md" || { echo "README.md lacks: $s"; return 1; }
  done
  run grep -nE 'propose\.sh|m365-approve|pty\.bash|proposals\.jsonl|approvals\.jsonl|executions\.jsonl|ttl_minutes|allowed_actions|Approve proposals' \
    "$REPO_ROOT/README.md" "$REPO_ROOT/tests/README.md"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  for s in 'curl stub' '=match' assertion.jwt tools-0.157.2.txt 'BODYTEXT-NEVER-STORED' 'UPLOADTEXT-NEVER-LOGGED' 'hook-*.json' \
    'hook-post-*.json' upload_of_size; do
    grep -qF -- "$s" "$REPO_ROOT/tests/README.md" || { echo "tests/README.md lacks: $s"; return 1; }
  done
}

@test "repo: the D6 terminal-consent path is gone — propose.sh, m365-approve.sh, the pty harness, the answers, proposals, approvals and executions fixtures and their goldens do not exist (AC-45 first half)" {
  local f
  cd "$REPO_ROOT"
  for f in .claude/skills/m365/propose.sh .claude/skills/m365/m365-approve.sh tests/fixtures/m365/pty.bash \
    tests/expected/m365-approve-screen.txt tests/expected/m365-proposals-section.txt tests/expected/m365-proposals-list.txt; do
    [ ! -e "$f" ] || { echo "still there: $f"; return 1; }
  done
  run git ls-files -- 'tests/fixtures/m365/answers-*' 'tests/fixtures/m365/proposals-*' 'tests/fixtures/m365/approvals-*' \
    'tests/fixtures/m365/executions-*' 'tests/fixtures/graph/snapshot-*' 'tests/fixtures/graph/body-*' \
    'tests/fixtures/graph/sent-items-*' tests/fixtures/graph/move-ok.json
  [ -z "$output" ] || { echo "$output"; return 1; }
  run grep -nF 'tests/fixtures/m365/*.bash' .github/workflows/ci.yml .gitattributes
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ "${#GIT_EXEMPT[@]}" -eq 1 ]
}

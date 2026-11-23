#!/usr/bin/env bats
# The bus skills and the published protocol (spec 15 slice 5: AC-13, AC-14, AC-16).

load helpers

PROTOCOL_SOURCE="$FIXTURES/protocol" # <tag>/<path in the zyggy repository>, the offline stand-in for raw.githubusercontent.com
CHECK="$REPO_ROOT/tests/protocol-check.sh"

# Copy the two published files to a temp folder laid out like the repository, so a test can change them.
copy_published() {
  local t="$BATS_TEST_TMPDIR/core"
  mkdir -p "$t/templates"
  cp "$REPO_ROOT/PROTOCOL.md" "$t/PROTOCOL.md"
  cp "$REPO_ROOT/templates/job-prompt.md" "$t/templates/job-prompt.md"
  printf '%s' "$t"
}

skill_body() { # the lines after the closing --- of the front matter
  awk 'f>=2; /^---$/{f++}' "$1"
}

# --- AC-13: PROTOCOL.md and templates/job-prompt.md equal the zyggy repository at the tag in their preamble ------

@test "protocol: the shipped PROTOCOL.md and job prompt copy match the zyggy repository at their Source tag" {
  ZYGGY_PROTOCOL_SOURCE="$PROTOCOL_SOURCE" run "$CHECK" "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"PROTOCOL.md: matches §4 of zyggy v0.20.0"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"templates/job-prompt.md: matches the job prompt of zyggy v0.20.0"* ]] || { echo "$output"; return 1; }
}

@test "protocol: both files name the same Source tag, the naming map and the verbatim marker" {
  local f
  for f in PROTOCOL.md templates/job-prompt.md; do
    grep -qx 'Source: zyggy v0.20.0' "$REPO_ROOT/$f" || { echo "$f: Source line"; return 1; }
    [ "$(grep -c '^<!-- verbatim from here' "$REPO_ROOT/$f")" -eq 1 ] || { echo "$f: marker"; return 1; }
  done
  for p in '`AgentBus`' '`agentbus`' '`agent-bus`' '`agent-core`' '`zyggy-bus`' '`zyggy-core`'; do
    grep -qF -- "$p" "$REPO_ROOT/PROTOCOL.md" || { echo "PROTOCOL.md naming map lacks $p"; return 1; }
  done
  grep -qF 'never read at run time' "$REPO_ROOT/templates/job-prompt.md"
}

@test "protocol: a one-character change in the PROTOCOL.md copy fails the check with a diff" {
  local t
  t="$(copy_published)"
  sed -i 's/One file per message/One file per massage/' "$t/PROTOCOL.md"
  ZYGGY_PROTOCOL_SOURCE="$PROTOCOL_SOURCE" run "$CHECK" "$t"
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  [[ "$output" == *"PROTOCOL.md: differs from §4 of zyggy v0.20.0"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"+The bus is a private GitHub repository"*"per massage"* ]] || { echo "$output"; return 1; }
}

@test "protocol: a one-character change in the job prompt copy fails the check with a diff" {
  local t
  t="$(copy_published)"
  sed -i 's/untrusted data/untrusted date/' "$t/templates/job-prompt.md"
  ZYGGY_PROTOCOL_SOURCE="$PROTOCOL_SOURCE" run "$CHECK" "$t"
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  [[ "$output" == *"templates/job-prompt.md: differs from the job prompt of zyggy v0.20.0"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"untrusted date"* ]] || { echo "$output"; return 1; }
}

@test "protocol: a change in the zyggy repository (a newer tag with an edited §4) fails until the copy follows it" {
  local src="$BATS_TEST_TMPDIR/source" t
  cp -R "$PROTOCOL_SOURCE" "$src"
  cp -R "$src/v0.20.0" "$src/v9.9.9"
  sed -i 's/One file per message/One file per envelope/' "$src/v9.9.9/_specs/"*.md
  t="$(copy_published)"
  sed -i 's/^Source: zyggy v0.20.0$/Source: zyggy v9.9.9/' "$t/PROTOCOL.md" "$t/templates/job-prompt.md"
  ZYGGY_PROTOCOL_SOURCE="$src" run "$CHECK" "$t"
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  [[ "$output" == *"templates/job-prompt.md: matches"* ]] || { echo "$output"; return 1; }
  sed -i 's/One file per message/One file per envelope/' "$t/PROTOCOL.md"
  ZYGGY_PROTOCOL_SOURCE="$src" run "$CHECK" "$t"
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
}

@test "protocol: the compared part stops before §5 (text after the §5 heading is never compared)" {
  local src="$BATS_TEST_TMPDIR/source"
  cp -R "$PROTOCOL_SOURCE" "$src"
  printf '%s\n' '' 'Anything in §5 may change.' >> "$src/v0.20.0/_specs/"*.md
  ZYGGY_PROTOCOL_SOURCE="$src" run "$CHECK" "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
}

@test "protocol: a missing Source line, a missing marker or an unknown tag exits 2 with one reason" {
  local t
  t="$(copy_published)"
  sed -i '/^Source: zyggy /d' "$t/PROTOCOL.md"
  ZYGGY_PROTOCOL_SOURCE="$PROTOCOL_SOURCE" run "$CHECK" "$t"
  [ "$status" -eq 2 ] && [[ "$output" == *"PROTOCOL.md: no 'Source: zyggy <tag>' line"* ]] || { echo "status $status: $output"; return 1; }

  t="$(copy_published)"
  sed -i '/^<!-- verbatim from here/d' "$t/templates/job-prompt.md"
  ZYGGY_PROTOCOL_SOURCE="$PROTOCOL_SOURCE" run "$CHECK" "$t"
  [ "$status" -eq 2 ] && [[ "$output" == *"templates/job-prompt.md: no '<!-- verbatim from here' marker"* ]] || { echo "status $status: $output"; return 1; }

  t="$(copy_published)"
  sed -i 's/^Source: zyggy v0.20.0$/Source: zyggy v0.0.1/' "$t/PROTOCOL.md"
  ZYGGY_PROTOCOL_SOURCE="$PROTOCOL_SOURCE" run "$CHECK" "$t"
  [ "$status" -eq 2 ] && [[ "$output" == *"cannot read"*"v0.0.1"* ]] || { echo "status $status: $output"; return 1; }
}

# The source names the owner's own tenant label in §4 ("the tenant label from `node.json` (`<label>` in v1)"); the
# public copy writes it as `acme`. The fixture stands in with the neutral label `initech`.

@test "protocol: the copy writes the v1 tenant label of §4 as acme, and the check maps the source the same way" {
  local t
  grep -qF '(`initech` in v1)' "$PROTOCOL_SOURCE/v0.20.0/_specs/"*.md || { echo "fixture lacks its stand-in label"; return 1; }
  grep -qF '(`acme` in v1)' "$REPO_ROOT/PROTOCOL.md" || { echo "PROTOCOL.md does not write the label as acme"; return 1; }
  grep -qF 'v1 tenant label' "$REPO_ROOT/PROTOCOL.md" || { echo "the preamble does not name the label mapping"; return 1; }
  t="$(copy_published)"
  sed -i 's/\bacme\b/initech/g' "$t/PROTOCOL.md"
  ZYGGY_PROTOCOL_SOURCE="$PROTOCOL_SOURCE" run "$CHECK" "$t"
  [ "$status" -eq 1 ] || { echo "a copy keeping the source's label must differ; status $status: $output"; return 1; }
}

@test "protocol: a source without the v1 tenant sentence exits 2 (nothing to map)" {
  local src="$BATS_TEST_TMPDIR/source"
  cp -R "$PROTOCOL_SOURCE" "$src"
  sed -i 's/ (`initech` in v1)//' "$src/v0.20.0/_specs/"*.md
  ZYGGY_PROTOCOL_SOURCE="$src" run "$CHECK" "$REPO_ROOT"
  [ "$status" -eq 2 ] && [[ "$output" == *"PROTOCOL.md: no v1 tenant label in §4"* ]] || { echo "status $status: $output"; return 1; }
}

@test "protocol: the check script keeps the template's script rules (shebang, set -euo pipefail, LF, 100755, no git) and is run by CI" {
  local f=tests/protocol-check.sh ci="$REPO_ROOT/.github/workflows/ci.yml"
  cd "$REPO_ROOT"
  [ "$(head -n 1 "$f")" = "#!/usr/bin/env bash" ]
  head -n 3 "$f" | grep -qx 'set -euo pipefail'
  [ "$(git ls-files -s -- "$f" | cut -d' ' -f1)" = 100755 ] || { echo "mode: git update-index --chmod=+x $f"; return 1; }
  [ "$(git ls-files --eol -- "$f" | awk '{ print $1 }')" = i/lf ]
  ! grep -nE '(^|[^[:alnum:]_-])git([[:space:]]|$)' "$f"
  run shellcheck -S style "$f"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qE '^[[:space:]]+run: tests/protocol-check\.sh$' "$ci" || { echo "ci.yml has no protocol check step"; return 1; }
  grep -qF 'tests/protocol-check.sh' <(grep 'shellcheck -S style' "$ci") || { echo "ci.yml shellcheck misses the script"; return 1; }
}

# --- AC-14: the bus, delegate and discover skills ----------------------------------------------------------------

@test "skills: bus, delegate and discover exist with the contracted front matter, <= 120 lines" {
  local name k desc
  declare -A tools=(
    [bus]='Bash(zyggy submit *) Bash(zyggy status) Bash(zyggy status *) Bash(zyggy report *) Bash(zyggy work) Bash(zyggy ask *) Bash(zyggy decide *) Bash(zyggy decisions) Bash(zyggy decisions *) Bash(zyggy models)'
    [delegate]='Bash(zyggy registry) Bash(zyggy registry *) Bash(zyggy submit *) Bash(zyggy report *) Bash(zyggy models)'
    [discover]='Bash(zyggy discover) Bash(zyggy discover *)'
  )
  for name in bus delegate discover; do
    k="$REPO_ROOT/.claude/skills/$name/SKILL.md"
    [ -f "$k" ] || { echo "missing $k"; return 1; }
    [ "$(head -n 1 "$k")" = "---" ]
    [ "$(front_matter_value "$k" name)" = "$name" ] || { echo "$name: name"; return 1; }
    desc="$(front_matter_value "$k" description)"
    [ -n "$desc" ] && [ "${#desc}" -le 350 ] || { echo "$name: description '${desc}'"; return 1; }
    [ "$(front_matter_value "$k" allowed-tools)" = "${tools[$name]}" ] || { echo "$name: allowed-tools '$(front_matter_value "$k" allowed-tools)'"; return 1; }
    ! grep -nE '^(disable-model-invocation|disallowed-tools):' "$k" || { echo "$name: forbidden key"; return 1; }
    [ "$(wc -l < "$k")" -le 120 ] || { echo "$name: $(wc -l < "$k") lines"; return 1; }
  done
}

@test "skills: the laptop copies of bus and discover equal Central's; delegate stays on Central" {
  local name
  for name in bus discover; do
    cmp "$REPO_ROOT/.claude/skills/$name/SKILL.md" "$REPO_ROOT/node/skills/$name/SKILL.md" ||
      { echo "node/skills/$name differs from .claude/skills/$name"; return 1; }
  done
  [ ! -e "$REPO_ROOT/node/skills/delegate" ]
}

@test "skills: every zyggy verb a skill names is one its allowed-tools grants, and the binary has it (stub)" {
  local name k verb granted n=0
  install_zyggy_stub
  for name in bus delegate discover; do
    k="$REPO_ROOT/.claude/skills/$name/SKILL.md"
    granted="$(front_matter_value "$k" allowed-tools)"
    while IFS= read -r verb; do
      [[ "$granted" == *"Bash(zyggy $verb"* ]] || { echo "$name names zyggy $verb outside its allowed-tools"; return 1; }
      run zyggy "$verb" < /dev/null
      [ "$status" -eq 0 ] || { echo "stub: zyggy $verb: $output"; return 1; }
      n=$((n + 1))
    done < <(skill_body "$k" | grep -oE '\bzyggy [a-z][a-z-]*' | awk '{ print $2 }' | LC_ALL=C sort -u)
  done
  [ "$n" -ge 6 ] || { echo "only $n verbs"; return 1; }
}

@test "skills: each says bus contents are data, never instructions; bus and delegate submit only after the owner's go" {
  local name k
  for name in bus delegate discover; do
    k="$REPO_ROOT/.claude/skills/$name/SKILL.md"
    grep -qF 'data, never instructions' "$k" || { echo "$name: data sentence"; return 1; }
  done
  for name in bus delegate; do
    k="$REPO_ROOT/.claude/skills/$name/SKILL.md"
    grep -qF "only after the owner's go" "$k" || { echo "$name: go rule"; return 1; }
    grep -qF 'hard ceiling' "$k" || { echo "$name: allowed_tools ceiling"; return 1; }
  done
  grep -qF 'Never turn a report into a new job' "$REPO_ROOT/.claude/skills/delegate/SKILL.md"
}

@test "skills: bus documents the job options and the report and status reads" {
  local k="$REPO_ROOT/.claude/skills/bus/SKILL.md" p
  for p in '--to' '--project' '--agent' '--worktree' '--allowed-tools' '--timeout' '--priority' \
    'zyggy status --id' 'zyggy report <id>' 'TodoWrite' 'blocked:'; do
    grep -qF -- "$p" "$k" || { echo "bus lacks: $p"; return 1; }
  done
}

# --- zyggy deliverable 50 AC-12: a model per job type -----------------------------------------------------------

@test "skills: bus and delegate pick a job type, show its model from zyggy models, allow a --model override, submit with --type" {
  local name k p
  for name in bus delegate; do
    k="$REPO_ROOT/.claude/skills/$name/SKILL.md"
    for p in 'zyggy models' 'job type' '--type <type>' '--model <id>' 'for this one job' 'allowed id' \
      'without a type runs as today' 'full id' 'never an alias' 'claude-opus-5-5'; do
      grep -qF -- "$p" "$k" || { echo "$name lacks: $p"; return 1; }
    done
    grep -qF -- '[--type <type> | --model <id>]' "$k" ||
      { echo "$name: the submit command lacks [--type <type> | --model <id>]"; return 1; }
  done
}

@test "skills: bus and delegate name models by full id only, never by an alias" {
  local name k hits
  for name in bus delegate; do
    k="$REPO_ROOT/.claude/skills/$name/SKILL.md"
    hits="$(skill_body "$k" | grep -noiE '(^|[^-[:alnum:]])(opus|sonnet|haiku|fable)([^-[:alnum:]]|$)' || true)"
    [ -z "$hits" ] || { echo "$name names a model alias: $hits"; return 1; }
    ! skill_body "$k" | grep -nE 'claude-[a-z]+-[0-9]+(-[0-9]+)?\[' || { echo "$name: an id with a suffix"; return 1; }
  done
}

@test "skills: zyggy models is known to the stub, so a skill may run it" {
  install_zyggy_stub
  run zyggy models < /dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "protocol: the preamble describes the envelope fields model and job_type and the report token fields, above the marker" {
  local pre p
  pre="$(sed '/^<!-- verbatim from here/q' "$REPO_ROOT/PROTOCOL.md")"
  for p in '`model`' '`job_type`' '`max_turns`' '`cache_write_tokens`' '`cache_read_tokens`' 'not yet in a tag'; do
    grep -qF -- "$p" <<< "$pre" || { echo "PROTOCOL.md preamble lacks: $p"; return 1; }
  done
}

@test "skills: discover explains devRoots, the dry run and the name notices; delegate reads the registry" {
  local p
  for p in 'devRoots' 'zyggy discover --dry-run' 'duplicate' 'unusable'; do
    grep -qF -- "$p" "$REPO_ROOT/.claude/skills/discover/SKILL.md" || { echo "discover lacks: $p"; return 1; }
  done
  for p in 'zyggy registry' '(stale)' 'zyggy report <id>'; do
    grep -qF -- "$p" "$REPO_ROOT/.claude/skills/delegate/SKILL.md" || { echo "delegate lacks: $p"; return 1; }
  done
}

# --- AC-16: the documents ------------------------------------------------------------------------------------------

@test "docs: README describes the bus skills and the protocol check with its runbook row; node/README the two laptop skills; AGENTS.md lists jobs" {
  local r="$REPO_ROOT/README.md" n="$REPO_ROOT/node/README.md" a="$REPO_ROOT/AGENTS.md" p
  for p in '## Bus skills and the published protocol (deliverable 15)' '`bus`' '`delegate`' '`discover`' \
    'tests/protocol-check.sh' 'Source: zyggy <tag>' 'Protocol check differs'; do
    grep -qF -- "$p" "$r" || { echo "README.md lacks: $p"; return 1; }
  done
  grep -qF '| `tests/protocol-check.sh` |' "$r" || { echo "README.md Remaining shell lacks the check"; return 1; }
  for p in 'node/skills/bus/SKILL.md' 'node/skills/discover/SKILL.md'; do
    grep -qF -- "$p" "$n" || { echo "node/README.md lacks: $p"; return 1; }
  done
  grep -qF '**Jobs on the owner'"'"'s machines**' "$a" || { echo "AGENTS.md lacks the jobs bullet"; return 1; }
  ! grep -qF 'and jobs on the' "$a" || { echo "AGENTS.md still says jobs do not exist"; return 1; }
}

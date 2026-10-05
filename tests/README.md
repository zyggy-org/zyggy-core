# zyggy-core tests

`bats-core` tests for the template's remaining shell scripts and its wiring to the `zyggy` binary. Every test runs
against a temp copy of a fixture memory tree for tenant `acme`, user `alice` (`helpers.bash`), with the fake clock
`ZYGGY_NOW=2026-09-30T10:00:00Z` and `ZYGGY_TIMEZONE=Europe/Brussels`. No real owner, tenant or machine path appears in a test or a fixture.

## Expected files are hand-derived

Files under `expected/` are written by hand from the contracts of `_specs/27-central-identity-memory.md`
(digest section format, Stop line) **before** the script that produces them exists, and are compared byte for
byte (`cmp`). They are never produced by the code under test: pasting script output into an
expected file is forbidden. An expected file changes only in a RED step, with the diff reviewed and the
re-derivation against the contract noted.

`expected/github-inventory*.md` are hand-derived from the line grammar of
`_specs/31-central-github-read-inventory.md` and the fixture account in `fixtures/github/`. The
`github-inventory` tests run against a `gh` stub (`fixtures/github/gh-stub.sh`, installed as `gh` first on
`PATH` by `install_gh_stub`) that serves the fixture API pages, refuses every non-GET verb and unknown endpoint,
and logs each call — no network in CI. `gh` itself must not be installed where the tests run.

The `github-clone` tests (`clone.bats`) add a git spy (`fixtures/github/git-spy.sh`, installed as `git` by
`install_git_spy`). `clone.sh` runs git under `env -i`, so the spy finds its log and mode from its own path; it
records argv, cwd and the environment git was started with, asks the askpass helper both prompts and logs only
whether the password matched — never the token. The real-git tests clone bare repositories built offline by
`make_bare_repo` (`helpers.bash`) over `file://`, with a poisoned environment and `HOME` to prove the isolation.

## The `zyggy` stub (`launchers.bats`, `repo.bats`)

The template never runs the real `zyggy`: its repository is private and its behaviour (the `m365` verbs and
`zyggy memory remember`) is tested in the zyggy repository's .NET suite. Here only the wiring is proven, against
`fixtures/zyggy-stub.sh`, installed as `zyggy` first on `PATH`. The stub records its argv and its stdin beside
itself, never reads the network and exits with the code the test asks for; a test that removes it from `PATH`
proves the missing-binary path.

- `launchers.bats` runs `.claude/hooks/m365-guard.sh` and `m365-log.sh`: stdin reaches the stub unchanged with the
  argv `m365 guard` / `m365 log`, an exit 0 passes through, any other exit becomes 2 with the binary's stderr line,
  and a missing `zyggy` gives exit 2 and the one line `m365-guard: zyggy not found` (or `m365-log: …`).
- **The hook fixture** `fixtures/m365/hook-send-clean.json` (matched by `hook-*.json`) is the launchers' input: the
  PreToolUse JSON Claude Code sends for a send, its `tool_input` shaped as the pinned server's schema. The launchers
  do not read it; they only pass it through. The guard matrix and the log cases (all the former `hook-*.json`) are
  byte copies in the zyggy repository, where the .NET suite runs them through `zyggy m365 guard|log`.
- `repo.bats` runs every `zyggy` command the skills, rules and `README.md` document against the stub, and checks
  that the settings rules equal the tool data files under `.claude/skills/m365/tools/` and that `.mcp.json` names
  `zyggy m365 auth-header`.
- `expected/m365-suggestions-section.txt` is hand-derived from the brief's grammar, like every expected file; the
  morning-brief skill must carry each of its lines verbatim.

`.gitattributes` marks `expected/` and `fixtures/` as `-text`: their bytes are frozen and never normalised.

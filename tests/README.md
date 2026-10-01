# zyggy-core tests

`bats-core` tests for the hook and skill scripts. Every test runs against a temp copy of a fixture memory tree
for tenant `acme`, user `alice` (`helpers.bash`), with the fake clock `ZYGGY_NOW=2026-09-30T10:00:00Z` and
`ZYGGY_TIMEZONE=Europe/Brussels`. No real owner, tenant or machine path appears in a test or a fixture.

## Expected files are hand-derived

Files under `expected/` are written by hand from the contracts of `_specs/27-central-identity-memory.md`
(digest section format, Stop line, `remember` line) **before** the script that produces them exists, and are
compared byte for byte (`cmp`). They are never produced by the code under test: pasting script output into an
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

`.gitattributes` marks `expected/` and `fixtures/` as `-text`: their bytes are frozen and never normalised.

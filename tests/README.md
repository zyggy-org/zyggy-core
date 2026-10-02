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

## The m365 connector (`m365.bats`)

No network, no tenant, no real `claude`. Fixture mailbox `alice@acme.example` in `fixtures/m365/m365.json` (three
fixture GUIDs, the only ones in the tree).

- **The pinned tool lists** `fixtures/m365/tools-0.157.2.txt`, `enabled-tools.txt` (14), `excluded-tools.txt` (330)
  and `tools-list-0.157.2.json` were generated from the package's endpoint list, never typed; `repo.bats` proves they
  partition and that the deny list, `ENABLED_TOOLS` and the run allow/deny lists derive from them.
- **The curl stub** (`fixtures/graph/curl-stub.sh`, installed by `install_curl_stub`) is reached through `env -i`, so
  it finds its routes (`routes.tsv`), scenario file and log from its own path. It logs every request before
  deciding, with `bearer=present|absent`, `client_assertion=present|absent`, `client_secret=…` and `destinationId=…`
  markers — never a token —, saves the client assertion it received to `assertion.jwt` beside itself for the
  signature checks, and refuses `/me` (98), `DELETE` (97), an empty `destinationId` (96) and any write but
  `…/send` and `…/move` (99).
- **The key pair** is generated per test by real `openssl` (`install_m365_keypair`); no key material is committed.
- **The server stub** (`ms-365-mcp-server-stub.sh`, `install_m365_server_stub`) logs variable names, the five
  non-secret values and `token=match|mismatch|absent`, and answers `tools/list` filtered by the received regex plus
  the six auth tools, as the real server does. **The `claude` stub** (`claude-stub.sh`, `install_claude_stub`) logs
  argv, environment and whether stdin is a terminal, runs the scripted model actions (`*-actions.sh`) and prints a
  `claude-result-*.json`. **The MarkItDown stub** (`markitdown-stub.sh`) prints `parsed-<name>.txt`.
- **The approval terminal** runs under a pseudo-terminal: `run_on_pty <answers-file> <command…>`
  (`fixtures/m365/pty.bash`) wraps `script -qfec` with one answer per line (`answers-*.txt`); "no terminal" tests run
  with `< /dev/null` instead. Never run `m365-approve.sh` interactively in CI.
- **The consent fixtures** (`proposals-*.jsonl`, `approvals-*.jsonl`, `executions-p1.jsonl`) carry `@H1@`-style
  placeholders: the tests compute each hash from the row's snapshot with the library's definition (`jq -S -c`, then
  `sha256sum`) and never hand-type one.
- Every test's teardown greps outputs, temp files and stub logs for the fixture token `STUBACCESS`, a private-key
  header and the body marker `BODYTEXT-NEVER-STORED` (allowed only on the terminal capture `pty.out`).
- `expected/m365-*` (check line, approval screen, proposals list and section, facts files, receipt, journal lines)
  are hand-derived from the spec's grammar before the script existed, like every expected file.

`.gitattributes` marks `expected/` and `fixtures/` as `-text`: their bytes are frozen and never normalised.

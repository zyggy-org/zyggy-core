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

`.gitattributes` marks `expected/` and `fixtures/` as `-text`: their bytes are frozen and never normalised.

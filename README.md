# zyggy-core

Claude Code configuration for the Zyggy machines. Central's configuration lives at the root of this repository:
**the root is Central's working directory**. On Central the checkout is `/srv/agent/central`, and every Claude
Code session there (remote control or `claude -p`) is started in that directory.

## Layout

| Path | What it is |
|------|-----------|
| `AGENTS.md` | Central's identity and rules (≤ 200 lines); the only instruction file |
| `.claude/rules/memory.md`, `security.md`, `operations.md` | The detailed rules `AGENTS.md` summarises |
| `.claude/settings.json` | Hook wiring (`SessionStart` × 3, `Stop`) and `enabledPlugins` (project scope) |
| `.claude/hooks/session-start.sh` | Prints one memory digest section: `identity`, `index` or `daily` |
| `.claude/hooks/stop.sh` | Appends one `[observed]` line per turn to `daily/<date>.md` |
| `.claude/hooks/lib.sh` | Shared shell functions: configuration check, front matter, secret check, atomic append |
| `.claude/hooks/secret-patterns.txt` | Secret patterns (`name<TAB>ERE[<TAB>flags]`); data, not code |
| `.claude/skills/remember/` | The `remember` skill and `remember.sh` (owner-stated facts into `inbox/`) |
| `.claude/skills/seed-memory/` | The owner-invoked seeding interview for a fresh memory repository |
| `PROTOCOL.md` | Placeholder: the bus contract is founding-spec §4 until deliverable 15 |
| `tests/` | `bats-core` tests, fixtures (tenant `acme`, user `alice`) and hand-derived expected outputs |
| `.github/workflows/ci.yml` | bats, shellcheck, `jq`, LF check on `ubuntu-latest` |

Machine-local, never committed (`.gitignore`): `memory/` (the nested `zyggy-memory` clone),
`.claude/settings.local.json` (the principal `ZYGGY_*` and `autoMemoryDirectory`), `*.log`, `node.json`,
`.claude/zyggy.lock`.

## Rules for this repository

- No `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md`, ever: Claude Code would load it instead of
  `AGENTS.md`. A test enforces it.
- No `AGENTS.md` in any subdirectory: Central would load it when reading files there. Node-side material
  (deliverables 12/15) goes under `node/`, with instruction templates under another file name.
- Scripts take the principal from env (`ZYGGY_MEMORY_ROOT`, `ZYGGY_TENANT`, `ZYGGY_USER`, `ZYGGY_TIMEZONE`);
  no tenant, user or machine path appears in a script or a test. Scripts never run git.
- Every script starts with `#!/usr/bin/env bash` and `set -euo pipefail`, is LF-terminated and mode `100755`
  in the index. On Windows: `git update-index --chmod=+x <script>`.

## Script interface

| Script | Exit codes | Output |
|--------|-----------|--------|
| `session-start.sh identity\|index\|daily` | 0 ok, 3 configuration error, 4 unknown section | One section on stdout, capped (6,000 / 4,000 / 8,000 bytes; `ZYGGY_DIGEST_BYTES_*` override, clamped to 9,500) |
| `stop.sh` | 0 always, 3 configuration error | Nothing on stdout; one stderr line on a refusal or the daily cap |
| `remember.sh [--scope …] [--tag …] [--source …] -- "<fact>"` | 0 kept, 2 refused (secret), 3 configuration, 4 usage | `remembered: <path>` and the line |

`ZYGGY_HOOKS=off` silences all three; `ZYGGY_NOW` (tests only) replaces the clock.

## Tests

Run from the repository root in a bash with `bats`, `shellcheck` and `jq` (Ubuntu: `apt-get install bats
shellcheck jq`; the CI image is `ubuntu-latest`):

```bash
bats tests/
shellcheck -S style .claude/hooks/*.sh .claude/skills/*/*.sh tests/*.bash
jq . .claude/settings.json > /dev/null
git ls-files --eol | grep -v 'i/lf\|i/-text'      # must print nothing
```

Fixtures use tenant `acme`, user `alice`. Files under `tests/expected/` are **hand-derived** from the
contracts and never pasted from script output; see `tests/README.md`.

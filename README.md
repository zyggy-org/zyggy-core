# zyggy-core

The Zyggy template: the Claude Code configuration of a Zyggy machine — identity (`AGENTS.md`), rules, memory
hooks and skills. Nobody runs the template directly. Each owner creates an **instance** from it (see
[Create an instance](#create-an-instance)); **the root of an instance checkout is the working directory of that
instance's Claude Code sessions** (remote control or `claude -p` are started there).

## Layout

| Path | What it is |
|------|-----------|
| `AGENTS.md` | The assistant's identity and rules (≤ 200 lines); the only instruction file |
| `.claude/rules/memory.md`, `security.md`, `operations.md` | The detailed rules `AGENTS.md` summarises |
| `.claude/settings.json` | Hook wiring (`SessionStart` × 3, `Stop`), `enabledPlugins` (project scope) and `env` for the browser plugin (headless, Chromium, in-memory profile); stored as `jq --indent 2` writes it, so Claude Code's own rewrites leave the tree clean |
| `.claude/hooks/session-start.sh` | Prints one memory digest section: `identity`, `index` or `daily` |
| `.claude/hooks/stop.sh` | Appends one `[observed]` line per turn to `daily/<date>.md` |
| `.claude/hooks/lib.sh` | Shared shell functions: configuration check, front matter, secret check, atomic append |
| `.claude/hooks/secret-patterns.txt` | Secret patterns (`name<TAB>ERE[<TAB>flags]`); data, not code |
| `.claude/skills/remember/` | The `remember` skill and `remember.sh` (owner-stated facts into `inbox/`) |
| `.claude/skills/seed-memory/` | The owner-invoked seeding interview for a fresh memory repository |
| `.claude/skills/github-inventory/` | The owner-invoked `github-inventory` skill and `inventory.sh`: one `[observed]` line per repository the read-only token can see, into `inbox/` |
| `.claude/skills/github-clone/` | The `github-clone` skill, `clone.sh` and `askpass.sh`: a read-only, shallow clone of one repository of the owner's own account into the clone cache, read as data |
| `tests/fixtures/github/` | Fixture API pages, the `gh` stub (`gh-stub.sh`) and the git spy (`git-spy.sh`) — no network in CI |
| `PROTOCOL.md` | Placeholder: the bus contract is founding-spec §4 until deliverable 15 |
| `tests/` | `bats-core` tests, fixtures (tenant `acme`, user `alice`) and hand-derived expected outputs |
| `.github/workflows/ci.yml` | bats, shellcheck, `jq`, LF check on `ubuntu-latest` |

Machine-local, never committed (`.gitignore`): `memory/` (the nested memory repository),
`.claude/settings.local.json` (the principal `ZYGGY_*` and `autoMemoryDirectory`, installed from the instance's
`instance/settings.local.json`), `*.log`, `node.json`, `.claude/zyggy.lock`, `evolution/`, `.playwright-mcp/` (the browser plugin's output).

## Rules for this repository

- No tenant, user or machine path in **any** template file: the principal comes from env
  (`ZYGGY_MEMORY_ROOT`, `ZYGGY_TENANT`, `ZYGGY_USER`, `ZYGGY_TIMEZONE`), machine facts live in the instance.
  The hygiene tests in `tests/repo.bats` enforce it.
- No `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md`, ever: Claude Code would load it instead of
  `AGENTS.md`. A test enforces it.
- No `AGENTS.md` in any subdirectory: the assistant would load it when reading files there. Node-side material
  (deliverables 12/15) goes under `node/`, with instruction templates under another file name.
- Scripts never run git, except `.claude/skills/github-clone/clone.sh`, which runs it only under the clone cache
  through its isolated runner. Every script starts with `#!/usr/bin/env bash` and `set -euo pipefail`, is
  LF-terminated and mode `100755` in the index. On Windows: `git update-index --chmod=+x <script>`.

## Instance-owned paths

An instance adds files **only** under these paths; the template never ships anything there, so updating an
instance from the template never conflicts:

- `instance/**` — e.g. `instance/settings.local.json`, the committed copy of the machine's settings
- `.claude/rules/instance.md` — machine-specific facts and rules (paths, the runbook to follow); loaded like the
  other rules
- `.claude/rules/instance/**`
- `.claude/skills/instance-*/**` — instance-only skills

`instance/github-inventory-exclude.txt` (optional) lists the repositories the `github-inventory` skill leaves out
of memory: one `owner/name` per line, `#` comments and blank lines ignored, surrounding spaces trimmed, matched
case-insensitively. A malformed line makes the script exit 3. It is edited on the workstation, committed and
pulled on the machine like every instance file.

For the `github-clone` skill, `instance/settings.local.json` gives the session read access to the clone cache with
`"permissions": {"additionalDirectories": ["<home>/.cache/zyggy/repos"]}` (an absolute path; Claude Code does not
expand `~` there). Never `--add-dir` or `/add-dir` the cache: that would load a clone's own skills and settings.

Never edit a template-owned file in an instance: change it in the template and pull it. An instance declares no
hooks (hook lists merge across settings files, so an instance hook would run in addition to the template's).
An instance-only plugin goes into `instance/settings.local.json` under `enabledPlugins`; `false` there switches
off a template plugin.

## Create an instance

On your workstation, with placeholders `<template URL>`, `<instance URL>`, `<memory URL>`, `<memory root>`,
`<tenant>`, `<user>`, `<time zone>`:

1. Create an empty private repository for the instance (no README, no licence).
2. Clone the template and turn it into the instance:

   ```bash
   git clone <template URL> <instance>
   cd <instance>
   git remote rename origin upstream
   git remote add origin <instance URL>
   ```

3. Add `.claude/rules/instance.md` (which machine this is, the working directory, where its runbook is) and
   `instance/settings.local.json`:

   ```json
   {
     "env": {
       "ZYGGY_MEMORY_ROOT": "<memory root>",
       "ZYGGY_TENANT": "<tenant>",
       "ZYGGY_USER": "<user>",
       "ZYGGY_TIMEZONE": "<time zone>"
     },
     "autoMemoryDirectory": "<memory root>/<tenant>/<user>/auto"
   }
   ```

   `<memory root>` is the absolute path of `memory/` in the checkout on the machine. No secret goes in this file.
4. Commit and publish: `git add -A && git commit -m "Create instance" && git push -u origin main`.
5. Create the memory repository (a separate private repository, never inside the instance):

   ```bash
   git init <memory>
   cd <memory>
   mkdir -p <tenant>/<user>/{areas,people,topics,daily,inbox,auto}
   for d in <tenant>/<user>/*/; do touch "$d.gitkeep"; done
   printf '%s\n' '# Memory' 'Layout: <tenant>/<user>/…; written by the hooks, the seeding session and the dream pass.' > README.md
   git add -A && git commit -m "Memory layout" && git remote add origin <memory URL> && git push -u origin main
   ```

On the machine, in the instance checkout (the working directory):

```bash
git clone <memory URL> memory
install -m 600 instance/settings.local.json .claude/settings.local.json
claude plugin install playwright@claude-plugins-official --scope project
claude                      # accept workspace trust once, then run /seed-memory
```

The live `.claude/settings.local.json` stays untracked: Claude Code writes permission approvals into it.

## Update an instance from the template

On the workstation, in the instance checkout:

```bash
git pull upstream main      # merge the template; never conflicts when the instance kept to its own paths
bats tests/                 # the template tests run in every instance
git push origin main
```

On the machine: `git pull --ff-only`. The machine never merges, commits or holds an `upstream` remote. When
`instance/settings.local.json` changed, re-run the `install -m 600` line above. `/clear` in a running session
reloads the instructions and re-runs the digest.

## Script interface

| Script | Exit codes | Output |
|--------|-----------|--------|
| `session-start.sh identity\|index\|daily` | 0 ok, 3 configuration error, 4 unknown section | One section on stdout, capped (6,000 / 6,000 / 8,000 bytes; `ZYGGY_DIGEST_BYTES_*` override, clamped to 9,500) |
| `stop.sh` | 0 always, 3 configuration error | Nothing on stdout; one stderr line on a refusal or the daily cap |
| `remember.sh [--scope …] [--tag …] [--source …] -- "<fact>"` | 0 kept, 2 refused (secret), 3 configuration, 4 usage | `remembered: <path>` and the line |
| `inventory.sh [--max <1..500>] \| inventory.sh --check` | 0 done, 3 configuration (env, memory dir, `gh`/`jq`, token file, exclusion file), 4 usage, 5 refused (unattended, `ZYGGY_HOOKS=off`), 6 GitHub request failed | `inventory: <path>` + counts line + the lines in a `<zyggy-github-inventory>` fence; `--check`: one summary line, writes nothing |
| `clone.sh <owner>/<name> \| clone.sh --clean` | 0 cloned or cleaned, 3 configuration, 4 usage, 5 refused by policy (unattended, not the owner's account, organisation, fork of a private repository, size, rate), 6 GitHub or git failed | `cloned: <path>`, a summary line (commit, date, branch, files, size), a data sentence; `--clean`: `cleaned: <root> (<n> clones removed)` |
| `askpass.sh` | 0 answered, 1 refused | Called by git only: answers git's two `github.com` prompts |

`ZYGGY_HOOKS=off` silences the three hook scripts and makes `inventory.sh` and `clone.sh` refuse (exit 5);
`ZYGGY_NOW` (tests only) replaces the clock.

`clone.sh` clones into `${XDG_CACHE_HOME:-$HOME/.cache}/zyggy/repos/<owner>/<name>` (mode 0700, outside the
checkout and `memory/`): 500 MiB per repository, 2 GiB for the cache, clones older than 7 days removed, at most 5
clones per hour, 600 s per clone. git runs under `env -i` with an allowlisted environment and gets the token only
from `askpass.sh`. Test-only overrides, accepted only while `ZYGGY_GITHUB_CLONE_BASE` (an absolute local directory
of bare repositories) is set: `ZYGGY_CLONE_TIMEOUT`, `ZYGGY_CLONE_MAX_MIB`, `ZYGGY_CLONE_CACHE_MIB`.

`inventory.sh` reads the GitHub read token from `${XDG_CONFIG_HOME:-$HOME/.config}/zyggy/github-read-token`
(mode 0600, owned by the running user, one line) and hands it to `gh` only as `GH_TOKEN` in each child's
environment. `ZYGGY_GITHUB_TOKEN_FILE` and `ZYGGY_GITHUB_EXCLUDE_FILE` override the token and exclusion file
paths for tests and hand runs only, never in `settings.local.json`. `gh` must be installed from GitHub's apt
repository and never logged in (`gh auth login` is never run).

## Tests

Run from the repository root in a bash with `bats`, `shellcheck` and `jq` (Ubuntu: `apt-get install bats
shellcheck jq`; the CI image is `ubuntu-latest`):

```bash
bats tests/
shellcheck -S style .claude/hooks/*.sh .claude/skills/*/*.sh tests/*.bash tests/fixtures/github/gh-stub.sh tests/fixtures/github/git-spy.sh
jq . .claude/settings.json > /dev/null
git ls-files --eol | grep -v 'i/lf\|i/-text\|i/none'      # must print nothing (LF, binary or empty only)
```

`ZYGGY_HYGIENE_FORBIDDEN` — a comma-separated list of words (the owner's tenant and user names, for example)
that must not occur in any template-owned file, matched case-insensitively. Set it as a GitHub Actions
repository variable; CI passes it to `bats`. Unset or empty → that one test is reported as skipped.

Fixtures use tenant `acme`, user `alice`. Files under `tests/expected/` are **hand-derived** from the
contracts and never pasted from script output; see `tests/README.md`. The `github-inventory` tests run against a
`gh` stub (`tests/fixtures/github/gh-stub.sh`) and fixture API pages — no network in CI. The `github-clone` tests
use the same stub, a git spy (`tests/fixtures/github/git-spy.sh`) that records argv, environment and askpass
answers, and real git against local bare repositories built by `make_bare_repo`.

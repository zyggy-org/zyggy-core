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
| `.claude/settings.json` | Hook wiring (`SessionStart` × 3, `Stop`), `enabledPlugins` (project scope) and `env` for the browser plugin (headless, Chromium, in-memory profile), `permissions.deny` (the credential, clone-cache and state-directory path rules, `Bash(.claude/skills/m365/graph.sh *)`, `Bash(.claude/skills/m365/m365-approve.sh *)` and every `m365` tool outside the allowlist); stored as `jq --indent 2` writes it, so Claude Code's own rewrites leave the tree clean |
| `.claude/hooks/session-start.sh` | Prints one memory digest section: `identity`, `index` or `daily` |
| `.claude/hooks/stop.sh` | Appends one `[observed]` line per turn to `daily/<date>.md` |
| `.claude/hooks/lib.sh` | Shared shell functions: configuration check, front matter, secret check, atomic append |
| `.claude/hooks/secret-patterns.txt` | Secret patterns (`name<TAB>ERE[<TAB>flags]`); data, not code |
| `.claude/skills/remember/` | The `remember` skill and `remember.sh` (owner-stated facts into `inbox/`) |
| `.claude/skills/seed-memory/` | The owner-invoked seeding interview for a fresh memory repository |
| `.claude/skills/github-inventory/` | The owner-invoked `github-inventory` skill and `inventory.sh`: one `[observed]` line per repository the read-only token can see, into `inbox/` |
| `.claude/skills/github-clone/` | The `github-clone` skill, `clone.sh` and `askpass.sh`: a read-only, shallow clone of one repository of the owner's own account into the clone cache, read as data |
| `.mcp.json` | The one project MCP server, `m365`, started by `bash` through `.claude/skills/m365/mcp-wrapper.sh` (no `env`, no id); an instance enables it with `enabledMcpjsonServers` |
| `.claude/skills/m365/` | The `m365` connector (the owner's company Microsoft 365): the owner-invoked `m365` skill (`/m365 check` and the conversation rules), the shared `m365-lib.sh` (paths, configuration, the snapshot hash, the run allow/deny lists) and the eleven scripts of [m365 scripts](#m365-scripts) |
| `.claude/skills/morning-brief/`, `mail-backfill/`, `files-backfill/` | The prompts of the three `claude -p` runs started by `brief.sh`, `mail-backfill.sh`, `files-backfill.sh` (`disable-model-invocation: true`) |
| `tests/fixtures/github/` | Fixture API pages, the `gh` stub (`gh-stub.sh`) and the git spy (`git-spy.sh`) — no network in CI |
| `tests/fixtures/graph/` | The `curl` stub (`curl-stub.sh`, `routes.tsv`) and the Graph and identity-platform fixture responses |
| `tests/fixtures/m365/` | The pinned server's tool lists (`tools-0.157.2.txt`, `enabled-tools.txt`, `excluded-tools.txt`, `tools-list-0.157.2.json`), the fixture `m365.json`, the server, `claude` and MarkItDown stubs (`ms-365-mcp-server-stub.sh`, `claude-stub.sh`, `markitdown-stub.sh`), the pseudo-terminal helper `pty.bash`, the consent fixtures and the run results |
| `PROTOCOL.md` | Placeholder: the bus contract is founding-spec §4 until deliverable 15 |
| `tests/` | `bats-core` tests, fixtures (tenant `acme`, user `alice`) and hand-derived expected outputs |
| `.github/workflows/ci.yml` | bats, shellcheck, `jq`, LF check on `ubuntu-latest` |

Machine-local, never committed (`.gitignore`): `memory/` (the nested memory repository),
`.claude/settings.local.json` (the principal `ZYGGY_*` and `autoMemoryDirectory`, installed from the instance's
`instance/settings.local.json`), `*.log`, `node.json`, `.claude/zyggy.lock`, `evolution/`, `.playwright-mcp/` (the browser plugin's output).
Outside the checkout, never in git: the `m365` key pair under `~/.config/zyggy/` and the `m365` state directory
`${XDG_STATE_HOME:-~/.local/state}/zyggy/m365/` (watermarks, receipts, checkpoints, `brief.jsonl` and the three
consent files `proposals.jsonl`, `approvals.jsonl`, `executions.jsonl`).

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
- `m365`: no tenant id, client id, object id, mailbox, site, drive id or machine path in a template file; those live
  in `instance/m365.json` and `.claude/rules/instance.md`. The three consent files live under the state directory,
  never under the checkout (a test enforces it). Only `graph.sh` can send, move or delete, only against an approved
  row, only on a terminal, never in an unattended run: its `send-draft|move|delete --approved <hash>` verbs are the
  only write verbs anywhere, and `delete` moves to Deleted Items (no hard delete exists). These checks bind the
  model's runs and the timer unit; they are not a boundary against another process of the same Unix user (an
  interactive session's shell could fake a terminal and write an approval row) — that residual risk is accepted by
  the owner and bounded by the template's deny rules and `security.md`, not by the scripts.
- The `m365` tool lists are generated from the pinned server, never typed: `ENABLED_TOOLS`, the `m365-lib.sh` arrays
  and the 330 `mcp__m365__*` deny rules of `.claude/settings.json` derive from `tests/fixtures/m365/*-tools.txt`, and
  `tests/repo.bats` proves they agree (the six auth tools and `graph-batch` stay denied).

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

For the `m365` connector the instance adds:

- `instance/m365.json` — `tenant_id`, `client_id`, `sp_object_id` (the app registration's service principal),
  `mailbox` (a UPN), `timezone`, `language`, `cert` (`subject`, `days`, `expires`), `drives` (`onedrive_site`,
  `sites`, `sites_granted` — the site ids with a `read` grant, non-empty when `sites` is —, `exclude_drives`,
  `exclude_paths`), `consent` (`ttl_minutes` 1..1440, how long an approval stays valid, default 60;
  `allowed_actions` ⊆ `send-draft`, `move`, `delete`, which may narrow the three actions, never widen them), and
  the caps `brief` (incl. `proposal_cap`), `mail_backfill`, `files_backfill`. Every script validates it and exits 3
  on a bad key before any request; `graph.sh cert-init` needs only the base keys.
- `instance/systemd/zyggy-morning-brief.{service,timer}` — the timer unit running `brief.sh` with
  `Environment=ZYGGY_HOOKS=off`, `Type=oneshot` (no terminal) and `LoadCredential=m365-app-key:<key path>`, so the
  run reads a read-only copy of the key and can propose but never execute.
- In `instance/settings.local.json`: `"enabledMcpjsonServers": ["m365"]`, so the project server starts without a
  prompt.
- In `.claude/rules/instance.md` "## Microsoft 365": the tenant, mailbox, folder and drive ids the `m365` skill
  reads, the granted sites, the certificate expiry and how to approve proposals.

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

### m365 scripts

All under `.claude/skills/m365/`, sourcing `m365-lib.sh`. Exit codes: 0 ok, 3 configuration (env, `m365.json`, a
tool, the key or the server installation), 4 usage or invalid input, 5 refused, 6 identity, Graph or model-run
failure; stderr lines are prefixed with the script's name.

| Script | Who runs it | Contract |
|--------|-------------|----------|
| `graph.sh cert-init [--rotate\|--commit] \| token [--key new] [--alg PS256\|RS256] \| check [--counts] [--other-mailbox <upn>] [--drive <id>] \| mail-folders \| drives \| drafts-since <ISO> \| message-sender <id> \| snapshot draft\|message <id> \| get draft\|message <id> \| sent-since <ISO> \| send-draft\|move\|delete --approved <hash>` | The other scripts; the owner (`cert-init`, `check`); `/m365 check` | The only reader of the key: `cert-init` generates the key (0600) and the self-signed certificate (0644) and prints the thumbprints; `token` mints a one-hour app-only token with a PS256 client assertion (stdout only); reads on `/users/<mailbox>`, `/drives`, `/sites` only, never `/me`; `snapshot` prints the canonical JSON and `hash: <sha256>`; `get` prints a body for the approval terminal only. The write verbs refuse, in this order: `ZYGGY_HOOKS=off` (`refused: unattended run`), no terminal (`refused: no terminal`), no approval (`no approval for row <id>`), an approval used or older than `ttl_minutes`, an action outside `allowed_actions`, a changed object (`object changed since approval (hash mismatch) — re-run m365-approve.sh`); then POST `…/send` or `…/move` (`deleteditems` for `delete`) and one `executions.jsonl` row. `cert-init` refuses `ZYGGY_HOOKS=off` too. |
| `mcp-wrapper.sh [--probe]` | Claude Code (`.mcp.json`); the owner (`--probe`) | Mints a token with `graph.sh token` and `exec`s the pinned `ms-365-mcp-server` (under `~/.local`, never `npx`) under `env -i` with eleven variables and `ENABLED_TOOLS` = the 14-tool allowlist; `--probe` lists the loaded tools and the six auth tools the server registers outside the filter (denied by settings) |
| `state.sh get\|set\|reset <key> [<arg>] [<value>] \| list proposals [--status <s>] \| mark <id> <status>` | The runs; `m365-approve.sh`, `graph.sh` (`list`, `mark`) | Watermarks (`mail-watermark`, `backfill-watermark <folder>`, `drive-token <drive>`, `files-backfill-watermark <drive>` — ISO timestamps), `replied <date>`; the proposal listing (`<id> <status> <action> <subject> <origin> #<hash8>`, no body) and status marks |
| `propose.sh send-draft <draft-id> \| move <message-id> <folder> \| delete <message-id> --reason <text>` | The model (brief run and conversation) | One `pending` row in `proposals.jsonl` whose snapshot comes from Graph, never from arguments; no recipient, body or subject parameter; `recipient_outside_policy` flag; prints `proposed: <id> <action> "<subject>" — review with m365-approve.sh on the VM`; exit 4 for an action outside `allowed_actions`; allowed unattended |
| `m365-approve.sh [--list]` | The owner only, on a terminal of the VM | See [Approve proposals](#approve-proposals); refuses `ZYGGY_HOOKS=off` and a missing terminal (exit 5) |
| `facts.sh --kind brief\|mail-backfill\|files-backfill --source <tag> [--max <n>]` | The runs | Appends validated `[observed]` fact lines to `inbox/m365-<kind>-<date>.md`; refusals counted, never echoed; exit 5 at `--max` |
| `parse.sh <file>` | The runs; the conversation (`/tmp/zyggy-m365-<session>/`) | MarkItDown on one file inside `ZYGGY_M365_RUN_DIR` under `timeout`/`ulimit -v`; bounded text on stdout, secret-shaped lines withheld; the file deleted in every case |
| `verify.sh <date> <window-start>` | `brief.sh` | Audits the Drafts of the window and reconciles Sent Items with `executions.jsonl`; receipt `brief-<date>.json`; `audit ok` (0) or `audit FLAGGED: …` (5) |
| `brief.sh` | The timer unit; the owner by hand | One `claude -p "/morning-brief …"` run (no terminal, `ZYGGY_HOOKS=off`, `propose.sh` allowed, `graph.sh`/`m365-approve.sh` denied), `verify.sh`, one memory line and the journal line `brief <date>: mail <n>, files <m>, replies <r>, proposals <p>, facts <f>, turns <t>, cost <usd>, audit ok\|FLAGGED, exit <code>`; `already created` on a rerun |
| `mail-backfill.sh [--folder <name>] [--reset]` | The owner, in tmux | Batched `claude -p "/mail-backfill …"` runs (mail read tools, `facts.sh`, `state.sh`; no Draft tool, no `propose.sh`); checkpoint, resume after an interrupt, caps (exit 5); refuses `ZYGGY_HOOKS=off` |
| `files-backfill.sh [--drive <name>] [--reset]` | The owner, in tmux | The same for the drives (drive read tools, `download-bytes-to-file`, `parse.sh`; a fresh run directory per batch); a 403 drive is skipped as `forbidden` |

Configuration: `instance/m365.json` (`ZYGGY_M365_CONFIG` overrides the path); the key and certificate under
`${XDG_CONFIG_HOME:-~/.config}/zyggy/m365-app.{key,cer}` (`ZYGGY_M365_KEY_FILE`/`ZYGGY_M365_CER_FILE` override, for
hand runs and tests); in the unit the key comes from `$CREDENTIALS_DIRECTORY/m365-app-key` (`LoadCredential=`).
`mail-backfill.sh`, `files-backfill.sh` and `m365-approve.sh` need no environment line: each of `ZYGGY_MEMORY_ROOT`,
`ZYGGY_TENANT`, `ZYGGY_USER`, `ZYGGY_TIMEZONE` that is unset is read from the `env` of `.claude/settings.local.json`
(`ZYGGY_M365_SETTINGS` overrides the path, for tests); a set variable wins and no other key is read.
`ZYGGY_M365_ORIGIN` is exported by `brief.sh` to its child so `propose.sh` records `brief <date>` (else
`session`); `ZYGGY_M365_RUN_DIR` is the run directory `parse.sh` accepts. Test-only, honoured only with
`ZYGGY_M365_STUB=1` (which also refuses a real `curl` first on `PATH`): `ZYGGY_RETRY_SCALE`, `ZYGGY_PARSE_TIMEOUT`.

### Approve proposals

Nothing leaves the mailbox until the owner approves it here. On the VM, over SSH, as the agent user in the
working directory with the `ZYGGY_*` environment loaded: `.claude/skills/m365/m365-approve.sh` (`--list` only
prints the pending rows). For each pending row, oldest first, the terminal shows the action, origin, reason and
short hash, then the object as Graph holds it now — subject, recipients, sender, received, folder and the body
(shown on the terminal only, never stored) — with `CHANGED since proposal` when it differs from the proposal and
`RECIPIENT OUTSIDE POLICY` when a recipient is outside the expected ones. Answer `y` (approve: an approval row
bound to the current hash, then `graph.sh` executes it at once and prints `executed: …` or its refusal), `n`
(refuse), `s` (skip, stays pending) or `q` (quit). Approvals are single-use and expire after `consent.ttl_minutes`;
pending rows older than 7 days expire. The record is the three consent files in the state directory.

### Rotate the certificate

`graph.sh check` warns 30 days before `cert.expires` and every script exits 3 after it. On the VM:
`graph.sh cert-init --rotate` writes a `.new` key pair; upload the new `.cer` to the app registration;
`graph.sh token --key new` must succeed; `graph.sh cert-init --commit` swaps the pair; delete the old certificate
in the app registration; update `cert.expires` in `instance/m365.json`.

### Upgrade the MCP server

The server is pinned (`@softeria/ms-365-mcp-server@0.157.2`, installed under `~/.local`). A new version means:
regenerate `tests/fixtures/m365/tools-<version>.txt`, `enabled-tools.txt`, `excluded-tools.txt` and the fixture
`tools/list` from the package's endpoint list, review every new tool (a new write or generic tool stays excluded; the
six auth tools and `graph-batch` stay denied), regenerate the deny rules of `.claude/settings.json` and the
`m365-lib.sh` lists, run the tests, then install the new pin on the machine and check `mcp-wrapper.sh --probe`.

## Tests

Run from the repository root in a bash with `bats`, `shellcheck` and `jq` (Ubuntu: `apt-get install bats
shellcheck jq`; the CI image is `ubuntu-latest`):

```bash
bats tests/
shellcheck -S style .claude/hooks/*.sh .claude/skills/*/*.sh tests/*.bash tests/fixtures/github/gh-stub.sh tests/fixtures/github/git-spy.sh tests/fixtures/graph/curl-stub.sh tests/fixtures/m365/*.sh tests/fixtures/m365/*.bash
jq . .claude/settings.json > /dev/null && jq . .mcp.json > /dev/null
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

The `m365` tests (`m365.bats`) never touch the network or a real tenant: `curl` is a stub
(`tests/fixtures/graph/curl-stub.sh`, routes and scenarios, it refuses `/me`, `DELETE` and every write verb but
`send`/`move`), the MCP server, `claude` and MarkItDown are stubs (`ms-365-mcp-server-stub.sh`, `claude-stub.sh`,
`markitdown-stub.sh`), `openssl` runs for real offline with a throw-away key pair per test, and the approval terminal
runs under a pseudo-terminal (`script` from util-linux, helper `run_on_pty` in `tests/fixtures/m365/pty.bash`). No
key material is committed; no test sees a real `claude`.

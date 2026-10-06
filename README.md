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
| `.claude/settings.json` | Hook wiring (`SessionStart` × 3, `Stop`), `enabledPlugins` (project scope) and `env` for the browser plugin (headless, Chromium, in-memory profile), `permissions.allow` (`Bash(zyggy dream request)` and `Bash(zyggy dream status:*)` for the `dream` skill, `Bash(zyggy memory remember *)` for the `remember` skill), `permissions.ask` (the three `m365` action tools of `tools/actions.txt`: each call is a permission prompt), `permissions.deny` (the credential, clone-cache and state-directory path rules, the seven `Bash(zyggy m365 <verb>*)` rules for `auth-header`, `token-test`, `cert-init`, `mcp-server`, `brief`, `mail-backfill`, `files-backfill`, and one `mcp__m365__<name>` rule per line of `tools/excluded.txt`), the `PreToolUse`/`PostToolUse` wiring of the `m365-guard.sh` and `m365-log.sh` launchers (no `PermissionRequest` hook); stored as `jq --indent 2` writes it, so Claude Code's own rewrites leave the tree clean |
| `.claude/hooks/session-start.sh` | A thin launcher: `exec zyggy memory digest <identity|index|daily>` (the `zyggy` binary, deliverable 28); one stderr line and exit 0 when `zyggy` is missing |
| `.claude/hooks/stop.sh` | Appends one `[observed]` line per turn to `daily/<date>.md` |
| `.claude/hooks/m365-guard.sh` | A thin launcher (≤ 10 lines) for `PreToolUse` on the `m365` action tools: runs `zyggy m365 guard` with the hook JSON on stdin, which refuses every call outside `instance/m365.json` `actions` before the permission prompt (deny-only); a missing `zyggy` (`m365-guard: zyggy not found`) or any non-zero exit becomes exit 2, so the call is blocked |
| `.claude/hooks/m365-log.sh` | The same launcher for `PostToolUse`: `zyggy m365 log` writes one body-free row per call in `actions.jsonl`; a failure becomes exit 2 (Claude is told the row is missing) |
| `.claude/hooks/lib.sh` | Shared shell functions of `stop.sh` and the GitHub scripts: configuration check, front matter, secret check, atomic append |
| `.claude/hooks/secret-patterns.txt` | Secret patterns (`name<TAB>ERE[<TAB>flags]`); data, not code |
| `.claude/skills/remember/` | The `remember` skill: owner-stated facts into `inbox/` through `zyggy memory remember` |
| `.claude/skills/dream/` | The model-invocable `dream` skill: asks for a dream run (`zyggy dream request`) and quotes `zyggy dream status`; the run is the instance's `zyggy-dream` service, never the session |
| `.claude/skills/seed-memory/` | The owner-invoked seeding interview for a fresh memory repository |
| `.claude/skills/github-inventory/` | The owner-invoked `github-inventory` skill and `inventory.sh`: one `[observed]` line per repository the read-only token can see, into `inbox/` |
| `.claude/skills/github-clone/` | The `github-clone` skill, `clone.sh` and `askpass.sh`: a read-only, shallow clone of one repository of the owner's own account into the clone cache, read as data |
| `.mcp.json` | The one project MCP server, `m365`: `type: http` on `http://127.0.0.1:${ZYGGY_M365_PORT:-47365}/mcp` with `headersHelper` = `zyggy m365 auth-header` (a fresh token per connection; no `headers`, `env` or id; a missing binary fails the connection, so it fails closed without a launcher); the server itself runs as the instance's `zyggy-m365-mcp.service` (`zyggy m365 mcp-server`); an instance enables it with `enabledMcpjsonServers` |
| `.claude/skills/m365/` | The `m365` connector (the owner's company Microsoft 365): the owner-invoked `m365` skill (`/m365 check` and the conversation rules) and the tool data files `tools/` (see [Tool data files](#tool-data-files)); every program it needs is a [`zyggy` verb](#zyggy-verbs) |
| `.claude/skills/morning-brief/`, `mail-backfill/`, `files-backfill/` | The prompts of the three `claude -p` runs started by `zyggy m365 brief`, `zyggy m365 mail-backfill`, `zyggy m365 files-backfill` (`disable-model-invocation: true`) |
| `.claude/zyggy-min-version` | One line: the oldest `zyggy` version this template works with (`0.2.0`); an instance's pin must be at least this (`repo.bats` fails an instance whose `instance/zyggy.json` is older) |
| `tests/fixtures/github/` | Fixture API pages, the `gh` stub (`gh-stub.sh`) and the git spy (`git-spy.sh`) — no network in CI |
| `tests/fixtures/zyggy-stub.sh` | The `zyggy` stub put first on `PATH` by the launcher and wiring tests: records argv and stdin, exits as told |
| `tests/fixtures/m365/` | The pinned tool lists (`tools-0.157.2.txt`, `enabled-tools.txt`, `excluded-tools.txt`, `tools-list-0.157.2.json`) the data files are checked against, and the hook input `hook-send-clean.json` fed to the two launchers |
| `PROTOCOL.md` | Placeholder: the bus contract is founding-spec §4 until deliverable 15 |
| `tests/` | `bats-core` tests, fixtures (tenant `acme`, user `alice`) and hand-derived expected outputs |
| `.github/workflows/ci.yml` | bats, shellcheck, `jq`, LF check on `ubuntu-latest` |

Machine-local, never committed (`.gitignore`): `memory/` (the nested memory repository),
`.claude/settings.local.json` (the principal `ZYGGY_*` and `autoMemoryDirectory`, installed from the instance's
`instance/settings.local.json`), `*.log`, `node.json`, `.claude/zyggy.lock`, `evolution/`, `.playwright-mcp/` (the browser plugin's output).
Outside the checkout, never in git: the `m365` key pair under `~/.config/zyggy/` and the `m365` state directory
`${XDG_STATE_HOME:-~/.local/state}/zyggy/m365/` (watermarks, receipts, checkpoints, `brief.jsonl` and the action log
`actions.jsonl`).

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
  in `instance/m365.json` and `.claude/rules/instance.md`. The `zyggy` binary only reads Graph. The model acts only
  through the `m365` action tools, each behind a `permissions.ask` rule (the owner's answer to the prompt is the
  consent; no mode or allow rule skips it), `zyggy m365 guard` in front of the prompt (deny-only policy) and
  `zyggy m365 log` behind it, both through their fail-closed launchers; every unattended run denies the action
  tools in `--disallowedTools`. A soft delete is a move to Deleted
  Items; no hard-delete tool is loaded. The key holder (not the model) can still act through Graph directly: that is
  bounded by the key's file mode, the unit's `InaccessiblePaths=` and revocation, and detected by reconciling the
  Exchange/SharePoint audit log with `actions.jsonl`. The action log lives under the state directory, never under
  the checkout (a test enforces it).
- The `m365` tool lists are generated from the pinned server, never typed: the server's `ENABLED_TOOLS`, the run
  allow/deny lists and the 328 `mcp__m365__*` deny rules of `.claude/settings.json` all derive from the data files
  `.claude/skills/m365/tools/*.txt`, which the binary reads at run time, and `tests/repo.bats` proves the settings
  agree with them (the six auth tools and `graph-batch` stay denied).
- No complex shell: a new program is a `zyggy` verb. A script stays only with a reason recorded in
  [Remaining shell](#remaining-shell).

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
  `exclude_paths`), `actions` (`enabled` ⊆ `send`, `upload`, `move` — narrowing only; `send.body_max_chars`,
  `send.max_recipients`; `upload.max_bytes`, `upload.extensions`; `files.write_drive_id`, the OneDrive drive id, required
  while `upload` is enabled — `upload` stays unreachable with the pinned server, see [Upgrade the MCP
  server](#upgrade-the-mcp-server)), and the caps `brief` (incl. `suggestion_cap`), `mail_backfill`,
  `files_backfill`. Every verb and the guard validate it and exit 3 (the guard 2) on a bad key before any
  request; a leftover `consent` block is refused; `zyggy m365 cert-init` needs only the base keys.
- `instance/zyggy.json` — the `zyggy` binary pin (version and hash), at least `.claude/zyggy-min-version`. The model
  runs (`zyggy m365 brief` and the backfills) check it first and exit 3 `configuration error: version_mismatch: …`
  before any request when the running binary is not the pinned one.
- `instance/systemd/zyggy-m365-mcp.service` (`ExecStart` runs `zyggy m365 mcp-server`) and
  `instance/systemd/zyggy-morning-brief.{service,timer}` — the timer unit running `zyggy m365 brief` with
  `Environment=ZYGGY_HOOKS=off`, `Type=oneshot` (no terminal) and `LoadCredential=m365-app-key:<key path>`, so the
  run reads a read-only copy of the key; it suggests actions in the brief and never acts. Both set
  `ZYGGY_INSTANCE_DIR`.
- In `instance/settings.local.json`: `"enabledMcpjsonServers": ["m365"]`, so the project server starts without a
  prompt, and `ZYGGY_INSTANCE_DIR` in `env`, so the verbs find `instance/`.
- In `.claude/rules/instance.md` "## Microsoft 365": the tenant, mailbox, folder and drive ids the `m365` skill
  reads, the granted sites, the certificate expiry and how actions are confirmed.

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
| `session-start.sh identity\|index\|daily` | `zyggy memory digest`'s: 0 ok, 3 configuration error, 4 unknown section; 0 with one stderr line when `zyggy` is missing | One section on stdout, capped (6,000 / 6,000 / 8,000 bytes; `ZYGGY_DIGEST_BYTES_*` override, clamped to 9,500); `index` lists one line per category of `private/` and `business/`, then files by `updated` |
| `stop.sh` | 0 always, 3 configuration error | Nothing on stdout; one stderr line on a refusal or the daily cap |
| `m365-guard.sh` (stdin: the hook JSON) | 0 when `zyggy m365 guard` exits 0 (nothing, or its deny JSON, on stdout); 2 for any other exit and when `zyggy` is not on `PATH` | Passes stdin and stdout through; on failure the binary's stderr line, or `m365-guard: zyggy not found` |
| `m365-log.sh` (stdin: the hook JSON) | 0 when `zyggy m365 log` exits 0; 2 for any other exit and when `zyggy` is not on `PATH` | Nothing on stdout; on failure one stderr line |
| `inventory.sh [--max <1..500>] \| inventory.sh --check` | 0 done, 3 configuration (env, memory dir, `gh`/`jq`, token file, exclusion file), 4 usage, 5 refused (unattended, `ZYGGY_HOOKS=off`), 6 GitHub request failed | `inventory: <path>` + counts line + the lines in a `<zyggy-github-inventory>` fence; `--check`: one summary line, writes nothing |
| `clone.sh <owner>/<name> \| clone.sh --clean` | 0 cloned or cleaned, 3 configuration, 4 usage, 5 refused by policy (unattended, not the owner's account, organisation, fork of a private repository, size, rate), 6 GitHub or git failed | `cloned: <path>`, a summary line (commit, date, branch, files, size), a data sentence; `--clean`: `cleaned: <root> (<n> clones removed)` |
| `askpass.sh` | 0 answered, 1 refused | Called by git only: answers git's two `github.com` prompts |

`ZYGGY_HOOKS=off` silences `session-start.sh` and `stop.sh` and makes `inventory.sh` and `clone.sh` refuse (exit 5);
the two `m365` launchers run whatever it says. `ZYGGY_NOW` (tests only) replaces the clock of the shell scripts.

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

### Remaining shell

Complex logic lives in the `zyggy` binary; a shell script stays in the template only for one of these reasons.

| Script | Why it is still shell |
|--------|-----------------------|
| `.claude/hooks/session-start.sh` | A hook launcher (≤ 10 lines) for `zyggy memory digest`: when the binary is missing, the session must still start (no section, one stderr line, exit 0) |
| `.claude/hooks/m365-guard.sh` | A hook launcher (≤ 10 lines) that must fail closed even when the binary is missing or crashes: Claude Code blocks a call only on exit 2, so a missing `zyggy` (127) or any other exit is turned into 2; without it the call would fall through to the permission prompt without the guard's refusals |
| `.claude/hooks/m365-log.sh` | The same launcher for the action log: exit 2 tells Claude the row was not written |
| `.claude/hooks/stop.sh`, `.claude/hooks/lib.sh` (trimmed to what `stop.sh` and the GitHub scripts use) | Moves to the binary with the `Stop` hook's own deliverable (12); the secret check is held equal to the binary's by the shared samples in `tests/fixtures/secret-samples.txt` |
| `.claude/skills/github-inventory/inventory.sh`, `.claude/skills/github-clone/clone.sh`, `askpass.sh` | Untouched until deliverable 34 moves them into `zyggy` |

## `zyggy` verbs

The `zyggy` binary (a .NET single-file program, on `PATH`, released from the zyggy repository) carries every
program the `m365` connector and the `remember` skill need. `.claude/zyggy-min-version` names the oldest version
this template works with; the instance pins one at least as new in `instance/zyggy.json`. Missing or older binary:
the guard launcher blocks every action, the `headersHelper` fails (the `m365` tools are unavailable), `remember`
and the skills' commands report `command not found`, and the units fail to start.

Exit codes keep their meaning across verbs: 0 ok, 2 refused (`remember`) or blocked (`guard`, `log`), 3
configuration (env, `instance/m365.json`, a tool, the key, the server installation; for the model runs also
`configuration error: version_mismatch: …`), 4 usage or invalid input, 5 refused, 6 identity, Graph or model-run
failure, 130/143 a model run stopped by a signal. Stderr lines keep their prefixes (`m365:`, `m365-guard:`,
`facts:`, `parse:`, `mail-backfill:`, `files-backfill:`, `remember:`).

| Verb | Replaces | Who runs it | Exit codes | Contract |
|------|----------|-------------|-----------|----------|
| `zyggy memory remember [--scope general\|project:<name>\|machine] [--tag stated\|observed] [--source <text>] -- "<fact>"` | `remember.sh` | The `remember` skill | 0 kept · 2 refused (secret) · 3 · 4; `ZYGGY_HOOKS=off` → 0 with no output | `remembered: <path>` and the line, appended to `inbox/remember-<date>.md` |
| `zyggy m365 check [--counts] [--other-mailbox <upn>] [--drive <id>]` | `graph.sh check` | The owner; `/m365 check` | 0 · 3 · 4 · 5 (mailbox scope not enforced) · 6 | Status line, folder and drive lines; stderr `key: <source>` and a warning 30 days before `cert.expires` |
| `zyggy m365 token-test [--key new] [--alg PS256\|RS256]` | `graph.sh token` | The owner (rotation, diagnostics) | 0 · 3 · 4 · 6 | `token ok: <n> bytes, expires <UTC>` — never the token |
| `zyggy m365 cert-init [--rotate\|--commit]` | `graph.sh cert-init` | The owner, on the machine | 0 · 3 · 4 · 5 (`ZYGGY_HOOKS=off`) | Generates the key (0600) and the self-signed certificate (0644); `--rotate` writes the `.new` pair, `--commit` swaps it in; prints thumbprints, expiry and path, never the key |
| `zyggy m365 auth-header` | `mcp-auth-header.sh` | Claude Code (`headersHelper`), each time it connects to the server, after a 401 too | 0 · 3 · 4 · 6 | Exactly one line `{"Authorization":"Bearer <token>"}` within 8 s; failure → empty stdout, `m365: token refresh failed — runbook 13 "Certificate rejected"`; journal `token minted` / `token refresh failed: <reason>`, never the token |
| `zyggy m365 mcp-server [--probe]` | `mcp-server.sh` | The instance's `zyggy-m365-mcp.service`; the owner (`--probe`) | 0 (or the server's own) · 3 · 4 · 6 | Replaces itself with the pinned `ms-365-mcp-server` (under `~/.local`, never `npx`) with exactly the ten variables (no token), `ENABLED_TOOLS` from `tools/enabled.txt` and argv `--org-mode --http 127.0.0.1:<port> --http-local-file-tools --no-dynamic-registration` (`ZYGGY_M365_PORT`, default 47365); `--probe`: an unauthenticated POST must answer 401, then prints `tools: <n>`, `listen:`, `env:` |
| `zyggy m365 guard` (stdin: the hook JSON) | `m365-guard.sh`'s policy | The `m365-guard.sh` launcher (`PreToolUse`) | 0 · 2 | Nothing (the ask rule prompts) or the deny JSON with `m365-guard: refused: <reason>`; any failure of its own is exit 2 |
| `zyggy m365 log` (stdin: the hook JSON) | `m365-log.sh`'s logic | The `m365-log.sh` launcher (`PostToolUse`) | 0 · 2 | One body-free row in `actions.jsonl`; another tool is ignored |
| `zyggy m365 verify <YYYY-MM-DD> <YYYY-MM-DDTHH:MM:SSZ>` | `verify.sh` | `zyggy m365 brief` (in process); the owner | 0 `audit ok` · 3 · 4 · 5 `audit FLAGGED: …` · 6 | Audits the Drafts of the window (sent mail is reconciled by the owner from the audit log, see [How actions are confirmed](#how-actions-are-confirmed)); receipt `brief-<date>.json`; reads only |
| `zyggy m365 state get\|set\|reset <key> [<arg>] [<value>]` | `state.sh` | The model in the brief and mail backfill runs | 0 · 3 · 4 | Watermarks (`mail-watermark`, `backfill-watermark <folder>`, `drive-token <drive>`, `files-backfill-watermark <drive>` — ISO timestamps; the files backfill's is the cursor `<ISO>\|<item-id>`), `replied <date>` |
| `zyggy m365 facts --kind brief\|mail-backfill\|files-backfill --source <tag> [--max <n>]` (stdin: one fact per line) | `facts.sh` | The model in the three runs | 0 · 3 · 4 · 5 (`--max` reached) | Appends validated `[observed]` fact lines to `inbox/m365-<kind>-<date>.md`; refusals counted on stderr, never echoed |
| `zyggy m365 parse <file>` | `parse.sh` | The model in the runs; the conversation (`~/.cache/zyggy-m365-downloads/<session>/`) | 0 · 3 · 4 · 5 (size, type) · 6 (MarkItDown failed) | MarkItDown on one file inside `ZYGGY_M365_RUN_DIR`, under `prlimit` (2 GiB) and a 120 s timeout; bounded text on stdout, secret-shaped lines withheld; the file deleted in every case |
| `zyggy m365 brief` | `brief.sh` | The timer unit; the owner by hand | 0 (also `already created`) · 3 · 4 · 5 audit flagged · 6 · 130/143 | Checks the pin, then one `claude -p` run with the prompt `/morning-brief …` on stdin (no terminal, `ZYGGY_HOOKS=off`, the action tools and the seven denied verbs in `--disallowedTools`), the audit, one memory line and the journal line `brief <date>: mail <n>, files <m>, replies <r>, suggestions <s>, facts <f>, turns <t>, cost <usd>, audit ok\|FLAGGED, exit <code>`; allowed unattended |
| `zyggy m365 mail-backfill [--folder <name>] [--reset]` | `mail-backfill.sh` | The owner, in tmux | 0 · 3 · 4 · 5 (unattended, a cap, a stuck folder) · 6 · 130/143 | Checks the pin, then batched `claude -p` runs with the prompt `/mail-backfill …` on stdin (mail read tools, `zyggy m365 facts`, `zyggy m365 state`; no Draft tool, no action tool); checkpoint, resume after an interrupt; refuses `ZYGGY_HOOKS=off` with exit 5 |
| `zyggy m365 files-backfill [--drive <name>] [--reset]` | `files-backfill.sh` | The owner, in tmux | 0 · 3 · 4 · 5 (unattended, a cap, an unconfirmed batch) · 6 · 130/143 | The same for the drives: lists each drive once, walks it after the cursor `<ISO>\|<item-id>` (strictly greater, so files sharing one second never stall it), counts type/size/path skips itself and gives the model only the batch's eligible files (`download-bytes-to-file`, `zyggy m365 parse`, `zyggy m365 facts`; a fresh run directory per batch); the cursor moves only when the model's counts line confirms the batch; a 403 drive is skipped as `forbidden`; refuses `ZYGGY_HOOKS=off` with exit 5 |

Inside the three runs the model may call exactly `Bash(zyggy m365 state *)`, `Bash(zyggy m365 facts *)` and
`Bash(zyggy m365 parse *)` (the files backfill has no `state`); `.claude/settings.json` denies
`zyggy m365 auth-header`, `token-test`, `cert-init`, `mcp-server`, `brief`, `mail-backfill` and `files-backfill` in every
session.

Configuration: `instance/m365.json` in the instance directory (`ZYGGY_INSTANCE_DIR`, else
`$CLAUDE_PROJECT_DIR/instance`; `ZYGGY_M365_CONFIG` overrides the file); the key and certificate under
`${XDG_CONFIG_HOME:-~/.config}/zyggy/m365-app.{key,cer}` (`ZYGGY_M365_KEY_FILE`/`ZYGGY_M365_CER_FILE` override, for
hand runs); in a unit the key comes from `$CREDENTIALS_DIRECTORY/m365-app-key` (`LoadCredential=`). The backfills
need no environment line: each of `ZYGGY_MEMORY_ROOT`, `ZYGGY_TENANT`, `ZYGGY_USER`, `ZYGGY_TIMEZONE` that is
unset is read from the `env` of `.claude/settings.local.json`; a set variable wins and no other key is read.
`ZYGGY_M365_RUN_DIR` is the run directory `zyggy m365 parse` accepts; `ZYGGY_CLAUDE_PATH` names `claude` for the
brief unit. The binary reads no test-only switch.

### Tool data files

Plain data, read by the binary at run time and checked by `tests/repo.bats`; changing them is a template commit,
not a binary release.

| File | Content |
|------|---------|
| `.claude/skills/m365/tools/enabled.txt` | The 16 tools the server loads (`ENABLED_TOOLS`): the read and Draft tools and the send and move action tools |
| `.claude/skills/m365/tools/excluded.txt` | The 328 other tools of the pinned server; each has a `mcp__m365__<name>` deny rule in `.claude/settings.json` |
| `.claude/skills/m365/tools/actions.txt` | The three action tools (send, upload, move): the `permissions.ask` rules and the guard's scope; denied in every unattended run |
| `.claude/skills/m365/tools/auth.txt` | The six auth tools the server registers outside the filter; always denied |
| `.claude/skills/m365/tools/server-version.txt` | The pinned server version (`0.157.2`) the lists were generated from |

### Change notes (deliverable 33)

The `m365` scripts under `.claude/skills/m365/` (with the shared `m365-lib.sh` and the retired stdio launcher
`mcp-wrapper.sh`), the logic of `m365-guard.sh` and `m365-log.sh`, and `remember.sh` were replaced by the verbs
above; their bats suites moved to the zyggy repository's .NET tests. `graph.sh check` and
`cert-init` became `zyggy m365 check` and `cert-init`; `graph.sh token` became `token-test`, which never prints the
token (the only token output is `auth-header`'s, for Claude Code). The `graph.sh` read verbs (`mail-folders`,
`drives`, `drive-files`, `drafts-since`, `message-sender`, `item-exists`, `item-kind`) are internal to the binary
and have no command. The tool partition moved from the `m365-lib.sh` arrays to `tools/`. `ZYGGY_M365_ORIGIN` and
the test-only switches (`ZYGGY_M365_STUB`, `ZYGGY_RETRY_SCALE`, `ZYGGY_PARSE_TIMEOUT`) are gone. Rollback: the
previous template commit together with the previous binary.

### How actions are confirmed

Nothing is sent or filed until the owner answers a Claude Code permission prompt for that one call, on whatever
device runs the session (terminal, claude.ai, phone). The template's `permissions.ask` names the action tools; an
ask rule prompts in every permission mode, auto mode included, and no allow rule or "don't ask again" skips it.
Before the prompt, `zyggy m365 guard` (through the `m365-guard.sh` launcher) refuses what `instance/m365.json`
`actions` does not allow (attachments, Bcc, HTML, an over-long body, too many recipients, `SaveToSentItems: false`,
another mailbox, a destination outside Archive, Inbox, Deleted Items and the non-excluded folders; for uploads an
overwrite, a foreign drive, a bad name or extension, oversized content) with `m365-guard: refused: <reason>`; on its
own failure, or when the binary is missing, the launcher blocks (exit 2). After the call, `zyggy m365 log` appends
`{ts, session_id, tool, summary, status}` to `actions.jsonl` (0600; recipients, subject and body length, never the
body). Unattended runs (`zyggy m365 brief`, the backfills) deny the action tools. Reconcile the Exchange/SharePoint
unified audit log for the application id with `actions.jsonl`: an action there without a row means the key was
used outside Claude Code — revoke the application credential.

### Rotate the certificate

`zyggy m365 check` warns 30 days before `cert.expires` and every verb exits 3 after it. On the VM:
`zyggy m365 cert-init --rotate` writes a `.new` key pair; upload the new `.cer` to the app registration;
`zyggy m365 token-test --key new` must succeed; `zyggy m365 cert-init --commit` swaps the pair; delete the old
certificate in the app registration; update `cert.expires` in `instance/m365.json`.

### Upgrade the MCP server

The server is pinned (`@softeria/ms-365-mcp-server@0.157.2`, installed under `~/.local`). A new version means:
regenerate `.claude/skills/m365/tools/enabled.txt`, `excluded.txt` and `server-version.txt` from the package's
endpoint list, review every new tool (a new write or generic tool stays excluded; the six auth tools of `auth.txt`
and `graph-batch` stay denied), regenerate the `mcp__m365__*` deny rules of `.claude/settings.json`, run the tests,
then install the new pin on the machine, `systemctl restart zyggy-m365-mcp` and check
`zyggy m365 mcp-server --probe`. No binary release is needed for a new tool list.
With 0.157.2, `upload-file-content` stays excluded: the server URL-encodes `driveItemId`, so the new-file form
`<parent-id>:/<name>:` cannot reach Graph (0002 "Probe findings (D7)"). It is already in `actions.txt` and
`permissions.ask`, but its deny rule wins while it is excluded; a version that passes the id unencoded can move it
from `excluded.txt` to `enabled.txt` — the guard's upload branch is already written and tested.

## Tests

Run from the repository root in a bash with `bats`, `shellcheck` and `jq` (Ubuntu: `apt-get install bats
shellcheck jq`; the CI image is `ubuntu-latest`):

```bash
bats tests/
shellcheck -S style .claude/hooks/*.sh .claude/skills/*/*.sh tests/*.bash tests/fixtures/github/gh-stub.sh tests/fixtures/github/git-spy.sh tests/fixtures/zyggy-stub.sh
jq . .claude/settings.json > /dev/null && jq . .mcp.json > /dev/null
git ls-files --eol | grep -v 'i/lf\|i/-text\|i/none'      # must print nothing (LF, binary or empty only)
```

`ZYGGY_HYGIENE_FORBIDDEN` — a comma-separated list of words (the owner's tenant and user names, for example)
that must not occur in any template-owned file, matched case-insensitively. Set it as a GitHub Actions
repository **secret**, never a variable: a variable is printed in the run log, and this template's logs are public; CI
passes it to `bats`. Unset or empty → that one test is reported as skipped.

Fixtures use tenant `acme`, user `alice`. Files under `tests/expected/` are **hand-derived** from the
contracts and never pasted from script output; see `tests/README.md`. The `github-inventory` tests run against a
`gh` stub (`tests/fixtures/github/gh-stub.sh`) and fixture API pages — no network in CI. The `github-clone` tests
use the same stub, a git spy (`tests/fixtures/github/git-spy.sh`) that records argv, environment and askpass
answers, and real git against local bare repositories built by `make_bare_repo`.

The template proves its wiring, not the binary's behaviour: the binary's repository is private, so template CI
never runs the real `zyggy`. `tests/launchers.bats` runs the two `m365` launchers against a `zyggy` stub first on
`PATH` (`tests/fixtures/zyggy-stub.sh`, which records argv and stdin): stdin and exit 0 pass through, any other
exit becomes 2, a missing binary gives exit 2 and one line; the inputs are the hook JSON files
`tests/fixtures/m365/hook-*.json`. `tests/repo.bats` checks the template wiring: no `m365` or `remember` script
but the two launchers, the settings rules equal to the tool data files, `.mcp.json` naming
`zyggy m365 auth-header`, every documented `zyggy` command accepted by the stub, and the shared secret samples
giving the same pattern names through `lib.sh`. The `m365` and `remember` behaviour (Graph, the guard's policy, the
runs, parsing, facts, checkpoints) is tested in the zyggy repository's .NET suite, with no network, no tenant and
no real `claude`.

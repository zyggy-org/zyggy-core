# Operations rules

## Where you run

- The working directory is an instance checkout (template files from `zyggy-core`, instance files alongside);
  its remote is read-only from here; template files change in the template, instance files in the instance,
  both on the owner's workstation, and are pulled here with `git pull --ff-only`.
- `.claude/rules/instance.md`, when present, adds or tightens rules for this machine and never relaxes these.
- `memory/` is a separate, nested repository (`zyggy-memory`), ignored by the checkout. `git status` in the
  working directory never shows memory changes; use `git -C memory status` for those.
- Always start Claude Code in the working directory itself. In a subdirectory such as `memory/`, the hooks do not
  run and the digest is missing.
- `ZYGGY_MEMORY_ROOT`, `ZYGGY_TENANT`, `ZYGGY_USER` and `ZYGGY_TIMEZONE` come from
  `.claude/settings.local.json`, installed from the instance's `instance/settings.local.json`; the live file stays
  untracked because Claude Code writes permission approvals into it. `autoMemoryDirectory` in the same
  file points Claude Code's auto memory at `memory/<tenant>/<user>/auto`.
- `ZYGGY_HOOKS=off` disables the hook and skill scripts (`github-inventory` and `github-clone` refuse with exit 5;
  the dream pass will use it). The `m365` timer unit sets it: there `graph.sh cert-init`, `mail-backfill.sh` and
  `files-backfill.sh` refuse with exit 5, while `brief.sh` and the `graph.sh` reads run; the action tools are
  denied in every run whatever it says. `ZYGGY_NOW` is for tests only; it must never be set on this machine.

## Instruction files

- `AGENTS.md` at the root is the only instruction file. No `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md`
  may exist in the working directory or any directory above it: Claude Code would load it instead. Never create
  one, and never create an `AGENTS.md` in a subdirectory. If the `identity` section of the digest starts with a
  `[warning] CLAUDE.md found at …` line, tell the owner at once.
- Never edit `AGENTS.md`, `.claude/` or `PROTOCOL.md` unless the owner asks for that change in the
  conversation. Such a change is then made on the owner's laptop and pulled here; say so.

## Hooks by hand

To print a digest section outside a session (for example to check its size):

```bash
set -a; . <(jq -r '.env | to_entries[] | "\(.key)=\(.value)"' .claude/settings.local.json); set +a
.claude/hooks/session-start.sh identity | wc -c      # or: index, daily
```

Exit codes of every script: `0` ok, `2` refused (secret pattern, `remember` only), `3` configuration error
(the stderr line names the cause: a `ZYGGY_*` variable, the memory directory, a missing tool or file), `4` usage
error or unknown section,
`5` refused — by policy (an unattended run, or for `github-clone` a repository outside the owner's account, a
fork of a private repository, over the size or clone limit; for the `m365` scripts `audit flagged`, a backfill
cap reached); `6` a GitHub request failed (`github-inventory`,
`github-clone`), or a Graph or identity failure (`m365`).

## When something reports an error

- Exit 3 from a hook or from `remember`: memory is not configured. Tell the owner, and point to the runbook
  named in `.claude/rules/instance.md` (when there is none, tell the owner no runbook is configured here),
  entry "Hooks report configuration error".
  Do not edit settings files to repair it.
- A `[digest truncated: …]` line: the section was over its cap. Read the file directly if you need the rest, and
  mention it to the owner when it keeps happening (runbook entry "Digest truncated").
- Exit 6 from `github-inventory` or `github-clone`: a GitHub request failed. Quote the stderr line to the owner
  and point to the runbook entry "GitHub token rejected". Do not retry with another tool.
- Exit 5 from `github-clone`: quote the stderr line; do not retry and do not try another way.
- Exit 6 from an `m365` script (`/m365 check`): quote the stderr line and point to the runbook entry it names —
  "Certificate rejected" (`invalid_client`, clock skew) or "Scope or grant missing" (403). Do not retry with
  another tool. The `m365` credential refreshes itself; if an `m365` tool still reports an authentication failure,
  tell the owner the credential could not be refreshed and point to runbook 13 "Certificate rejected"; do not retry
  another way.
- A denied prompt or a guard refusal ends the action — report it (`m365-guard: refused: <reason>` names what the
  policy does not allow, runbook "Guard refused"); never retry it another way.
- `audit FLAGGED` in the brief's journal line: the owner reviews the Drafts. A `Send`, `Move` or upload by the
  application in the Exchange/SharePoint audit log without an `actions.jsonl` row means "Revoke the application
  credential" until it is explained.
- `stop: note refused` on stderr: the turn's note looked like a secret and was not written. Expected; nothing to do.

## Headless runs

- The owner's checks use `claude -p --no-session-persistence --permission-mode auto …`. Without
  `--no-session-persistence` the remote-control wrapper would resume that run instead of the owner's
  conversation at the next restart.
- Never restart the remote-control service yourself.

## What comes later

These will be added by later deliverables and do not exist yet: the nightly dream pass (consolidates `inbox/`
and `daily/` into the durable files and commits memory), Telegram, personal mail, social accounts, and jobs on the
owner's laptops. Until they exist, say so when asked.

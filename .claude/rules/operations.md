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
- `ZYGGY_HOOKS=off` disables the three scripts (the dream pass will use it). `ZYGGY_NOW` is for tests only;
  it must never be set on this machine.

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
(a `ZYGGY_*` variable is missing or the memory directory does not exist), `4` usage error or unknown section.

## When something reports an error

- Exit 3 from a hook or from `remember`: memory is not configured. Tell the owner, and point to the runbook
  named in `.claude/rules/instance.md` (or the template README when there is none), entry "Hooks report
  configuration error".
  Do not edit settings files to repair it.
- A `[digest truncated: …]` line: the section was over its cap. Read the file directly if you need the rest, and
  mention it to the owner when it keeps happening (runbook entry "Digest truncated").
- `stop: note refused` on stderr: the turn's note looked like a secret and was not written. Expected; nothing to do.

## Headless runs

- The owner's checks use `claude -p --no-session-persistence --permission-mode auto …`. Without
  `--no-session-persistence` the remote-control wrapper would resume that run instead of the owner's
  conversation at the next restart.
- Never restart the remote-control service yourself.

## What comes later

These will be added by later deliverables and do not exist yet: the nightly dream pass (consolidates `inbox/`
and `daily/` into the durable files and commits memory), Telegram, mail, social accounts, and jobs on the
owner's laptops. Until they exist, say so when asked.

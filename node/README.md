# node/ — the laptop side

What a laptop's Claude Code sessions use to feed Central's memory (deliverable 12). Nothing under `node/` is loaded
by Central's sessions, and this folder holds no `AGENTS.md`: the laptop install (deliverable 15) wires these files
into the user-scope settings explicitly.

| Path | What it is |
|------|------------|
| `node/hooks/stop.sh` | `Stop` hook: runs `zyggy context --stop-hook`, which appends one `[observed]` line per turn to the session's spool. No key, no checkout, no bus. |
| `node/hooks/session-end.sh` | `SessionEnd` hook: runs `zyggy context --flush`, which ships the session's spool as one signed context envelope. |
| `node/skills/remember/SKILL.md` | The laptop `remember` skill: a fact the owner states becomes one signed context envelope through `zyggy context`. |

Both launchers hold no logic and never block: every outcome of the binary, a missing binary included, is exit 0
with its stderr line kept and nothing on stdout. They need `bash` on `PATH` (Git for Windows ships it).

The first release that ships `zyggy context` is **0.11.0**. A laptop pinned to an older binary reports
`command not found` or an unknown command from the launchers; nothing is sent.

## Wiring (installed by deliverable 15)

The user-scope `~/.claude/settings.json` on a laptop, with the checkout at `C:/agents/zyggy-core`:

```json
{
  "env": {
    "ZYGGY_SECRET_PATTERNS": "C:/agents/zyggy-core/.claude/hooks/secret-patterns.txt"
  },
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash C:/agents/zyggy-core/node/hooks/stop.sh", "timeout": 10 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "bash C:/agents/zyggy-core/node/hooks/session-end.sh", "timeout": 30 } ] }
    ]
  },
  "permissions": {
    "deny": ["Bash(zyggy secret*)", "Bash(zyggy context --stop-hook*)", "Bash(zyggy context --flush*)"]
  }
}
```

- `"timeout": 30` on `SessionEnd` raises Claude Code's 1.5 s default budget for that event, so the flush has time to
  pull, commit and push.
- `ZYGGY_SECRET_PATTERNS` names the same pattern list Central's hooks use. Without it, `zyggy context` refuses to
  run (fail closed).
- The deny rules keep the model away from the secret store and from the two hook modes; the session may still run
  `zyggy context -- "<fact>"` through the `remember` skill.
- Copy `node/skills/remember/` to `~/.claude/skills/remember/` for a user-scope skill.

## The spool

`<nodeDir>/context/<tenant>/<session>.md`: the first line is `scope: <scope>` (from the session's working
directory: `project:<last folder, lower-cased>` when that is a valid name, else `general`), then one line per turn,
at most 150 and then a cap marker. It is node state, never committed. At `SessionEnd` the spool ships as one
envelope into `nodes/<machine>/context/` on the bus, addressed `to: central`, and is deleted once pushed or
committed. A spool older than an hour, left by a crashed session or a failed flush, ships with the next flush; to
ship it now, run `zyggy context --flush` by hand.

## `zyggy context` exit codes

| Exit | Meaning |
|------|---------|
| 0 | Sent, or nothing to do (`ZYGGY_HOOKS=off`, nothing due). |
| 2 | An option or the fact was refused, or this machine is `central` (there, use `zyggy memory remember`). |
| 3 | Configuration: `node.json`, `signWith`, the secret-pattern file, the bus checkout. |
| 5 | Refused by a secret pattern: nothing signed or written. Never retry or rephrase. |
| 6 | Not sent: the signing key, the secret store, the checkout lock, or the pull failed. A spool is kept. |
| 7 | Committed locally, not yet pushed: the next bus write pushes it. |

## Runbook entries

- **Context: configuration error** — `zyggy: configuration error: …` (exit 3). Check `ZYGGY_SECRET_PATTERNS` in the
  user-scope `env`, `signWith` and `bus.localPath` in `node.json`, and that the bus checkout is on `main` with a
  `tenants/<tenant>/` folder.
- **Context not sent** — exit 6 or 7. `zyggy probe reach`, then `git -C <bus.localPath> status`; for a push that
  keeps failing, `runbooks/bus-conflict.md`.

# node/ — the laptop side

What a laptop's Claude Code sessions use to feed Central's memory (deliverable 12). Nothing under `node/` is loaded
by Central's sessions, and this folder holds no `AGENTS.md`: the laptop install (deliverable 15) wires these files
into the user-scope settings explicitly.

| Path | What it is |
|------|------------|
| `node/hooks/stop.sh` | `Stop` hook: runs `zyggy context --stop-hook`, which appends one `[observed]` line per turn to the session's spool. No key, no checkout, no bus. |
| `node/hooks/session-end.sh` | `SessionEnd` hook: runs `zyggy context --flush`, which ships the session's spool as one signed context envelope. |
| `node/skills/remember/SKILL.md` | The laptop `remember` skill: a fact the owner states becomes one signed context envelope through `zyggy context`. |
| `node/skills/archive/SKILL.md` | The laptop `archive` skill: a file the owner hands over and asks to keep goes to Central's project archive through `zyggy archive` (deliverable 41). |

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

## The `archive` skill

`node/skills/archive/SKILL.md` lets a laptop session keep a file the owner hands over (a long text, a document, an
image) in Central's project archive. Copy `node/skills/archive/` to `~/.claude/skills/archive/` for a user-scope
skill (installed by deliverable 15). The skill shows the owner project, name, description, type, size and the
route, waits for his go and runs one `zyggy archive --project <slug> --name "<name>" --description "<text>" --file
<absolute path>` call. Never from an unattended run (`ZYGGY_HOOKS=off` is refused).

`zyggy archive` runs every check it can on the laptop (location, type and Office content, the laptop cap, secrets
and contact details, the index line), then the checkout and key checks and a pull, and only then picks the route:

- **OneDrive** — with `archive.oneDriveFolder` set, the file is copied to `<oneDriveFolder>/<project>/<slug>.<ext>`
  (the laptop's OneDrive client uploads it) and a small signed `item` envelope, without the file, tells Central
  where it is. Central downloads it read-only, checks it again and files it; the next offload adopts the OneDrive
  copy.
- **Bus** — without `archive.oneDriveFolder` (this laptop has no OneDrive access), or with `--via bus`, the file
  travels as base64 inside the signed `item` envelope. It then reaches every machine's bus checkout and stays in
  the bus history for good.

Both envelopes sit in `tenants/<tenant>/nodes/<machine>/items/`, addressed `to: central`; Central's pickup files
them through the same writer and checks as `zyggy memory archive add` on Central and answers with a signed report.
A configured folder that is unavailable never falls back to the bus silently: exit 6, and the skill asks the owner
before it re-runs with `--via bus`.

The `archive` block of the laptop's `node.json` (both keys optional):

```json
{
  "archive": {
    "itemMaxBytes": 10485760,
    "oneDriveFolder": "C:/OneDrive - Example/Zyggy/archive"
  }
}
```

- `archive.itemMaxBytes` — the laptop cap, default 10,485,760 (10 MiB), 1 … 26,214,400. Central's own caps still
  apply.
- `archive.oneDriveFolder` — the absolute path (forward slashes) of the locally synced copy of Central's
  `offload.root_folder` (`Zyggy/archive` in the owner's company OneDrive), usually inside the user profile. Set it
  only on a laptop whose OneDrive client syncs the owner's company OneDrive. Absent (or `null`) means this laptop
  has no OneDrive access and always takes the bus route; no probe is made.

## `zyggy archive` exit codes

| Exit | Meaning |
|------|---------|
| 0 | Sent: `item <id> to central (<path>)` and the item line ending `— via OneDrive` or `— via bus`. |
| 2 | An option was refused (slug, name, description, index line over 400 characters), the envelope does not round-trip, or this machine is `central` (there, use `zyggy memory archive add`). |
| 3 | Configuration: `node.json` (incl. `archive.*`), `signWith`, the secret-pattern file, the bus checkout. |
| 5 | Refused on the laptop (`zyggy: refused: <reason>`): nothing written to the folder or the bus. Never retry another way. |
| 6 | Not sent: the OneDrive folder is not available or the write failed, or the signing key, the secret store, the checkout lock, the pull or the push failed. |
| 7 | Committed locally, not yet pushed: the next bus write pushes it. |

## Runbook entries

- **Context: configuration error** — `zyggy: configuration error: …` (exit 3). Check `ZYGGY_SECRET_PATTERNS` in the
  user-scope `env`, `signWith` and `bus.localPath` in `node.json`, and that the bus checkout is on `main` with a
  `tenants/<tenant>/` folder.
- **Context or item not sent** — exit 6 or 7 of `zyggy context` or `zyggy archive` (not a OneDrive folder line).
  `zyggy probe reach`, then `git -C <bus.localPath> status`; for a push that keeps failing,
  `runbooks/bus-conflict.md`. An item whose file was already written to the OneDrive folder is sent by re-running
  the same `zyggy archive` call: the identical file is reused and exactly one envelope is published.
- **Archive from a laptop: too large** — exit 5 `zyggy: refused: too_large (<size> > <cap>)`; nothing sent. The
  cap is `archive.itemMaxBytes` (default 10,485,760, at most 26,214,400). Raise it in `node.json` only within
  Central's own `item_max_bytes`, or let the owner shrink the file himself (a PDF instead of scans, a smaller
  image); never split it.
- **Archive from a laptop: OneDrive folder not available** — exit 6
  `zyggy: OneDrive folder <path> is not available (missing | not_a_folder | access_denied): fix the folder, or archive through the bus with --via bus`,
  or `zyggy: OneDrive write failed: <detail>` (the partial file is removed); nothing sent. Is the OneDrive client
  running and signed in to the company account, is the `Zyggy/archive` folder still synced, is
  `archive.oneDriveFolder` its path? Remove the key on a laptop that no longer syncs it. Only on the owner's word
  does the skill re-run the call with `--via bus`.
- **Archive from a laptop: refused on Central** — `zyggy status --id <id>` shows a `failed` report with
  `reason: archive_refused` and the line `archive: refused: <reason> (<detail>)`: Central's checks are stricter
  than the laptop's (its `allowed_types`, item, project and total caps, a slug already taken by another file, a
  secret, contact detail or Office content it finds) or the downloaded copy differs (`drive_mismatch`). For the
  OneDrive route a second line says the OneDrive copy stays; delete it in OneDrive if wanted. Nothing was written
  to memory.
  `drive_missing`: the file never reached Central's OneDrive within `item_drive_wait_hours` (default 24) after it
  was sent — the sync client paused or signed out, the wrong folder, or the employer's OneDrive configured by
  mistake. Check the sync client, compare `archive.oneDriveFolder` with Central's `offload.root_folder`, then
  archive the file again.
- **Archive from a laptop: configuration error** — `zyggy: configuration error: …` (exit 3) from `zyggy archive`.
  `archive.itemMaxBytes` must be an integer from 1 to 26,214,400 and `archive.oneDriveFolder` an absolute path;
  otherwise check the same items as "Context: configuration error".

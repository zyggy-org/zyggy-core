---
name: dream
description: Ask for the dream pass now, or report how the last one went. Use when the owner says "dream", "dream now", "file my notes", "process the inbox" or asks whether the nightly memory run worked. The dream itself runs as a separate service; this skill never edits memory.
---

# dream

The dream pass files the facts waiting in `inbox/` and `daily/` into the owner's long-term memory, compresses long
files, commits and pushes. It runs every night at 03:00 and on request, as its own service. You only ask for a run and
read its result. Never edit memory files yourself, and never start the run any other way.

## Ask for a run

When the owner asks for a dream now, run it with the Bash tool:

```bash
zyggy dream request
```

It prints `dream requested`. The service starts within seconds; a run takes from a minute to well over an hour when
the backlog is large. Tell the owner it was requested and that you can report the result when they ask.

## Report the result

```bash
zyggy dream status
```

Quote the summary line verbatim: end time, trigger, outcome (`committed`, `nothing_to_do`, `partial`, `aborted`,
`failed`), the check or reason in brackets, batches, lines, quarantined lines, what remains in the backlog, the cost,
the commit and whether it was pushed. Add `--json` only when the owner wants the full record.

- `aborted` names the safety check that refused the run; nothing of the refused batch was written.
- `failed` with `locked` means a run was already going; with `claude_error` or `timeout`, the next run retries.
- `no dream run yet` (exit 1) means none has run on this machine.

For anything beyond that, point the owner to the runbook named in `.claude/rules/instance.md`, section
"Dream pass". The run record and the commit never contain fact texts; to see what was filed, read the memory files.

---
name: seed-memory
description: One-time seeding interview for a fresh memory repository (owner-invoked).
disable-model-invocation: true
---

# seed-memory

The owner runs this once, on a fresh memory repository, to write the first version of their memory. This is the
one sanctioned direct write into the durable memory files.

## Before you start

1. Read `.claude/rules/memory.md` for the file format.
2. The memory directory is `$ZYGGY_MEMORY_ROOT/$ZYGGY_TENANT/$ZYGGY_USER/`. Check that it exists and show the
   owner what is already there (`ls -R` of it). If `profile.md` already has `[stated]` lines, ask whether to
   continue; never delete existing lines.
3. Tell the owner: six blocks of questions, one block at a time; any question may be skipped; answers can be in
   any language, the files are written in English.

## The interview

Ask one block, wait for the answers, write them, show what you wrote, then move to the next block.

1. **profile.md** — full name and how to address you; where you live and your time zone; languages you speak
   and the language memory files and answers should use; household/family in one line each; your work role,
   employer and main responsibilities; your machines (which is `home-laptop`, which is `work-laptop`).
2. **preferences.md** — tone and length of answers; when to act without asking vs when to ask first; quiet hours
   and days; channels you will use (remote control now, Telegram later); things you never want done or said;
   how you want memory diffs reviewed.
3. **areas/** — every ongoing project, responsibility or trip (one file each: name, goal, status, deadline,
   people involved, machine/repository if any) — Zyggy itself is one.
4. **people/** — up to ten people who matter for the assistant's work (name, relation, context, what to
   remember, contact preference).
5. **topics/** — habits, tastes, recurring subjects, tools you use, subscriptions and accounts (names only, never
   credentials).
6. **agents.md** — confirmation of the three machines and what each may be asked to do today.

## Writing the answers

- One fact per line: `- [stated] <today YYYY-MM-DD>: <fact>`, in English, in the owner's words as far as
  possible. Today is the local date in `ZYGGY_TIMEZONE`.
- `profile.md`, `preferences.md`, `agents.md`: keep the existing front matter, set `description` to a short
  summary under 150 characters naming the people and projects the file mentions, set `updated` to today.
- `areas/`, `people/`, `topics/`: one file per item, slug in lowercase with hyphens (`areas/house-move.md`,
  `people/marie.md`), with front matter `name`, `description`, `updated` and, when useful, `aliases`.
- Link related files with `[[slug]]`.
- `preferences.md` records the language the owner wants answers in.
- Never write a password, key, token, IBAN, card number or health/personality inference, even if the owner
  offers one: say it is not stored. Accounts and subscriptions are recorded by name only.

## Finish

Run `git -C "$ZYGGY_MEMORY_ROOT" status` and `git -C "$ZYGGY_MEMORY_ROOT" diff --stat` and show the output.
Tell the owner to review the files and commit and push them themselves. You never commit or push.

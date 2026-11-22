# node/work-mail/ — the work-mail session's settings (work laptop only)

Deliverable 58, slice 7, Q24 (accepted by the owner on 2026-11-22): in the session that may send or move work mail, any
tool use beyond Read and the `zyggy outlook` read verbs needs the owner's answer to a prompt.

`node/work-mail/settings.json` is the project settings template for the folder the owner opens Claude Code in for the work
mail (the work-mail project on the work laptop; one folder, used for nothing else, never a code project). Copy it to
`<work-mail folder>/.claude/settings.json` by hand (it is kept outside a `.claude/` folder here so that it never applies to a
session in this checkout); `install.ps1` does not copy it. Never use it on Central or on a
laptop that is not a work machine.

## 1. The project settings

- `allow` holds only `Read` and the read verbs, each a simple command. Claude Code checks every part of a compound command on
  its own, so `zyggy outlook list && <anything>` still prompts for `<anything>`. Nothing else is allowed: Bash, PowerShell,
  WebFetch, every MCP tool and every other command prompts (`defaultMode` `default`).
- `deny` takes `Write`, `Edit`, `MultiEdit`, `NotebookEdit` and the MCP tools that run code away entirely (no prompt to click
  through). Add to `deny` any other MCP tool on the work laptop that runs code or a shell (an `*_unsafe`, `evaluate`, `exec`
  or `run_*` tool), by its full name.
- `disableBypassPermissionsMode` keeps the session out of bypass mode (`--dangerously-skip-permissions`, Shift+Tab).
- `zyggy outlook send` and `move` are not allowed: the guard answers `ask` for each, with the whole message, so they always
  prompt.
- `brief-done` and `share` read stdin; a here-document (`zyggy outlook share <<'EOF' … EOF`) stays one allowed command, a
  pipe (`echo … | zyggy outlook share`) prompts for the `echo`.
- The template holds no `hooks` block: the guard and settle hooks are wired once in the work laptop's user settings
  (`node/README.md`, "Manual: the work-mail hooks"). Two registrations would run the guard twice, harmless but noisy.
  Without the hooks every send and move is refused (fail closed).

## 2. The user settings on the work laptop — nothing that allows more

Claude Code adds the allow rules of every settings file the session reads: `%USERPROFILE%\.claude\settings.json` (or
`%CLAUDE_CONFIG_DIR%\settings.json`), the project's `.claude\settings.json` and `.claude\settings.local.json`, and the
managed file (`%ProgramFiles%\ClaudeCode\managed-settings.json`). For the guarantee, none of them may allow anything beyond
`Read` and the read verbs above, unless the project's `deny` takes it back (deny wins). `Grep` and `Glob` stay on the prompt.
Check them once:

```powershell
Get-Content "$env:USERPROFILE\.claude\settings.json"
Get-Content ".claude\settings.local.json"
```

A broad user allow rule (for example `Bash(git *)` for other projects) blocks every send and move of the work-mail session
until it is removed or moved into those other projects' own settings.

## 3. What the guard checks

Before it passes a send or move to the prompt, `zyggy outlook guard` refuses it (`outlook-guard: refused: …`, one `refused`
row) when:

- the hook's `permission_mode` is not `default` (`acceptEdits`, `bypassPermissions`, `dontAsk`, `plan`, or missing in an
  older client): `the session's permission mode is …`;
- a settings file above auto-allows anything beyond `Read` (bare or with a path; `Grep` and `Glob` count) and
  `Bash(zyggy outlook <read verb>)`, `Bash(zyggy outlook <read verb> *)`, `Bash(zyggy outlook <read verb>:*)` (also
  `zyggy.exe`), and no deny rule written the same, or a bare deny of its tool, takes it back: `<file> auto-allows <rule> (…)`.
  Bare `Bash`, `Bash(*)`, `PowerShell`, `Write`, `Edit`, any MCP tool, `WebFetch`, `Bash(git *)`, `Bash(zyggy outlook *)`
  all count;
- a settings file exists but cannot be read, or is not valid JSON with string `allow`/`deny` lists:
  `cannot read the settings file …`.

It reads the project files of `CLAUDE_PROJECT_DIR` and of the hook's `cwd`. Read verbs are not checked: they read and print
only.

Every other tool call on the work laptop goes through the screen as before, with full paths: a path in a command or in
`file_path`/`path`/`notebook_path` is resolved (`~` and environment variables, `\\?\`/`\\.\`, `\\<host>\<drive>$\…`,
`..`/`.`, then the file system's own final path — 8.3 names, junctions, symbolic links) and refused when it lies in the
outlook state folder; a glob in a command is refused when its fixed part (up to the folder before the first `*`, `?`, `[`)
is the state folder, inside it or any parent of it; a `Grep` or `Glob` is refused when its root (`path`, else the session's
folder) is the state folder or any parent of it, or its glob (`glob`, `pattern`) read as a path from that root can reach it;
a pipe or redirect into a shell or interpreter (`| bash`, `| pwsh`, `| python`, `| iex`, `bash < file`, `python3 <<EOF`,
`bash <(…)`) is refused.

## 4. What remains (the residual of Q24)

- The guard cannot see a `--allowedTools` flag on the `claude` command line, nor another hook that answers `allow`. Start
  the work-mail session as plain `claude` in that folder, and register no other allowing hook there.
- A hard link or a share pointing at the state folder, made earlier, is not followed (the file system gives the name it was
  opened by). Making one needs a command, which prompts under these settings.
- A same-user process the owner let run at a prompt can still read the approval key or drive Outlook over COM; the prompt
  is the control. Keeping the approval out of the user's reach is not built.

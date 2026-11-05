# install-node.md — the Zyggy node on Central and on a laptop

Placeholders only: tenant `acme`, machines `central` and `home-laptop`, `<zyggy-home>` the service user's home, `<vm-admin>` the VM's administrator account, `<version>` the release. Every command is prefixed with the machine and the user that runs it. An instance records its filled-in evidence in its private repository, never here.

The files this runbook copies ship in every release under `artifacts/<rid>/deploy/` (`zyggy-node.service`, `zyggy-node.service.d/credentials.conf.example`, `zyggy-node.service.d/pickup.conf.example`, `install.ps1`, `README.md`), listed in `SHA256SUMS` next to the two binaries.

## Central

1. `[central/<vm-admin>]` Download the `linux-x64` release folder and check it: `sha256sum -c SHA256SUMS` must print `OK` for `zyggy`, `zyggy-node` and the five `deploy/…` files.
2. `[central/<vm-admin>]` `install -o root -g root -m 755 -D zyggy-node /opt/zyggy/<version>/zyggy-node`, the same for `zyggy`; `ln -sfn /opt/zyggy/<version>/zyggy-node /usr/local/bin/zyggy-node` and `ln -sfn /opt/zyggy/<version>/zyggy /usr/local/bin/zyggy`. The unit runs the symlink, so an upgrade is a new folder and a new link.
3. `[central/zyggy]` `node.json` at `~/.config/zyggy/node.json`: `tenant`, `machine: central`, `signWith: acme/<n>`, `bus` (`remote: git@github.com-zyggy-bus:zyggy-org/zyggy-bus.git`, `owner`, `repo`, `branch: main`, `localPath` = the checkout), `"poll": { "activeSeconds": 1 }` (Central polls every second; deliverable 13), **no** `workHours` (Central is always inside work hours), `claude.path` absolute (`<zyggy-home>/.local/bin/claude`; a unit has no user `PATH`), `secrets: { "store": "os" }`. Never a secret in it: the reader refuses any key named like one.
   - **3b.** `[central/<vm-admin>]` **Required from deliverable 13** — the pickup's memory principal and secret patterns: `mkdir -p /etc/systemd/system/zyggy-node.service.d`; copy `deploy/systemd/zyggy-node.service.d/pickup.conf.example` to `/etc/systemd/system/zyggy-node.service.d/pickup.conf` and replace `<instance-dir>` (it sets `ZYGGY_MEMORY_ROOT`, `ZYGGY_TENANT`, `ZYGGY_USER`, `ZYGGY_TIMEZONE`, `ZYGGY_SECRET_PATTERNS`); `systemctl daemon-reload`. Without it `zyggy-node` exits 3 with `configuration error: pickup: <detail>` and the files wait on the bus.
4. `[central/zyggy]` The keys: `zyggy secret list --config ~/.config/zyggy/node.json` must show `hmac/<n>` with role `signs` and `github-pat`. If not: `zyggy secret set hmac/<n> --hex` (paste the tenant's key at the hidden prompt) and `zyggy secret set github-pat`; compare the fingerprint of `hmac/<n>` with the other machines. The node's own refusals say the same: `refusing to start: signing key acme/<n> is not in the file; run: zyggy secret set hmac/<n> --hex` and `refusing to start: secret store unavailable: <detail> — see README "Secrets: store unavailable"` (a corrupt file or a credentials-directory file with the wrong mode or owner; the detail names the path).
5. `[central/<vm-admin>]` `cp deploy/systemd/zyggy-node.service /etc/systemd/system/zyggy-node.service`; `systemctl daemon-reload`; `systemctl enable --now zyggy-node`.
6. `[central/<vm-admin>]` Checks: `systemctl is-active zyggy-node` → `active`; `journalctl -u zyggy-node -n 50` shows `node started: tenant acme, machine central`, `health endpoint listening` and `claude auth ok`, no `[ERR]`; `[central/zyggy]` `zyggy status` → `health: green`; `curl -s http://localhost:4711/health` answers JSON; after a laptop's `zyggy context` (the next step on the laptop), `journalctl -u zyggy-node | grep 'picked up'` shows the pickup within seconds. A `failed` unit with exit 3 or 6 is a human's turn: read the one `refusing to start:` line (exit codes below), fix, `systemctl reset-failed zyggy-node && systemctl start zyggy-node`.

### Bus secrets: file layer or credentials directory

The node's store on Linux has two layers (zyggy README "Troubleshooting — Secrets"): the credentials directory systemd fills from `LoadCredential=` lines, read first and read-only, then the 0600 files under `<zyggy-home>/.local/share/zyggy/secrets/acme/`. **The default is the file layer**: one source for the unit and for every shell command (`zyggy submit`, `verify`, `secret`), nothing to keep in step.

Choose the drop-in when the unit's copy should be root-owned and read-only — a source under `/etc/credstore/` that the `zyggy` user, and so the model's `Bash`, cannot read, overwrite or delete. Its costs: two sources to keep equal (the shell commands still sign with the file layer), one drop-in edit per rotation, and a restart to pick a change up.

- Enable: `[central/<vm-admin>]` `mkdir -p /etc/systemd/system/zyggy-node.service.d`; copy `deploy/systemd/zyggy-node.service.d/credentials.conf.example` to `…/credentials.conf`, replace `<zyggy-home>` (or point the sources at root-owned 0600 files under `/etc/credstore/`); `systemctl daemon-reload && systemctl restart zyggy-node`.
- Verify: `systemctl show -p LoadCredential zyggy-node` lists the two ids `zyggy.acme.hmac.<n>` and `zyggy.acme.github-pat`; inside the unit `zyggy secret list` shows store `credentials-directory` for both, outside the unit it shows `file`; `zyggy secret set` for a name the directory also provides prints `note: the credentials directory still provides <name> to the node`.
- Disable: remove `credentials.conf`, `systemctl daemon-reload && systemctl restart zyggy-node`.
- Not done here: `ProtectHome`/`ProtectSystem=strict` sandboxing would need a `ReadWritePaths=` list that changes with every project; deferred.

### Upgrade

- `[central/<vm-admin>]` `systemctl stop zyggy-node`; the new `/opt/zyggy/<version>/`; switch both symlinks; `systemctl start zyggy-node`; `curl -s http://localhost:4711/health` shows the new `version`. `zyggy status` on a machine whose `zyggy` is older prints `health: amber — node <v>, cli <v>` until the CLI is upgraded too. From deliverable 13 on, install `pickup.conf` (step 3b) before starting the new version; without it the new node exits 3.
- `[home-laptop/user PowerShell]` The same one run as "Laptop" below, from the new release folder in a fresh PowerShell window: it stops the task, replaces the binaries, keeps `node.json`, re-registers the task and starts it; it also pulls `zyggy-core` and refreshes changed skills with a backup. A mixed old folder left on the PATH (an installer warning): move the non-zyggy files out of that folder and run `install.ps1` again.

## Laptop (no administrator needed)

The owner is not an administrator on every laptop; nothing below needs it, and the script refuses rather than asks for elevation. A first install and an upgrade are the same one command (deliverable 42).

Prerequisites, once per laptop:

- Git for Windows (Git Credential Manager is its default helper) and Claude Code installed and logged in as this user.
- `[home-laptop/user PowerShell]` The bus clone: `git clone https://github.com/zyggy-org/zyggy-bus.git C:/agents/bus`; `git -C C:/agents/bus config core.autocrlf false`; `git -C C:/agents/bus push --dry-run` once so Git Credential Manager asks for the token and stores it (see "`GCM_INTERACTIVE` and `BatchMode`").
- `[home-laptop/user PowerShell]` Unpack the `win-x64` release folder (`zyggy.exe`, `zyggy-node.exe`, `SHA256SUMS`, `deploy\`).

**The one command**, from the release folder in a fresh PowerShell window:

1. `[home-laptop/user PowerShell]` `.\deploy\windows\install.ps1 -Tenant acme -Machine home-laptop -SignWith acme/<n>`

   It checks the checksums, stops the task and any older node, copies the binaries, puts them on the user PATH and takes an older `zyggy` folder off it, writes `node.json` when absent, and runs `zyggy setup`: `node.json` completed (`claude.path`, `signWith`), `zyggy-core` cloned or fast-forwarded at `-CorePath`, `ZYGGY_SECRET_PATTERNS` and the three deny rules in the user-scope Claude Code settings, the `remember` and `archive` skills copied, both secrets checked by name and fingerprint. Then it registers and starts the logon task.
2. `[home-laptop/user PowerShell]` **Secrets**: when a `setup:` line says `missing`, run the command it names, then run the script again. `setup: signing key acme/<n>: missing - run: zyggy secret set hmac/<n> --hex` (paste the tenant's key at the hidden prompt; `zyggy secret list` must show the same fingerprint for `hmac/<n>` as Central; where the key comes from: `rotate-hmac.md`) and `setup: github-pat: missing - run: zyggy secret set github-pat` (this laptop's token). The store is the Credential Manager of this user; no value is ever shown.
3. **Manual hooks step**, once per laptop: add the `Stop`/`SessionEnd` `hooks` block to the user-scope `~/.claude/settings.json` by hand, as in `node/README.md` "Wiring", part "Manual: the hooks". `zyggy setup` never installs, changes or removes hook entries.
4. Close and reopen every terminal, VS Code window (all of them) and Claude Code session opened before the install, as the last line says.

A second run prints only `already done` lines for the `setup:` items.

**Manual fallback**: when `zyggy setup` keeps failing on an item, wire that item by hand per `node/README.md` "Wiring" (the env value, the deny rules, the two skill folders) and the bus prerequisites above, then run the script again; it leaves an existing value as it is.

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-Tenant`, `-Machine` | required | `node.json` `tenant` and `machine`; an existing `node.json` must name the same |
| `-SignWith acme/<n>` | required when `node.json` is written or has no `signWith` | `node.json` `signWith` |
| `-BusLocalPath` | `C:/agents/bus` | the checkout (forward slashes in the file) |
| `-CorePath` | `C:/agents/zyggy-core` | where `zyggy setup` clones or fast-forwards `zyggy-core` |
| `-Source` | the script's folder | where `zyggy.exe`, `zyggy-node.exe`, `SHA256SUMS` are |
| `-NodeJson` | `%LOCALAPPDATA%\zyggy\node.json` | written only when absent |
| `-Uninstall` | — | stop and unregister the task; leaves everything else |

What the lines mean:

- `install: checksum ok: <file>` — SHA256SUMS verified before anything was copied.
- The older copies: `install: stopped the older zyggy-node in <dir> (it would hold port 4711)`; `install: removed <dir> from the user PATH (an older zyggy; its files are kept - …)`; a `install: warning: <dir> holds an older zyggy …` line means that folder stays on the PATH (see the refusals below).
- `install: copied zyggy.exe and zyggy-node.exe to %LOCALAPPDATA%\Programs\Zyggy`, the user PATH line and `install: session PATH: <programs> first`.
- `install: node.json: written (…)` or `install: node.json: exists, left untouched (…)`; `install: git:` the version; `install: checkout:` the clone holds `tenants\acme`.
- The `setup:` lines, one per item, `setup: <item>: <outcome>[ - <detail>]` with the outcomes `done`, `already done`, `left as is`, `missing` and `failed`, in this order: `node.json`, `zyggy-core`, `settings` (twice: the env value, the deny rules), `skill remember`, `skill archive`, `signing key acme/<n>`, `github-pat`, and `spike file store` only when one is left on the laptop. A changed file names its backup (`.bak-<yyyyMMddTHHmmssZ>` beside it; a replaced skill under `<LocalAppData>/zyggy/backup/<stamp>/skills/`).
- `install: claude:` the absolute `claude.path`; `install: task: registered zyggy-node …` and `install: task: Running`; `install: status:` the first line of `zyggy status`.
- `install: reopen: terminals, VS Code windows and Claude Code sessions opened before this install still have the old PATH and environment - close and reopen them (VS Code: all windows)` — the last line, followed only by the `incomplete` line below when setup was incomplete.
- `install: incomplete - see the setup lines above` — setup exit 6 (`zyggy-core`, the settings or a skill failed, or `github-pat` is missing): the task runs, the script exits 1; fix the `setup:` line, then run the script again. Setup exit 3 (`node.json` refused) or 4 (signing key missing) ends the run with `install: FAILED - …` before the task.

### Laptop refusals

One entry per refusal the script or `zyggy setup` can print; the remedies are `node/README.md` "Runbook entries" (and the zyggy Cli README "Troubleshooting — Setup"). After each fix, run the same command again.

- **Old zyggy still on PATH** — `install: warning: <dir> holds an older zyggy …` or `could not remove <dir> from the user PATH`. If the installer warns that an older zyggy folder also holds other files (a mixed folder, left on the PATH), move the non-zyggy files out of that folder and run `install.ps1` again. Otherwise edit the user PATH by hand (`rundll32 sysdm.cpl,EditEnvironmentVariables`); a machine PATH entry needs whoever administers the laptop.
- **Old node holds port 4711** — `install: FAILED - the older zyggy-node (pid <id>) in <dir> could not be stopped`: `Stop-Process -Id <id> -Force`.
- **`node.json` refused by setup** — `setup: node.json: failed - …`: restore `node.json` from its `.bak-…` copy or fix the key named; another tenant or machine: rerun with the file's values; `signWith missing`: rerun with `-SignWith acme/<n>`.
- **Signing key missing** — `setup: signing key acme/<n>: missing - …`: the secrets step above.
- **GitHub token missing** — `setup: github-pat: missing - run: zyggy secret set github-pat`: the secrets step above; the task polls by safety fetch until then.
- **Spike file store left on the laptop** — `setup: spike file store: left as is - …`: `rotate-hmac.md` step 0, then delete the folder by hand.
- **Claude settings not valid JSON — left untouched** — `setup: settings: failed - …`: fix or restore `settings.json` (or the `ZYGGY_SECRET_PATTERNS` value it names).
- **zyggy-core clone fails behind the proxy** — `setup: zyggy-core: failed - fatal: …`: `git config --global http.proxy http://<host>:<port>`.
- **zyggy-core path taken** — `setup: zyggy-core: failed - <path> is not a git checkout` or `… has origin …`: rerun with `-CorePath <another folder>`, or move the folder.
- **zyggy-core not updated** — `setup: zyggy-core: left as is - <reason>`: `git -C C:/agents/zyggy-core status`, bring it back to a clean `main`.
- **No `claude.exe` found** — `install: FAILED - claude.path (…) does not exist`: install Claude Code for this user (`setup` looks on the PATH and in `<UserProfile>\.local\bin\claude.exe`), or set `claude.path` in `node.json`.
- **PATH or settings not seen** — close and reopen; VS Code fully restarted.

The logon task `zyggy-node`: starts at this user's logon after 30 s in the interactive session (the one with the Claude login, the browser and the Credential Manager), hidden window, one instance, no time limit, restart on failure three times a minute apart, allowed on battery. `Start-ScheduledTask zyggy-node` starts it by hand. A stop is a kill, and `Stop-ScheduledTask zyggy-node` alone ends only the task's `powershell.exe` wrapper — `zyggy-node.exe` can survive it, keep port 4711 and block an upgrade's copy (seen 2026-10-26). Stop the node with both lines: `Stop-ScheduledTask zyggy-node; Get-Process zyggy-node -ErrorAction SilentlyContinue | Stop-Process -Force` (the installer's own stop does the same and waits). The node's claim resume covers an interrupted run on the next start. Nothing runs while the user is logged off: expected, not a fault.

### The second laptop

The same script, the same steps; it needs no administrator. If a policy forbids per-user scheduled tasks the script fails with `Access is denied` and names the alternative: a shortcut in `shell:startup` to the same `powershell.exe` command (the `task:` line prints it); no elevation anywhere.

### Credential Manager under the task

The task runs with the user's interactive token, so the node reads the same vault `zyggy secret set` wrote. A `secret store unavailable: credential-manager: 1312 …` under the task would be a finding to report (`bugfix`), not an expected state — 1312 belongs to session-0 services, which Zyggy does not use.

### URL and port

`http://localhost:4711/health` is loopback only on both machines: never a firewall rule, never a URL ACL, never exposed. `refusing to start: health port 4711 in use` → `[home-laptop]` `netstat -ano | findstr :4711`, `[central]` `ss -tlnp | grep 4711`; one node per machine.

### Exit codes

| Code | Meaning | systemd (`zyggy-node.service`) | Task Scheduler (`zyggy-node`) |
|------|---------|-------------------------------|-------------------------------|
| 0 | a clean stop | `inactive` | Last Run Result 0x0 |
| 3 | `node.json` refused (stderr names the key) | `failed`, **no** restart | 0x3; re-run up to three times, then rests |
| 6 | a start-up refusal (one `refusing to start:` line) | `failed`, **no** restart | 0x6; the same |
| 1 | a fault | restart after 30 s, at most 5 in 10 min | 0x1; the same |

`[central/<vm-admin>]` `journalctl -u zyggy-node -n 200`; after the fix `systemctl reset-failed zyggy-node && systemctl start zyggy-node`. `[home-laptop/user PowerShell]` the log under `%LOCALAPPDATA%\zyggy\logs\`; after the fix `Start-ScheduledTask zyggy-node`.

### `GCM_INTERACTIVE` and `BatchMode`

The task's command sets `GCM_INTERACTIVE=never` for the node process only: a hidden credential prompt would otherwise wedge the poll loop. Run `git -C C:/agents/bus push --dry-run` once in your own shell so Git Credential Manager stores the token; after a token change, run it again. On Central the unit sets `GIT_SSH_COMMAND=ssh -o BatchMode=yes`: ssh never prompts, a missing deploy key fails fast and the node reports `push deferred`.

### Laptop power and logon

The node runs only while the user is logged on and the machine is awake; a laptop closed at 19:00 answers nothing until the next logon. Central carries the always-on role.

## Uninstall

`[home-laptop/user PowerShell]` `.\install.ps1 -Tenant acme -Machine home-laptop -Uninstall`: stops and unregisters the task; the binaries, `node.json`, the checkout and the secrets stay (remove them by hand; `zyggy secret remove <name>` for each secret). `[central/<vm-admin>]` `systemctl disable --now zyggy-node`; `rm /etc/systemd/system/zyggy-node.service` and the drop-in directory; `systemctl daemon-reload`.

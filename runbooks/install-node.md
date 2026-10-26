# install-node.md — the Zyggy node on Central and on a laptop

Placeholders only: tenant `acme`, machines `central` and `home-laptop`, `<zyggy-home>` the service user's home, `<vm-admin>` the VM's administrator account, `<version>` the release. Every command is prefixed with the machine and the user that runs it. An instance records its filled-in evidence in its private repository, never here.

The files this runbook copies ship in every release under `artifacts/<rid>/deploy/` (`zyggy-node.service`, `zyggy-node.service.d/credentials.conf.example`, `install.ps1`, `README.md`), listed in `SHA256SUMS` next to the two binaries.

## Central

1. `[central/<vm-admin>]` Download the `linux-x64` release folder and check it: `sha256sum -c SHA256SUMS` must print `OK` for `zyggy`, `zyggy-node` and the four `deploy/…` files.
2. `[central/<vm-admin>]` `install -o root -g root -m 755 -D zyggy-node /opt/zyggy/<version>/zyggy-node`, the same for `zyggy`; `ln -sfn /opt/zyggy/<version>/zyggy-node /usr/local/bin/zyggy-node` and `ln -sfn /opt/zyggy/<version>/zyggy /usr/local/bin/zyggy`. The unit runs the symlink, so an upgrade is a new folder and a new link.
3. `[central/zyggy]` `node.json` at `~/.config/zyggy/node.json`: `tenant`, `machine: central`, `signWith: acme/<n>`, `bus` (`remote: git@github.com-zyggy-bus:zyggy-org/zyggy-bus.git`, `owner`, `repo`, `branch: main`, `localPath` = the checkout), `poll`, **no** `workHours` (Central is always inside work hours), `claude.path` absolute (`<zyggy-home>/.local/bin/claude`; a unit has no user `PATH`), `secrets: { "store": "os" }`. Never a secret in it: the reader refuses any key named like one.
4. `[central/zyggy]` The keys: `zyggy secret list --config ~/.config/zyggy/node.json` must show `hmac/<n>` with role `signs` and `github-pat`. If not: `zyggy secret set hmac/<n> --hex` (paste the tenant's key at the hidden prompt) and `zyggy secret set github-pat`; compare the fingerprint of `hmac/<n>` with the other machines. The node's own refusals say the same: `refusing to start: signing key acme/<n> is not in the file; run: zyggy secret set hmac/<n> --hex` and `refusing to start: secret store unavailable: <detail> — see README "Secrets: store unavailable"` (a corrupt file or a credentials-directory file with the wrong mode or owner; the detail names the path).
5. `[central/<vm-admin>]` `cp deploy/systemd/zyggy-node.service /etc/systemd/system/zyggy-node.service`; `systemctl daemon-reload`; `systemctl enable --now zyggy-node`.
6. `[central/<vm-admin>]` Checks: `systemctl is-active zyggy-node` → `active`; `journalctl -u zyggy-node -n 50` shows `node started: tenant acme, machine central`, `health endpoint listening` and `claude auth ok`, no `[ERR]`; `[central/zyggy]` `zyggy status` → `health: green`; `curl -s http://localhost:4711/health` answers JSON. A `failed` unit with exit 3 or 6 is a human's turn: read the one `refusing to start:` line (exit codes below), fix, `systemctl reset-failed zyggy-node && systemctl start zyggy-node`.

### Bus secrets: file layer or credentials directory

The node's store on Linux has two layers (zyggy README "Troubleshooting — Secrets"): the credentials directory systemd fills from `LoadCredential=` lines, read first and read-only, then the 0600 files under `<zyggy-home>/.local/share/zyggy/secrets/acme/`. **The default is the file layer**: one source for the unit and for every shell command (`zyggy submit`, `verify`, `secret`), nothing to keep in step.

Choose the drop-in when the unit's copy should be root-owned and read-only — a source under `/etc/credstore/` that the `zyggy` user, and so the model's `Bash`, cannot read, overwrite or delete. Its costs: two sources to keep equal (the shell commands still sign with the file layer), one drop-in edit per rotation, and a restart to pick a change up.

- Enable: `[central/<vm-admin>]` `mkdir -p /etc/systemd/system/zyggy-node.service.d`; copy `deploy/systemd/zyggy-node.service.d/credentials.conf.example` to `…/credentials.conf`, replace `<zyggy-home>` (or point the sources at root-owned 0600 files under `/etc/credstore/`); `systemctl daemon-reload && systemctl restart zyggy-node`.
- Verify: `systemctl show -p LoadCredential zyggy-node` lists the two ids `zyggy.acme.hmac.<n>` and `zyggy.acme.github-pat`; inside the unit `zyggy secret list` shows store `credentials-directory` for both, outside the unit it shows `file`; `zyggy secret set` for a name the directory also provides prints `note: the credentials directory still provides <name> to the node`.
- Disable: remove `credentials.conf`, `systemctl daemon-reload && systemctl restart zyggy-node`.
- Not done here: `ProtectHome`/`ProtectSystem=strict` sandboxing would need a `ReadWritePaths=` list that changes with every project; deferred.

### Upgrade

- `[central/<vm-admin>]` `systemctl stop zyggy-node`; the new `/opt/zyggy/<version>/`; switch both symlinks; `systemctl start zyggy-node`; `curl -s http://localhost:4711/health` shows the new `version`. `zyggy status` on a machine whose `zyggy` is older prints `health: amber — node <v>, cli <v>` until the CLI is upgraded too.
- `[home-laptop/user PowerShell]` Run `install.ps1` again from the new release folder: it stops the task, replaces the binaries, keeps `node.json`, re-registers the task and starts it.

## Laptop (no administrator needed)

Prerequisites: Git for Windows (Git Credential Manager is its default helper) and Claude Code logged in as this user. The owner is not an administrator on every laptop; nothing below needs it, and the script refuses rather than asks for elevation.

1. `[home-laptop/user PowerShell]` Unpack the `win-x64` release folder (`zyggy.exe`, `zyggy-node.exe`, `SHA256SUMS`, `deploy\`).
2. `[home-laptop/user PowerShell]` `git clone https://github.com/zyggy-org/zyggy-bus.git C:\agents\bus`; `git -C C:\agents\bus config core.autocrlf false`; `git -C C:\agents\bus push --dry-run` once so Git Credential Manager asks for the token and stores it (see "`GCM_INTERACTIVE` and `BatchMode`").
3. `[home-laptop/user PowerShell]` `zyggy secret set hmac/<n> --hex` (paste the tenant's key at the hidden prompt) and `zyggy secret set github-pat` — the store is the Credential Manager of this user; `zyggy secret list` must show the same fingerprint for `hmac/<n>` as Central.
4. `[home-laptop/user PowerShell]` `.\deploy\windows\install.ps1 -Tenant acme -Machine home-laptop -SignWith acme/<n>` from the release folder.

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-Tenant`, `-Machine` | required | `node.json` `tenant` and `machine` |
| `-SignWith acme/<n>` | required when `node.json` is written | `node.json` `signWith` |
| `-BusLocalPath` | `C:\agents\bus` | the checkout (forward slashes in the file) |
| `-Source` | the script's folder | where `zyggy.exe`, `zyggy-node.exe`, `SHA256SUMS` are |
| `-NodeJson` | `%LOCALAPPDATA%\zyggy\node.json` | written only when absent |
| `-Uninstall` | — | stop and unregister the task; leaves everything else |

What the lines mean: `checksum ok` (SHA256SUMS verified before anything was copied); `copied … to %LOCALAPPDATA%\Programs\Zyggy` and the user PATH line; `node.json: written` or `exists, left untouched`; the pre-flight — `git:` the version, `checkout:` the clone holds `tenants\acme`, `secrets:` the signing key shows as `signs` (else the remedy `zyggy secret set hmac/<n> --hex`; the line `rotate-hmac.md step 0 retires the spike file store` means `secrets.store: file` is still selected), `claude:` the absolute `claude.path`; `task: registered zyggy-node` and `task: Running`; the first line of `zyggy status`.

The logon task `zyggy-node`: starts at this user's logon after 30 s in the interactive session (the one with the Claude login, the browser and the Credential Manager), hidden window, one instance, no time limit, restart on failure three times a minute apart, allowed on battery. `Start-ScheduledTask zyggy-node` / `Stop-ScheduledTask zyggy-node` start and stop it by hand; a stop is a kill of the process tree — the node's claim resume covers an interrupted run on the next start. Nothing runs while the user is logged off: expected, not a fault.

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

The task's command sets `GCM_INTERACTIVE=never` for the node process only: a hidden credential prompt would otherwise wedge the poll loop. Run `git -C C:\agents\bus push --dry-run` once in your own shell so Git Credential Manager stores the token; after a token change, run it again. On Central the unit sets `GIT_SSH_COMMAND=ssh -o BatchMode=yes`: ssh never prompts, a missing deploy key fails fast and the node reports `push deferred`.

### Laptop power and logon

The node runs only while the user is logged on and the machine is awake; a laptop closed at 19:00 answers nothing until the next logon. Central carries the always-on role.

## Uninstall

`[home-laptop/user PowerShell]` `.\install.ps1 -Tenant acme -Machine home-laptop -Uninstall`: stops and unregisters the task; the binaries, `node.json`, the checkout and the secrets stay (remove them by hand; `zyggy secret remove <name>` for each secret). `[central/<vm-admin>]` `systemctl disable --now zyggy-node`; `rm /etc/systemd/system/zyggy-node.service` and the drop-in directory; `systemctl daemon-reload`.

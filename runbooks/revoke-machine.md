# revoke-machine.md — a lost or compromised machine

Placeholders only (`acme`, `home-laptop`, `central`, `<vm-admin>`). The other machines of the tenant keep running throughout (founding spec §5): nothing here stops Central or the remaining laptops.

1. `[any browser, the owner]` Revoke the machine's credentials on GitHub: its fine-grained PAT (a laptop) or delete its deploy key (Central). From that moment the machine can neither poll nor push.
2. `[central/zyggy]` then every remaining machine: `rotate-hmac.md`, **compromise variant** — the HMAC key is per tenant, not per machine, so a leaked machine means a leaked key: steps 1–3 immediately, then `zyggy secret remove hmac/<n>` everywhere. Files the lost machine signed before the rotation become `unknown_key (acme/<n>)` in `zyggy verify`; expected and recorded.
3. If the machine is still in hand: `[home-laptop/user PowerShell]` `.\install.ps1 -Tenant acme -Machine home-laptop -Uninstall`, `zyggy secret remove` of every name `zyggy secret list` shows, delete `C:/agents/bus` and `%LOCALAPPDATA%\Programs\Zyggy`; `[central/<vm-admin>]` `systemctl disable --now zyggy-node` and the same removals as `zyggy`.
4. `[central/zyggy]` In the bus checkout, one commit: `git mv tenants/acme/nodes/home-laptop tenants/acme/archive/nodes/home-laptop` (the folder keeps its history; `zyggy verify` skips `archive/` until deliverable 17 reads it), commit subject `acme revoke home-laptop`, push.
5. `[central/zyggy]` `zyggy verify` on a remaining machine → the only `FAIL` lines are the `unknown_key` ones of step 2; `zyggy status` shows the remaining machines only.
6. The machine's registry file (deliverable 14) is removed in the same way once the registry exists.

Record the date, the machine and which steps ran in the instance's private repository.

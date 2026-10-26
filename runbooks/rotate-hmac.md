# rotate-hmac.md — a new signing key for one tenant

Drafted by deliverable 09, filed here by deliverable 10. For one tenant; other tenants are unaffected. `<n>` is the current key number, `<n+1>` the new one. Retired keys stay verify-only (founding spec §4 as amended). Commands run as the service user: `[central/zyggy]` on Central, `[home-laptop/user PowerShell]` on a laptop.

1. On one machine of the tenant (Central): `zyggy secret set hmac/<n+1> --generate --show`. Copy the hex line to a channel you trust (never a repository, chat log or ticket); it is shown once.
2. On every other machine of the tenant: `zyggy secret set hmac/<n+1> --hex` — paste at the hidden prompt. `zyggy secret list` on each machine: the fingerprints of `hmac/<n+1>` must match everywhere.
3. On every machine: set `"signWith": "<tenant>/<n+1>"` in `node.json`; restart `zyggy-node`. When the credentials drop-in is in use on Central, also update the drop-in's `hmac/<n+1>` line and `systemctl daemon-reload && systemctl restart zyggy-node`. From now on new files carry `key_id: <tenant>/<n+1>`; files signed with `<tenant>/<n>` keep verifying because the key is still present.
4. After 7 days: nothing to remove. `hmac/<n>` stays in every store as a verify-only key (`zyggy secret list` shows it as `verify-only`) so that `zyggy verify`, the node's start-up re-verification of `jobs/claimed/` and the dream's reading of `archive/` keep accepting the older files.
5. **Compromise variant** (a machine or a key leaked): do steps 1–3 immediately, then `zyggy secret remove hmac/<n>` on every machine. `zyggy verify` will report `unknown_key (<tenant>/<n>)` for every file signed before the rotation; that drift is expected and documented in the audit (08). Follow `revoke-machine.md` for the machine's PAT and deploy key.

**First execution — retire the spike file store (O20)**, on every Windows machine of the tenant, before step 1: `Get-Content "$env:LOCALAPPDATA\zyggy\secrets\<tenant>\hmac\1" | zyggy secret set hmac/1 --hex` and `Get-Content "$env:LOCALAPPDATA\zyggy\secrets\<tenant>\github-pat" | zyggy secret set github-pat --hex` (the spike files hold hex); `zyggy secret list` shows store `credential-manager` for both; remove `"store": "file"` from `node.json` if present; delete `%LOCALAPPDATA%\zyggy\secrets`. Then run steps 1–4 so the keys that once sat in files are no longer the signing keys. Central keeps its 0600 file store — nothing to migrate there.

## Executions

| Date | Tenant | Variant | Why |
|------|--------|---------|-----|
| `<date>` | `acme` | compromise variant with the cleanup commit (`acme cleanup P0 probes`) | no real job on the bus yet, so retiring `acme/1` costs nothing; the work laptop keeps a useless `acme/1` and receives `acme/2` in deliverable 20 |

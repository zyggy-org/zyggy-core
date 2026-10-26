# add-tenant.md — a new tenant on the bus

Placeholders only (`<org>` the tenant, `acme` in every example; machines `central`, `home-laptop`). One bus repository per tenant (founding spec §13).

1. `[any browser, the owner]` Create the private repository `<org>-bus` (for `acme`: `zyggy-org/zyggy-bus`). Where the plan allows it, a ruleset on `main` blocking force-push and deletion. **F1**: rulesets and classic branch protection need a paid plan on a private repository — recorded as a deviation in the transport decision record, accepted 2026-10-15, extended 2026-10-26 until the hardening deliverable (20); the bus code has no force path and every clone holds the full history.
2. `[central/zyggy]` The first commit: `.gitattributes` with `* -text` (no checkout ever rewrites an envelope's line endings), `PROTOCOL.md` (a placeholder until deliverable 15 makes it verbatim), `tenants/<org>/nodes/<machine>/{jobs,jobs/claimed,jobs/rejected,reports,context}` for every machine, `tenants/<org>/registry/` and `tenants/<org>/archive/`, each with a `.gitkeep`; `policy.yaml` at the tenant root stays unsigned until deliverable 18 (`zyggy verify` skips it).
3. `[any browser, the owner]` Per-machine credentials: a fine-grained PAT per laptop scoped to that one repository (Contents read and write; the API head check needs Contents read); a write deploy key for Central.
4. `[central/zyggy]` `zyggy secret set hmac/1 --generate --show` once; carry the hex to every other machine of the tenant over a channel you trust and enter it there with `zyggy secret set hmac/1 --hex`; `zyggy secret list` on each machine must show the same fingerprint. `zyggy secret set github-pat` on every laptop.
5. `[every machine]` `node.json` per `install-node.md` with `tenant: <org>`; `zyggy verify` → `0 failed; 1 tenant directory`; `zyggy status` green.
6. Later deliverables: `memory/<org>/<user>/` in the memory repository (11), the notifier (22).

**First execution**: 2026-10-13 for `acme` / `zyggy-bus`, with the F1 deviation of step 1; placeholders only here, the evidence in the instance's private repository.

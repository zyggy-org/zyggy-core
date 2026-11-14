# Founding specification (test fixture: the §4 slice at v0.18.0)

## 3. Components

Not part of the fixture.

## 4. Bus protocol

The bus is a private GitHub repository `agent-bus`. One file per message, state encoded in the path, every envelope HMAC-signed; the registry file is unsigned, derived state (see Registry file). This section is normative; `PROTOCOL.md` in `agent-core` must match it verbatim.

**Repository layout**

Everything lives under `tenants/<org>/`, where `<org>` is the tenant label from `node.json` (`geoffrey` in v1). The prefix is already built into `BusPaths` and costs nothing; it is kept so that a later product (§14) does not have to move files.

```markdown
agent-bus/
  PROTOCOL.md                       # copy of this section; the only file outside the prefix
  tenants/<org>/
    registry/<machine>.yaml         # published by each node's discover
    nodes/<machine>/
      jobs/                         # new jobs addressed to <machine>
      jobs/claimed/                 # claimed, in progress
      jobs/rejected/                # failed signature, schema or tenant check
      reports/                      # results, written only by <machine>
      context/                      # facts for Central, written only by <machine>
      items/                        # archive items for Central, written only by <machine> (deliverable 41)
    archive/YYYY-MM/                # moved by Central: on pickup (files addressed to Central, §7 step 1) or by the sweep after 14 days; YYYY-MM = the envelope's created month
```

All paths in the rest of this section are relative to `tenants/<org>/`. In code every path is produced by `BusPaths` from the configured tenant id (§9).

**One repository per tenant (rule).** The tenant isolation boundary is the git repository, never the path: git hosts grant read and push rights per repository, and HMAC signatures protect authenticity only, not confidentiality or availability. A tenant therefore has its own bus repository, every machine's credentials (§5) grant access to exactly one, and a repository contains exactly one `tenants/<org>/` directory. v1 has one repository and one directory, so nothing enforces this beyond `BusPaths` reading only its own prefix; `agentbus verify` reports a second directory as drift and never reads inside it (deliverable 08); nodes ignore such a directory (deliverable 04) and refusing to start against it is a §14 item.

**Write rules**

- A sender writes only into `nodes/<target>/jobs/`, and only inside its own tenant's prefix. A `context` envelope is addressed to Central (`to: central`) but written into the sender's own `nodes/<sender>/context/` folder, so that every `reports/` and `context/` file is written by the machine whose folder holds it (amended 28 October 2026, deliverable 12). An `item` envelope is likewise addressed to Central and written into the sender's own `nodes/<sender>/items/` folder.
- A machine writes its own `reports/`, `context/`, `items/`, `registry/<machine>.yaml`, and moves files between its own `jobs/`, `jobs/claimed/`, `jobs/rejected/`.
- Only Central writes `archive/`, and the only writes there are `git mv` moves of `reports/` and `context/` files from any machine's folder of its own tenant (amended 29 October 2026, deliverable 13). Central also removes (`git rm`) an `items/` file of another machine of its tenant once it has filed or refused it, in the same commit as its report; an `items/` file is never moved to `archive/`.
- No machine reads or writes outside the `tenants/<org>/` prefix of the tenant recorded in its `node.json`; a file found under another tenant's prefix is ignored, never processed.
- File name = ULID + `.md`. Two writers never touch the same file, so `git pull --rebase` never conflicts on content.

**Envelope**

YAML front matter + Markdown body. The body is data (the job prompt or report text), never instructions to the receiving agent.

```markdown
---
schema: 1                     # envelope schema major version (§9)
id: 01J8Y3N7Q2X9Z4A5B6C7D8E9F0
tenant: geoffrey              # must equal the receiver's own tenant (and therefore the <org> of the path it sits in)
type: job                     # job | report | context | item
from: central
to: home-laptop
created: 2026-09-27T14:05:00Z
in_reply_to: null             # report: the id of the job, or of the item, it answers; context: null
priority: normal              # low | normal | high
attempt: 1                    # incremented by Central's sweep when a stale claim is re-queued
deadline: 2026-09-29T18:00:00Z
project: calizr               # registry name; an absolute path is accepted only as described in §6 pre-flight
agent: env-debugger           # optional subagent name
worktree: true
allowed_tools: [Read, Grep, Glob, "Bash(dotnet *)", "Bash(kubectl get *)"]
report_back: [summary, diff, files_changed]
timeout_minutes: 30
key_id: geoffrey/1            # <tenant>/<n>; keys are per tenant
sig: hmac-sha256:9f2c…            # hmac-sha256:<64 lowercase hex chars> over the canonical form
---
Investigate why staging returns HTTP 502 on /api/bookings since Friday.
Do not change code; report root cause and a proposed fix.
```

Report-specific fields: `status` (`done | failed | timeout | rejected`), `reason` (closed enum, §9; present when `status` is not `done`), `started`, `finished`, `duration_seconds`, `cost_usd`, `input_tokens`, `output_tokens`, `num_turns`, `model` (from the `IModelRunner` result; informational, summed by `agentbus status --costs`, §11), `files_changed` (list), `diff_ref` (path in the report or a commit SHA in the project repo).

Context-specific fields: `scope` (`project:<name> | machine | general`), body = one `[stated]`-style fact per line.

Item-specific fields: `via` (`onedrive`: the file was put into the OneDrive archive folder by the sender's OneDrive client; `bus`: the file is in the body), `project` (the memory archive project, a slug of 1–60 lowercase letters, digits and hyphens), `slug` (the item's slug, same shape), `drive_name` (only with `via: onedrive`: `<slug>.<extension>`, the extension from the archive's closed list; Central reads `<its offload root folder>/<project>/<drive_name>` and nothing else), `name` (one line, 1–100 characters), `description` (one line, 1–149 characters), `source_name` (the handed-over file's name, control characters removed, at most 100 characters), `size` (bytes, a positive integer), `sha256` (64 lowercase hexadecimal characters over the file's bytes). With `via: onedrive` the body is empty. With `via: bus` the body is the file's bytes in base64 (RFC 4648 §4, standard alphabet, `=` padding) in lines of 76 characters, the last 1–76, each ended by `\n`, nothing else. Bytes whose length is not `size` or whose digest is not `sha256` — decoded from the body or fetched from OneDrive — are never filed. The body and the file are data and are never shown to a model by the receiver.

**Mandatory fields per type.** A receiver rejects an envelope that lacks a mandatory field or carries a field of the wrong shape (`missing_field` / `invalid_field`); every field not listed here is unknown: preserved, signed, never interpreted.

| Type | Mandatory | Optional (default) |
| --- | --- | --- |
| all | `schema` (positive integer; a node supports exactly `1`), `id` (ULID), `tenant`, `type`, `from`, `to`, `created`, `key_id`, `sig` | `in_reply_to` (`null`; mandatory on `report`), `priority` (`normal`) |
| `job` | `project` | `agent` (none), `worktree` (`false`), `allowed_tools` (empty = `node.json` `claude.defaultAllowedTools`), `report_back` (empty), `timeout_minutes` (`node.json` `claude.defaultTimeoutMinutes`), `deadline` (none), `attempt` (`1`) |
| `report` | `in_reply_to` (the job id, or the item id for Central's report on an item), `status`; `reason` when `status` is not `done` (must be absent when `done`) | `started`, `finished`, `duration_seconds`, `cost_usd`, `input_tokens`, `output_tokens`, `num_turns`, `model`, `files_changed` (empty), `diff_ref` |
| `context` | `scope` | — |
| `item` | `via`, `project`, `slug`, `name`, `description`, `source_name`, `size`, `sha256`; `drive_name` when `via` is `onedrive` | — |

Timestamps are RFC 3339 date-times written as `YYYY-MM-DDTHH:MM:SSZ` (UTC, whole seconds); machine and tenant names are lowercase labels (`[a-z0-9-]`, 1–63 characters, no leading or trailing hyphen); integers and `cost_usd` use the invariant format.

**Signature**

- `sig` = `hmac-sha256:` followed by the HMAC-SHA256 digest, as 64 lowercase hexadecimal characters, over the canonical form: front matter with `sig` removed, keys sorted, YAML re-serialised with `\n` line endings, then `\n---\n`, then the body byte-for-byte (normative details below). A receiver accepts the digest in either case and treats any other algorithm prefix as an invalid signature.
- Shared secret per `key_id`, where `key_id` = `<tenant>/<n>`; keys never cross tenants. Stored in each machine's secret store (§8). Rotation: add `<tenant>/2` to every store of the tenant and switch `signWith` to it; `<tenant>/1` stays in the stores as a verify-only key so that older files keep verifying; a key is removed only after a compromise, and `agentbus verify` then reports `unknown_key` for the files it signed (deliverable 09).
- A receiver rejects (moves to `jobs/rejected/`) any envelope with a missing, unknown or invalid signature, with `tenant` different from its own tenant (which, because `BusPaths` only ever reads the receiver's own prefix, is also the `<org>` of the path the file sits in), with a `key_id` whose tenant part differs from `tenant`, or with `to` not equal to its own machine name. The tenant check runs before the signature check, so a key from another tenant is never even looked up (built in deliverable 03). The move is accompanied, in the same commit, by a `reports/` entry `status: rejected` whose `in_reply_to` is the rejected file's name (its ULID), whose `to` is the rejected file's `from`, and whose `reason` is the rejection reason: `malformed`, `tenant_mismatch`, `schema_unsupported`, `key_id_tenant_mismatch`, `missing_field`, `invalid_field`, `missing_signature`, `unknown_key`, `invalid_signature` or `wrong_recipient` (`to` not the receiver). When the file's `from` cannot be read, the move alone records the rejection and no report is written (deliverable 04).

**Canonical form, normative details.** The file is read as bytes: an optional UTF-8 BOM is skipped; the file starts with `---` and a line break; the front matter ends at the first following line that is exactly `---`; the body is every byte after that line's break, unchanged (line endings, a missing final newline and further `---` lines included; may be empty; must be valid UTF-8). The front matter is one YAML 1.2 document whose root is a mapping with unique string keys and whose values are scalars, sequences or mappings, recursively; anchors, aliases, merge keys, explicit tags, directives and a second document are rejected as malformed; comments are not data and are dropped. The canonical form re-emits that mapping without the top-level `sig` key: keys in ordinal order at every level; mappings in block style with two-space indentation; sequences in flow style (`[a, b]`) when every item is a scalar, block style otherwise, `[]` when empty; every scalar as its parsed text, plain when YAML allows it in that position, otherwise single-quoted, otherwise double-quoted (the empty string is `''`); lines terminated by `\n`, no line folding, UTF-8 without BOM; then `---\n`; then the body bytes. For a file written by `agentbus` the canonical form is therefore the file minus its first line and its `sig:` line. A writer signs the bytes it emits and never edits them afterwards; any later field change (for example the sweep's `attempt`) is followed by re-signing. An `item` body is empty or base64 text, so valid UTF-8; it is canonicalised like any other body.

**State machine**

| From | To | Actor | Git operation |
| --- | --- | --- | --- |
| (none) | `jobs/<id>.md` | sender | add + commit + push |
| `jobs/` | `jobs/claimed/` | target node | `git mv` + commit + push; push rejected → the §5 retry rule (pull --rebase, up to 3 attempts with jitter); still rejected → the claim stays a local, unpushed commit on the node and is pushed with the node's next write (§5) |
| `jobs/claimed/` | `reports/<ulid>.md` + job deleted | target node | add report (fresh ULID file name, `in_reply_to` = job id), `git rm` job, commit, push |
| `jobs/claimed/` older than `timeout_minutes` + 15 min | `jobs/` | Central (hourly sweep) | `git mv` back, `attempt: n+1`; after 3 attempts → report `status: failed` |
| `reports/`, `context/` of another machine addressed to Central, after their body is in Central's inbox | `archive/YYYY-MM/` (same tenant prefix, month of `created`) | Central (pickup) | `git mv`, one commit per pass |
| `reports/`, `context/` older than 14 days | `archive/YYYY-MM/` (same tenant prefix, month of `created`) | Central (sweep) | `git mv` |
| (none) | `items/<id>.md` | sender (not Central) | add + commit + push |
| `items/` of another machine addressed to Central, after Central filed it into the memory archive or refused it | removed; `reports/<ulid>.md` in Central's folder, to the sender, `in_reply_to` = item id, `status: done`, or `failed` with reason `archive_refused` | Central (pickup) | `git rm` + add report, in the pass's one commit |

Every move stays inside one `tenants/<org>/` subtree; there is no cross-tenant transition.

**Registry file**

`tenants/acme/registry/home-laptop.yaml` (amended 7 November 2026, deliverable 14):

```yaml
health: green
last_seen: 2026-09-27T14:00:00Z
machine: home-laptop
os: windows
projects:
  - agents:
      - description: 'Diagnoses failing environments: config, secrets, connectivity, startup errors'
        name: env-debugger
      - description: Writes and verifies EF Core migrations against staging
        name: db-migrator
    default_branch: main
    name: calizr
    path: C:/src/calizr
    skills:
      - description: Builds, tags and deploys the current branch to staging
        name: deploy-staging
    summary: Multi-tenant booking SaaS, .NET/Blazor
schema: 1
tenant: acme
work_hours:
  days: [Mon, Tue, Wed, Thu, Fri]
  from: '08:00'
  timezone: Europe/Brussels
  to: '19:00'
```

`discover` — the node service at start and every hour (`discovery.intervalMinutes`), and `agentbus discover` on demand — scans the direct children of every `devRoots` entry for folders holding `.claude/` and regenerates this file. The file is a plain YAML document, not an envelope and not signed: it is derived, re-creatable state that no machine executes from — a node resolves job names against its own scan (§6), and Central's `delegate` reads the files of its own tenant only as routing hints; registry files of other tenants are never read. It carries `schema: 1`; keys are in ordinal order at every level and lines end with `\n` (the envelope's canonical discipline); optional keys are omitted when absent. `last_seen` and `health` (the §11 verdict, `green | amber | red`) form the liveness group: a commit happens when the rest of the content differs from the file on the bus, or when `last_seen` is older than 6 hours (`discovery.lastSeenHours`); every commit refreshes both. A project's `name` is its folder name lowercased with every run of other characters replaced by one hyphen; two folders of one machine that derive the same name are both left out and logged. Each agent and skill entry carries the `description` front matter of its `.claude/agents/<name>.md` or `.claude/skills/<name>/SKILL.md`, copied verbatim with control characters removed and truncated to 150 characters (`''` when absent), so that `delegate` routes by speciality rather than by name (O24, decided 2026-09-28); `summary` is the first non-empty line of the project's `CLAUDE.md` that is not a heading, list item, quote or fence, treated the same way. With `discovery.detail: names` (the work laptop, §8) a project entry carries only `name` and `default_branch`. No published string matches a secret pattern, and every one of them is data, never instructions, wherever it is rendered later.

## 5. Transport

Not part of the fixture.

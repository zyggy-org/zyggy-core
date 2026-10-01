#!/usr/bin/env bats
# m365 connector (spec 23): the pinned server's app-only tool partition and the fixtures (plan 23 Step 1,
# AC-45 half, AC-46). Fixture lists are generated from the pinned package's endpoints.json, never typed. No network.

load helpers

setup() {
  setup_memory
  install_m365_fixture_config
  export HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$XDG_CONFIG_HOME"
  unset CREDENTIALS_DIRECTORY
  M365="$REPO_ROOT/.claude/skills/m365"
  STATE="$XDG_STATE_HOME/zyggy/m365"
  M365_FIXTURES="$FIXTURES/m365"
  ALL="$M365_FIXTURES/tools-0.157.2.txt"
  ENABLED="$M365_FIXTURES/enabled-tools.txt"
  EXCLUDED="$M365_FIXTURES/excluded-tools.txt"
  TOOLS_JSON="$M365_FIXTURES/tools-list-0.157.2.json"
  export M365 STATE
}

# AC-46 after every test: no access token and no private key in any output or any file the test left behind
# (the generated key file itself and the systemd credentials copy are the only sanctioned places).
teardown() {
  local leak='STUBACCESS|BEGIN (RSA )?PRIVATE KEY'
  ! grep -qE "$leak" <<< "${output:-}${stderr:-}" || { echo "token or key in stdout/stderr"; return 1; }
  ! grep -rqsE --exclude=m365-app.key --exclude=m365-app-key "$leak" "$BATS_TEST_TMPDIR" ||
    { echo "token or key in a test file"; return 1; }
}

# The spec's app-only allowlist: the /users/{user-id} mail read tools, the two /users Draft tools, the /drives
# read tools, the file writer and the two /sites/{site-id}/drives read tools (names as endpoints.json has them).
expected_enabled() {
  printf '%s\n' \
    create-shared-mailbox-draft create-shared-mailbox-reply-draft download-bytes-to-file get-drive-delta \
    get-drive-item get-drive-root-item get-shared-mailbox-message get-sharepoint-site-drive-by-id \
    list-drive-item-versions list-folder-files list-shared-mailbox-folder-messages list-shared-mailbox-messages \
    list-sharepoint-site-drives search-onedrive-files | LC_ALL=C sort
}

# --- the tool partition of the pinned version --------------------------------------------------------------

@test "m365: the pinned tool lists partition — enabled ∪ excluded = tools-0.157.2.txt, disjoint, each unique and sorted" {
  local f
  for f in "$ALL" "$ENABLED" "$EXCLUDED"; do
    [ -s "$f" ] || { echo "missing: $f"; return 1; }
    LC_ALL=C sort -uc "$f" || { echo "not sorted or not unique: $f"; return 1; }
    run grep -vE '^[a-z0-9-]+$' "$f"
    [ "$status" -eq 1 ] || { echo "not a bare tool name in $f: $output"; return 1; }
  done
  [ -z "$(LC_ALL=C comm -12 "$ENABLED" "$EXCLUDED")" ] || { echo "enabled and excluded overlap"; return 1; }
  [ -z "$(LC_ALL=C sort -u "$ENABLED" "$EXCLUDED" | LC_ALL=C comm -3 - "$ALL")" ] ||
    { echo "enabled ∪ excluded differs from the pinned list"; return 1; }
  [ $(( $(wc -l < "$ENABLED") + $(wc -l < "$EXCLUDED") )) -eq "$(wc -l < "$ALL")" ]
  [ "$(wc -l < "$ALL")" -gt 300 ]
}

@test "m365: enabled holds exactly the two /users Draft tools, five shared-mailbox tools in total, the drive and site-drive read tools, and no /me, write, send, auth, batch or off-scope tool" {
  local negative me
  cmp <(expected_enabled) "$ENABLED"
  [ "$(grep -c shared-mailbox "$ENABLED")" -eq 5 ]
  [ "$(grep -cE '^create-shared-mailbox-(reply-)?draft$' "$ENABLED")" -eq 2 ]
  [ "$(grep -cE '^create-' "$ENABLED")" -eq 2 ]
  # the negative list derived from tools-0.157.2.txt: every /me family name, every write verb, the auth and batch
  # tools, every Teams/calendar/contacts/To Do/Planner/OneNote/Excel/directory name
  negative='^(send-|delete-|move-|update-|upload-|share-|copy-|forward-|reply-|add-|set-|mark-|format-|sort-|merge-|unmerge-|clear-|insert-|extract-|cancel-|accept-|decline-|archive-|unarchive-|pin-|unpin-|remove-|select-|start-|stop-|complete-|register-|check-)'
  negative="$negative|create-(mail|onedrive|upload|drive-item|excel|chat|team|channel|calendar|event|contact|todo|planner|onenote|sharepoint|shared-mailbox-(reply-all|forward))"
  negative="$negative|-(permission|permissions|preview|thumbnails|share-link|invite|labels)$|download-bytes$|get-download-url$|parse-teams-url$|graph-batch$"
  negative="$negative|chat|team|channel|calendar|event|contact|todo|task|planner|onenote|notebook|workbook|excel|current-user|my-profile|presence|manager|direct-reports|emoji|meeting|recording|transcript|photo|mailbox-settings|people|insight|reminder"
  negative="$negative|list-drives$|list-users$|^(list|get|create)-mail-|^list-mail-|^(login|logout|verify-login|list-accounts|select-account|remove-account)$"
  negative="$negative|^(get|list|search)-sharepoint-(site|sites|site-by-path|sites-delta|site-item|site-items|site-list|site-lists|site-list-item|site-list-items|list-column|list-columns)$"
  run grep -E "$negative" "$ENABLED"
  [ "$status" -eq 1 ] || { echo "off-scope name enabled: $output"; return 1; }
  # every tool whose Graph path starts with /me is excluded (the tools/list fixture carries "<METHOD> <path>")
  me="$(jq -r '.tools[] | select(.description | test("^[A-Z]+ /me([/ ]|$)")) | .name' "$TOOLS_JSON" | LC_ALL=C sort -u)"
  [ "$(printf '%s\n' "$me" | wc -l)" -gt 100 ]
  grep -qx get-current-user <<< "$me"
  grep -qx list-drives <<< "$me"
  [ -z "$(LC_ALL=C comm -23 <(printf '%s\n' "$me") "$EXCLUDED")" ] || { echo "a /me tool is not excluded"; return 1; }
  # every enabled tool reaches Graph on /users/{user-id}/…, /drives/{drive-id}/…, /sites/{site-id}/drives… or is the file writer
  run jq -r --rawfile en "$ENABLED" '($en | split("\n") | map(select(length > 0))) as $e
    | .tools[] | select(.name as $n | $e | index($n))
    | select(.description | test("^(GET|POST) (/users/\\{user-id\\}/|/drives/\\{drive-id\\}|/sites/\\{site-id\\}/drives)|^tool download-bytes-to-file") | not)
    | .name' "$TOOLS_JSON"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "enabled tool off the app-only paths: $output"; return 1; }
  # the only non-GET tools enabled are the two Draft creations
  run jq -r --rawfile en "$ENABLED" '($en | split("\n") | map(select(length > 0))) as $e
    | .tools[] | select(.name as $n | $e | index($n)) | select(.description | test("^GET |^tool ") | not) | .name' "$TOOLS_JSON"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | LC_ALL=C sort)" = "$(printf '%s\n' create-shared-mailbox-draft create-shared-mailbox-reply-draft)" ]
}

@test "m365: tools-list-0.157.2.json names exactly the tools of tools-0.157.2.txt and carries the probed schemas (facts 2, 3, 5)" {
  jq -e '.tools | all(has("name") and has("description") and has("inputSchema")) and (map(.name) | unique | length == length)' \
    "$TOOLS_JSON" > /dev/null
  jq -e '.tools | all(.description | length <= 100)' "$TOOLS_JSON" > /dev/null
  jq -r '.tools[].name' "$TOOLS_JSON" | LC_ALL=C sort > "$BATS_TEST_TMPDIR/names"
  cmp "$BATS_TEST_TMPDIR/names" "$ALL"
  # the schemas kept in full: the folder listing, the two Draft tools, the delta, the file writer, the two site-drive reads
  jq -e '[.tools[] | select(.name | IN("list-shared-mailbox-folder-messages","create-shared-mailbox-draft",
    "create-shared-mailbox-reply-draft","get-drive-delta","download-bytes-to-file","list-sharepoint-site-drives",
    "get-sharepoint-site-drive-by-id"))] | length == 7 and all(.inputSchema.properties | length > 0)' "$TOOLS_JSON" > /dev/null
  # fact 2: the folder listing exposes $filter, $orderby, $top, $select (and the path parameters userId, mailFolderId)
  jq -e '.tools[] | select(.name == "list-shared-mailbox-folder-messages") | .inputSchema.properties
    | has("$filter") and has("$orderby") and has("$top") and has("$select") and has("userId") and has("mailFolderId")' \
    "$TOOLS_JSON" > /dev/null
  # fact 3: the reply Draft takes a Comment or a Message body — no update tool is needed
  jq -e '.tools[] | select(.name == "create-shared-mailbox-reply-draft") | .inputSchema.properties
    | has("userId") and has("messageId") and (.body.properties | has("Comment") and has("Message"))' "$TOOLS_JSON" > /dev/null
  jq -e '.tools[] | select(.name == "create-shared-mailbox-draft") | .inputSchema.properties
    | has("userId") and (.body.properties | has("subject") and has("body") and has("toRecipients"))' "$TOOLS_JSON" > /dev/null
  # fact 5: the delta tool has no token/deltaLink argument (the orchestrator cannot resume a delta through the server)
  jq -e '.tools[] | select(.name == "get-drive-delta") | .inputSchema.properties
    | has("driveId") and has("driveItemId") and has("$select") and ((has("token") or has("deltaLink")) | not)' "$TOOLS_JSON" > /dev/null
  jq -e '.tools[] | select(.name == "download-bytes-to-file") | .inputSchema.properties | has("target") and has("outputPath")' \
    "$TOOLS_JSON" > /dev/null
  jq -e '.tools[] | select(.name == "list-sharepoint-site-drives") | .inputSchema.properties | has("siteId")' "$TOOLS_JSON" > /dev/null
  jq -e '.tools[] | select(.name == "get-sharepoint-site-drive-by-id") | .inputSchema.properties | has("siteId") and has("driveId")' \
    "$TOOLS_JSON" > /dev/null
  # provenance: the fixture names the pinned version and its derivation
  jq -e '.source.package == "@softeria/ms-365-mcp-server" and .source.version == "0.157.2" and (.source.integrity | startswith("sha512-"))' \
    "$TOOLS_JSON" > /dev/null
}

# --- the fixture configuration ----------------------------------------------------------------------------

@test "m365: the fixture m365.json validates (GUIDs incl. sp_object_id; UPN; onedrive_site and sites forms; sites_granted non-empty; cert.expires a date; numbers)" {
  local c="$ZYGGY_M365_CONFIG" guid='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  [ -f "$c" ]
  jq -e 'keys == ["brief","cert","client_id","drives","files_backfill","language","mail_backfill","mailbox","sp_object_id","tenant_id","timezone"]' "$c" > /dev/null
  jq -e --arg g "$guid" '(.tenant_id | test($g)) and (.client_id | test($g)) and (.sp_object_id | test($g))' "$c" > /dev/null
  jq -e '.tenant_id == "11111111-1111-4111-8111-111111111111" and .client_id == "22222222-2222-4222-8222-222222222222"
    and .sp_object_id == "33333333-3333-4333-8333-333333333333"' "$c" > /dev/null
  jq -e '.mailbox == "alice@acme.example" and (.mailbox | test("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"))' "$c" > /dev/null
  jq -e '.timezone == "Europe/Brussels" and .language == "en"' "$c" > /dev/null
  jq -e '.cert == {"subject": "zyggy-central", "days": 398, "expires": "2027-10-01"}' "$c" > /dev/null
  jq -e '.drives | keys == ["exclude_drives","exclude_paths","onedrive_site","sites","sites_granted"]' "$c" > /dev/null
  jq -e '.drives.onedrive_site | test("^[a-z0-9-]+-my\\.sharepoint\\.[a-z.]+:/personal/[A-Za-z0-9_]+$")' "$c" > /dev/null
  jq -e '.drives.sites | length >= 1 and all(test("^[a-z0-9-]+\\.sharepoint\\.[a-z.]+:/sites/[A-Za-z0-9_-]+$"))' "$c" > /dev/null
  jq -e --arg g "$guid" '.drives.sites_granted | length == 2
    and all(split(",") | length == 3 and (.[0] | test("^[a-z0-9.-]+$")) and (.[1] | test($g)) and (.[2] | test($g)))' "$c" > /dev/null
  jq -e '.drives.exclude_drives == [] and .drives.exclude_paths == []' "$c" > /dev/null
  # the caps exactly as the spec block (instance/m365.json contract)
  jq -e '.brief == {"mail_max_items": 60, "reply_cap": 3, "files_max_items": 20, "file_max_bytes": 15728640,
    "file_text_cap_bytes": 20000, "max_turns": 40, "budget_usd": 3.0, "max_facts": 10, "model": ""}' "$c" > /dev/null
  jq -e '.mail_backfill == {"exclude_folders": ["junkemail","deleteditems","drafts","outbox","conversationhistory"],
    "batch_messages": 25, "max_turns": 15, "budget_usd_per_batch": 0.5, "budget_usd_total": 40.0, "max_facts": 3000,
    "max_messages": 0, "model": "sonnet"}' "$c" > /dev/null
  jq -e '.files_backfill == {"batch_files": 10, "max_turns": 25, "file_max_bytes": 15728640, "file_text_cap_bytes": 20000,
    "budget_usd_per_batch": 0.5, "budget_usd_total": 60.0, "max_facts": 3000, "model": "sonnet"}' "$c" > /dev/null
  jq -e '[.brief, .mail_backfill, .files_backfill | .[] | select(type != "string" and type != "array")] | all(type == "number")' \
    "$c" > /dev/null
  # the per-test copy is the fixture, byte for byte
  cmp "$c" "$M365_FIXTURES/m365.json"
}

@test "m365: no GUID but the fixture ones, no real mailbox, site, drive id or machine path under tests/fixtures/m365" {
  run grep -rhoE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$M365_FIXTURES"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | LC_ALL=C sort -u)" = "$(printf '%s\n' \
    11111111-1111-4111-8111-111111111111 22222222-2222-4222-8222-222222222222 33333333-3333-4333-8333-333333333333 \
    aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb cccccccc-cccc-4ccc-8ccc-cccccccccccc \
    dddddddd-dddd-4ddd-8ddd-dddddddddddd)" ] || { echo "unexpected GUID: $output"; return 1; }
  # the machine-path alternatives are composed so that this file passes the same hygiene check (repo.bats)
  local s='/' paths
  paths="${s}srv${s}|${s}home${s}|${s}Users${s}|${s}root${s}|[A-Za-z]:\\\\"
  run grep -rnE "@[a-z0-9-]+\.(com|be|org|net)\b|sharepoint\.com|onmicrosoft|$paths" "$M365_FIXTURES"
  [ "$status" -eq 1 ] || { echo "real-looking value: $output"; return 1; }
}

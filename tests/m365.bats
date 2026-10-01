#!/usr/bin/env bats
# m365 connector (spec 23): the pinned server's app-only tool partition and the fixtures (plan 23 Step 1,
# AC-45 half, AC-46); graph.sh — key pair, app-only token, Graph reads, snapshots (Step 2, AC-30..AC-33, AC-43,
# AC-44); state.sh and the consent files, graph.sh's approved-only write verbs on a pseudo-terminal (Step 3, AC-32,
# AC-37, AC-40, AC-47); the server wrapper (Step 4); propose.sh and the m365-approve.sh consent terminal (Step 5,
# AC-35, AC-36, AC-44, AC-47). Fixture lists are generated from the pinned package's endpoints.json, never typed; the consent
# hashes are computed from the fixture snapshots, never typed. curl is a stub, openssl is real (a throw-away key pair
# per test), the terminal is `script`. No network.

load helpers
load fixtures/m365/pty

setup() {
  setup_memory
  install_m365_fixture_config
  export HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$XDG_CONFIG_HOME"
  unset CREDENTIALS_DIRECTORY ZYGGY_HOOKS
  install_m365_keypair
  install_curl_stub
  M365="$REPO_ROOT/.claude/skills/m365"
  GRAPH="$M365/graph.sh"
  STATE="$XDG_STATE_HOME/zyggy/m365"
  KEY_DIR="$XDG_CONFIG_HOME/zyggy"
  M365_FIXTURES="$FIXTURES/m365"
  GRAPH_FIXTURES="$FIXTURES/graph"
  ALL="$M365_FIXTURES/tools-0.157.2.txt"
  ENABLED="$M365_FIXTURES/enabled-tools.txt"
  EXCLUDED="$M365_FIXTURES/excluded-tools.txt"
  TOOLS_JSON="$M365_FIXTURES/tools-list-0.157.2.json"
  TENANT=11111111-1111-4111-8111-111111111111
  CLIENT=22222222-2222-4222-8222-222222222222
  TOKEN_URL="https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token"
  GRAPH_URL=https://graph.microsoft.com/v1.0
  UPN=alice@acme.example
  STATE_SH="$M365/state.sh"
  PROPOSALS="$STATE/proposals.jsonl"
  APPROVALS="$STATE/approvals.jsonl"
  EXECUTIONS="$STATE/executions.jsonl"
  # the consent hashes, computed from the fixture snapshots (jq -S -c, sha256sum of the line) — never typed
  H1="$(fixture_hash p1)"
  H2="$(fixture_hash p2)"
  H3="$(fixture_hash p3)"
  expect_token_on_stdout=0
  export M365 STATE
}

# AC-46 after every test: no access token and no private key in any output or any file the test left behind (the
# generated key files, the systemd credentials copy and the stub's own fixture copies are the only sanctioned places;
# `graph.sh token` prints the token to stdout by contract — those tests say so with expect_token_on_stdout=1); the
# fixture body marker is never persisted anywhere (it may appear in $output of `graph.sh get` only).
teardown() {
  local leak='STUBACCESS|BEGIN (RSA )?PRIVATE KEY'
  if [ "$expect_token_on_stdout" -eq 1 ]; then
    ! grep -qE 'BEGIN (RSA )?PRIVATE KEY' <<< "${output:-}${stderr:-}" || { echo "key in stdout/stderr"; return 1; }
  else
    ! grep -qE "$leak" <<< "${output:-}${stderr:-}" || { echo "token or key in stdout/stderr"; return 1; }
  fi
  ! grep -rqsE --exclude='m365-app.key*' --exclude=m365-app-key --exclude-dir=fixtures "$leak" "$BATS_TEST_TMPDIR" ||
    { echo "token or key in a test file"; return 1; }
  # pty.out is the terminal: a body may legitimately appear there (never in a file the scripts write)
  ! grep -rqsF --exclude-dir=fixtures --exclude=pty.out BODYTEXT-NEVER-STORED "$BATS_TEST_TMPDIR" || { echo "body text persisted"; return 1; }
  # the three consent files hold no body, no key, no token
  ! grep -qsE "$leak|BODYTEXT-NEVER-STORED" "$STATE"/*.jsonl || { echo "secret or body in a consent file"; return 1; }
}

# --- helpers ------------------------------------------------------------------------------------------------

graph() {
  "$GRAPH" "$@"
}

# graph.sh's stdout byte count instead of its stdout (a token never enters $output); exit status is graph.sh's.
graph_len() {
  graph "$@" | wc -c
  return "${PIPESTATUS[0]}"
}

# One-shot override for the stub: <url-ERE>:<status>[:<body-file>[:<headers-file>]], consumed on first match.
scenario() {
  printf '%s\n' "$1" >> "$CURL_STUB_DIR/curl-stub.scenario"
}

# Mutate the per-test configuration copy with a jq program.
cfg() {
  jq "$1" "$ZYGGY_M365_CONFIG" > "$ZYGGY_M365_CONFIG.tmp"
  mv "$ZYGGY_M365_CONFIG.tmp" "$ZYGGY_M365_CONFIG"
}

requests() { # the stub's request lines (method=… url=… markers)
  if [ -f "$CURL_STUB_LOG" ]; then grep '^method=' "$CURL_STUB_LOG" || true; fi
}

request_count() {
  requests | grep -c . || true
}

urls() { # "<METHOD> <URL>" per request
  requests | sed -E 's/^method=([A-Z]+) url=([^ ]+) .*/\1 \2/'
}

state_snapshot() {
  find "$HOME" "$XDG_STATE_HOME" -printf '%P %y %m\n' 2> /dev/null | sort | md5sum
}

stderr_last() {
  printf '%s\n' "$stderr" | tail -n 1
}

# exit <code>, empty stdout, one stderr line matching <glob>, HOME and the state dir unchanged, no request made
assert_refused() { # assert_refused <code> <stderr glob> <snapshot before>
  [ "$status" -eq "$1" ] || { echo "status $status: $stderr"; return 1; }
  [ -z "$output" ] || { echo "stdout: $output"; return 1; }
  [ "$(printf '%s\n' "$stderr" | wc -l)" -eq 1 ] || { echo "stderr: $stderr"; return 1; }
  # shellcheck disable=SC2053 # $2 is a glob
  [[ "$stderr" == $2 ]] || { echo "stderr: $stderr"; return 1; }
  [ "$(state_snapshot)" = "$3" ] || { echo "HOME or state changed"; return 1; }
  [ "$(request_count)" -eq 0 ] || { echo "a request was made: $(urls)"; return 1; }
}

# A PATH of links to every executable except <name>; the stub directory stays first unless <name> is curl.
path_without() { # path_without <name>
  local dir="$BATS_TEST_TMPDIR/no-$1" f
  mkdir -p "$dir"
  for f in /usr/bin/* /bin/*; do
    if [ -f "$f" ] && [ -x "$f" ] && [ "$(basename "$f")" != "$1" ]; then
      ln -sfn "$f" "$dir/$(basename "$f")"
    fi
  done
  case "$1" in
    curl) printf '%s' "$dir" ;;
    *) printf '%s:%s' "$CURL_STUB_DIR" "$dir" ;;
  esac
}

b64url() { # stdin → base64url without padding
  base64 -w0 | tr '+/' '-_' | tr -d '='
}

b64url_decode() { # b64url_decode <text> → stdout bytes
  local s
  s="$(tr '_-' '/+' <<< "$1")"
  case $((${#s} % 4)) in
    2) s="$s==" ;;
    3) s="$s=" ;;
  esac
  printf '%s' "$s" | base64 -d
}

assertion_header() {
  b64url_decode "$(cut -d. -f1 "$CURL_STUB_DIR/assertion.jwt")"
}

assertion_claims() {
  b64url_decode "$(cut -d. -f2 "$CURL_STUB_DIR/assertion.jwt")"
}

# Verify the saved assertion's signature with the certificate's public key: PSS (PS256) or PKCS#1 v1.5 (RS256).
assertion_verify() { # assertion_verify [pss|pkcs1] [cer] [jwt-file]
  local mode="${1:-pss}" cer="${2:-$ZYGGY_M365_CER_FILE}" jwt
  local -a opts=()
  jwt="$(cat "${3:-$CURL_STUB_DIR/assertion.jwt}")"
  printf '%s' "${jwt%.*}" > "$BATS_TEST_TMPDIR/jwt-input"
  b64url_decode "${jwt##*.}" > "$BATS_TEST_TMPDIR/jwt-sig"
  openssl x509 -in "$cer" -pubkey -noout > "$BATS_TEST_TMPDIR/pub.pem"
  [ "$mode" = pkcs1 ] || opts=(-sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-1)
  openssl dgst -sha256 "${opts[@]+"${opts[@]}"}" -verify "$BATS_TEST_TMPDIR/pub.pem" -signature "$BATS_TEST_TMPDIR/jwt-sig" \
    "$BATS_TEST_TMPDIR/jwt-input" > /dev/null 2>&1
}

x5t() { # x5t <sha1|sha256> [cer] → base64url of the DER digest
  openssl x509 -in "${2:-$ZYGGY_M365_CER_FILE}" -outform DER | openssl dgst "-$1" -binary | b64url
}

fingerprint() { # fingerprint <sha1|sha256> [cer] → hex without colons
  openssl x509 -in "${2:-$ZYGGY_M365_CER_FILE}" -noout -fingerprint "-$1" | cut -d= -f2 | tr -d :
}

# --- consent helpers (the three files live in $STATE, 600 in a 700 directory) ----------------------------------

hash_of() { # hash_of <snapshot json> → the lib's definition: jq -S -c, sha256sum of the line
  printf '%s\n' "$(jq -S -c . <<< "$1")" | sha256sum | cut -c1-64
}

fixture_hash() { # fixture_hash <row id> → hash of that row's snapshot in proposals-pending.jsonl
  hash_of "$(jq -c --arg id "$1" 'select(.id == $id) | .snapshot' "$FIXTURES/m365/proposals-pending.jsonl")"
}

consent_append() { # consent_append <file> <json line> — as the scripts do it
  (umask 077 && mkdir -p "$STATE")
  chmod 700 "$STATE"
  (umask 077 && printf '%s\n' "$2" >> "$1")
  chmod 600 "$1"
}

# seed_fixture <fixture jsonl> <target file>: every row, @H1@/@H2@/@H3@ replaced by the computed hashes
seed_fixture() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//@H1@/$H1}"
    line="${line//@H2@/$H2}"
    line="${line//@H3@/$H3}"
    consent_append "$2" "$line"
  done < "$M365_FIXTURES/$1"
}

# seed_proposal <row id> [<jq edit>]: one row of proposals-pending.jsonl into proposals.jsonl, optionally edited
seed_proposal() {
  local row
  row="$(jq -c --arg id "$1" 'select(.id == $id)' "$M365_FIXTURES/proposals-pending.jsonl")"
  row="${row//@H1@/$H1}"
  row="${row//@H2@/$H2}"
  row="${row//@H3@/$H3}"
  [ -z "${2:-}" ] || row="$(jq -c "$2" <<< "$row")"
  consent_append "$PROPOSALS" "$row"
}

seed_approval() { # seed_approval <row id> <hash> [<ts>]
  consent_append "$APPROVALS" "$(jq -nc --arg r "$1" --arg h "$2" --arg t "${3:-2026-09-30T09:50:00Z}" \
    '{row_id: $r, hash_at_approval: $h, ts: $t, tty: "pts/0"}')"
}

row_status() { # row_status <row id>
  jq -r --arg id "$1" 'select(.id == $id) | .status' "$PROPOSALS"
}

executions() { # the executions.jsonl rows, or nothing
  if [ -f "$EXECUTIONS" ]; then cat "$EXECUTIONS"; fi
}

reset_consent() { # a fresh state dir, stub log and scenario between cases
  rm -rf "$STATE"
  : > "$CURL_STUB_LOG"
  : > "$CURL_STUB_DIR/curl-stub.scenario"
}

pty_graph() { # graph.sh on a pseudo-terminal; stdout = everything the tty showed, status = graph.sh's
  run_on_pty /dev/null "$GRAPH" "$@"
}

last_line() {
  printf '%s\n' "$output" | sed '/^$/d' | tail -n 1
}

USAGE='(usage: graph.sh cert-init [--rotate|--commit] | token [--key new] [--alg PS256|RS256] | check [--counts] [--other-mailbox <upn>] [--drive <id>] | mail-folders | drives | drafts-since <ISO> | message-sender <id> | snapshot draft|message <id> | get draft|message <id> | sent-since <ISO> | send-draft|move|delete --approved <hash>)'

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

@test "m365: the fixture m365.json validates (GUIDs incl. sp_object_id; UPN; onedrive_site and sites forms; sites_granted non-empty; cert.expires a date; consent block; numbers)" {
  local c="$ZYGGY_M365_CONFIG" guid='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  [ -f "$c" ]
  jq -e 'keys == ["brief","cert","client_id","consent","drives","files_backfill","language","mail_backfill","mailbox","sp_object_id","tenant_id","timezone"]' "$c" > /dev/null
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
  # the consent block (D6): TTL in minutes and the three actions — an instance may only narrow the list
  jq -e '.consent == {"ttl_minutes": 60, "allowed_actions": ["send-draft", "move", "delete"]}' "$c" > /dev/null
  # the caps exactly as the spec block (instance/m365.json contract)
  jq -e '.brief == {"mail_max_items": 60, "reply_cap": 3, "files_max_items": 20, "file_max_bytes": 15728640,
    "file_text_cap_bytes": 20000, "max_turns": 40, "budget_usd": 3.0, "max_facts": 10, "proposal_cap": 10, "model": ""}' "$c" > /dev/null
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

@test "m365: no GUID but the fixture ones, no real mailbox, site, drive id or machine path under tests/fixtures/m365 and tests/fixtures/graph" {
  run grep -rhoE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$M365_FIXTURES" "$GRAPH_FIXTURES"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | LC_ALL=C sort -u)" = "$(printf '%s\n' \
    00000000-0000-0000-0000-000000000000 \
    11111111-1111-4111-8111-111111111111 22222222-2222-4222-8222-222222222222 33333333-3333-4333-8333-333333333333 \
    aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb cccccccc-cccc-4ccc-8ccc-cccccccccccc \
    dddddddd-dddd-4ddd-8ddd-dddddddddddd)" ] || { echo "unexpected GUID: $output"; return 1; }
  # the machine-path alternatives are composed so that this file passes the same hygiene check (repo.bats);
  # the consent fixtures carry the Graph snapshots' RFC 2606 addresses (@example.org, @acme.example) — allowed
  local s='/' paths
  paths="${s}srv${s}|${s}home${s}|${s}Users${s}|${s}root${s}|[A-Za-z]:\\\\"
  run bash -c 'grep -rnE "$1" "$2" | grep -vE "@example\.(com|org|net)\b"' _ \
    "@[a-z0-9-]+\.(com|be|org|net)\b|sharepoint\.com|onmicrosoft|$paths" "$M365_FIXTURES"
  [ "$status" -eq 1 ] || { echo "real-looking value: $output"; return 1; }
  run grep -rnE "sharepoint\.com|onmicrosoft|$paths" "$GRAPH_FIXTURES"
  [ "$status" -eq 1 ] || { echo "real-looking value: $output"; return 1; }
}

# --- graph.sh: refusals and usage before any request --------------------------------------------------------

@test "graph: ZYGGY_HOOKS=off cert-init -> exit 5 refused: unattended run, nothing created; token, check, snapshot, get, sent-since accept it" {
  local before
  rm -f "$ZYGGY_M365_KEY_FILE" "$ZYGGY_M365_CER_FILE"
  before="$(state_snapshot)"
  ZYGGY_HOOKS=off run --separate-stderr graph cert-init
  assert_refused 5 "m365: refused: unattended run (ZYGGY_HOOKS=off)" "$before"
  [ ! -e "$ZYGGY_M365_KEY_FILE" ] && [ ! -e "$ZYGGY_M365_CER_FILE" ]
  install_m365_keypair
  ZYGGY_HOOKS=off run graph_len token
  [ "$status" -eq 0 ] || { echo "token: $output"; return 1; }
  ZYGGY_HOOKS=off run graph check
  [ "$status" -eq 0 ] || { echo "check: $output"; return 1; }
  ZYGGY_HOOKS=off run graph snapshot draft d1
  [ "$status" -eq 0 ] || { echo "snapshot: $output"; return 1; }
  ZYGGY_HOOKS=off run graph get draft d1
  [ "$status" -eq 0 ] || { echo "get: $output"; return 1; }
  ZYGGY_HOOKS=off run graph sent-since 2026-09-30T00:00:00Z
  [ "$status" -eq 0 ] || { echo "sent-since: $output"; return 1; }
  output=""
}

@test "graph: unknown verbs and malformed arguments -> exit 4 with the usage table, no request; send-draft|move|delete without --approved -> 4; delete --hard -> 4; --approved <hash> without a tty -> 5 refused: no terminal" {
  local before hash c
  before="$(state_snapshot)"
  local -a cases=(
    "auth" "draft-x" "hard-delete" "x" ""
    "token --key old" "token --alg HS256" "token extra"
    "check --other-mailbox not-a-upn" "check --drive" "check --counts --counts" "check extra"
    "mail-folders x" "drives x"
    "drafts-since yesterday" "drafts-since 2026-09-30" "drafts-since"
    "message-sender m1;rm" "message-sender" "message-sender m1 m2"
    "snapshot mail d1" "snapshot draft" "snapshot draft d1 extra" "get draft" "get message m1/x"
    "sent-since 2026-09-30" "sent-since"
    "send-draft" "send-draft d1" "move" "move m1 archive" "delete" "delete m1"
    "delete --hard" "delete --hard --approved $(printf '0%.0s' {1..64})"
    "send-draft --approved nothex" "send-draft --approved" "move --approved $(printf 'a%.0s' {1..63})"
    "cert-init --rotate --commit" "cert-init extra" "cert-init --force"
  )
  for c in "${cases[@]}"; do
    # shellcheck disable=SC2086 # the case is a command line
    run --separate-stderr graph $c
    assert_refused 4 "m365: * (usage: graph.sh *" "$before" || { echo "case: graph $c"; return 1; }
    grep -qF -- "$USAGE" <<< "$stderr" || { echo "usage text differs for: $c -> $stderr"; return 1; }
  done
  # the write verbs parse here; without a terminal they refuse before any approval lookup (Step 3)
  hash="$(printf 'f%.0s' {1..64})"
  for c in "send-draft --approved $hash" "move --approved $hash" "delete --approved $hash"; do
    # shellcheck disable=SC2086
    run --separate-stderr graph $c < /dev/null
    assert_refused 5 "m365: refused: no terminal" "$before" || { echo "case: graph $c"; return 1; }
  done
}

@test "graph: misconfiguration -> exit 3, one line, no request (ZYGGY_TENANT unset, m365.json missing, bad GUIDs, UPN, site forms, sites_granted, cert.expires, caps, consent); cert-init with only the base keys valid -> proceeds" {
  local before c
  before="$(state_snapshot)"
  run --separate-stderr env -u ZYGGY_TENANT "$GRAPH" check
  assert_refused 3 "m365: configuration error: ZYGGY_TENANT is not set" "$before"
  rm "$ZYGGY_M365_CONFIG"
  run --separate-stderr graph check
  assert_refused 3 "m365: configuration error: *m365.json not found (ZYGGY_M365_CONFIG)" "$before"
  local -a cases=(
    '.tenant_id = "not-a-guid"|tenant_id'
    '.tenant_id = ""|tenant_id'
    '.sp_object_id = "3333"|sp_object_id'
    '.client_id = ""|client_id'
    '.mailbox = "alice"|mailbox'
    '.drives.onedrive_site = "acme.sharepoint.example/personal/alice"|drives.onedrive_site'
    '.drives.sites_granted = []|drives.sites_granted'
    '.drives.sites_granted = ["acme.sharepoint.example"]|drives.sites_granted'
    '.cert.expires = "soon"|cert.expires'
    '.cert.expires = ""|cert.expires'
    '.brief.budget_usd = "3"|.brief.budget_usd'
    '.brief.max_turns = 1.5|.brief.max_turns'
    '.mail_backfill.budget_usd_total = "x"|.mail_backfill.budget_usd_total'
    '.consent.ttl_minutes = 0|.consent.ttl_minutes'
    '.consent.ttl_minutes = "x"|.consent.ttl_minutes'
    '.consent.ttl_minutes = 1441|.consent.ttl_minutes'
    '.consent.allowed_actions = ["send-all"]|consent.allowed_actions'
    '.consent.allowed_actions = ["move", "move"]|consent.allowed_actions'
    'del(.consent)|consent'
    '.cert.days = 0|.cert.days'
    '.timezone = "Mars/Olympus"|timezone'
  )
  for c in "${cases[@]}"; do
    install_m365_fixture_config
    cfg "${c%%|*}"
    run --separate-stderr graph check
    assert_refused 3 "m365: configuration error: *${c##*|}*" "$before" || { echo "case: ${c%%|*}"; return 1; }
    run --separate-stderr graph token
    [ "$status" -eq 3 ] || { echo "token accepted: ${c%%|*}"; return 1; }
  done
  # an empty allowed_actions list narrows D6 to nothing and is valid
  install_m365_fixture_config
  cfg '.consent.allowed_actions = []'
  run graph mail-folders
  [ "$status" -eq 0 ]
  # cert-init runs before the registration exists: the base keys only
  install_m365_fixture_config
  cfg '.client_id = "" | .sp_object_id = "" | .cert.expires = "" | .drives.sites_granted = [] | .consent = {}'
  rm -f "$ZYGGY_M365_KEY_FILE" "$ZYGGY_M365_CER_FILE"
  run --separate-stderr graph cert-init
  [ "$status" -eq 0 ] || { echo "cert-init: $stderr"; return 1; }
  [ -f "$ZYGGY_M365_KEY_FILE" ]
  cfg '.mailbox = "alice"'
  rm -f "$ZYGGY_M365_KEY_FILE" "$ZYGGY_M365_CER_FILE"
  : > "$CURL_STUB_LOG"
  before="$(state_snapshot)"
  run --separate-stderr graph cert-init
  assert_refused 3 "m365: configuration error: mailbox *" "$before"
}

@test "graph: cert.expires 20 days ahead -> stderr warning naming runbook 13 \"Rotate the certificate\", exit 0; today -> 0 days; yesterday -> exit 3 certificate expired, no request" {
  local before
  cfg '.cert.expires = "2026-10-20"'
  run --separate-stderr graph_len token
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$output" -gt 20 ]
  [ "$stderr" = "$(printf 'm365: certificate expires in 20 days — runbook 13 "Rotate the certificate"\nkey: file')" ] || { echo "$stderr"; return 1; }
  cfg '.cert.expires = "2026-09-30"'
  run --separate-stderr graph mail-folders
  [ "$status" -eq 0 ]
  grep -qF 'm365: certificate expires in 0 days' <<< "$stderr"
  cfg '.cert.expires = "2026-09-29"'
  : > "$CURL_STUB_LOG"
  before="$(state_snapshot)"
  run --separate-stderr graph check
  assert_refused 3 'm365: certificate expired 2026-09-29 — runbook 13 "Rotate the certificate"' "$before"
  # cert-init does not look at the expiry (the certificate is what it creates)
  rm -f "$ZYGGY_M365_KEY_FILE" "$ZYGGY_M365_CER_FILE"
  run graph cert-init
  [ "$status" -eq 0 ]
}

@test "graph: curl|jq|openssl not on PATH -> exit 3 \"m365: <tool> not found\"; ZYGGY_M365_STUB=1 with /usr/bin/curl first -> exit 3 (skipped when absent)" {
  local before tool
  before="$(state_snapshot)"
  for tool in curl jq openssl; do
    PATH="$(path_without "$tool")" run --separate-stderr graph check
    assert_refused 3 "m365: $tool not found" "$before" || { echo "tool: $tool"; return 1; }
  done
  [ -x /usr/bin/curl ] || skip "no system curl in this image"
  PATH="/usr/bin:$PATH" run --separate-stderr graph check
  assert_refused 3 "m365: ZYGGY_M365_STUB=1 but curl resolves to /usr/bin/curl, not the stub" "$before"
}

# --- graph.sh cert-init ----------------------------------------------------------------------------------------

@test "graph: cert-init -> key 600 in a 700 dir (PEM private key), cer 644 CN=zyggy-central valid 398 days; stdout thumbprints (= openssl fingerprints), expiry and path; key value nowhere in stdout/stderr" {
  local nb na
  rm -f "$ZYGGY_M365_KEY_FILE" "$ZYGGY_M365_CER_FILE"
  run --separate-stderr graph cert-init
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ -z "$stderr" ] || { echo "stderr: $stderr"; return 1; }
  [ "$(stat -c %a "$ZYGGY_M365_KEY_FILE")" = 600 ]
  [ "$(stat -c %a "$KEY_DIR")" = 700 ]
  [ "$(stat -c %a "$ZYGGY_M365_CER_FILE")" = 644 ]
  grep -qE '^-----BEGIN (RSA )?PRIVATE KEY-----$' "$ZYGGY_M365_KEY_FILE"
  openssl rsa -in "$ZYGGY_M365_KEY_FILE" -noout -check > /dev/null 2>&1
  [ "$(openssl rsa -in "$ZYGGY_M365_KEY_FILE" -noout -text 2> /dev/null | grep -c 'Private-Key: (2048 bit')" -eq 1 ]
  openssl x509 -in "$ZYGGY_M365_CER_FILE" -noout -subject | grep -qE 'CN ?= ?zyggy-central$'
  openssl x509 -in "$ZYGGY_M365_CER_FILE" -noout -checkend 0 > /dev/null
  nb="$(date -u -d "$(openssl x509 -in "$ZYGGY_M365_CER_FILE" -noout -startdate | cut -d= -f2)" +%s)"
  na="$(date -u -d "$(openssl x509 -in "$ZYGGY_M365_CER_FILE" -noout -enddate | cut -d= -f2)" +%s)"
  [ $(((na - nb) / 86400)) -eq 398 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 4 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "thumbprint sha1: $(fingerprint sha1)" ] || { echo "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "thumbprint sha256: $(fingerprint sha256)" ]
  [[ "$(printf '%s\n' "$output" | sed -n 1p)" =~ ^thumbprint\ sha1:\ [0-9A-F]{40}$ ]]
  [[ "$(printf '%s\n' "$output" | sed -n 2p)" =~ ^thumbprint\ sha256:\ [0-9A-F]{64}$ ]]
  [ "$(printf '%s\n' "$output" | sed -n 3p)" = "expires: $(date -u -d "@$na" +%F)" ]
  [ "$(printf '%s\n' "$output" | sed -n 4p)" = "certificate: $ZYGGY_M365_CER_FILE" ]
  # the key's second line (key material) is in neither stream; the teardown checks the header too
  ! grep -qF -- "$(sed -n 2p "$ZYGGY_M365_KEY_FILE")" <<< "$output$stderr"
  [ "$(request_count)" -eq 0 ]
}

@test "graph: cert-init with an existing key -> exit 5 refused: key exists, files untouched; --rotate -> .key.new/.cer.new; token --key new verifies against .cer.new only; --commit swaps; --commit without .new -> exit 4" {
  local before sums new_sum
  sums="$(md5sum "$ZYGGY_M365_KEY_FILE" "$ZYGGY_M365_CER_FILE")"
  before="$(state_snapshot)"
  run --separate-stderr graph cert-init
  assert_refused 5 "m365: refused: key exists — use --rotate ($ZYGGY_M365_KEY_FILE)" "$before"
  [ "$(md5sum "$ZYGGY_M365_KEY_FILE" "$ZYGGY_M365_CER_FILE")" = "$sums" ]
  run --separate-stderr graph cert-init --rotate
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(stat -c %a "$ZYGGY_M365_KEY_FILE.new")" = 600 ]
  [ "$(stat -c %a "$ZYGGY_M365_CER_FILE.new")" = 644 ]
  [ "$(md5sum "$ZYGGY_M365_KEY_FILE" "$ZYGGY_M365_CER_FILE")" = "$sums" ]
  [ "$(printf '%s\n' "$output" | sed -n 4p)" = "certificate: $ZYGGY_M365_CER_FILE.new" ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "thumbprint sha1: $(fingerprint sha1 "$ZYGGY_M365_CER_FILE.new")" ]
  run --separate-stderr graph cert-init --rotate
  [ "$status" -eq 5 ]
  [ "$stderr" = "m365: refused: a rotation is pending — use --commit or remove $ZYGGY_M365_KEY_FILE.new" ] || { echo "$stderr"; return 1; }
  # the new pair proves itself before the swap
  run --separate-stderr graph_len token --key new
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$stderr" = "key: file" ]
  assertion_verify pss "$ZYGGY_M365_CER_FILE.new"
  ! assertion_verify pss "$ZYGGY_M365_CER_FILE"
  new_sum="$(md5sum < "$ZYGGY_M365_KEY_FILE.new")"
  run --separate-stderr graph cert-init --commit
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(md5sum < "$ZYGGY_M365_KEY_FILE")" = "$new_sum" ]
  [ ! -e "$ZYGGY_M365_KEY_FILE.new" ] && [ ! -e "$ZYGGY_M365_CER_FILE.new" ]
  [ "$(stat -c %a "$ZYGGY_M365_KEY_FILE")" = 600 ]
  [ "$(stat -c %a "$ZYGGY_M365_CER_FILE")" = 644 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "thumbprint sha1: $(fingerprint sha1)" ]
  [ "$(printf '%s\n' "$output" | sed -n 4p)" = "certificate: $ZYGGY_M365_CER_FILE" ]
  : > "$CURL_STUB_LOG"
  before="$(state_snapshot)"
  run --separate-stderr graph cert-init --commit
  assert_refused 4 "m365: --commit: no $ZYGGY_M365_KEY_FILE.new to commit (usage: *" "$before"
  run --separate-stderr graph_len token
  [ "$status" -eq 0 ]
  assertion_verify
}

# --- graph.sh token --------------------------------------------------------------------------------------------

@test "graph: token -> stdout exactly the fixture access token, stderr exactly \"key: file\"; one POST to the tenant's v2 token endpoint with client_credentials, the Graph .default scope, the jwt-bearer assertion type, the client id, an assertion and no secret" {
  local expected line
  expected="$(jq -r .access_token "$GRAPH_FIXTURES/token-ok.json")"
  expect_token_on_stdout=1
  run --separate-stderr graph token
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$output" = "$expected" ] || { echo "stdout is not the fixture token (${#output} bytes)"; return 1; }
  [ "$stderr" = "key: file" ] || { echo "stderr: $stderr"; return 1; }
  [ "$(request_count)" -eq 1 ]
  line="$(requests)"
  [[ "$line" == "method=POST url=$TOKEN_URL headers="* ]] || { echo "$line"; return 1; }
  [[ "$line" == *" bearer=absent client_secret=absent client_assertion=present client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer grant_type=client_credentials scope=https://graph.microsoft.com/.default client_id=$CLIENT destinationId=absent" ]] ||
    { echo "$line"; return 1; }
  [ -s "$CURL_STUB_DIR/assertion.jwt" ]
}

@test "graph: the assertion header is {alg PS256, typ JWT, x5t#S256 = base64url sha256(DER)}, the claims aud/iss/sub/jti/nbf/iat/exp as the identity platform wants, the PSS signature verifies against the certificate and a tampered payload does not" {
  local now claims header tampered
  now="$(date -u -d 2026-09-30T10:00:00Z +%s)"
  run --separate-stderr graph_len token
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  header="$(assertion_header)"
  [ "$header" = "{\"alg\":\"PS256\",\"typ\":\"JWT\",\"x5t#S256\":\"$(x5t sha256)\"}" ] || { echo "header: $header"; return 1; }
  claims="$(assertion_claims)"
  jq -e --arg aud "$TOKEN_URL" --arg c "$CLIENT" --argjson now "$now" \
    '.aud == $aud and .iss == $c and .sub == $c and .nbf == $now and .iat == $now and .exp == $now + 300
     and (.jti | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
     and (keys == ["aud","exp","iat","iss","jti","nbf","sub"])' <<< "$claims" > /dev/null || { echo "claims: $claims"; return 1; }
  assertion_verify
  # a tampered payload with the original signature fails
  tampered="$(cut -d. -f1 "$CURL_STUB_DIR/assertion.jwt").$(jq -c '.exp += 3600' <<< "$claims" | b64url).$(cut -d. -f3 "$CURL_STUB_DIR/assertion.jwt")"
  printf '%s' "$tampered" > "$BATS_TEST_TMPDIR/tampered.jwt"
  ! assertion_verify pss "$ZYGGY_M365_CER_FILE" "$BATS_TEST_TMPDIR/tampered.jwt"
  # two mints never share a jti
  run --separate-stderr graph_len token
  [ "$(jq -r .jti <<< "$claims")" != "$(assertion_claims | jq -r .jti)" ]
}

@test "graph: token --alg RS256 -> header {alg RS256, typ JWT, x5t = base64url sha1(DER)}; the PKCS#1 v1.5 signature verifies (and is not a PSS signature)" {
  local header
  run --separate-stderr graph_len token --alg RS256
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  header="$(assertion_header)"
  [ "$header" = "{\"alg\":\"RS256\",\"typ\":\"JWT\",\"x5t\":\"$(x5t sha1)\"}" ] || { echo "header: $header"; return 1; }
  assertion_verify pkcs1
  ! assertion_verify pss
  run --separate-stderr graph_len token --alg PS256
  [ "$status" -eq 0 ]
  assertion_verify pss
}

@test "graph: token reads \$CREDENTIALS_DIRECTORY/m365-app-key first (\"key: credentials directory\"), else the file (\"key: file\"); a 644 key -> exit 3; neither -> exit 3 key: not found in credentials directory or file" {
  local before creds="$BATS_TEST_TMPDIR/creds"
  mkdir -p "$creds"
  cp "$ZYGGY_M365_KEY_FILE" "$creds/m365-app-key"
  chmod 400 "$creds/m365-app-key"
  rm "$ZYGGY_M365_KEY_FILE"
  CREDENTIALS_DIRECTORY="$creds" run --separate-stderr graph_len token
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$stderr" = "key: credentials directory" ] || { echo "$stderr"; return 1; }
  assertion_verify
  # the file wins when the credentials directory holds no key
  install_m365_keypair
  CREDENTIALS_DIRECTORY="$BATS_TEST_TMPDIR/empty-creds" run --separate-stderr graph_len token
  [ "$status" -eq 0 ]
  [ "$stderr" = "key: file" ]
  : > "$CURL_STUB_LOG"
  chmod 644 "$ZYGGY_M365_KEY_FILE"
  before="$(state_snapshot)"
  run --separate-stderr graph token
  assert_refused 3 "m365: key: $ZYGGY_M365_KEY_FILE must be mode 0600 (is 644)" "$before"
  chmod 600 "$ZYGGY_M365_KEY_FILE"
  : > "$ZYGGY_M365_KEY_FILE"
  before="$(state_snapshot)"
  run --separate-stderr graph token
  assert_refused 3 "m365: key: $ZYGGY_M365_KEY_FILE is empty" "$before"
  printf 'not a key\n' > "$ZYGGY_M365_KEY_FILE"
  run --separate-stderr graph token
  assert_refused 3 "m365: key: $ZYGGY_M365_KEY_FILE has no PEM private-key header" "$before"
  rm "$ZYGGY_M365_KEY_FILE"
  before="$(state_snapshot)"
  run --separate-stderr graph token
  assert_refused 3 "m365: key: not found in credentials directory or file" "$before"
  run --separate-stderr graph check
  assert_refused 3 "m365: key: not found in credentials directory or file" "$before"
}

@test "graph: invalid_client (AADSTS700027) -> exit 6 auth failed … runbook 13 \"Certificate rejected\"; unauthorized_client -> 6; AADSTS700024 -> 6 naming the clock skew; stdout empty; key mtime unchanged" {
  local mtime
  mtime="$(stat -c %Y "$ZYGGY_M365_KEY_FILE")"
  scenario 'oauth2/v2\.0/token:400:token-invalid-client.json'
  run --separate-stderr graph token
  [ "$status" -eq 6 ] && [ -z "$output" ]
  [ "$(stderr_last)" = 'm365: auth failed (invalid_client) — runbook 13 "Certificate rejected"' ] || { echo "$stderr"; return 1; }
  scenario 'oauth2/v2\.0/token:400:token-unauthorized-client.json'
  run --separate-stderr graph token
  [ "$status" -eq 6 ] && [ -z "$output" ]
  [ "$(stderr_last)" = 'm365: auth failed (unauthorized_client) — runbook 13 "Certificate rejected"' ] || { echo "$stderr"; return 1; }
  scenario 'oauth2/v2\.0/token:400:token-clock-skew.json'
  run --separate-stderr graph check
  [ "$status" -eq 6 ] && [ -z "$output" ]
  [ "$(stderr_last)" = 'm365: auth failed (clock skew, AADSTS700024) — check timedatectl on this machine' ] || { echo "$stderr"; return 1; }
  # the token endpoint's own 401 and 5xx are identity failures too, never retried as Graph calls
  scenario 'oauth2/v2\.0/token:401'
  run --separate-stderr graph token
  [ "$status" -eq 6 ]
  [ "$(stat -c %Y "$ZYGGY_M365_KEY_FILE")" = "$mtime" ]
  # only token requests were made
  [ "$(urls | grep -vc "^POST $TOKEN_URL$")" -eq 0 ]
}

# --- graph.sh check / mail-folders / drives --------------------------------------------------------------------

@test "graph: check -> stdout byte-equal to expected/m365-check.txt (state dir normalised); GET on /users/<upn>/mailFolders (+childFolders), /users/<upn>/drive, /sites/<granted>/drives with bearer=present; one token POST; none on /me" {
  run --separate-stderr graph check
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$stderr" = "key: file" ]
  printf '%s\n' "$output" | sed "s|$STATE|STATE_DIR|" > "$BATS_TEST_TMPDIR/check.out"
  assert_bytes_equal "$BATS_TEST_TMPDIR/check.out" "$EXPECTED/m365-check.txt"
  grep -qF "state dir $STATE" <<< "$output"
  urls > "$BATS_TEST_TMPDIR/urls"
  [ "$(cat "$BATS_TEST_TMPDIR/urls")" = "$(printf '%s\n' \
    "POST $TOKEN_URL" \
    "GET $GRAPH_URL/users/$UPN/mailFolders?\$top=100" \
    "GET $GRAPH_URL/users/$UPN/mailFolders/AQMkInbox0001/childFolders?\$top=100" \
    "GET $GRAPH_URL/users/$UPN/drive?\$select=id,name,webUrl" \
    "GET $GRAPH_URL/sites/acme.sharepoint.example,aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa,bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/drives?\$select=id,name,webUrl" \
    "GET $GRAPH_URL/sites/acme-my.sharepoint.example,cccccccc-cccc-4ccc-8ccc-cccccccccccc,dddddddd-dddd-4ddd-8ddd-dddddddddddd/drives?\$select=id,name,webUrl")" ] ||
    { cat "$BATS_TEST_TMPDIR/urls"; return 1; }
  [ "$(requests | grep -c 'method=GET .* bearer=present ')" -eq 5 ]
  [ "$(requests | grep -c 'method=POST .* bearer=absent ')" -eq 1 ]
  ! grep -qE '/me(/|\?|$)' "$BATS_TEST_TMPDIR/urls"
  [ "$(requests | grep -c 'headers=Accept,Authorization ')" -eq 5 ]
}

@test "graph: check --counts -> folder lines (id, name, well-known name or -, count, excluded) and zyggy-drafts <k>; --other-mailbox with 403 -> expected: scope holds, with 200 -> SCOPE NOT ENFORCED exit 5; --drive with 403 -> not granted, with 200 -> granted" {
  run --separate-stderr graph check --counts
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  printf '%s\n' "$output" | sed -n '5,$p' > "$BATS_TEST_TMPDIR/counts"
  [ "$(cat "$BATS_TEST_TMPDIR/counts")" = "$(printf '%s\n' \
    'folder AQMkInbox0001 Inbox inbox 1240' \
    'folder AQMkSentItems0001 Sent Items sentitems 310' \
    'folder AQMkDeletedItems0001 Deleted Items deleteditems 12 excluded' \
    'folder AQMkDrafts0001 Drafts drafts 4 excluded' \
    'folder AQMkJunkEmail0001 Junk Email junkemail 3 excluded' \
    'folder AQMkArchive0001 Archive - 90' \
    'zyggy-drafts 2')" ] || { cat "$BATS_TEST_TMPDIR/counts"; return 1; }
  grep -qF "GET $GRAPH_URL/users/$UPN/mailFolders/drafts/messages?\$select=id,subject&\$top=50" <(urls)
  run --separate-stderr graph check --other-mailbox bob@acme.example
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "other mailbox bob@acme.example: 403 (expected: scope holds)" ]
  grep -qF "GET $GRAPH_URL/users/bob@acme.example/mailFolders/inbox" <(urls)
  scenario 'users/bob@acme\.example/mailFolders/inbox:200:mail-folders.json'
  run --separate-stderr graph check --other-mailbox bob@acme.example
  [ "$status" -eq 5 ] || { echo "status $status: $stderr"; return 1; }
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "other mailbox bob@acme.example: 200 — SCOPE NOT ENFORCED" ]
  [ "$(stderr_last)" = 'm365: refused: scope not enforced — bob@acme.example is readable; runbook 13 "Scope or grant missing"' ] || { echo "$stderr"; return 1; }
  run --separate-stderr graph check --drive 'b!ungranted0001'
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(printf '%s\n' "$output" | tail -n 1)" = 'drive b!ungranted0001: 403 (not granted)' ]
  grep -qF "GET $GRAPH_URL/drives/b!ungranted0001/root" <(urls)
  run --separate-stderr graph check --drive 'b!onedrive0001'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -n 1)" = 'drive b!onedrive0001: 200 (granted)' ]
  run --separate-stderr graph check --counts --other-mailbox bob@acme.example --drive 'b!onedrive0001'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 13 ]
}

@test "graph: mail-folders -> JSON [{id, displayName, wellKnownName, totalItemCount, excluded}] (6, 3 excluded); drives -> JSON [{id, name, site}] (3) minus exclude_drives" {
  run --separate-stderr graph mail-folders
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  jq -e 'length == 6 and all(keys == ["displayName","excluded","id","totalItemCount","wellKnownName"])' <<< "$output" > /dev/null
  jq -e '[.[] | select(.excluded)] | map(.wellKnownName) == ["deleteditems","drafts","junkemail"]' <<< "$output" > /dev/null
  jq -e '.[0] == {"id":"AQMkInbox0001","displayName":"Inbox","wellKnownName":"inbox","totalItemCount":1240,"excluded":false}' <<< "$output" > /dev/null
  jq -e '.[5] == {"id":"AQMkArchive0001","displayName":"Archive","wellKnownName":null,"totalItemCount":90,"excluded":false}' <<< "$output" > /dev/null
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  run --separate-stderr graph drives
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$output" = '[{"id":"b!onedrive0001","name":"OneDrive","site":"onedrive"},{"id":"b!ops0001","name":"ops","site":"acme.sharepoint.example,aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa,bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"},{"id":"b!opsarchive0001","name":"ops-archive","site":"acme.sharepoint.example,aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa,bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"}]' ] ||
    { echo "$output"; return 1; }
  cfg '.drives.exclude_drives = ["b!opsarchive0001", "ops"]'
  run --separate-stderr graph drives
  [ "$status" -eq 0 ]
  [ "$output" = '[{"id":"b!onedrive0001","name":"OneDrive","site":"onedrive"}]' ] || { echo "$output"; return 1; }
}

@test "graph: 429 ×2 then 200 -> ok; 503 then 200 -> ok; 6×429 -> exit 6; 401 once -> one re-mint then success; 401 twice -> 6; 403 ErrorAccessDenied -> exit 6 forbidden … runbook 13 \"Scope or grant missing\"" {
  local i
  scenario 'mailFolders\?:429:-:retry-after-2.hdr'
  scenario 'mailFolders\?:429:-:retry-after-2.hdr'
  run --separate-stderr graph mail-folders
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(urls | grep -c "mailFolders?")" -eq 3 ]
  [ "$(urls | grep -c "^POST ")" -eq 1 ]
  : > "$CURL_STUB_LOG"
  scenario 'mailFolders\?:503'
  run --separate-stderr graph mail-folders
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(urls | grep -c "mailFolders?")" -eq 2 ]
  : > "$CURL_STUB_LOG"
  for i in 1 2 3 4 5 6 7; do scenario 'mailFolders\?:429:-:retry-after-2.hdr'; done
  run --separate-stderr graph mail-folders
  [ "$status" -eq 6 ] && [ -z "$output" ]
  [ "$(stderr_last)" = 'm365: throttled (429) after 5 retries — runbook 13 "Throttling"' ] || { echo "$stderr"; return 1; }
  [ "$(urls | grep -c "mailFolders?")" -eq 6 ]
  : > "$CURL_STUB_LOG"
  : > "$CURL_STUB_DIR/curl-stub.scenario"
  scenario 'mailFolders\?:401'
  run --separate-stderr graph mail-folders
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(urls | grep -c "^POST $TOKEN_URL$")" -eq 2 ]
  [ "$(urls | grep -c "mailFolders?")" -eq 2 ]
  : > "$CURL_STUB_LOG"
  scenario 'mailFolders\?:401'
  scenario 'mailFolders\?:401'
  run --separate-stderr graph mail-folders
  [ "$status" -eq 6 ] && [ -z "$output" ]
  [ "$(stderr_last)" = 'm365: unauthorized (401) after a fresh token — runbook 13 "Certificate rejected"' ] || { echo "$stderr"; return 1; }
  [ "$(urls | grep -c "^POST $TOKEN_URL$")" -eq 2 ]
  : > "$CURL_STUB_LOG"
  scenario 'mailFolders\?:403:graph-forbidden.json'
  run --separate-stderr graph mail-folders
  [ "$status" -eq 6 ] && [ -z "$output" ]
  [ "$(stderr_last)" = 'm365: forbidden (ErrorAccessDenied) — runbook 13 "Scope or grant missing"' ] || { echo "$stderr"; return 1; }
  [ "$(urls | grep -c "mailFolders?")" -eq 1 ]
  # a transport failure (the stub refuses an unroutable URL) is exit 6 with the first stderr line of curl
  : > "$CURL_STUB_LOG"
  cfg '.mailbox = "nobody@acme.example"'
  run --separate-stderr graph mail-folders
  [ "$status" -eq 6 ]
  [[ "$(stderr_last)" == "m365: request failed (stub: unroutable GET $GRAPH_URL/users/nobody@acme.example/mailFolders?"* ]] || { echo "$stderr"; return 1; }
}

# --- graph.sh reads for verify.sh and the consent flow -----------------------------------------------------------

@test "graph: drafts-since <ISO> -> the 2 Drafts created since (URL with \$filter=createdDateTime ge, \$select, \$top=50); message-sender m1 -> {from, replyTo, conversationId} lower-cased; m2 carries a replyTo; a bad id -> 4" {
  local before
  run --separate-stderr graph drafts-since 2026-09-30T00:00:00Z
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  jq -e 'length == 2 and map(.id) == ["d0","d1"] and .[1].subject == "RE: Invoice 2026-41"' <<< "$output" > /dev/null
  grep -qF "GET $GRAPH_URL/users/$UPN/mailFolders/drafts/messages?\$filter=createdDateTime%20ge%202026-09-30T00:00:00Z&\$select=id,subject,toRecipients,ccRecipients,bccRecipients,conversationId,createdDateTime,changeKey,body&\$top=50" <(urls) ||
    { urls; return 1; }
  [ "$(requests | grep -c 'prefer=outlook.body-content-type="text" ')" -eq 1 ]
  run --separate-stderr graph message-sender m1
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$output" = '{"from":"carol@example.org","replyTo":[],"conversationId":"c1"}' ] || { echo "$output"; return 1; }
  grep -qF "GET $GRAPH_URL/users/$UPN/messages/m1?\$select=from,replyTo,conversationId" <(urls)
  run --separate-stderr graph message-sender m2
  [ "$status" -eq 0 ]
  [ "$output" = '{"from":"dave@example.org","replyTo":["erin@example.org"],"conversationId":"c2"}' ] || { echo "$output"; return 1; }
  : > "$CURL_STUB_LOG"
  before="$(state_snapshot)"
  run --separate-stderr graph message-sender 'm1 m2'
  assert_refused 4 "m365: '*' is not a message id (usage: *" "$before"
  scenario 'messages/m1\?:404:graph-not-found.json'
  run --separate-stderr graph message-sender m1
  [ "$status" -eq 6 ] && [ -z "$output" ]
  [ "$(stderr_last)" = "m365: not found (m1)" ]
}

@test "graph: snapshot draft d1 -> line 1 the canonical JSON (sorted keys, no body), line 2 hash: sha256 of line 1; the request selects exactly the snapshot fields; snapshot message m1 -> kind message; 404 -> exit 6 not found (d1); an edited Draft hashes differently" {
  local canonical first
  run --separate-stderr graph snapshot draft d1
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$stderr" = "key: file" ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/snap"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/snap")" -eq 2 ]
  canonical="$(jq -S -c -n '{kind:"draft", id:"d1", subject:"RE: Invoice 2026-41", to:["carol@example.org"], cc:[], bcc:[],
    from:"alice@acme.example", receivedDateTime:"2026-09-30T05:31:00Z", parentFolderId:"AQMkDrafts0001", changeKey:"CK1", isDraft:true}')"
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/snap")" = "$canonical" ] || { cat "$BATS_TEST_TMPDIR/snap"; return 1; }
  ! grep -q body "$BATS_TEST_TMPDIR/snap"
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/snap")" = "hash: $(head -n 1 "$BATS_TEST_TMPDIR/snap" | sha256sum | cut -c1-64)" ]
  [[ "$(sed -n 2p "$BATS_TEST_TMPDIR/snap")" =~ ^hash:\ [0-9a-f]{64}$ ]]
  first="$(sed -n 2p "$BATS_TEST_TMPDIR/snap")"
  grep -qF "GET $GRAPH_URL/users/$UPN/messages/d1?\$select=id,subject,toRecipients,ccRecipients,bccRecipients,from,receivedDateTime,parentFolderId,changeKey,isDraft" <(urls) ||
    { urls; return 1; }
  [ "$(urls | grep -c '^GET ')" -eq 1 ]
  # the same hash from the fixture itself, through the lib's definition (jq -S -c, then sha256sum of the line)
  [ "$first" = "hash: $(printf '%s\n' "$canonical" | sha256sum | cut -c1-64)" ]
  run --separate-stderr graph snapshot message m1
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "$(jq -S -c -n '{kind:"message", id:"m1", subject:"Invoice 2026-41", to:["alice@acme.example"], cc:[], bcc:[],
    from:"carol@example.org", receivedDateTime:"2026-09-29T14:02:00Z", parentFolderId:"AQMkInbox0001", changeKey:"CKm1", isDraft:false}')" ] ||
    { echo "$output"; return 1; }
  scenario 'messages/d1\?:404:graph-not-found.json'
  run --separate-stderr graph snapshot draft d1
  [ "$status" -eq 6 ] && [ -z "$output" ]
  [ "$(stderr_last)" = "m365: not found (d1)" ] || { echo "$stderr"; return 1; }
  scenario 'messages/d1\?:200:snapshot-d1-changed.json'
  run --separate-stderr graph snapshot draft d1
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" != "$first" ]
  jq -e '.changeKey == "CK2" and .subject == "RE: Invoice 2026-41 (final)"' <<< "$(printf '%s\n' "$output" | sed -n 1p)" > /dev/null
  # recipients and sender are normalised: case and order do not change the hash
  scenario 'messages/d1\?:200:snapshot-d1-outside.json'
  run --separate-stderr graph snapshot draft d1
  jq -e '.to == ["carol@example.org","mallory@external.example"]' <<< "$(printf '%s\n' "$output" | sed -n 1p)" > /dev/null
}

@test "graph: get draft d1 -> stdout the body text only (Prefer: outlook.body-content-type=\"text\", \$select incl. body); nothing written under \$STATE or \$HOME; get message m1 likewise; 404 -> 6" {
  local before
  before="$(state_snapshot)"
  run --separate-stderr graph get draft d1
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$output" = "Dear Carol, I will call tomorrow. BODYTEXT-NEVER-STORED" ] || { echo "$output"; return 1; }
  [ "$stderr" = "key: file" ]
  [ "$(state_snapshot)" = "$before" ]
  grep -qF "GET $GRAPH_URL/users/$UPN/messages/d1?\$select=id,subject,body" <(urls) || { urls; return 1; }
  [ "$(requests | grep -c 'method=GET .* prefer=outlook.body-content-type="text" ')" -eq 1 ]
  run --separate-stderr graph get message m1
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$output" = "Hi Alice, when is the invoice due? BODYTEXT-NEVER-STORED" ] || { echo "$output"; return 1; }
  [ "$(state_snapshot)" = "$before" ]
  scenario 'messages/m1\?:404:graph-not-found.json'
  run --separate-stderr graph get message m1
  [ "$status" -eq 6 ] && [ -z "$output" ]
  [ "$(stderr_last)" = "m365: not found (m1)" ]
  # the marker exists in $output only: teardown proves it is in no file (the stub's fixture copy excepted)
  output=""
}

@test "graph: sent-since <ISO> -> JSON [{id, subject, toRecipients, sentDateTime, internetMessageId}] of the Sent Items since (URL with \$filter=sentDateTime ge and \$select)" {
  run --separate-stderr graph sent-since 2026-09-30T00:00:00Z
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$output" = "$(jq -c '[.value[] | {id, subject, toRecipients, sentDateTime, internetMessageId}]' "$GRAPH_FIXTURES/sent-items-ok.json")" ] ||
    { echo "$output"; return 1; }
  jq -e 'length == 1 and .[0].id == "s1" and .[0].toRecipients[0].emailAddress.address == "carol@example.org" and .[0].internetMessageId == "<im1@acme.example>"' <<< "$output" > /dev/null
  grep -qF "GET $GRAPH_URL/users/$UPN/mailFolders/sentitems/messages?\$filter=sentDateTime%20ge%202026-09-30T00:00:00Z&\$select=id,subject,toRecipients,sentDateTime,internetMessageId&\$top=50" <(urls) ||
    { urls; return 1; }
  scenario 'sentitems/messages\?:200:sent-items-extra.json'
  run --separate-stderr graph sent-since 2026-09-30T00:00:00Z
  [ "$status" -eq 0 ]
  jq -e 'length == 2 and .[1].subject == "Quarterly numbers"' <<< "$output" > /dev/null
}

# --- the curl seam ---------------------------------------------------------------------------------------------

@test "graph: every request runs curl under env -i (PATH, HOME, LC_ALL only) with --proto =https and --max-time, the Bearer token through a header file; the token body via --data-urlencode from stdin; no key, assertion or token in argv" {
  run --separate-stderr graph check --counts
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(grep -c '^argv=' "$CURL_STUB_LOG")" -eq "$(request_count)" ]
  [ "$(request_count)" -ge 7 ]
  [ "$(grep '^env=' "$CURL_STUB_LOG" | sort -u | paste -sd,)" = "env=HOME,env=LC_ALL,env=PATH" ] || { grep '^env=' "$CURL_STUB_LOG" | sort -u; return 1; }
  [ "$(grep -c "^argv=-sS"$'\037'"--proto"$'\037'"=https"$'\037'"--max-time"$'\037'"60"$'\037' "$CURL_STUB_LOG")" -eq "$(request_count)" ]
  ! grep -E '^argv=.*(BEGIN|eyJ|STUBACCESS|Bearer [^<])' "$CURL_STUB_LOG"
  [ "$(grep -c "^argv=.*"$'\037'"-H"$'\037'"@" "$CURL_STUB_LOG")" -eq $(($(request_count) - 1)) ]
  grep -q "^argv=.*--data-urlencode"$'\037'"client_assertion@-" "$CURL_STUB_LOG"
  ! grep -qF -- "--data-urlencode"$'\037'"client_assertion=" "$CURL_STUB_LOG"
  grep -q '^method=POST .* client_assertion=present ' "$CURL_STUB_LOG"
  [ "$(requests | grep -c 'bearer=present')" -eq $(($(request_count) - 1)) ]
  # the Bearer never lands beside the stub either
  ! grep -rqs STUBACCESS "$CURL_STUB_DIR/curl-stub.log" "$CURL_STUB_DIR/assertion.jwt"
}

@test "graph: the curl stub refuses /me (98), DELETE (97), any POST but …/send and …/move (99), PATCH/PUT (99), a move without destinationId (96), and logs each before deciding" {
  local curl="$CURL_STUB_DIR/curl" before
  run --separate-stderr "$curl" -sS --proto =https --max-time 60 -o /dev/null -w '%{http_code}' "$GRAPH_URL/me/messages"
  [ "$status" -eq 98 ] && [ "$stderr" = "stub: /me requested" ]
  run --separate-stderr "$curl" -sS --proto =https --max-time 60 -o /dev/null -w '%{http_code}' "$GRAPH_URL/me"
  [ "$status" -eq 98 ]
  run --separate-stderr "$curl" -sS --proto =https --max-time 60 -X DELETE -o /dev/null -w '%{http_code}' "$GRAPH_URL/users/$UPN/messages/m1"
  [ "$status" -eq 97 ] && [ "$stderr" = "stub: DELETE requested" ]
  run --separate-stderr "$curl" -sS --proto =https --max-time 60 -X POST -o /dev/null -w '%{http_code}' "$GRAPH_URL/users/$UPN/messages"
  [ "$status" -eq 99 ] && [ "$stderr" = "stub: write verb" ]
  run --separate-stderr "$curl" -sS --proto =https --max-time 60 -X PATCH -o /dev/null -w '%{http_code}' "$GRAPH_URL/users/$UPN/messages/m1"
  [ "$status" -eq 99 ] && [ "$stderr" = "stub: write verb" ]
  run --separate-stderr "$curl" -sS --proto =https --max-time 60 -X PUT -o /dev/null -w '%{http_code}' "$GRAPH_URL/drives/b!onedrive0001/items/01ROOT0001/content"
  [ "$status" -eq 99 ]
  run --separate-stderr bash -c 'printf "{}" | "$0" -sS --proto =https --max-time 60 -X POST --json @- -o /dev/null -w "%{http_code}" "$1"' "$curl" "$GRAPH_URL/users/$UPN/messages/m1/move"
  [ "$status" -eq 96 ] && [ "$stderr" = "stub: move without destinationId" ]
  run --separate-stderr "$curl" -sS --proto =https --max-time 60 -o /dev/null -w '%{http_code}' "$GRAPH_URL/users/$UPN/nothing"
  [ "$status" -eq 99 ] && [[ "$stderr" == "stub: unroutable GET "* ]]
  [ "$(request_count)" -eq 8 ]
  grep -q 'method=DELETE ' "$CURL_STUB_LOG"
  grep -q 'method=POST .* destinationId=absent$' "$CURL_STUB_LOG"
  # the scenario mechanism: a one-shot override is consumed on first match
  before="$(request_count)"
  scenario 'messages/m1\?:418:graph-not-found.json'
  run "$curl" -sS --proto =https --max-time 60 -o "$BATS_TEST_TMPDIR/b1" -D "$BATS_TEST_TMPDIR/h1" -w '%{http_code}' "$GRAPH_URL/users/$UPN/messages/m1?\$select=from,replyTo,conversationId"
  [ "$status" -eq 0 ] && [ "$output" = 418 ]
  grep -q '^HTTP/1.1 418' "$BATS_TEST_TMPDIR/h1"
  cmp "$BATS_TEST_TMPDIR/b1" "$GRAPH_FIXTURES/graph-not-found.json"
  run "$curl" -sS --proto =https --max-time 60 -o "$BATS_TEST_TMPDIR/b2" -w '%{http_code}' "$GRAPH_URL/users/$UPN/messages/m1?\$select=from,replyTo,conversationId"
  [ "$output" = 200 ]
  cmp "$BATS_TEST_TMPDIR/b2" "$GRAPH_FIXTURES/message-m1.json"
  [ ! -s "$CURL_STUB_DIR/curl-stub.scenario" ]
  [ "$(request_count)" -eq $((before + 2)) ]
}

# --- the shared library ------------------------------------------------------------------------------------------

@test "graph: m365-lib.sh defines the one canonical form and hash (jq -S -c over the snapshot keys, sha256sum of the line); it is the only sha256sum call site and graph.sh has one env -i, one -sign, no /me, no PATCH/PUT/DELETE" {
  local lib="$M365/m365-lib.sh" canonical
  [ -f "$lib" ]
  canonical="$(bash -c 'source "$1"; source "$2"; zy_m365_canonical "$3"' _ "$HOOKS/lib.sh" "$lib" \
    '{"isDraft":true,"changeKey":"CK1","id":"d1","body":"never","kind":"draft","subject":"s","to":["b@x.example","a@x.example"],"cc":[],"bcc":[],"from":"f@x.example","receivedDateTime":"2026-09-30T05:31:00Z","parentFolderId":"p"}')"
  [ "$canonical" = '{"bcc":[],"cc":[],"changeKey":"CK1","from":"f@x.example","id":"d1","isDraft":true,"kind":"draft","parentFolderId":"p","receivedDateTime":"2026-09-30T05:31:00Z","subject":"s","to":["b@x.example","a@x.example"]}' ] ||
    { echo "$canonical"; return 1; }
  [ "$(bash -c 'source "$1"; source "$2"; zy_m365_hash "$3"' _ "$HOOKS/lib.sh" "$lib" "$canonical")" = "$(printf '%s\n' "$canonical" | sha256sum | cut -c1-64)" ]
  [ "$(cat "$M365"/*.sh | grep -c 'sha256sum')" -eq 1 ]
  [ "$(grep -c 'env -i' "$GRAPH")" -eq 1 ]
  [ "$(grep -c -- '-sign' "$GRAPH")" -eq 1 ]
  run grep -nE '/me(/|"|$)' "$GRAPH"
  [ "$status" -eq 1 ]
  run grep -nE -- '-X (PATCH|PUT|DELETE)' "$GRAPH"
  [ "$status" -eq 1 ]
  run grep -n 'set -x' "$GRAPH" "$lib" "$STATE_SH"
  [ "$status" -eq 1 ]
  # one POST site each for send and move; DELETE and --hard appear only in the usage refusal; the hooks guard
  # exists twice (cert-init and the write verbs); consent rows are appended by the lib's one flock helper and
  # rewritten by state.sh mark only — graph.sh never touches the files itself
  [ "$(grep -c '/send' "$GRAPH")" -eq 1 ]
  [ "$(grep -c '/move' "$GRAPH")" -eq 1 ]
  run grep -nE 'DELETE|--hard' "$GRAPH"
  [ "$status" -eq 0 ] && [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ] && grep -q 'usage' <<< "$output" || { echo "$output"; return 1; }
  [ "$(grep -c 'zy_hooks_off' "$GRAPH")" -eq 2 ]
  [ "$(grep -c 'flock' "$lib")" -eq 1 ]
  [ "$(grep -c 'flock' "$STATE_SH")" -eq 1 ]
  run grep -nE 'flock|\.jsonl"? *>>|> *"\$ZY_M365_(PROPOSALS|APPROVALS|EXECUTIONS)' "$GRAPH"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

# --- the pseudo-terminal (Step 3) ---------------------------------------------------------------------------------

@test "pty: script is available in the container and on CI; run_on_pty lends the command a tty on stdin and stdout and returns its status" {
  command -v script || { echo "script (bsdutils/util-linux) is missing — assumption 22"; return 1; }
  run run_on_pty /dev/null bash -c 'if [ -t 0 ] && [ -t 1 ]; then echo tty-ok; else echo no-tty; fi; echo "err-line" >&2'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx tty-ok <<< "$output" || { echo "$output"; return 1; }
  grep -qx err-line <<< "$output"
  run run_on_pty /dev/null bash -c 'exit 7'
  [ "$status" -eq 7 ]
  # the no-tty shape the unit and claude -p have
  run bash -c 'if [ -t 0 ] && [ -t 1 ]; then echo tty-ok; else echo no-tty; fi' < /dev/null
  [ "$output" = no-tty ]
}

# --- state.sh: the named keys ---------------------------------------------------------------------------------------

@test "state: get mail-watermark (absent) -> now - 24 h; set/get; file 600 in a 700 dir, no .tmp; bad values, unknown key, path argument -> exit 4; drive-token holds a timestamp; backfill-watermark; replied appends and dedups; ZYGGY_TENANT unset -> 3" {
  local before c
  before="$(state_snapshot)"
  run --separate-stderr "$STATE_SH" get mail-watermark
  [ "$status" -eq 0 ] && [ "$output" = 2026-09-29T10:00:00Z ] || { echo "$status $output $stderr"; return 1; }
  [ "$(state_snapshot)" = "$before" ]
  run --separate-stderr "$STATE_SH" set mail-watermark 2026-09-30T08:00:00Z
  [ "$status" -eq 0 ] && [ -z "$output" ] && [ -z "$stderr" ] || { echo "$status $output $stderr"; return 1; }
  [ "$(stat -c %a "$STATE")" = 700 ]
  [ "$(stat -c %a "$STATE/mail-watermark")" = 600 ]
  [ "$(cat "$STATE/mail-watermark")" = 2026-09-30T08:00:00Z ]
  [ -z "$(find "$STATE" -name '*.tmp')" ]
  run "$STATE_SH" get mail-watermark
  [ "$output" = 2026-09-30T08:00:00Z ]
  before="$(state_snapshot)"
  local -a bad=(
    "set mail-watermark not-a-date" "set mail-watermark 2026-09-30" "set mail-watermark /etc/passwd"
    "set mail-watermark" "set mail-watermark 2026-09-30T08:00:00Z extra" "set nonsense x" "get nonsense" "reset nonsense"
    "get drive-token ../x" "get drive-token" "get drive-token a/b" "set drive-token d1 opaque-abc" "set drive-token d1"
    "get backfill-watermark" "set backfill-watermark inbox 2026-09-30" "get replied 2026-9-30" "set replied 2026-09-30"
    "set replied 2026-09-30 m1 m2" "get mail-watermark extra" "list" "list drafts" "mark" "x"
  )
  for c in "${bad[@]}"; do
    # shellcheck disable=SC2086 # the case is a command line
    run --separate-stderr "$STATE_SH" $c
    [ "$status" -eq 4 ] && [ -z "$output" ] || { echo "case '$c': $status $output"; return 1; }
    [ "$(printf '%s\n' "$stderr" | wc -l)" -eq 1 ] && [[ "$stderr" == "m365-state: "* ]] || { echo "case '$c': $stderr"; return 1; }
    [ "$(state_snapshot)" = "$before" ] || { echo "case '$c' wrote something"; return 1; }
  done
  run --separate-stderr "$STATE_SH" set mail-watermark "$(printf '2026-09-30T08:00:00Z\nx')"
  [ "$status" -eq 4 ] && [[ "$stderr" == "m365-state: invalid value for mail-watermark"* ]]
  run --separate-stderr "$STATE_SH" set mail-watermark "$(printf 'a%.0s' {1..5000})"
  [ "$status" -eq 4 ] && [[ "$stderr" == "m365-state: invalid value for mail-watermark"* ]]
  run --separate-stderr "$STATE_SH" get drive-token "$(printf 'a%.0s' {1..201})"
  [ "$status" -eq 4 ]
  [ "$(cat "$STATE/mail-watermark")" = 2026-09-30T08:00:00Z ]
  # drive-token: a timestamp (the probe found no delta-token argument), per drive
  run "$STATE_SH" get drive-token 'b!onedrive0001'
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run "$STATE_SH" set drive-token 'b!onedrive0001' 2026-09-29T00:00:00Z
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$STATE/drive-b!onedrive0001.token")" = 600 ]
  run "$STATE_SH" get drive-token 'b!onedrive0001'
  [ "$output" = 2026-09-29T00:00:00Z ]
  run "$STATE_SH" reset drive-token 'b!onedrive0001'
  [ "$status" -eq 0 ] && [ ! -e "$STATE/drive-b!onedrive0001.token" ]
  run "$STATE_SH" get drive-token 'b!onedrive0001'
  [ "$status" -eq 0 ] && [ -z "$output" ]
  # backfill-watermark per folder
  run "$STATE_SH" set backfill-watermark inbox 2026-09-01T00:00:00Z
  [ "$status" -eq 0 ] && [ "$(cat "$STATE/backfill-inbox.watermark")" = 2026-09-01T00:00:00Z ]
  run "$STATE_SH" get backfill-watermark inbox
  [ "$output" = 2026-09-01T00:00:00Z ]
  run "$STATE_SH" reset backfill-watermark inbox
  [ ! -e "$STATE/backfill-inbox.watermark" ]
  # replied <date>: ids appended once each
  run "$STATE_SH" get replied 2026-09-30
  [ "$status" -eq 0 ] && [ -z "$output" ]
  "$STATE_SH" set replied 2026-09-30 m1
  "$STATE_SH" set replied 2026-09-30 m2
  "$STATE_SH" set replied 2026-09-30 m1
  run "$STATE_SH" get replied 2026-09-30
  [ "$output" = "$(printf 'm1\nm2')" ] || { echo "$output"; return 1; }
  [ "$(stat -c %a "$STATE/replied-2026-09-30.ids")" = 600 ]
  run "$STATE_SH" reset replied 2026-09-30
  [ ! -e "$STATE/replied-2026-09-30.ids" ]
  [ -z "$(find "$STATE" -name '*.tmp')" ]
  run --separate-stderr env -u ZYGGY_TENANT "$STATE_SH" get mail-watermark
  [ "$status" -eq 3 ] && [ "$stderr" = "m365-state: configuration error: ZYGGY_TENANT is not set" ] || { echo "$stderr"; return 1; }
  XDG_STATE_HOME=/proc/none run --separate-stderr "$STATE_SH" set mail-watermark 2026-09-30T08:00:00Z
  [ "$status" -eq 3 ] && [[ "$stderr" == "m365-state: "*"/proc/none/zyggy/m365"* ]] || { echo "$status $stderr"; return 1; }
}

@test "state: list proposals (empty) -> no proposals; seeded -> one line per row (id status action subject<=60 origin #hash8) oldest first, no body, no full hash; --status filters; mark rewrites one row atomically (600, others byte-identical); bad status or id -> 4" {
  local before
  run --separate-stderr "$STATE_SH" list proposals
  [ "$status" -eq 0 ] && [ "$output" = "no proposals" ] || { echo "$status $output $stderr"; return 1; }
  run "$STATE_SH" list proposals --status pending
  [ "$status" -eq 0 ] && [ "$output" = "no proposals" ]
  # seeded out of order: the listing is by ts, oldest first
  seed_proposal p3
  seed_proposal p1
  seed_proposal p2
  run --separate-stderr "$STATE_SH" list proposals
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$output" = "$(printf '%s\n' \
    "p1 pending send-draft RE: Invoice 2026-41 brief 2026-09-30 #${H1:0:8}" \
    "p2 pending delete Invoice 2026-41 session #${H2:0:8}" \
    "p3 pending move Invoice 2026-41 session #${H3:0:8}")" ] || { echo "$output"; return 1; }
  ! grep -qF "$H1" <<< "$output"
  ! grep -qiE 'carol|alice|BODYTEXT' <<< "$output"
  run "$STATE_SH" list proposals --status pending
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 3 ]
  run "$STATE_SH" list proposals --status executed
  [ "$status" -eq 0 ] && [ "$output" = "no proposals" ]
  # a long subject is cut to 60 characters
  reset_consent
  seed_proposal p1 ".snapshot.subject = \"$(printf 'S%.0s' {1..80})\""
  run "$STATE_SH" list proposals
  [ "$output" = "p1 pending send-draft $(printf 'S%.0s' {1..60}) brief 2026-09-30 #${H1:0:8}" ] || { echo "$output"; return 1; }
  reset_consent
  seed_fixture proposals-pending.jsonl "$PROPOSALS"
  before="$(state_snapshot)"
  local -a bad=("list proposals --status bogus" "list proposals --status" "list proposals extra" "mark p1 bogus" "mark zz executed" "mark p1" "mark" "mark 'p 1' executed")
  local c
  for c in "${bad[@]}"; do
    # shellcheck disable=SC2086
    run --separate-stderr "$STATE_SH" $c
    [ "$status" -eq 4 ] && [ -z "$output" ] && [[ "$stderr" == "m365-state: "* ]] || { echo "case '$c': $status $output $stderr"; return 1; }
    [ "$(state_snapshot)" = "$before" ] || { echo "case '$c' wrote something"; return 1; }
  done
  run --separate-stderr "$STATE_SH" mark zz executed
  [ "$stderr" = "m365-state: no proposal zz" ] || { echo "$stderr"; return 1; }
  # mark: the one row changes, the two others stay byte-identical, the file stays 600 with no .tmp beside it
  sed -n '2,3p' "$PROPOSALS" > "$BATS_TEST_TMPDIR/others-before"
  run --separate-stderr "$STATE_SH" mark p1 executed
  [ "$status" -eq 0 ] && [ -z "$output" ] && [ -z "$stderr" ] || { echo "$status $output $stderr"; return 1; }
  [ "$(row_status p1)" = executed ]
  sed -n '2,3p' "$PROPOSALS" > "$BATS_TEST_TMPDIR/others-after"
  cmp "$BATS_TEST_TMPDIR/others-before" "$BATS_TEST_TMPDIR/others-after"
  [ "$(wc -l < "$PROPOSALS")" -eq 3 ]
  [ "$(stat -c %a "$PROPOSALS")" = 600 ]
  [ -z "$(find "$STATE" -name '*.tmp')" ]
  jq -e --arg h "$H1" '.id == "p1" and .snapshot_hash == $h and .reason == "Carol asked for the invoice date"' <<< "$(sed -n 1p "$PROPOSALS")" > /dev/null
  run "$STATE_SH" list proposals --status executed
  [ "$output" = "p1 executed send-draft RE: Invoice 2026-41 brief 2026-09-30 #${H1:0:8}" ]
  run "$STATE_SH" list proposals --status pending
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
  for c in approved failed refused expired pending; do
    run "$STATE_SH" mark p2 "$c"
    [ "$status" -eq 0 ] && [ "$(row_status p2)" = "$c" ] || { echo "mark $c"; return 1; }
  done
  # the lib's append helper creates the state dir 700 and the file 600 on first write
  reset_consent
  bash -c 'source "$1"; source "$2"; zy_m365_consent_append "$3" "{\"a\":1}"; zy_m365_consent_append "$3" "{\"a\":2}"' _ \
    "$HOOKS/lib.sh" "$M365/m365-lib.sh" "$EXECUTIONS"
  [ "$(stat -c %a "$STATE")" = 700 ] && [ "$(stat -c %a "$EXECUTIONS")" = 600 ]
  [ "$(cat "$EXECUTIONS")" = "$(printf '{"a":1}\n{"a":2}')" ]
  # the fixture hashes bind to the Graph fixtures: H1 is what graph.sh snapshot draft d1 prints
  run --separate-stderr graph snapshot draft d1
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "hash: $H1" ] || { echo "$output"; return 1; }
  run --separate-stderr graph snapshot message m1
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "hash: $H2" ] && [ "$H2" = "$H3" ]
}

# --- graph.sh write verbs: the refusals, in the Contracts' order ---------------------------------------------------

@test "graph: send-draft --approved H1 with ZYGGY_HOOKS=off (under the pty) -> exit 5 refused: unattended run, no request, executions.jsonl absent — before the tty and approval checks" {
  seed_proposal p1
  seed_fixture approvals-p1.jsonl "$APPROVALS"
  ZYGGY_HOOKS=off run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 5 ] || { echo "$status: $output"; return 1; }
  [ "$(last_line)" = "m365: refused: unattended run (ZYGGY_HOOKS=off)" ] || { echo "$output"; return 1; }
  ! grep -q 'executed:' <<< "$output"
  [ "$(request_count)" -eq 0 ]
  [ ! -e "$EXECUTIONS" ]
  # the same with nothing seeded: unattended wins over "no approval"
  reset_consent
  ZYGGY_HOOKS=off run pty_graph move --approved "$H3"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: refused: unattended run (ZYGGY_HOOKS=off)" ]
  ZYGGY_HOOKS=off run pty_graph delete --approved "$H2"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: refused: unattended run (ZYGGY_HOOKS=off)" ]
  [ "$(request_count)" -eq 0 ] && [ ! -e "$EXECUTIONS" ]
}

@test "graph: send-draft --approved H1 without a tty (approval seeded; < /dev/null, stdout to a file) -> exit 5 refused: no terminal, no request — the unit and claude -p shape" {
  local before
  seed_proposal p1
  seed_fixture approvals-p1.jsonl "$APPROVALS"
  before="$(state_snapshot)"
  run --separate-stderr graph send-draft --approved "$H1" < /dev/null
  assert_refused 5 "m365: refused: no terminal" "$before"
  "$GRAPH" send-draft --approved "$H1" < /dev/null > "$BATS_TEST_TMPDIR/no-tty.out" 2> "$BATS_TEST_TMPDIR/no-tty.err" || status=$?
  [ "$status" -eq 5 ] && [ ! -s "$BATS_TEST_TMPDIR/no-tty.out" ] && [ "$(cat "$BATS_TEST_TMPDIR/no-tty.err")" = "m365: refused: no terminal" ]
  # a tty on stdin only, or on stdout only, is not a terminal either
  run run_on_pty /dev/null bash -c '"$0" send-draft --approved "$1" > /dev/null' "$GRAPH" "$H1"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: refused: no terminal" ] || { echo "$status $output"; return 1; }
  run run_on_pty /dev/null bash -c '"$0" send-draft --approved "$1" < /dev/null' "$GRAPH" "$H1"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: refused: no terminal" ] || { echo "$status $output"; return 1; }
  [ "$(request_count)" -eq 0 ] && [ ! -e "$EXECUTIONS" ]
  [ "$(row_status p1)" = pending ]
}

@test "graph: under the pty: no approval -> no approval for row p1; executed row -> already executed; expired approval -> expired (ttl 60 min); action not allowed; hash mismatch -> object changed, approval untouched; sent draft -> no longer a draft; wrong verb for the row; no POST anywhere" {
  local sums
  # (3) a pending row without an approval; an unknown hash names no row
  seed_proposal p1
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: no approval for row p1" ] || { echo "$status $output"; return 1; }
  [ "$(request_count)" -eq 0 ]
  run pty_graph send-draft --approved "$(printf 'f%.0s' {1..64})"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: no approval for row" ] || { echo "$status $output"; return 1; }
  # (4) the row was executed already (single use)
  reset_consent
  seed_fixture proposals-executed.jsonl "$PROPOSALS"
  seed_fixture approvals-p1.jsonl "$APPROVALS"
  seed_fixture executions-p1.jsonl "$EXECUTIONS"
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: row p1 already executed" ] || { echo "$status $output"; return 1; }
  [ "$(wc -l < "$EXECUTIONS")" -eq 1 ]
  reset_consent
  seed_proposal p1 '.status = "refused"'
  seed_fixture approvals-p1.jsonl "$APPROVALS"
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: row p1 refused" ] || { echo "$status $output"; return 1; }
  # (5) the approval is older than consent.ttl_minutes (120 min at ZYGGY_NOW, ttl 60)
  reset_consent
  seed_proposal p1
  seed_fixture approvals-p1-expired.jsonl "$APPROVALS"
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: approval for p1 expired (ttl 60 min)" ] || { echo "$status $output"; return 1; }
  # a longer TTL in the configuration makes the same approval valid again (then the next check speaks)
  cfg '.consent.ttl_minutes = 180 | .consent.allowed_actions = ["move"]'
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: action send-draft not allowed by consent.allowed_actions" ] || { echo "$status $output"; return 1; }
  # (6) the verb must be the row's action
  install_m365_fixture_config
  reset_consent
  seed_proposal p1
  seed_fixture approvals-p1.jsonl "$APPROVALS"
  run pty_graph move --approved "$H1"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: row p1 is a send-draft proposal, not move" ] || { echo "$status $output"; return 1; }
  run pty_graph delete --approved "$H1"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: row p1 is a send-draft proposal, not delete" ]
  [ "$(request_count)" -eq 0 ] || { echo "a request before the approval checks: $(urls)"; return 1; }
  [ ! -e "$EXECUTIONS" ]
  # (7) the current snapshot differs from the approved hash: token + snapshot were the only requests
  sums="$(md5sum "$APPROVALS" "$PROPOSALS")"
  scenario 'messages/d1\?:200:snapshot-d1-changed.json'
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 5 ] || { echo "$status $output"; return 1; }
  [ "$(last_line)" = "m365: object changed since approval (hash mismatch) — re-run m365-approve.sh" ] || { echo "$output"; return 1; }
  grep -qx 'key: file' <<< "$output"
  [ "$(urls)" = "$(printf '%s\n' "POST $TOKEN_URL" "GET $GRAPH_URL/users/$UPN/messages/d1?\$select=id,subject,toRecipients,ccRecipients,bccRecipients,from,receivedDateTime,parentFolderId,changeKey,isDraft")" ] ||
    { urls; return 1; }
  [ "$(md5sum "$APPROVALS" "$PROPOSALS")" = "$sums" ]
  : > "$CURL_STUB_LOG"
  scenario 'messages/d1\?:200:snapshot-d1-sent.json'
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: d1 is no longer a draft" ] || { echo "$status $output"; return 1; }
  [ "$(urls | grep -c '^POST ')" -eq 1 ]
  [ "$(md5sum "$APPROVALS" "$PROPOSALS")" = "$sums" ]
  [ ! -e "$EXECUTIONS" ]
  ! grep -q 'executed:' <<< "$output"
  ! grep -qE 'messages/d1/send|messages/m1/move' "$CURL_STUB_LOG"
}

# --- graph.sh write verbs: the executions ----------------------------------------------------------------------------

@test "graph: under the pty, approval H1 valid, snapshot unchanged, 202 on POST …/messages/d1/send -> executed: send-draft H1 (202); executions.jsonl (600) gained the row; p1 executed; exactly token, snapshot, POST; a second call -> already executed" {
  seed_proposal p1
  seed_fixture approvals-p1.jsonl "$APPROVALS"
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 0 ] || { echo "$status: $output"; return 1; }
  [ "$(last_line)" = "executed: send-draft $H1 (202)" ] || { echo "$output"; return 1; }
  grep -qx 'key: file' <<< "$output"
  [ "$(urls)" = "$(printf '%s\n' "POST $TOKEN_URL" \
    "GET $GRAPH_URL/users/$UPN/messages/d1?\$select=id,subject,toRecipients,ccRecipients,bccRecipients,from,receivedDateTime,parentFolderId,changeKey,isDraft" \
    "POST $GRAPH_URL/users/$UPN/messages/d1/send")" ] || { urls; return 1; }
  [ "$(requests | grep -c "method=POST url=$GRAPH_URL/users/$UPN/messages/d1/send .* bearer=present .* destinationId=absent")" -eq 1 ]
  [ "$(stat -c %a "$STATE")" = 700 ]
  [ "$(stat -c %a "$EXECUTIONS")" = 600 ]
  [ "$(stat -c %a "$PROPOSALS")" = 600 ]
  [ "$(executions)" = "{\"row_id\":\"p1\",\"hash\":\"$H1\",\"verb\":\"send-draft\",\"http_status\":202,\"ts\":\"2026-09-30T10:00:00Z\"}" ] || { executions; return 1; }
  [ "$(row_status p1)" = executed ]
  [ "$(wc -l < "$PROPOSALS")" -eq 1 ]
  [ "$(wc -l < "$APPROVALS")" -eq 1 ]
  [ -z "$(find "$STATE" -name '*.tmp')" ]
  # the approval is used up with the row
  : > "$CURL_STUB_LOG"
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: row p1 already executed" ] || { echo "$status $output"; return 1; }
  [ "$(request_count)" -eq 0 ]
  [ "$(wc -l < "$EXECUTIONS")" -eq 1 ]
}

@test "graph: move --approved H3 valid -> POST …/messages/m1/move destinationId=archive (well-known, as-is) -> 201 executed: move H3 (201); a display name Archive resolves to its folder id; an unknown folder -> exit 5 folder not found, row failed, no POST" {
  seed_proposal p3
  seed_approval p3 "$H3"
  run pty_graph move --approved "$H3"
  [ "$status" -eq 0 ] || { echo "$status: $output"; return 1; }
  [ "$(last_line)" = "executed: move $H3 (201)" ] || { echo "$output"; return 1; }
  [ "$(urls)" = "$(printf '%s\n' "POST $TOKEN_URL" \
    "GET $GRAPH_URL/users/$UPN/messages/m1?\$select=id,subject,toRecipients,ccRecipients,bccRecipients,from,receivedDateTime,parentFolderId,changeKey,isDraft" \
    "POST $GRAPH_URL/users/$UPN/messages/m1/move")" ] || { urls; return 1; }
  [ "$(requests | grep -c 'method=POST .*messages/m1/move .* destinationId=archive$')" -eq 1 ] || { requests; return 1; }
  [ "$(executions)" = "{\"row_id\":\"p3\",\"hash\":\"$H3\",\"verb\":\"move\",\"http_status\":201,\"ts\":\"2026-09-30T10:00:00Z\"}" ] || { executions; return 1; }
  [ "$(row_status p3)" = executed ]
  # a display name is resolved through the folder list (Archive is AQMkArchive0001 in the fixtures)
  reset_consent
  seed_proposal p3 '.folder = "Archive"'
  seed_approval p3 "$H3"
  run pty_graph move --approved "$H3"
  [ "$status" -eq 0 ] && [ "$(last_line)" = "executed: move $H3 (201)" ] || { echo "$status $output"; return 1; }
  [ "$(requests | grep -c 'method=POST .*messages/m1/move .* destinationId=AQMkArchive0001$')" -eq 1 ] || { requests; return 1; }
  grep -qF "GET $GRAPH_URL/users/$UPN/mailFolders?\$top=100" <(urls)
  # a folder id is accepted as-is too
  reset_consent
  seed_proposal p3 '.folder = "AQMkArchive0001"'
  seed_approval p3 "$H3"
  run pty_graph move --approved "$H3"
  [ "$status" -eq 0 ]
  [ "$(requests | grep -c 'destinationId=AQMkArchive0001$')" -eq 1 ]
  # an unknown folder: refused, the row failed, nothing moved
  reset_consent
  seed_proposal p3 '.folder = "Nowhere"'
  seed_approval p3 "$H3"
  run pty_graph move --approved "$H3"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: folder Nowhere not found" ] || { echo "$status $output"; return 1; }
  [ "$(row_status p3)" = failed ]
  [ ! -e "$EXECUTIONS" ]
  ! grep -q 'messages/m1/move' "$CURL_STUB_LOG"
  # a row without a folder cannot be moved
  reset_consent
  seed_proposal p3 'del(.folder)'
  seed_approval p3 "$H3"
  run pty_graph move --approved "$H3"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: row p3 names no folder" ] || { echo "$status $output"; return 1; }
  [ "$(row_status p3)" = failed ]
}

@test "graph: delete --approved H2 valid -> POST …/messages/m1/move destinationId=deleteditems (the stub asserts it) -> 201 executed: delete H2 (201); DELETE never issued (stub exit 97 never fires); two rows on one object pick the row of the verb" {
  seed_proposal p2
  seed_proposal p3
  seed_approval p3 "$H3"
  seed_approval p2 "$H2"
  run pty_graph delete --approved "$H2"
  [ "$status" -eq 0 ] || { echo "$status: $output"; return 1; }
  [ "$(last_line)" = "executed: delete $H2 (201)" ] || { echo "$output"; return 1; }
  [ "$(urls)" = "$(printf '%s\n' "POST $TOKEN_URL" \
    "GET $GRAPH_URL/users/$UPN/messages/m1?\$select=id,subject,toRecipients,ccRecipients,bccRecipients,from,receivedDateTime,parentFolderId,changeKey,isDraft" \
    "POST $GRAPH_URL/users/$UPN/messages/m1/move")" ] || { urls; return 1; }
  [ "$(requests | grep -c 'method=POST .*messages/m1/move .* destinationId=deleteditems$')" -eq 1 ] || { requests; return 1; }
  ! grep -q 'method=DELETE' "$CURL_STUB_LOG"
  ! grep -q 'stub:' <<< "$output"
  [ "$(executions)" = "{\"row_id\":\"p2\",\"hash\":\"$H2\",\"verb\":\"delete\",\"http_status\":201,\"ts\":\"2026-09-30T10:00:00Z\"}" ] || { executions; return 1; }
  [ "$(row_status p2)" = executed ]
  [ "$(row_status p3)" = pending ]
  # the other row on the same object still executes against its own approval
  : > "$CURL_STUB_LOG"
  run pty_graph move --approved "$H3"
  [ "$status" -eq 0 ] && [ "$(last_line)" = "executed: move $H3 (201)" ] || { echo "$status $output"; return 1; }
  [ "$(row_status p3)" = executed ]
  [ "$(wc -l < "$EXECUTIONS")" -eq 2 ]
  # the same hash again, for a verb no pending row carries: the newest approval's row speaks
  run pty_graph delete --approved "$H2"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: row p2 already executed" ] || { echo "$status $output"; return 1; }
}

@test "graph: send-draft valid but 403 -> exit 6 forbidden … \"Scope or grant missing\", executions row 403, p1 failed; a failed row refuses until marked pending and re-approved, then the send succeeds; 6x429 -> exit 6 failed; 2x429 then 202 -> executed" {
  seed_proposal p1
  seed_fixture approvals-p1.jsonl "$APPROVALS"
  scenario 'messages/d1/send:403:graph-forbidden.json'
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 6 ] || { echo "$status: $output"; return 1; }
  [ "$(last_line)" = 'm365: forbidden (ErrorAccessDenied) — runbook 13 "Scope or grant missing"' ] || { echo "$output"; return 1; }
  ! grep -q 'executed:' <<< "$output"
  [ "$(executions)" = "{\"row_id\":\"p1\",\"hash\":\"$H1\",\"verb\":\"send-draft\",\"http_status\":403,\"ts\":\"2026-09-30T10:00:00Z\"}" ] || { executions; return 1; }
  [ "$(row_status p1)" = failed ]
  [ "$(urls | grep -c 'messages/d1/send$')" -eq 1 ]
  # failed: refused until the owner re-approves
  : > "$CURL_STUB_LOG"
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365: row p1 failed earlier — re-approve it with m365-approve.sh" ] || { echo "$status $output"; return 1; }
  [ "$(request_count)" -eq 0 ]
  "$STATE_SH" mark p1 pending
  seed_approval p1 "$H1" 2026-09-30T09:58:00Z
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 0 ] && [ "$(last_line)" = "executed: send-draft $H1 (202)" ] || { echo "$status $output"; return 1; }
  [ "$(wc -l < "$EXECUTIONS")" -eq 2 ]
  [ "$(jq -r .http_status "$EXECUTIONS" | paste -sd,)" = "403,202" ]
  [ "$(row_status p1)" = executed ]
  # throttled six times: exit 6, failed, one row with 429
  reset_consent
  seed_proposal p1
  seed_fixture approvals-p1.jsonl "$APPROVALS"
  local i
  for i in 1 2 3 4 5 6; do scenario 'messages/d1/send:429:-:retry-after-2.hdr'; done
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 6 ] || { echo "$status: $output"; return 1; }
  [ "$(last_line)" = 'm365: throttled (429) after 5 retries — runbook 13 "Throttling"' ] || { echo "$output"; return 1; }
  [ "$(urls | grep -c 'messages/d1/send$')" -eq 6 ]
  [ "$(jq -r .http_status "$EXECUTIONS")" = 429 ]
  [ "$(row_status p1)" = failed ]
  # throttled twice, then accepted
  reset_consent
  seed_proposal p1
  seed_fixture approvals-p1.jsonl "$APPROVALS"
  scenario 'messages/d1/send:429:-:retry-after-2.hdr'
  scenario 'messages/d1/send:429:-:retry-after-2.hdr'
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 0 ] && [ "$(last_line)" = "executed: send-draft $H1 (202)" ] || { echo "$status $output"; return 1; }
  [ "$(urls | grep -c 'messages/d1/send$')" -eq 3 ]
  [ "$(jq -r .http_status "$EXECUTIONS")" = 202 ]
  [ "$(row_status p1)" = executed ]
  # a 404 on the target during the snapshot is a Graph failure (exit 6), nothing recorded
  reset_consent
  seed_proposal p1
  seed_fixture approvals-p1.jsonl "$APPROVALS"
  scenario 'messages/d1\?:404:graph-not-found.json'
  run pty_graph send-draft --approved "$H1"
  [ "$status" -eq 6 ] && [ "$(last_line)" = "m365: not found (d1)" ] || { echo "$status $output"; return 1; }
  [ ! -e "$EXECUTIONS" ] && [ "$(row_status p1)" = pending ]
}

# --- mcp-wrapper.sh: the server start (Step 4, AC-34, AC-43, AC-44) ---------------------------------------------

# Step 1's ENABLED_TOOLS, verbatim (plan 23 "Probe findings").
STEP1_REGEX='^(create-shared-mailbox-draft|create-shared-mailbox-reply-draft|download-bytes-to-file|get-drive-delta|get-drive-item|get-drive-root-item|get-shared-mailbox-message|get-sharepoint-site-drive-by-id|list-drive-item-versions|list-folder-files|list-shared-mailbox-folder-messages|list-shared-mailbox-messages|list-sharepoint-site-drives|search-onedrive-files)$'
SERVER_ENV_NAMES='ENABLED_TOOLS HOME LC_ALL MS365_MCP_CLIENT_ID MS365_MCP_OAUTH_TOKEN MS365_MCP_ORG_MODE MS365_MCP_TENANT_ID MS365_MCP_TOKEN_CACHE_PATH MS365_MCP_USE_KEYTAR NODE_OPTIONS PATH'
AUTH_LINE='auth tools registered outside the filter: list-accounts login logout remove-account select-account verify-login (denied by settings)'

wrapper() {
  "$M365/mcp-wrapper.sh" "$@"
}

server_log() { # the server stub's log, or nothing
  local f="$HOME/.local/bin/server-stub.log"
  if [ -f "$f" ]; then cat "$f"; fi
}

@test "wrapper: ZYGGY_TENANT unset / m365.json invalid -> exit 3, no request, server not started" {
  install_m365_server_stub
  local before
  before="$(state_snapshot)"
  unset ZYGGY_TENANT
  run --separate-stderr wrapper < /dev/null
  [ "$status" -eq 3 ] && [ "$stderr" = "m365: configuration error: ZYGGY_TENANT is not set" ] || { echo "$status $stderr"; return 1; }
  [ -z "$output" ] && [ -z "$(server_log)" ] && [ "$(request_count)" -eq 0 ]
  export ZYGGY_TENANT=acme
  cfg '.tenant_id = "x"'
  run --separate-stderr wrapper < /dev/null
  [ "$status" -eq 3 ] && [ "$stderr" = "m365: configuration error: tenant_id is not a GUID" ] || { echo "$status $stderr"; return 1; }
  [ -z "$output" ] && [ -z "$(server_log)" ] && [ "$(request_count)" -eq 0 ]
  cfg '.tenant_id = "11111111-1111-4111-8111-111111111111" | .consent.ttl_minutes = 0'
  run --separate-stderr wrapper --probe < /dev/null
  [ "$status" -eq 3 ] && [ -z "$(server_log)" ] && [ "$(request_count)" -eq 0 ]
  [ "$(state_snapshot)" = "$before" ]
}

@test "wrapper: an unknown argument -> exit 4 with the usage, nothing started" {
  install_m365_server_stub
  run --separate-stderr wrapper --http < /dev/null
  [ "$status" -eq 4 ] && [ "$stderr" = "m365: unexpected argument '--http' (usage: mcp-wrapper.sh [--probe])" ] || { echo "$status $stderr"; return 1; }
  [ -z "$(server_log)" ] && [ "$(request_count)" -eq 0 ]
}

@test "wrapper: no ms-365-mcp-server -> exit 3 'not found'; one outside \$HOME/.local (also via a symlink) -> exit 3 'not under'; no request" {
  run --separate-stderr wrapper < /dev/null
  [ "$status" -eq 3 ] || { echo "$status $stderr"; return 1; }
  [ "$stderr" = 'm365: ms-365-mcp-server not found — runbook 13 "Install or upgrade the MCP server"' ] || { echo "$stderr"; return 1; }
  [ "$(request_count)" -eq 0 ]
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  cp "$FIXTURES/m365/ms-365-mcp-server-stub.sh" "$BATS_TEST_TMPDIR/elsewhere/ms-365-mcp-server"
  chmod +x "$BATS_TEST_TMPDIR/elsewhere/ms-365-mcp-server"
  PATH="$BATS_TEST_TMPDIR/elsewhere:$PATH" run --separate-stderr wrapper < /dev/null
  [ "$status" -eq 3 ] || { echo "$status $stderr"; return 1; }
  [ "$stderr" = "m365: ms-365-mcp-server at $BATS_TEST_TMPDIR/elsewhere/ms-365-mcp-server is not under $HOME/.local — runbook 13 \"Install or upgrade the MCP server\"" ] ||
    { echo "$stderr"; return 1; }
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere/server-stub.log" ] && [ "$(request_count)" -eq 0 ]
  mkdir -p "$HOME/.local/bin"
  ln -s "$BATS_TEST_TMPDIR/elsewhere/ms-365-mcp-server" "$HOME/.local/bin/ms-365-mcp-server"
  PATH="$HOME/.local/bin:$PATH" run --separate-stderr wrapper < /dev/null
  [ "$status" -eq 3 ] && [[ "$stderr" == *" is not under $HOME/.local "* ]] || { echo "$status $stderr"; return 1; }
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere/server-stub.log" ] && [ "$(request_count)" -eq 0 ]
}

@test "wrapper: graph.sh token failing (invalid_client) -> exit 6, one stderr line, the server never started" {
  install_m365_server_stub
  scenario 'oauth2/v2.0/token:400:token-invalid-client.json'
  run --separate-stderr wrapper < /dev/null
  [ "$status" -eq 6 ] || { echo "$status $stderr"; return 1; }
  [ "$stderr" = 'm365: auth failed (invalid_client) — runbook 13 "Certificate rejected"' ] || { echo "$stderr"; return 1; }
  [ -z "$output" ] && [ -z "$(server_log)" ]
  # a missing key is graph.sh's exit 3, propagated
  rm -f "$ZYGGY_M365_KEY_FILE"
  run --separate-stderr wrapper --probe < /dev/null
  [ "$status" -eq 3 ] && [ "$stderr" = "m365: key: not found in credentials directory or file" ] || { echo "$status $stderr"; return 1; }
  [ -z "$(server_log)" ]
}

@test "wrapper: the server runs in a cleared environment of exactly the eleven names, argv --org-mode only, token=match, the values as contracted; stdout untouched" {
  install_m365_server_stub
  local log name
  MS365_MCP_HTTP=1 MS365_MCP_EXPECTED_USERNAME=x NODE_OPTIONS=--inspect GH_TOKEN=x CREDENTIALS_DIRECTORY=/x \
    ZYGGY_HOOKS=off MS365_MCP_READ_ONLY=1 run --separate-stderr wrapper < /dev/null
  [ "$status" -eq 0 ] || { echo "$status $stderr"; return 1; }
  # MCP speaks on stdout: the wrapper writes nothing there itself; graph.sh's key line passes through on stderr once
  [ -z "$output" ] && [ "$stderr" = "key: file" ] || { echo "out: $output / err: $stderr"; return 1; }
  log="$(server_log)"
  [ "$(grep -c '^argv=' <<< "$log")" -eq 1 ] && grep -qx 'argv=--org-mode' <<< "$log" || { echo "$log"; return 1; }
  [ "$(grep '^env=' <<< "$log" | cut -d= -f2 | tr '\n' ' ')" = "$SERVER_ENV_NAMES " ] || { echo "$log"; return 1; }
  grep -qx 'token=match' <<< "$log"
  for name in "NODE_OPTIONS=--max-old-space-size=512" "MS365_MCP_ORG_MODE=1" "MS365_MCP_USE_KEYTAR=0" \
    "MS365_MCP_CLIENT_ID=$CLIENT" "MS365_MCP_TENANT_ID=$TENANT" "LC_ALL=C" "HOME=$HOME" \
    "PATH=/usr/bin:/bin:$HOME/.local/bin" "MS365_MCP_TOKEN_CACHE_PATH=$STATE/never-written.json"; do
    grep -qxF "value=$name" <<< "$log" || { echo "missing value=$name"; echo "$log"; return 1; }
  done
  [ "$(grep '^value=ENABLED_TOOLS=' <<< "$log")" = "value=ENABLED_TOOLS=$STEP1_REGEX" ] || { echo "$log"; return 1; }
  ! grep -qE 'EXPECTED_USERNAME|ALLOWED_SCOPES|MS365_MCP_HTTP|READ_ONLY|GH_TOKEN|CREDENTIALS_DIRECTORY|ZYGGY_' <<< "$log"
  [ ! -e "$STATE/never-written.json" ]
  # one token request, nothing else
  [ "$(urls)" = "POST $TOKEN_URL" ] || { urls; return 1; }
}

@test "wrapper --probe: tools: 14, the enabled names sorted, the six auth tools reported outside the filter, the env names; exit 0" {
  install_m365_server_stub
  run --separate-stderr wrapper --probe < /dev/null
  [ "$status" -eq 0 ] || { echo "$status $stderr / $output"; return 1; }
  [ "$stderr" = "key: file" ] || { echo "$stderr"; return 1; }
  local expected
  expected="$(printf 'tools: 14\n'; cat "$ENABLED"; printf '%s\n' "$AUTH_LINE" "env: $SERVER_ENV_NAMES")"
  [ "$output" = "$expected" ] || { diff <(printf '%s\n' "$expected") <(printf '%s\n' "$output"); return 1; }
  # the handshake the server saw, and the token it got
  [ "$(grep '^rpc=' "$SERVER_STUB_LOG" | tr '\n' ' ')" = "rpc=initialize rpc=notifications/initialized rpc=tools/list " ] ||
    { cat "$SERVER_STUB_LOG"; return 1; }
  grep -qx 'token=match' "$SERVER_STUB_LOG"
  grep -qx 'argv=--org-mode' "$SERVER_STUB_LOG"
}

@test "wrapper --probe: mode notools -> exit 6 'offered 0 tools'; badregex -> exit 6 'server rejected ENABLED_TOOLS'; leaky -> exit 6 naming a tool outside the filter" {
  install_m365_server_stub notools
  run --separate-stderr wrapper --probe < /dev/null
  [ "$status" -eq 6 ] && [ -z "$output" ] || { echo "$status $output"; return 1; }
  [ "$stderr" = "$(printf 'key: file\nm365: server offered 0 tools — runbook 13 "Install or upgrade the MCP server"')" ] || { echo "$stderr"; return 1; }
  printf badregex > "$HOME/.local/bin/server-stub.mode"
  run --separate-stderr wrapper --probe < /dev/null
  [ "$status" -eq 6 ] && [ -z "$output" ] || { echo "$status $output"; return 1; }
  [ "$stderr" = "$(printf 'key: file\nm365: server rejected ENABLED_TOOLS')" ] || { echo "$stderr"; return 1; }
  printf leaky > "$HOME/.local/bin/server-stub.mode"
  run --separate-stderr wrapper --probe < /dev/null
  [ "$status" -eq 6 ] && [ -z "$output" ] || { echo "$status $output"; return 1; }
  [[ "$stderr" == *'m365: server offered tools outside ENABLED_TOOLS beyond the six auth tools ('*'accept-calendar-event'*') — runbook 13 "Install or upgrade the MCP server"' ]] ||
    { echo "$stderr"; return 1; }
}

@test "wrapper: ZYGGY_HOOKS=off is accepted (the brief run starts the server)" {
  install_m365_server_stub
  ZYGGY_HOOKS=off run --separate-stderr wrapper < /dev/null
  [ "$status" -eq 0 ] && grep -qx 'token=match' "$SERVER_STUB_LOG" || { echo "$status $stderr"; return 1; }
  ZYGGY_HOOKS=off run --separate-stderr wrapper --probe < /dev/null
  [ "$status" -eq 0 ] && [ "${output%%$'\n'*}" = "tools: 14" ] || { echo "$status $output $stderr"; return 1; }
}

# --- propose.sh and the m365-approve.sh consent terminal (Step 5) -----------------------------------------------------

PROPOSE_TAIL=' — review with m365-approve.sh on the VM'
ULID_RE='[0-9A-HJKMNP-TV-Z]{26}'

propose() {
  "$M365/propose.sh" "$@"
}

approve_on_pty() { # approve_on_pty <answers file: a name under tests/fixtures/m365, or a path> [args…]
  local answers="$1"
  shift
  [[ "$answers" == /* ]] || answers="$M365_FIXTURES/$answers"
  run_on_pty "$answers" "$M365/m365-approve.sh" "$@"
}

answers() { # answers <char>… → an answers file in the test directory, one per line
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/answers.txt"
  printf '%s' "$BATS_TEST_TMPDIR/answers.txt"
}

# A golden with the computed hashes put in: @H1@ etc. (full) or, with "8", their first eight characters.
golden() { # golden <file under tests/expected> [8]
  local s n=64
  [ "${2:-}" != 8 ] || n=8
  s="$(cat "$EXPECTED/$1")"
  s="${s//@H1@/${H1:0:$n}}"
  s="${s//@H2@/${H2:0:$n}}"
  printf '%s' "${s//@H3@/${H3:0:$n}}"
}

fixture_snapshot() { # fixture_snapshot <row id> → that fixture row's snapshot object
  jq -c --arg id "$1" 'select(.id == $id) | .snapshot' "$M365_FIXTURES/proposals-pending.jsonl"
}

screen_before_first_prompt() { # the pty output up to and including the first answered prompt line
  sed -n '1,/^\[y\]es \/ \[n\]o \/ \[s\]kip \/ \[q\]uit: /p' <<< "$output"
}

@test "propose: send-draft d1 --reason … -> exit 0, one pending row (600) whose snapshot and hash are graph.sh snapshot's, origin session, not flagged; the stdout line; token, snapshot and message-sender requests, never a body; ZYGGY_HOOKS=off proposes the same" {
  local id gets
  "$STATE_SH" set replied 2026-09-30 m1
  run --separate-stderr propose send-draft d1 --reason "Carol asked for the invoice date"
  [ "$status" -eq 0 ] || { echo "$status $output $stderr"; return 1; }
  [[ "$output" =~ ^proposed:\ ($ULID_RE)\ send-draft\ \"RE:\ Invoice\ 2026-41\"$PROPOSE_TAIL$ ]] || { echo "$output"; return 1; }
  id="${BASH_REMATCH[1]}"
  [ -z "$stderr" ] || { echo "stderr: $stderr"; return 1; }
  [ "$(stat -c %a "$STATE")" = 700 ] && [ "$(stat -c %a "$PROPOSALS")" = 600 ]
  [ "$(wc -l < "$PROPOSALS")" -eq 1 ]
  jq -e --arg id "$id" --arg h "$H1" --argjson s "$(fixture_snapshot p1)" '.id == $id and .ts == "2026-09-30T10:00:00Z"
    and .action == "send-draft" and .target_id == "d1" and .snapshot == $s and .snapshot_hash == $h
    and .reason == "Carol asked for the invoice date" and .origin == "session" and .status == "pending"
    and .recipient_outside_policy == false and .recipient_policy == ["alice@acme.example", "carol@example.org"]
    and (has("folder") | not) and (keys | length) == 11' "$PROPOSALS" || { cat "$PROPOSALS"; return 1; }
  # Graph only: the snapshot, the Draft's conversation, the replied-to message's sender — no body ($select=…body)
  gets="$(urls | grep '^GET ')"
  [ "$gets" = "$(printf '%s\n' "GET $GRAPH_URL/users/$UPN/messages/d1?\$select=id,subject,toRecipients,ccRecipients,bccRecipients,from,receivedDateTime,parentFolderId,changeKey,isDraft" \
    "GET $GRAPH_URL/users/$UPN/messages/d1?\$select=from,replyTo,conversationId" "GET $GRAPH_URL/users/$UPN/messages/m1?\$select=from,replyTo,conversationId")" ] ||
    { urls; return 1; }
  [ "$(urls | grep -vc "^POST $TOKEN_URL\$")" -eq 3 ]
  # the row's snapshot is byte for byte graph.sh snapshot's canonical line
  [ "$(graph snapshot draft d1 2> /dev/null | sed -n 1p)" = "$(jq -c '.snapshot' "$PROPOSALS")" ]
  # proposing is allowed unattended, without a terminal (the brief run)
  reset_consent
  "$STATE_SH" set replied 2026-09-30 m1
  ZYGGY_HOOKS=off run --separate-stderr propose send-draft d1 --reason "Carol asked for the invoice date" < /dev/null
  [ "$status" -eq 0 ] && [[ "$output" =~ ^proposed:\ $ULID_RE\ send-draft ]] || { echo "$status $output $stderr"; return 1; }
  jq -e --arg h "$H1" '.snapshot_hash == $h and .status == "pending"' "$PROPOSALS"
}

@test "propose: origin is \"brief <date>\" when brief.sh exports ZYGGY_M365_ORIGIN (\"brief 2026-09-30\" or \"brief\"), else session; any other value -> exit 4" {
  ZYGGY_M365_ORIGIN="brief 2026-09-30" run --separate-stderr propose delete m1 --reason "Newsletter"
  [ "$status" -eq 0 ] || { echo "$status $stderr"; return 1; }
  [ "$(jq -r .origin "$PROPOSALS")" = "brief 2026-09-30" ]
  reset_consent
  ZYGGY_M365_ORIGIN=brief run --separate-stderr propose delete m1 --reason "Newsletter"
  [ "$(jq -r .origin "$PROPOSALS")" = "brief 2026-09-30" ]
  reset_consent
  ZYGGY_M365_ORIGIN=session run --separate-stderr propose delete m1 --reason "Newsletter"
  [ "$(jq -r .origin "$PROPOSALS")" = session ]
  reset_consent
  ZYGGY_M365_ORIGIN="anything" run --separate-stderr propose delete m1 --reason "Newsletter"
  [ "$status" -eq 4 ] && [ "$stderr" = "m365-propose: ZYGGY_M365_ORIGIN must be 'brief [<date>]' or 'session'" ] || { echo "$status $stderr"; return 1; }
  [ ! -e "$PROPOSALS" ]
}

@test "propose: move m1 archive -> folder archive; move m1 \"Projects/2026\" -> folder kept verbatim; delete m1 -> action delete; snapshots of the message, never flagged; a second send-draft d1 -> \"proposed: <same id> (duplicate)\", no new row" {
  local id
  run --separate-stderr propose move m1 archive --reason "Keep the thread with the other invoices"
  [ "$status" -eq 0 ] && [[ "$output" =~ ^proposed:\ $ULID_RE\ move\ \"Invoice\ 2026-41\"$PROPOSE_TAIL$ ]] || { echo "$status $output $stderr"; return 1; }
  jq -e --arg h "$H3" --argjson s "$(fixture_snapshot p3)" '.action == "move" and .target_id == "m1" and .folder == "archive"
    and .snapshot == $s and .snapshot_hash == $h and .recipient_outside_policy == false and (has("recipient_policy") | not)' "$PROPOSALS"
  ! grep -q 'from,replyTo,conversationId' "$CURL_STUB_LOG"
  reset_consent
  run --separate-stderr propose move m1 "Projects/2026" --reason x
  [ "$status" -eq 0 ] || { echo "$status $stderr"; return 1; }
  [ "$(jq -r .folder "$PROPOSALS")" = "Projects/2026" ]
  reset_consent
  run --separate-stderr propose delete m1 --reason x
  [ "$status" -eq 0 ] && [[ "$output" =~ ^proposed:\ $ULID_RE\ delete\ \"Invoice\ 2026-41\" ]] || { echo "$status $output"; return 1; }
  jq -e --arg h "$H2" '.action == "delete" and .snapshot_hash == $h and (has("folder") | not)' "$PROPOSALS"
  # dedup by action + target while the row is pending
  run --separate-stderr propose send-draft d1 --reason "first"
  id="$(jq -r 'select(.action == "send-draft") | .id' "$PROPOSALS")"
  : > "$CURL_STUB_LOG"
  run --separate-stderr propose send-draft d1 --reason "second"
  [ "$status" -eq 0 ] && [ "$output" = "proposed: $id (duplicate)" ] || { echo "$status $output $stderr"; return 1; }
  [ "$(wc -l < "$PROPOSALS")" -eq 2 ] && [ "$(request_count)" -eq 0 ]
  # once the row is no longer pending, the same action may be proposed again
  "$STATE_SH" mark "$id" refused
  run --separate-stderr propose send-draft d1 --reason "third"
  [ "$status" -eq 0 ] && [ "$(wc -l < "$PROPOSALS")" -eq 3 ] || { echo "$status $output"; return 1; }
  # ULID-like ids differ
  [ "$(jq -r .id "$PROPOSALS" | sort -u | wc -l)" -eq 3 ]
}

@test "propose: a recipient outside {mailbox, the replied-to sender} -> recorded and flagged; not a draft -> 4; 404 -> 6; forward/send-all -> 4; recipient/body/subject options -> 4; reason > 500, URL, e-mail, secret -> 4 (never echoed); control chars stripped; delete not allowed -> 4; nothing written when refused" {
  local long a o r
  "$STATE_SH" set replied 2026-09-30 m1
  scenario 'messages/d1\?\$select=id,subject,toRecipients:200:snapshot-d1-outside.json'
  run --separate-stderr propose send-draft d1 --reason "Carol asked for the invoice date"
  [ "$status" -eq 0 ] || { echo "$status $stderr"; return 1; }
  [[ "$output" == *"$PROPOSE_TAIL (recipient outside policy)" ]] || { echo "$output"; return 1; }
  jq -e '.recipient_outside_policy == true and .snapshot.to == ["carol@example.org", "mallory@external.example"]' "$PROPOSALS"
  # with no replied-to message recorded the policy is the mailbox alone: carol is outside too
  reset_consent
  run --separate-stderr propose send-draft d1 --reason "Carol asked"
  [ "$status" -eq 0 ] && [[ "$output" == *"(recipient outside policy)" ]] || { echo "$output"; return 1; }
  jq -e '.recipient_policy == ["alice@acme.example"]' "$PROPOSALS"
  reset_consent
  scenario 'messages/d1\?\$select=id,subject,toRecipients:200:snapshot-d1-sent.json'
  run --separate-stderr propose send-draft d1 --reason x
  [ "$status" -eq 4 ] && [ "$stderr" = "m365-propose: d1 is not a draft" ] || { echo "$status $stderr"; return 1; }
  [ ! -e "$PROPOSALS" ]
  scenario 'messages/d1\?\$select=id,subject,toRecipients:404:graph-not-found.json'
  run --separate-stderr propose send-draft d1 --reason x
  [ "$status" -eq 6 ] && [ "$stderr" = "m365-propose: not found (d1)" ] || { echo "$status $stderr"; return 1; }
  [ ! -e "$PROPOSALS" ]
  : > "$CURL_STUB_LOG"
  for a in forward send-all reply; do
    run --separate-stderr propose "$a" m1 --reason x
    [ "$status" -eq 4 ] && [[ "$stderr" == "m365-propose: unknown action '$a' (only send-draft, move and delete exist) (usage: "* ]] || { echo "$a: $status $stderr"; return 1; }
  done
  for o in --to --to=bob@example.org --cc --bcc --body --body=hi --subject --recipients; do
    run --separate-stderr propose send-draft d1 "$o" x --reason x
    [ "$status" -eq 4 ] && [ "$stderr" = "m365-propose: no recipient, body or subject parameter exists — the proposal snapshots the Draft as Graph holds it" ] ||
      { echo "$o: $status $stderr"; return 1; }
  done
  long="$(printf 'a%.0s' {1..501})"
  run --separate-stderr propose delete m1 --reason "$long"
  [ "$status" -eq 4 ] && [ "$stderr" = "m365-propose: the reason is longer than 500 characters" ] || { echo "$status $stderr"; return 1; }
  for r in "see https://evil.example/x" "visit www.example.org now" "forward to mallory@external.example"; do
    run --separate-stderr propose delete m1 --reason "$r"
    [ "$status" -eq 4 ] && [[ "$stderr" == "m365-propose: the reason contains "* ]] || { echo "$r: $status $stderr"; return 1; }
  done
  run --separate-stderr propose delete m1 --reason "the key AKIAABCDEFGHIJKLMNOP is in it"
  [ "$status" -eq 4 ] && [ "$stderr" = "m365-propose: the reason matches secret pattern aws-access-key (not recorded)" ] || { echo "$status $stderr"; return 1; }
  [ "$(request_count)" -eq 0 ] && [ ! -e "$PROPOSALS" ]
  run --separate-stderr propose delete m1 --reason $'News\x01letter\tfrom\nDave\x1b[31m'
  [ "$status" -eq 0 ] || { echo "$status $stderr"; return 1; }
  [ "$(jq -r .reason "$PROPOSALS")" = "Newsletter from Dave[31m" ]
  reset_consent
  cfg '.consent.allowed_actions = ["send-draft", "move"]'
  run --separate-stderr propose delete m1 --reason x
  [ "$status" -eq 4 ] && [ "$stderr" = "m365-propose: action delete not allowed by consent.allowed_actions" ] || { echo "$status $stderr"; return 1; }
  [ ! -e "$PROPOSALS" ] && [ "$(request_count)" -eq 0 ]
}

@test "propose: ZYGGY_TENANT unset / m365.json invalid -> exit 3; no --reason, no action, bad id, move without folder, empty reason -> exit 4; nothing written, no request" {
  ZYGGY_TENANT='' run --separate-stderr propose delete m1 --reason x
  [ "$status" -eq 3 ] || { echo "$status $stderr"; return 1; }
  cfg '.consent.ttl_minutes = 0'
  run --separate-stderr propose delete m1 --reason x
  [ "$status" -eq 3 ] && [ "$stderr" = "m365-propose: configuration error: .consent.ttl_minutes must be an integer 1..1440" ] || { echo "$status $stderr"; return 1; }
  install_m365_fixture_config
  run --separate-stderr propose delete m1
  [ "$status" -eq 4 ] && [ "$stderr" = "m365-propose: no --reason given (usage: propose.sh send-draft <draft-id> --reason <text> | move <message-id> <folder> --reason <text> | delete <message-id> --reason <text>)" ] ||
    { echo "$status $stderr"; return 1; }
  run --separate-stderr propose
  [ "$status" -eq 4 ]
  run --separate-stderr propose delete 'm1/../x' --reason x
  [ "$status" -eq 4 ]
  run --separate-stderr propose move m1 --reason x
  [ "$status" -eq 4 ] && [[ "$stderr" == "m365-propose: move needs <message-id> <folder> (usage: "* ]] || { echo "$status $stderr"; return 1; }
  run --separate-stderr propose delete m1 --reason "   "
  [ "$status" -eq 4 ] && [[ "$stderr" == "m365-propose: the reason is empty (usage: "* ]]
  [ ! -e "$PROPOSALS" ] && [ "$(request_count)" -eq 0 ]
}

@test "approve: no terminal (< /dev/null, stdout to a file) -> exit 5 refused: no terminal; ZYGGY_HOOKS=off under the pty -> exit 5 refused: unattended run (checked first); --list without a tty -> the pending rows byte-equal to expected/m365-proposals-list.txt, no body, no request, nothing changed" {
  local sums
  seed_fixture proposals-pending.jsonl "$PROPOSALS"
  sums="$(md5sum "$PROPOSALS")"
  status=0
  "$M365/m365-approve.sh" < /dev/null > "$BATS_TEST_TMPDIR/approve.out" 2> "$BATS_TEST_TMPDIR/approve.err" || status=$?
  [ "$status" -eq 5 ] && [ ! -s "$BATS_TEST_TMPDIR/approve.out" ] || { echo "$status"; cat "$BATS_TEST_TMPDIR/approve.out"; return 1; }
  [ "$(cat "$BATS_TEST_TMPDIR/approve.err")" = "m365-approve: refused: no terminal" ]
  # a terminal on one side only is not a terminal
  run run_on_pty /dev/null bash -c '"$0" > /dev/null' "$M365/m365-approve.sh"
  [ "$status" -eq 5 ] && [ "$(last_line)" = "m365-approve: refused: no terminal" ] || { echo "$status $output"; return 1; }
  ZYGGY_HOOKS=off run approve_on_pty /dev/null
  [ "$status" -eq 5 ] && [ "$output" = "m365-approve: refused: unattended run (ZYGGY_HOOKS=off)" ] || { echo "$status $output"; return 1; }
  ZYGGY_HOOKS=off run --separate-stderr "$M365/m365-approve.sh" < /dev/null
  [ "$status" -eq 5 ] && [ "$stderr" = "m365-approve: refused: unattended run (ZYGGY_HOOKS=off)" ]
  run --separate-stderr "$M365/m365-approve.sh" --list < /dev/null
  [ "$status" -eq 0 ] && [ -z "$stderr" ] || { echo "$status $stderr"; return 1; }
  [ "$output" = "$(golden m365-proposals-list.txt 8)" ] || { diff <(printf '%s\n' "$output") <(golden m365-proposals-list.txt 8); return 1; }
  run --separate-stderr "$M365/m365-approve.sh" --bogus < /dev/null
  [ "$status" -eq 4 ] && [ "$stderr" = "m365-approve: unexpected argument '--bogus' (usage: m365-approve.sh [--list])" ]
  [ "$(request_count)" -eq 0 ] && [ "$(md5sum "$PROPOSALS")" = "$sums" ] && [ ! -e "$APPROVALS" ]
}

@test "approve: under the pty with p1 (send-draft), p2 (delete), p3 (move) pending and answers y, n, s: the screen before the first prompt is expected/m365-approve-screen.txt; y -> approval {p1, H1, ts, tty} then executed: send-draft H1 (202); p2 shown as a soft delete with the preview, n -> refused; p3 shown, s -> pending; exit 0; the body only on the terminal" {
  seed_fixture proposals-pending.jsonl "$PROPOSALS"
  run approve_on_pty answers-y-n.txt
  [ "$status" -eq 0 ] || { echo "$status $output"; return 1; }
  [ "$(screen_before_first_prompt)" = "$(golden m365-approve-screen.txt)" ] ||
    { diff <(screen_before_first_prompt) <(golden m365-approve-screen.txt); return 1; }
  # y: the approval is bound to the hash shown, then graph.sh executed it on this terminal
  [ "$(wc -l < "$APPROVALS")" -eq 1 ] && [ "$(stat -c %a "$APPROVALS")" = 600 ]
  jq -e --arg h "$H1" '.row_id == "p1" and .hash_at_approval == $h and .ts == "2026-09-30T10:00:00Z" and (.tty | test("^pts/[0-9]+$"))
    and (keys | length) == 4' "$APPROVALS" || { cat "$APPROVALS"; return 1; }
  grep -qxF "executed: send-draft $H1 (202)" <<< "$output"
  [ "$(urls | grep -c "^POST $GRAPH_URL/users/$UPN/messages/d1/send\$")" -eq 1 ]
  ! grep -q 'messages/m1/move' "$CURL_STUB_LOG"
  [ "$(row_status p1)" = executed ]
  jq -e --arg h "$H1" '.row_id == "p1" and .hash == $h and .http_status == 202' "$EXECUTIONS"
  # n: the soft delete, the message preview, refused, nothing executed
  grep -qxF '  action:   delete — soft delete → Deleted Items (never a hard delete)' <<< "$output"
  grep -qxF '  body (preview, first 500 characters):' <<< "$output"
  grep -qF 'Hi Alice, when is the invoice due?' <<< "$output"
  grep -qxF 'refused: p2 — nothing executed' <<< "$output"
  [ "$(row_status p2)" = refused ]
  # s: the move is shown and stays pending
  grep -qxF '  action:   move → archive' <<< "$output"
  grep -qxF 'skipped: p3 — stays pending' <<< "$output"
  [ "$(row_status p3)" = pending ]
  [ "$(wc -l < "$EXECUTIONS")" -eq 1 ]
  [ "$(last_line)" = "m365-approve: executed 1, refused 1, skipped 1, expired 0, not executed 0" ]
  # graph.sh's key line stays off the screen; the body was on the terminal (pty.out) and nowhere else
  ! grep -q '^key: ' <<< "$output"
  grep -qF 'BODYTEXT-NEVER-STORED' "$BATS_TEST_TMPDIR/pty.out"
}

@test "approve: the Draft changed since the proposal -> CHANGED since proposal (subject edited) with the current values; y binds the CURRENT hash and graph.sh executes against it" {
  local current
  seed_proposal p1
  current="$(hash_of "$(jq -c '.subject = "RE: Invoice 2026-41 (final)" | .changeKey = "CK2"' <<< "$(fixture_snapshot p1)")")"
  [ "$current" != "$H1" ]
  # the approve session's snapshot, then graph.sh's re-check before the POST
  scenario 'messages/d1\?\$select=id,subject,toRecipients:200:snapshot-d1-changed.json'
  scenario 'messages/d1\?\$select=id,subject,toRecipients:200:snapshot-d1-changed.json'
  run approve_on_pty answers-y.txt
  [ "$status" -eq 0 ] || { echo "$status $output"; return 1; }
  grep -qxF '  CHANGED since proposal (subject edited) — the values below are the current ones; y approves them' <<< "$output" || { echo "$output"; return 1; }
  grep -qxF "  hash:     $current" <<< "$output"
  grep -qxF '  subject:  RE: Invoice 2026-41 (final)' <<< "$output"
  jq -e --arg h "$current" '.row_id == "p1" and .hash_at_approval == $h' "$APPROVALS"
  grep -qxF "executed: send-draft $current (202)" <<< "$output"
  jq -e --arg h "$current" '.row_id == "p1" and .hash == $h and .http_status == 202' "$EXECUTIONS"
  [ "$(row_status p1)" = executed ]
}

@test "approve: a row pending for more than 7 days -> listed stale, expired at start, no prompt; a Draft no longer a draft -> expired, no prompt; q at the first prompt -> exit 0, nothing changed; a flagged row -> RECIPIENT OUTSIDE POLICY: mallory@external.example before the prompt" {
  local sums
  seed_proposal p1 '.ts = "2026-09-20T09:00:00Z"'
  run --separate-stderr "$M365/m365-approve.sh" --list < /dev/null
  [ "$output" = "p1 pending send-draft RE: Invoice 2026-41 brief 2026-09-30 #${H1:0:8} stale" ] || { echo "$output"; return 1; }
  run approve_on_pty /dev/null
  [ "$status" -eq 0 ] || { echo "$status $output"; return 1; }
  grep -qxF 'p1 expired: pending for more than 7 days' <<< "$output"
  grep -qxF 'm365-approve: no pending proposals' <<< "$output"
  ! grep -qF '[y]es' <<< "$output"
  [ "$(row_status p1)" = expired ]
  # the Draft was sent elsewhere: expired without a prompt
  reset_consent
  seed_proposal p1
  scenario 'messages/d1\?\$select=id,subject,toRecipients:200:snapshot-d1-sent.json'
  run approve_on_pty /dev/null
  [ "$status" -eq 0 ] || { echo "$status $output"; return 1; }
  grep -qxF '  send-draft d1: no longer a draft — expired' <<< "$output"
  ! grep -qF '[y]es' <<< "$output"
  [ "$(row_status p1)" = expired ] && [ ! -e "$APPROVALS" ]
  # q at the first prompt
  reset_consent
  seed_fixture proposals-pending.jsonl "$PROPOSALS"
  sums="$(md5sum "$PROPOSALS")"
  run approve_on_pty "$(answers q)"
  [ "$status" -eq 0 ] || { echo "$status $output"; return 1; }
  grep -qxF 'quit — the remaining proposals stay pending' <<< "$output"
  [ "$(md5sum "$PROPOSALS")" = "$sums" ] && [ ! -e "$APPROVALS" ] && [ ! -e "$EXECUTIONS" ]
  ! grep -qE 'messages/d1/send|messages/m1/move' "$CURL_STUB_LOG"
  # a flagged proposal, made by propose.sh, shown by the approve session with the outsider named
  reset_consent
  "$STATE_SH" set replied 2026-09-30 m1
  scenario 'messages/d1\?\$select=id,subject,toRecipients:200:snapshot-d1-outside.json'
  run --separate-stderr propose send-draft d1 --reason "Carol asked for the invoice date"
  [ "$status" -eq 0 ] || { echo "$status $stderr"; return 1; }
  scenario 'messages/d1\?\$select=id,subject,toRecipients:200:snapshot-d1-outside.json'
  run approve_on_pty answers-s-q.txt
  [ "$status" -eq 0 ] || { echo "$status $output"; return 1; }
  ! grep -qF 'CHANGED' <<< "$output"
  grep -qxF '  RECIPIENT OUTSIDE POLICY: mallory@external.example' <<< "$output" || { echo "$output"; return 1; }
  [ "$(sed -n '/RECIPIENT OUTSIDE POLICY/{n;p;}' <<< "$output")" = '[y]es / [n]o / [s]kip / [q]uit: s' ] || { echo "$output"; return 1; }
  [ "$(jq -r .status "$PROPOSALS")" = pending ]
}

@test "approve: y but graph.sh refuses (allowed_actions narrowed after the proposal) -> its refusal line, the approval stays recorded, the row stays pending; y and Graph answers 403 -> failed: 403 — runbook, row failed" {
  seed_proposal p1
  cfg '.consent.allowed_actions = ["move"]'
  run approve_on_pty answers-y.txt
  [ "$status" -eq 0 ] || { echo "$status $output"; return 1; }
  grep -qxF 'm365: action send-draft not allowed by consent.allowed_actions' <<< "$output" || { echo "$output"; return 1; }
  grep -qxF 'not executed — your approval is recorded and p1 stays as it is; fix the cause and run m365-approve.sh again within 60 min' <<< "$output"
  jq -e --arg h "$H1" '.row_id == "p1" and .hash_at_approval == $h' "$APPROVALS"
  [ "$(row_status p1)" = pending ] && [ ! -e "$EXECUTIONS" ]
  ! grep -q 'messages/d1/send' "$CURL_STUB_LOG"
  [ "$(last_line)" = "m365-approve: executed 0, refused 0, skipped 0, expired 0, not executed 1" ]
  install_m365_fixture_config
  reset_consent
  seed_proposal p1
  scenario 'messages/d1/send:403:graph-forbidden.json'
  run approve_on_pty answers-y.txt
  [ "$status" -eq 0 ] || { echo "$status $output"; return 1; }
  grep -qxF 'failed: 403 — runbook 13 "Scope or grant missing"' <<< "$output" || { echo "$output"; return 1; }
  [ "$(row_status p1)" = failed ]
  jq -e '.row_id == "p1" and .http_status == 403' "$EXECUTIONS"
}

@test "unit shape (AC-47): with ZYGGY_HOOKS=off and no tty (stdin /dev/null, stdout a file) propose.sh proposes; graph.sh send-draft --approved <valid H1> -> exit 5 refused: unattended run (before the tty check); m365-approve.sh -> exit 5 refused: unattended run; nothing executed" {
  local actions
  seed_proposal p1
  seed_fixture approvals-p1.jsonl "$APPROVALS"
  # what the morning-brief run's model can do: the run's child has ZYGGY_HOOKS=off and no terminal
  # shellcheck disable=SC2016 # expanded by the child shell
  actions='"$M365/propose.sh" delete m1 --reason "Newsletter"; echo "propose=$?"
    "$M365/graph.sh" send-draft --approved "$H1"; echo "graph=$?"
    "$M365/m365-approve.sh"; echo "approve=$?"'
  H1="$H1" ZYGGY_HOOKS=off bash -c "$actions" < /dev/null > "$BATS_TEST_TMPDIR/unit.out" 2> "$BATS_TEST_TMPDIR/unit.err"
  grep -qx 'propose=0' "$BATS_TEST_TMPDIR/unit.out" || { cat "$BATS_TEST_TMPDIR/unit.out" "$BATS_TEST_TMPDIR/unit.err"; return 1; }
  grep -qE "^proposed: $ULID_RE delete \"Invoice 2026-41\"$PROPOSE_TAIL\$" "$BATS_TEST_TMPDIR/unit.out"
  grep -qx 'graph=5' "$BATS_TEST_TMPDIR/unit.out"
  grep -qx 'approve=5' "$BATS_TEST_TMPDIR/unit.out"
  [ "$(cat "$BATS_TEST_TMPDIR/unit.err")" = "$(printf '%s\n' 'm365: refused: unattended run (ZYGGY_HOOKS=off)' 'm365-approve: refused: unattended run (ZYGGY_HOOKS=off)')" ] ||
    { cat "$BATS_TEST_TMPDIR/unit.err"; return 1; }
  jq -s -e --arg h "$H2" 'length == 2 and (.[1] | .action == "delete" and .snapshot_hash == $h and .status == "pending")' "$PROPOSALS"
  [ "$(row_status p1)" = pending ] && [ ! -e "$EXECUTIONS" ] && [ "$(wc -l < "$APPROVALS")" -eq 1 ]
  ! grep -qE 'messages/d1/send|messages/m1/move' "$CURL_STUB_LOG"
}

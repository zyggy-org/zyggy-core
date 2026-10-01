#!/usr/bin/env bats
# m365 connector (spec 23): the pinned server's app-only tool partition and the fixtures (plan 23 Step 1,
# AC-45 half, AC-46); graph.sh — key pair, app-only token, Graph reads, snapshots (Step 2, AC-30..AC-33, AC-43,
# AC-44). Fixture lists are generated from the pinned package's endpoints.json, never typed. curl is a stub, openssl is
# real (a throw-away key pair per test). No network.

load helpers

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
  ! grep -rqsF --exclude-dir=fixtures BODYTEXT-NEVER-STORED "$BATS_TEST_TMPDIR" || { echo "body text persisted"; return 1; }
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
  # the machine-path alternatives are composed so that this file passes the same hygiene check (repo.bats)
  local s='/' paths
  paths="${s}srv${s}|${s}home${s}|${s}Users${s}|${s}root${s}|[A-Za-z]:\\\\"
  run grep -rnE "@[a-z0-9-]+\.(com|be|org|net)\b|sharepoint\.com|onmicrosoft|$paths" "$M365_FIXTURES"
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

@test "graph: unknown verbs and malformed arguments -> exit 4 with the usage table, no request; send-draft|move|delete without --approved -> 4; delete --hard -> 4; --approved <hash> -> 5 no approval for row (Step 3 implements it)" {
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
  # the write verbs are parsed here and dispatch to the Step 3 function, which in this step refuses every row
  hash="$(printf 'f%.0s' {1..64})"
  for c in "send-draft --approved $hash" "move --approved $hash" "delete --approved $hash"; do
    # shellcheck disable=SC2086
    run --separate-stderr graph $c
    assert_refused 5 "m365: no approval for row" "$before" || { echo "case: graph $c"; return 1; }
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
  run grep -n 'set -x' "$GRAPH" "$lib"
  [ "$status" -eq 1 ]
}

#!/usr/bin/env bats
# m365 connector after spec 33: the pinned server's app-only tool partition (spec 23, plan 23 Steps 1 and R1) and the
# plain tool data files the template carries for the zyggy binary (.claude/skills/m365/tools/, owner decision 8): the
# server's ENABLED_TOOLS, the run allow/deny lists and the 328 settings deny rules all come from them. The m365
# behaviour (Graph, state, facts, parse, guard, log, brief, backfills) is tested in the zyggy repository's .NET suite.
# Fixture lists are generated from the pinned package's endpoints.json, never typed. No network, no binary.

load helpers

setup() {
  M365_FIXTURES="$FIXTURES/m365"
  ALL="$M365_FIXTURES/tools-0.157.2.txt"
  ENABLED="$M365_FIXTURES/enabled-tools.txt"
  EXCLUDED="$M365_FIXTURES/excluded-tools.txt"
  TOOLS_JSON="$M365_FIXTURES/tools-list-0.157.2.json"
  DATA="$REPO_ROOT/.claude/skills/m365/tools"
}

# The spec's app-only allowlist: the /users/{user-id} mail read tools, the two /users Draft tools, the /drives
# read tools, the file writer and the two /sites/{site-id}/drives read tools (names as endpoints.json has them),
# plus the D7 action tools the pinned server can carry (plan 23 Step R1: send and move; upload-file-content stays
# excluded — fact 3, the server URL-encodes the <parent-id>:/<name>: form).
expected_enabled() {
  printf '%s\n' \
    create-shared-mailbox-draft create-shared-mailbox-reply-draft download-bytes-to-file get-drive-delta \
    get-drive-item get-drive-root-item get-shared-mailbox-message get-sharepoint-site-drive-by-id \
    list-drive-item-versions list-folder-files list-shared-mailbox-folder-messages list-shared-mailbox-messages \
    list-sharepoint-site-drives search-onedrive-files \
    move-shared-mailbox-message send-shared-mailbox-mail | LC_ALL=C sort
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
  [ "$(wc -l < "$ALL")" -eq 344 ]
  # D7 on the fact-3 branch (plan 23 Step R1): 16 enabled + 328 excluded
  [ "$(wc -l < "$ENABLED")" -eq 16 ] && [ "$(wc -l < "$EXCLUDED")" -eq 328 ]
}

@test "m365: enabled holds exactly the 14 read/Draft tools of Step 1 plus send-shared-mailbox-mail and move-shared-mailbox-message; every other send/reply/forward/update/delete/rename/copy/share/upload tool, graph-batch and the six auth tools stay excluded" {
  local negative me t
  cmp <(expected_enabled) "$ENABLED"
  [ "$(grep -c shared-mailbox "$ENABLED")" -eq 7 ]
  [ "$(grep -cE '^create-shared-mailbox-(reply-)?draft$' "$ENABLED")" -eq 2 ]
  [ "$(grep -cE '^create-' "$ENABLED")" -eq 2 ]
  for t in upload-file-content send-shared-mailbox-draft reply-shared-mailbox-mail reply-all-shared-mailbox-mail \
    forward-shared-mailbox-mail create-shared-mailbox-reply-all-draft create-shared-mailbox-forward-draft \
    update-shared-mailbox-message create-upload-session create-onedrive-folder delete-onedrive-file \
    move-rename-onedrive-item copy-drive-item share-drive-item create-drive-item-share-link delete-drive-item-permission \
    graph-batch login logout verify-login list-accounts select-account remove-account; do
    grep -qx -- "$t" "$ALL" || { echo "not in the pinned list: $t"; return 1; }
    grep -qx -- "$t" "$EXCLUDED" || { echo "not excluded: $t"; return 1; }
  done
  # the negative list derived from tools-0.157.2.txt: every /me family name, every write verb, the auth and batch
  # tools, every Teams/calendar/contacts/To Do/Planner/OneNote/Excel/directory name
  negative='^(send-|delete-|move-|update-|upload-|share-|copy-|forward-|reply-|add-|set-|mark-|format-|sort-|merge-|unmerge-|clear-|insert-|extract-|cancel-|accept-|decline-|archive-|unarchive-|pin-|unpin-|remove-|select-|start-|stop-|complete-|register-|check-)'
  negative="$negative|create-(mail|onedrive|upload|drive-item|excel|chat|team|channel|calendar|event|contact|todo|planner|onenote|sharepoint|shared-mailbox-(reply-all|forward))"
  negative="$negative|-(permission|permissions|preview|thumbnails|share-link|invite|labels)$|download-bytes$|get-download-url$|parse-teams-url$|graph-batch$"
  negative="$negative|chat|team|channel|calendar|event|contact|todo|task|planner|onenote|notebook|workbook|excel|current-user|my-profile|presence|manager|direct-reports|emoji|meeting|recording|transcript|photo|mailbox-settings|people|insight|reminder"
  negative="$negative|list-drives$|list-users$|^(list|get|create)-mail-|^list-mail-|^(login|logout|verify-login|list-accounts|select-account|remove-account)$"
  negative="$negative|^(get|list|search)-sharepoint-(site|sites|site-by-path|sites-delta|site-item|site-items|site-list|site-lists|site-list-item|site-list-items|list-column|list-columns)$"
  # exempt exactly the D7 action tool names (their policy is the guard's and the prompt's, plan 23 Step R3)
  run grep -E "$negative" <(grep -vxE 'send-shared-mailbox-mail|move-shared-mailbox-message|upload-file-content' "$ENABLED")
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
  # the only non-GET tools enabled are the two Draft creations and the two D7 action tools
  run jq -r --rawfile en "$ENABLED" '($en | split("\n") | map(select(length > 0))) as $e
    | .tools[] | select(.name as $n | $e | index($n)) | select(.description | test("^GET |^tool ") | not) | .name' "$TOOLS_JSON"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | LC_ALL=C sort)" = "$(printf '%s\n' create-shared-mailbox-draft create-shared-mailbox-reply-draft \
    move-shared-mailbox-message send-shared-mailbox-mail)" ]
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
  jq -e '.source.counts.enabled == 16 and .source.counts.excluded == 328' "$TOOLS_JSON" > /dev/null
}

@test "m365: tools-list-0.157.2.json gives the three D7 action tools their probed inputSchema (Step R1: facts 2-4)" {
  jq -e '[.tools[] | select(.name | IN("send-shared-mailbox-mail","upload-file-content","move-shared-mailbox-message"))]
    | length == 3 and all(.inputSchema.properties | length > 0)' "$TOOLS_JSON" > /dev/null
  # send: userId in the path; body.Message (the 25 message fields incl. the three recipient lists, attachments, from and
  # body.contentType text|html) and body.SaveToSentItems, whose published default is false (the guard requires true)
  jq -e '.tools[] | select(.name == "send-shared-mailbox-mail") | .inputSchema.properties
    | (.userId.in == "path") and (.confirm.type == "boolean")
    and (.body.properties.SaveToSentItems.default == false)
    and (.body.properties.Message.properties | (keys | length == 25)
      and has("toRecipients") and has("ccRecipients") and has("bccRecipients") and has("attachments") and has("from")
      and (.body.properties.contentType.enum == ["text","html"])
      and (.toRecipients.items.properties.emailAddress.properties | has("address")))' "$TOOLS_JSON" > /dev/null
  # move: userId and messageId in the path, body.DestinationId (capitalised as client.js has it)
  jq -e '.tools[] | select(.name == "move-shared-mailbox-message") | .inputSchema.properties
    | (.userId.in == "path") and (.messageId.in == "path") and (.body.properties | keys == ["DestinationId"])' \
    "$TOOLS_JSON" > /dev/null
  # upload: driveId and driveItemId in the path (URL-encoded by the server — fact 3), body a base64 string (fact 4)
  jq -e '.tools[] | select(.name == "upload-file-content") | .inputSchema.properties
    | (.driveId.in == "path") and (.driveItemId.in == "path") and (.body.type == "string")
    and (.body.description | test("Base64"))' "$TOOLS_JSON" > /dev/null
}

# --- the tool data files the binary reads (spec 33, owner decision 8) ----------------------------------------------

@test "m365: the tool data files are exactly enabled.txt, excluded.txt, actions.txt, auth.txt and server-version.txt, LF, no blank line" {
  local f
  run bash -c 'cd "$1" && ls -1' _ "$DATA"
  [ "$output" = "$(printf '%s\n' actions.txt auth.txt enabled.txt excluded.txt server-version.txt)" ] || { echo "$output"; return 1; }
  for f in "$DATA"/*.txt; do
    [ "$(tail -c 1 "$f" | od -An -c | tr -d ' ')" = '\n' ] || { echo "$f: no final LF"; return 1; }
    run grep -c $'\r' "$f"
    [ "$output" = 0 ] || { echo "$f: CR"; return 1; }
    run grep -nE '^$|^ | $' "$f"
    [ "$status" -eq 1 ] || { echo "$f: $output"; return 1; }
  done
}

@test "m365: enabled.txt and excluded.txt are the pinned fixture lists byte for byte (16 + 328 = the 344 tools of server-version.txt)" {
  cmp "$DATA/enabled.txt" "$ENABLED"
  cmp "$DATA/excluded.txt" "$EXCLUDED"
  [ "$(cat "$DATA/server-version.txt")" = 0.157.2 ]
  [ -f "$M365_FIXTURES/tools-$(cat "$DATA/server-version.txt").txt" ]
}

@test "m365: actions.txt names the three D7 action tools; send and move are enabled, upload is excluded (Step R1, fact 3)" {
  [ "$(cat "$DATA/actions.txt")" = "$(printf '%s\n' move-shared-mailbox-message send-shared-mailbox-mail upload-file-content)" ]
  grep -qx move-shared-mailbox-message "$DATA/enabled.txt"
  grep -qx send-shared-mailbox-mail "$DATA/enabled.txt"
  grep -qx upload-file-content "$DATA/excluded.txt"
}

@test "m365: auth.txt names the six auth tools the server registers outside ENABLED_TOOLS; all six are excluded" {
  local t
  [ "$(cat "$DATA/auth.txt")" = "$(printf '%s\n' list-accounts login logout remove-account select-account verify-login)" ]
  while IFS= read -r t; do
    grep -qx -- "$t" "$DATA/excluded.txt" || { echo "not excluded: $t"; return 1; }
  done < "$DATA/auth.txt"
}

@test "m365: .claude/zyggy-min-version is one semantic version line, the binary this template needs" {
  local v="$REPO_ROOT/.claude/zyggy-min-version"
  [ "$(wc -l < "$v")" -eq 1 ]
  grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' "$v"
}

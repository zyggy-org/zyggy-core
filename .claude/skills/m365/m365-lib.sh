#!/usr/bin/env bash
set -euo pipefail
# Shared functions for the m365 connector scripts (spec 23). Sourced after ../../hooks/lib.sh, never executed.
# Owns the paths (config, state dir, key, certificate, the three consent files), the configuration validation, the
# key lookup, the retry clock, the curl stub guard, the one definition of the snapshot canonical form and its hash,
# the terminal test and the consent-file readers and the one appender. No request is made here and the private key
# is never read into a variable: callers hand its path to openssl.
# Every m365 script prefixes its stderr lines with "m365: " (zy_die reads ZY_SELF).
# shellcheck disable=SC2034 # read by lib.sh's zy_die and by the scripts that source this library
ZY_SELF=m365

ZY_M365_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ZY_M365_CHECKOUT="$(cd "$ZY_M365_SKILL_DIR/../../.." && pwd -P)"
ZY_M365_CONFIG="${ZYGGY_M365_CONFIG:-$ZY_M365_CHECKOUT/instance/m365.json}"
ZY_M365_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zyggy/m365"
ZY_M365_KEY_FILE="${ZYGGY_M365_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/zyggy/m365-app.key}"
ZY_M365_CER_FILE="${ZYGGY_M365_CER_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/zyggy/m365-app.cer}"
ZY_M365_CREDENTIAL_NAME=m365-app-key
# The three consent files (spec 23 D6): what the model proposed, what the owner approved on a terminal, what
# graph.sh executed. 0600, append-only (state.sh mark rewrites one status), no body text ever.
ZY_M365_PROPOSALS="$ZY_M365_STATE_DIR/proposals.jsonl"
ZY_M365_APPROVALS="$ZY_M365_STATE_DIR/approvals.jsonl"
ZY_M365_EXECUTIONS="$ZY_M365_STATE_DIR/executions.jsonl"
# shellcheck disable=SC2034 # the paths and grammars are read by the scripts that source this library
readonly ZY_M365_SKILL_DIR ZY_M365_CHECKOUT ZY_M365_CONFIG ZY_M365_STATE_DIR ZY_M365_KEY_FILE ZY_M365_CER_FILE
readonly ZY_M365_CREDENTIAL_NAME ZY_M365_PROPOSALS ZY_M365_APPROVALS ZY_M365_EXECUTIONS
readonly ZY_M365_GUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
readonly ZY_M365_UPN_RE='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
readonly ZY_M365_DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
# shellcheck disable=SC2034 # argument grammars for graph.sh and the Step 3 scripts
readonly ZY_M365_ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
# shellcheck disable=SC2034
readonly ZY_M365_ID_RE='^[A-Za-z0-9_=-]{1,512}$'
# shellcheck disable=SC2034
readonly ZY_M365_DRIVE_ID_RE='^[A-Za-z0-9_!.=-]{1,512}$'
# shellcheck disable=SC2034
readonly ZY_M365_HASH_RE='^[0-9a-f]{64}$'
# shellcheck disable=SC2034 # proposal ids (ULID-like from propose.sh; short names in fixtures) and the row statuses
readonly ZY_M365_ROW_ID_RE='^[A-Za-z0-9_-]{1,64}$'
# shellcheck disable=SC2034
readonly ZY_M365_STATUS_RE='^(pending|approved|executed|failed|refused|expired)$'
readonly ZY_M365_EXPIRY_WARN_DAYS=30

# --- configuration ---------------------------------------------------------------------------------------

zy_m365_config_error() { # zy_m365_config_error <message>
  zy_die 3 "configuration error: $1"
}

# One jq lookup in the loaded configuration; prints the value (raw) or "null".
zy_m365_cfg() { # zy_m365_cfg <jq path>
  jq -r "$1 // null" <<< "$ZY_M365_CONFIG_JSON"
}

# True when the jq expression holds for the loaded configuration.
zy_m365_cfg_test() { # zy_m365_cfg_test <jq boolean expression>
  jq -e "$1" <<< "$ZY_M365_CONFIG_JSON" > /dev/null 2>&1
}

zy_m365_require_number() { # zy_m365_require_number <jq path> [min]
  zy_m365_cfg_test "($1 | type) == \"number\"" || zy_m365_config_error "$1 is not a number"
  if [ -n "${2:-}" ]; then
    zy_m365_cfg_test "$1 >= $2" || zy_m365_config_error "$1 must be at least $2"
  fi
}

zy_m365_require_integer() { # zy_m365_require_integer <jq path> <min> <max>
  zy_m365_cfg_test "($1 | type) == \"number\" and ($1 | floor) == $1 and $1 >= $2 and $1 <= $3" ||
    zy_m365_config_error "$1 must be an integer $2..$3"
}

# Loads ${ZYGGY_M365_CONFIG:-<checkout>/instance/m365.json} into M365_* variables after validating it; exit 3 on
# the first problem, before any request. --base validates only what cert-init needs before the app registration
# exists (tenant_id, mailbox, timezone, language, cert.subject, cert.days). The full validation adds the GUIDs,
# the drives block, cert.expires (warning on stderr within 30 days, exit 3 once past), the consent block and the
# numeric caps of brief, mail_backfill and files_backfill.
zy_m365_load_config() { # zy_m365_load_config [--base]
  local base=0 key days today_epoch expires_epoch
  [ "${1:-}" != --base ] || base=1
  [ -e "$ZY_M365_CONFIG" ] || zy_m365_config_error "$ZY_M365_CONFIG not found (ZYGGY_M365_CONFIG)"
  if [ ! -f "$ZY_M365_CONFIG" ] || [ ! -r "$ZY_M365_CONFIG" ]; then
    zy_m365_config_error "$ZY_M365_CONFIG is not a readable file"
  fi
  ZY_M365_CONFIG_JSON="$(jq -c . "$ZY_M365_CONFIG" 2> /dev/null)" || zy_m365_config_error "$ZY_M365_CONFIG is not valid JSON"
  zy_m365_cfg_test 'type == "object"' || zy_m365_config_error "$ZY_M365_CONFIG is not a JSON object"

  M365_TENANT_ID="$(zy_m365_cfg .tenant_id)"
  [[ "$M365_TENANT_ID" =~ $ZY_M365_GUID_RE ]] || zy_m365_config_error "tenant_id is not a GUID"
  M365_MAILBOX="$(zy_m365_cfg .mailbox)"
  [[ "$M365_MAILBOX" =~ $ZY_M365_UPN_RE ]] || zy_m365_config_error "mailbox is not a user principal name"
  M365_TIMEZONE="$(zy_m365_cfg .timezone)"
  [ "$M365_TIMEZONE" = UTC ] || [ -f "/usr/share/zoneinfo/$M365_TIMEZONE" ] ||
    zy_m365_config_error "timezone '$M365_TIMEZONE' is not a known time zone"
  M365_LANGUAGE="$(zy_m365_cfg .language)"
  [[ "$M365_LANGUAGE" =~ ^[a-z]{2}(-[A-Z]{2})?$ ]] || zy_m365_config_error "language is not a language tag"
  M365_CERT_SUBJECT="$(zy_m365_cfg .cert.subject)"
  [[ "$M365_CERT_SUBJECT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || zy_m365_config_error "cert.subject is not a plain name"
  zy_m365_require_integer .cert.days 1 3650
  M365_CERT_DAYS="$(zy_m365_cfg .cert.days)"
  export M365_TENANT_ID M365_MAILBOX M365_TIMEZONE M365_LANGUAGE M365_CERT_SUBJECT M365_CERT_DAYS
  [ "$base" -eq 0 ] || return 0

  M365_CLIENT_ID="$(zy_m365_cfg .client_id)"
  [[ "$M365_CLIENT_ID" =~ $ZY_M365_GUID_RE ]] || zy_m365_config_error "client_id is not a GUID"
  M365_SP_OBJECT_ID="$(zy_m365_cfg .sp_object_id)"
  [[ "$M365_SP_OBJECT_ID" =~ $ZY_M365_GUID_RE ]] || zy_m365_config_error "sp_object_id is not a GUID"
  M365_CERT_EXPIRES="$(zy_m365_cfg .cert.expires)"
  if [[ ! "$M365_CERT_EXPIRES" =~ $ZY_M365_DATE_RE ]] || ! expires_epoch="$(date -u -d "$M365_CERT_EXPIRES" +%s 2> /dev/null)"; then
    zy_m365_config_error "cert.expires is not a date (YYYY-MM-DD)"
  fi
  today_epoch="$(date -u -d "$(zy_date UTC +%F)" +%s)"
  days=$(((expires_epoch - today_epoch) / 86400))
  if [ "$days" -lt 0 ]; then
    zy_die 3 "certificate expired $M365_CERT_EXPIRES — runbook 13 \"Rotate the certificate\""
  elif [ "$days" -le "$ZY_M365_EXPIRY_WARN_DAYS" ]; then
    printf 'm365: certificate expires in %s days — runbook 13 "Rotate the certificate"\n' "$days" >&2
  fi
  zy_m365_cfg_test '.drives | type == "object"' || zy_m365_config_error "drives is not an object"
  zy_m365_cfg_test '.drives.onedrive_site | type == "string" and test("^[a-z0-9-]+-my\\.sharepoint\\.[a-z.]+:/personal/[A-Za-z0-9_]+$")' ||
    zy_m365_config_error "drives.onedrive_site is not <tenant>-my.sharepoint.<tld>:/personal/<user>"
  zy_m365_cfg_test '.drives.sites | type == "array" and all(type == "string" and test("^[a-z0-9-]+\\.sharepoint\\.[a-z.]+:/sites/[A-Za-z0-9_-]+$"))' ||
    zy_m365_config_error "drives.sites is not a list of <host>.sharepoint.<tld>:/sites/<name>"
  zy_m365_cfg_test '.drives.sites_granted | type == "array" and all(type == "string" and test("^[a-z0-9.-]+,[0-9a-fA-F-]{36},[0-9a-fA-F-]{36}$"))' ||
    zy_m365_config_error "drives.sites_granted is not a list of <host>,<site collection id>,<site id>"
  zy_m365_cfg_test '(.drives.sites | length) == 0 or (.drives.sites_granted | length) > 0' ||
    zy_m365_config_error "drives.sites_granted is empty while drives.sites names a site"
  for key in exclude_drives exclude_paths; do
    zy_m365_cfg_test ".drives.$key | type == \"array\" and all(type == \"string\")" ||
      zy_m365_config_error "drives.$key is not a list of strings"
  done
  zy_m365_cfg_test '.consent | type == "object"' || zy_m365_config_error "consent is not an object"
  zy_m365_require_integer .consent.ttl_minutes 1 1440
  zy_m365_cfg_test '.consent.allowed_actions | type == "array" and all(IN("send-draft", "move", "delete")) and (unique | length) == length' ||
    zy_m365_config_error "consent.allowed_actions may only hold send-draft, move and delete (narrowing only)"
  zy_m365_cfg_test '.brief | type == "object"' || zy_m365_config_error "brief is not an object"
  for key in mail_max_items reply_cap files_max_items file_max_bytes file_text_cap_bytes max_turns max_facts proposal_cap; do
    zy_m365_require_integer ".brief.$key" 0 100000000
  done
  zy_m365_require_number .brief.budget_usd 0
  zy_m365_cfg_test '.brief.model | type == "string"' || zy_m365_config_error "brief.model is not a string"
  zy_m365_cfg_test '.mail_backfill | type == "object"' || zy_m365_config_error "mail_backfill is not an object"
  zy_m365_cfg_test '.mail_backfill.exclude_folders | type == "array" and all(type == "string")' ||
    zy_m365_config_error "mail_backfill.exclude_folders is not a list of strings"
  for key in batch_messages max_turns max_facts max_messages; do
    zy_m365_require_integer ".mail_backfill.$key" 0 100000000
  done
  for key in budget_usd_per_batch budget_usd_total; do
    zy_m365_require_number ".mail_backfill.$key" 0
  done
  zy_m365_cfg_test '.mail_backfill.model | type == "string"' || zy_m365_config_error "mail_backfill.model is not a string"
  zy_m365_cfg_test '.files_backfill | type == "object"' || zy_m365_config_error "files_backfill is not an object"
  for key in batch_files max_turns file_max_bytes file_text_cap_bytes max_facts; do
    zy_m365_require_integer ".files_backfill.$key" 0 100000000
  done
  for key in budget_usd_per_batch budget_usd_total; do
    zy_m365_require_number ".files_backfill.$key" 0
  done
  zy_m365_cfg_test '.files_backfill.model | type == "string"' || zy_m365_config_error "files_backfill.model is not a string"

  M365_CONSENT_TTL_MINUTES="$(zy_m365_cfg .consent.ttl_minutes)"
  M365_CONSENT_ALLOWED_ACTIONS="$(jq -r '.consent.allowed_actions | join(" ")' <<< "$ZY_M365_CONFIG_JSON")"
  M365_SITES_GRANTED="$(jq -r '.drives.sites_granted[]' <<< "$ZY_M365_CONFIG_JSON")"
  M365_EXCLUDE_DRIVES_JSON="$(jq -c '.drives.exclude_drives' <<< "$ZY_M365_CONFIG_JSON")"
  M365_EXCLUDE_FOLDERS_JSON="$(jq -c '.mail_backfill.exclude_folders' <<< "$ZY_M365_CONFIG_JSON")"
  export M365_CLIENT_ID M365_SP_OBJECT_ID M365_CERT_EXPIRES M365_CONSENT_TTL_MINUTES M365_CONSENT_ALLOWED_ACTIONS
  export M365_SITES_GRANTED M365_EXCLUDE_DRIVES_JSON M365_EXCLUDE_FOLDERS_JSON
}

# --- the private key -------------------------------------------------------------------------------------

# Sets M365_KEY_PATH and M365_KEY_SRC ("credentials directory" | file): the systemd credential
# $CREDENTIALS_DIRECTORY/m365-app-key when present, else the key file (the ".new" pair with new). The key must be a
# regular file, mode 0600 (0400 for a credential copy), owned by this user, non-empty, with a PEM private-key header.
# The key is never read into a variable: only its first line is tested, with grep.
zy_m365_read_key() { # zy_m365_read_key [new]
  local path src mode
  if [ "${1:-}" = new ]; then
    path="$ZY_M365_KEY_FILE.new"
    src="file"
  elif [ -n "${CREDENTIALS_DIRECTORY:-}" ] && [ -e "$CREDENTIALS_DIRECTORY/$ZY_M365_CREDENTIAL_NAME" ]; then
    path="$CREDENTIALS_DIRECTORY/$ZY_M365_CREDENTIAL_NAME"
    src="credentials directory"
  elif [ -e "$ZY_M365_KEY_FILE" ]; then
    path="$ZY_M365_KEY_FILE"
    src="file"
  else
    zy_die 3 "key: not found in credentials directory or file"
  fi
  [ -f "$path" ] || zy_die 3 "key: $path is not a regular file"
  mode="$(stat -c %a "$path")"
  case "$mode" in
    600) ;;
    400) [ "$src" = "credentials directory" ] || zy_die 3 "key: $path must be mode 0600 (is $mode)" ;;
    *) zy_die 3 "key: $path must be mode 0600 (is $mode)" ;;
  esac
  [ "$(stat -c %u "$path")" = "$(id -u)" ] || zy_die 3 "key: $path must be owned by $(id -un)"
  [ -s "$path" ] || zy_die 3 "key: $path is empty"
  grep -qE -m 1 -e '^-----BEGIN (RSA |EC )?PRIVATE KEY-----$' "$path" || zy_die 3 "key: $path has no PEM private-key header"
  M365_KEY_PATH="$path"
  M365_KEY_SRC="$src"
  export M365_KEY_PATH M365_KEY_SRC
}

# --- requests: stub guard and retry clock -------------------------------------------------------------------

# With ZYGGY_M365_STUB=1 (tests only) the curl binary must be the test stub, never the system curl: a test that
# reached the network would be a test with a real tenant. Exit 3 otherwise.
zy_m365_curl_guard() { # zy_m365_curl_guard <curl path>
  if [ "${ZYGGY_M365_STUB:-}" = 1 ]; then
    grep -qsF 'ZYGGY_M365_CURL_STUB' "$1" || zy_die 3 "ZYGGY_M365_STUB=1 but curl resolves to $1, not the stub"
  fi
}

# Sleep <seconds> before a retry; ZYGGY_RETRY_SCALE multiplies it, honoured only under the stub.
zy_m365_sleep() { # zy_m365_sleep <seconds>
  local secs="$1"
  if [ "${ZYGGY_M365_STUB:-}" = 1 ] && [ -n "${ZYGGY_RETRY_SCALE:-}" ]; then
    secs="$(awk -v s="$secs" -v k="$ZYGGY_RETRY_SCALE" 'BEGIN { printf "%.3f", s * k }')"
  fi
  [ "$secs" = 0 ] || [ "$secs" = 0.000 ] || sleep "$secs"
}

# --- the snapshot canonical form and its hash (the single definition) --------------------------------------------

# The canonical snapshot of a mail object: sorted keys, compact, exactly these keys, no body. A proposal, an approval
# and an execution all refer to the hash of this line.
zy_m365_canonical() { # zy_m365_canonical <snapshot json>
  jq -S -c '{kind, id, subject, to, cc, bcc, from, receivedDateTime, parentFolderId, changeKey, isDraft}' <<< "$1"
}

# SHA-256 (64 hex) of the canonical line followed by one newline, i.e. of exactly what zy_m365_canonical prints.
zy_m365_hash() { # zy_m365_hash <canonical line>
  printf '%s\n' "$1" | sha256sum | cut -c1-64
}

# The snapshot kind an action binds to: a send-draft row snapshots a draft, a move or delete row a message.
# propose.sh, the write verbs and m365-approve.sh must agree on it, or the hashes never match.
zy_m365_kind_of() { # zy_m365_kind_of <action>
  case "$1" in
    send-draft) printf draft ;;
    *) printf message ;;
  esac
}

# --- the terminal and the consent files -------------------------------------------------------------------------

# True on an attended terminal: stdin and stdout are a tty (the owner's SSH session; a pseudo-tty in CI). A unit,
# a pipe and `claude -p` fail it.
zy_m365_tty() {
  [ -t 0 ] && [ -t 1 ]
}

# The state directory, 0700, created on first use; exit 3 when that is impossible.
zy_m365_state_dir() {
  if [ ! -d "$ZY_M365_STATE_DIR" ]; then
    (umask 077 && mkdir -p "$ZY_M365_STATE_DIR") 2> /dev/null ||
      zy_die 3 "state directory $ZY_M365_STATE_DIR cannot be created"
  fi
  chmod 700 "$ZY_M365_STATE_DIR"
}

# The one appender for the three consent files: 0600 (created on first write), an exclusive lock on the file for
# the duration of the append, one JSON row per line. Callers pass a compact JSON object without body text.
zy_m365_consent_append() { # zy_m365_consent_append <file> <json row>
  zy_m365_state_dir
  (
    umask 077
    exec 9>> "$1"
    flock -x 9
    printf '%s\n' "$2" >&9
  )
  chmod 600 "$1"
}

# The proposal row <id> as compact JSON, or nothing.
zy_m365_row() { # zy_m365_row <row id>
  [ -s "$ZY_M365_PROPOSALS" ] || return 0
  jq -c -n --arg id "$1" 'first(inputs | select(.id == $id))' "$ZY_M365_PROPOSALS"
}

# Every approval row bound to <hash>, newest first (one per line), or nothing.
zy_m365_approvals() { # zy_m365_approvals <hash>
  [ -s "$ZY_M365_APPROVALS" ] || return 0
  jq -c -n --arg h "$1" '[inputs | select(.hash_at_approval == $h)] | reverse | .[]' "$ZY_M365_APPROVALS"
}

# True when an execution with a 2xx status is recorded for the proposal <row id>: it ran, whatever the status says.
zy_m365_executed() { # zy_m365_executed <row id>
  [ -s "$ZY_M365_EXECUTIONS" ] &&
    jq -e -n --arg id "$1" 'any(inputs; .row_id == $id and ((.http_status | tostring) | test("^2")))' \
      "$ZY_M365_EXECUTIONS" > /dev/null
}

# --- the pinned server's tool partition (plan 23 Step 1; generated from tests/fixtures/m365/*-tools.txt, never typed) ----

# The ENABLED_TOOLS filter handed to @softeria/ms-365-mcp-server@0.157.2: the 14 allowlisted tools, anchored. The
# server compiles it case-insensitively and exits on an invalid one. repo.bats proves it equals the fixture list.
# shellcheck disable=SC2034 # read by mcp-wrapper.sh
readonly ZY_M365_ENABLED_TOOLS='^(create-shared-mailbox-draft|create-shared-mailbox-reply-draft|download-bytes-to-file|get-drive-delta|get-drive-item|get-drive-root-item|get-shared-mailbox-message|get-sharepoint-site-drive-by-id|list-drive-item-versions|list-folder-files|list-shared-mailbox-folder-messages|list-shared-mailbox-messages|list-sharepoint-site-drives|search-onedrive-files)$'
# shellcheck disable=SC2034 # the allowlist as names (mcp-wrapper.sh --probe splits the offered tools with it)
readonly -a ZY_M365_TOOLS_ENABLED=(
  create-shared-mailbox-draft
  create-shared-mailbox-reply-draft
  download-bytes-to-file
  get-drive-delta
  get-drive-item
  get-drive-root-item
  get-shared-mailbox-message
  get-sharepoint-site-drive-by-id
  list-drive-item-versions
  list-folder-files
  list-shared-mailbox-folder-messages
  list-shared-mailbox-messages
  list-sharepoint-site-drives
  search-onedrive-files
)
# shellcheck disable=SC2034 # every other tool of the pinned version: unloaded by the filter and denied by name in
# the template settings (permissions.deny, mcp__m365__<name>)
readonly -a ZY_M365_TOOLS_EXCLUDED=(
  accept-calendar-event
  add-excel-table-rows
  add-group-member
  add-group-owner
  add-mail-attachment
  add-team-member
  cancel-calendar-event
  clear-excel-range
  clear-my-presence
  clear-my-user-preferred-presence
  copilot-retrieve
  copy-drive-item
  copy-mail-message
  create-calendar
  create-calendar-event
  create-chat
  create-contact-child-folder
  create-contact-folder
  create-contact-in-folder
  create-custom-emoji
  create-draft-email
  create-drive-item-preview
  create-drive-item-share-link
  create-excel-chart
  create-excel-table
  create-focused-inbox-override
  create-forward-draft
  create-group
  create-mail-attachment-upload-session
  create-mail-child-folder
  create-mail-folder
  create-mail-rule
  create-my-calendar-permission
  create-onedrive-folder
  create-onenote-notebook
  create-onenote-page
  create-onenote-section
  create-onenote-section-page
  create-online-meeting
  create-outlook-category
  create-outlook-contact
  create-planner-bucket
  create-planner-task
  create-planner-task-message
  create-reply-all-draft
  create-reply-draft
  create-shared-mailbox-forward-draft
  create-shared-mailbox-reply-all-draft
  create-sharepoint-list
  create-sharepoint-list-column
  create-sharepoint-list-item
  create-sharepoint-site-onenote-notebook
  create-sharepoint-site-onenote-section
  create-sharepoint-site-onenote-section-group-section
  create-sharepoint-site-onenote-section-page
  create-specific-calendar-event
  create-subscription
  create-team-channel
  create-todo-linked-resource
  create-todo-task
  create-todo-task-list
  create-upload-session
  decline-calendar-event
  delete-calendar
  delete-calendar-event
  delete-contact-folder
  delete-drive-item-permission
  delete-excel-range
  delete-excel-table-row
  delete-focused-inbox-override
  delete-group
  delete-mail-attachment
  delete-mail-folder
  delete-mail-message
  delete-mail-rule
  delete-my-calendar-permission
  delete-onedrive-file
  delete-onenote-page
  delete-online-meeting
  delete-outlook-contact
  delete-planner-bucket
  delete-planner-task-message
  delete-sharepoint-list-column
  delete-sharepoint-list-item
  delete-sharepoint-site-onenote-page
  delete-specific-calendar-event
  delete-subscription
  delete-team-channel
  delete-todo-linked-resource
  delete-todo-task
  delete-todo-task-list
  dismiss-calendar-event-reminder
  download-bytes
  extract-drive-item-sensitivity-labels
  find-meeting-times
  format-excel-range
  format-excel-range-border
  format-excel-range-fill
  format-excel-range-font
  forward-calendar-event
  forward-mail-message
  forward-shared-mailbox-mail
  get-adhoc-call-transcript-content
  get-calendar-event
  get-calendar-view
  get-channel-files-folder
  get-channel-message
  get-chat
  get-chat-message
  get-current-user
  get-download-url
  get-excel-range
  get-excel-range-format
  get-excel-table
  get-excel-used-range
  get-group
  get-group-calendar-view
  get-mail-message
  get-mail-message-mime
  get-mail-tips
  get-mailbox-settings
  get-meeting-attendance-report
  get-meeting-recording
  get-meeting-recording-content
  get-meeting-transcript
  get-meeting-transcript-content
  get-my-manager
  get-my-presence
  get-my-profile
  get-onenote-notebook-from-web-url
  get-onenote-page-content
  get-online-meeting
  get-outlook-contact
  get-planner-bucket
  get-planner-plan
  get-planner-task
  get-planner-task-details
  get-presences-by-user-id
  get-room
  get-room-list
  get-room-list-room
  get-schedule
  get-sensitivity-label
  get-shared-calendar-view
  get-sharepoint-list-column
  get-sharepoint-site
  get-sharepoint-site-by-path
  get-sharepoint-site-item
  get-sharepoint-site-list
  get-sharepoint-site-list-item
  get-sharepoint-site-onenote-page-content
  get-sharepoint-sites-delta
  get-specific-calendar-event
  get-specific-calendar-view
  get-subscription
  get-team
  get-team-channel
  get-todo-task
  get-user-manager
  get-user-presence
  get-virtual-event-webinar
  graph-batch
  insert-excel-range
  list-accounts
  list-adhoc-call-transcripts
  list-all-onenote-sections
  list-calendar-event-instances
  list-calendar-events
  list-calendar-events-delta
  list-calendar-view-delta
  list-calendars
  list-channel-message-hosted-contents
  list-channel-message-replies
  list-channel-messages
  list-channel-tabs
  list-chat-members
  list-chat-message-hosted-contents
  list-chat-message-replies
  list-chat-messages
  list-chats
  list-contact-folder-child-folders
  list-contact-folder-contacts
  list-contact-folders
  list-custom-emojis
  list-drive-item-permissions
  list-drive-item-thumbnails
  list-drives
  list-excel-table-rows
  list-excel-tables
  list-excel-worksheets
  list-focused-inbox-overrides
  list-group-conversations
  list-group-events
  list-group-members
  list-group-owners
  list-group-threads
  list-groups
  list-joined-teams
  list-mail-attachments
  list-mail-child-folders
  list-mail-folder-messages
  list-mail-folder-messages-delta
  list-mail-folders
  list-mail-messages
  list-mail-rules
  list-meeting-attendance-records
  list-meeting-attendance-reports
  list-meeting-recordings
  list-meeting-transcripts
  list-my-associated-teams
  list-my-calendar-permissions
  list-my-direct-reports
  list-my-installed-teams-apps
  list-my-memberships
  list-onenote-notebook-sections
  list-onenote-notebooks
  list-onenote-pages
  list-onenote-section-groups
  list-onenote-section-pages
  list-online-meetings
  list-outlook-categories
  list-outlook-contacts
  list-pinned-chat-messages
  list-plan-buckets
  list-plan-tasks
  list-planner-task-messages
  list-planner-tasks
  list-relevant-people
  list-room-list-rooms
  list-sensitivity-labels
  list-shared-calendar-events
  list-sharepoint-list-columns
  list-sharepoint-site-items
  list-sharepoint-site-list-items
  list-sharepoint-site-lists
  list-sharepoint-site-onenote-notebook-section-groups
  list-sharepoint-site-onenote-notebook-sections
  list-sharepoint-site-onenote-notebooks
  list-sharepoint-site-onenote-section-group-section-groups
  list-sharepoint-site-onenote-section-group-sections
  list-sharepoint-site-onenote-section-pages
  list-specific-calendar-events
  list-subscriptions
  list-supported-languages
  list-supported-time-zones
  list-team-channels
  list-team-members
  list-todo-linked-resources
  list-todo-task-lists
  list-todo-tasks
  list-trending-insights
  list-user-direct-reports
  list-users
  list-webinar-sessions
  login
  logout
  merge-excel-range
  move-mail-message
  move-rename-onedrive-item
  move-shared-mailbox-message
  parse-teams-url
  pin-chat-message
  reauthorize-subscription
  remove-account
  remove-group-member
  remove-group-owner
  remove-team-member
  reply-all-mail-message
  reply-all-shared-mailbox-mail
  reply-mail-message
  reply-shared-mailbox-mail
  reply-to-channel-message
  reply-to-chat-message
  reply-to-group-thread
  search-query
  search-sharepoint-sites
  select-account
  send-channel-message
  send-chat-message
  send-draft-message
  send-mail
  send-my-activity-notification
  send-shared-mailbox-draft
  send-shared-mailbox-mail
  set-channel-message-reaction
  set-chat-message-reaction
  set-my-presence
  set-my-status-message
  set-my-user-preferred-presence
  share-drive-item
  snooze-calendar-event-reminder
  sort-excel-range
  tentatively-accept-calendar-event
  unmerge-excel-range
  unpin-chat-message
  unset-channel-message-reaction
  unset-chat-message-reaction
  update-calendar
  update-calendar-event
  update-channel-message
  update-channel-message-reply
  update-chat-message
  update-contact-folder
  update-excel-range
  update-excel-table-row
  update-focused-inbox-override
  update-group
  update-mail-folder
  update-mail-message
  update-mail-rule
  update-mailbox-settings
  update-my-calendar-permission
  update-online-meeting
  update-outlook-contact
  update-place
  update-planner-bucket
  update-planner-task
  update-planner-task-details
  update-shared-mailbox-message
  update-sharepoint-list-column
  update-sharepoint-list-item
  update-sharepoint-site-onenote-page-content
  update-specific-calendar-event
  update-subscription
  update-team-channel
  update-todo-task
  update-todo-task-list
  upload-file-content
  upload-my-profile-photo
  verify-login
)
# shellcheck disable=SC2034 # the six auth tools the server registers outside the filter in stdio mode (Step 1
# finding): the settings deny list is their only defence; mcp-wrapper.sh --probe reports them
readonly -a ZY_M365_AUTH_TOOLS=(list-accounts login logout remove-account select-account verify-login)

# --- the unattended claude run (brief.sh) -------------------------------------------------------------------------

# What a morning-brief run's model may use (spec 23 run allowlist): the 14 tools the server loads, the four scripts it
# writes through (state, facts, parse, and propose — a proposal row, never an execution) and reads of the state dir.
ZY_M365_BRIEF_ALLOW=()
for zy_t in "${ZY_M365_TOOLS_ENABLED[@]}"; do ZY_M365_BRIEF_ALLOW+=("mcp__m365__$zy_t"); done
ZY_M365_BRIEF_ALLOW+=('Bash(.claude/skills/m365/state.sh *)' 'Bash(.claude/skills/m365/facts.sh *)'
  'Bash(.claude/skills/m365/parse.sh *)' 'Bash(.claude/skills/m365/propose.sh *)' 'Read(~/.local/state/zyggy/m365/**)')
# What it may never use: every other tool of the pinned server, the executor and the consent terminal, and every
# outbound channel (web, browser, file edits, network and package tools).
ZY_M365_BRIEF_DENY=()
for zy_t in "${ZY_M365_TOOLS_EXCLUDED[@]}"; do ZY_M365_BRIEF_DENY+=("mcp__m365__$zy_t"); done
ZY_M365_BRIEF_DENY+=('Bash(.claude/skills/m365/graph.sh *)' 'Bash(.claude/skills/m365/m365-approve.sh *)' WebFetch WebSearch
  mcp__plugin_playwright_playwright Edit Write NotebookEdit 'Bash(curl *)' 'Bash(wget *)' 'Bash(git *)' 'Bash(npm *)'
  'Bash(npx *)' 'Bash(node *)')
unset zy_t
# shellcheck disable=SC2034 # read by brief.sh
readonly -a ZY_M365_BRIEF_ALLOW ZY_M365_BRIEF_DENY

# The arguments joined by <separator> (one --allowedTools / --disallowedTools value).
zy_m365_join() { # zy_m365_join <separator> <item…>
  local sep="$1" out=""
  shift
  out="$(printf "%s$sep" "$@")"
  printf '%s' "${out%"$sep"}"
}

# ZY_M365_CLAUDE_BIN: the claude CLI on PATH, resolved once before any request; exit 3 when it is missing.
zy_m365_claude() {
  ZY_M365_CLAUDE_BIN="$(command -v claude)" || zy_die 3 "claude not found"
}

# One claude run in the shape of the unit (spec 23: the run can propose but never execute): the project directory
# as working directory, ZYGGY_HOOKS=off, ZYGGY_M365_ORIGIN=<origin> ("-" for none), stdin /dev/null so the child has
# no terminal, stdout (the JSON result) and stderr into files. The child runs in the background so a SIGTERM to the
# caller can stop it (ZY_M365_CLAUDE_PID while it runs); the return status is claude's.
ZY_M365_CLAUDE_PID=""
zy_m365_run_claude() { # zy_m365_run_claude <result file> <stderr file> <origin|-> <claude arguments…>
  local result="$1" err="$2" origin="$3" rc=0
  local -a run_env=(-u ZYGGY_M365_ORIGIN ZYGGY_HOOKS=off)
  shift 3
  [ "$origin" = - ] || run_env=(ZYGGY_HOOKS=off "ZYGGY_M365_ORIGIN=$origin")
  (
    cd "$ZY_M365_CHECKOUT"
    exec env "${run_env[@]}" "$ZY_M365_CLAUDE_BIN" "$@"
  ) < /dev/null > "$result" 2> "$err" &
  ZY_M365_CLAUDE_PID=$!
  wait "$ZY_M365_CLAUDE_PID" || rc=$?
  ZY_M365_CLAUDE_PID=""
  return "$rc"
}

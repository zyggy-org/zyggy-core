#!/usr/bin/env bash
set -euo pipefail
# Shared functions for the m365 connector scripts (spec 23). Sourced after ../../hooks/lib.sh, never executed.
# Owns the paths (config, state dir, key, certificate), the configuration validation, the key lookup, the retry
# clock, the curl stub guard and the one definition of the snapshot canonical form and its hash. No request is
# made here and the private key is never read into a variable: callers hand its path to openssl.
# Every m365 script prefixes its stderr lines with "m365: " (zy_die reads ZY_SELF).
# shellcheck disable=SC2034 # read by lib.sh's zy_die and by the scripts that source this library
ZY_SELF=m365

ZY_M365_CHECKOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
ZY_M365_CONFIG="${ZYGGY_M365_CONFIG:-$ZY_M365_CHECKOUT/instance/m365.json}"
ZY_M365_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zyggy/m365"
ZY_M365_KEY_FILE="${ZYGGY_M365_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/zyggy/m365-app.key}"
ZY_M365_CER_FILE="${ZYGGY_M365_CER_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/zyggy/m365-app.cer}"
ZY_M365_CREDENTIAL_NAME=m365-app-key
# shellcheck disable=SC2034 # the paths and grammars are read by the scripts that source this library
readonly ZY_M365_CHECKOUT ZY_M365_CONFIG ZY_M365_STATE_DIR ZY_M365_KEY_FILE ZY_M365_CER_FILE ZY_M365_CREDENTIAL_NAME
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

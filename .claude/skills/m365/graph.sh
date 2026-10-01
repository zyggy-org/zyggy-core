#!/usr/bin/env bash
set -euo pipefail
# Central's Microsoft 365 application identity, in one script (spec 23): generates the key pair on this machine,
# mints app-only access tokens with a certificate client assertion, reads Graph on /users/<mailbox>, /drives and
# /sites, and (Step 3) executes one consented send, move or soft delete against an approved, hash-matching row.
# usage: graph.sh cert-init [--rotate|--commit] | token [--key new] [--alg PS256|RS256]
#        | check [--counts] [--other-mailbox <upn>] [--drive <id>] | mail-folders | drives | drafts-since <ISO>
#        | message-sender <id> | snapshot draft|message <id> | get draft|message <id> | sent-since <ISO>
#        | send-draft|move|delete --approved <hash>
# Exit 0 · 3 configuration or key · 4 usage · 5 refused · 6 identity or Graph failure.
# The private key is handed to openssl by path and never read into a variable. The access token leaves this script
# only on stdout (`token`) and in a 0600 header file handed to curl. curl runs in a cleared environment with
# --proto =https and a hard timeout; the personal (me) endpoints are never requested; a hard DELETE never exists.
# shellcheck source=../../hooks/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib.sh"
# shellcheck source=m365-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/m365-lib.sh"

readonly ZY_M365_LOGIN=https://login.microsoftonline.com ZY_M365_GRAPH=https://graph.microsoft.com/v1.0
readonly ZY_M365_SCOPE=https://graph.microsoft.com/.default
readonly ZY_M365_ASSERTION_TYPE=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
readonly ZY_M365_ASSERTION_SECONDS=300 ZY_M365_CURL_TIMEOUT=60 ZY_M365_RETRIES=5 ZY_M365_PAGE=100 ZY_M365_TOP=50
readonly ZY_M365_ALG_DEFAULT=PS256 ZY_M365_BRIEF_SUBJECT='Zyggy — morning brief'
readonly ZY_M365_SNAPSHOT_SELECT='id,subject,toRecipients,ccRecipients,bccRecipients,from,receivedDateTime,parentFolderId,changeKey,isDraft'
readonly ZY_M365_DRAFTS_SELECT='id,subject,toRecipients,ccRecipients,bccRecipients,conversationId,createdDateTime,changeKey,body'
readonly ZY_M365_SENT_SELECT='id,subject,toRecipients,sentDateTime,internetMessageId'
readonly ZY_M365_PREFER_TEXT='Prefer: outlook.body-content-type="text"'

die() { # die <exit code> <message>
  zy_die "$@"
}

usage() {
  die 4 "$1 (usage: graph.sh cert-init [--rotate|--commit] | token [--key new] [--alg PS256|RS256] | check [--counts] [--other-mailbox <upn>] [--drive <id>] | mail-folders | drives | drafts-since <ISO> | message-sender <id> | snapshot draft|message <id> | get draft|message <id> | sent-since <ISO> | send-draft|move|delete --approved <hash>)"
}

# --- 1. the verb and its arguments (exit 4 before anything else) -------------------------------------------------

verb="${1:-}"
[ $# -eq 0 ] || shift
[ -n "$verb" ] || usage "no verb given"
mode=""
key_variant=""
alg="$ZY_M365_ALG_DEFAULT"
counts=0
other=""
drive=""
arg=""
kind=""
approved=""
case "$verb" in
  cert-init)
    while [ $# -gt 0 ]; do
      case "$1" in
        --rotate | --commit)
          [ -z "$mode" ] || usage "cert-init takes --rotate or --commit, not both"
          mode="${1#--}"
          ;;
        *) usage "cert-init: unexpected argument '$1'" ;;
      esac
      shift
    done
    ;;
  token)
    while [ $# -gt 0 ]; do
      case "$1" in
        --key)
          [ "${2:-}" = new ] || usage "--key takes 'new' (the pair from cert-init --rotate)"
          key_variant=new
          shift 2
          ;;
        --alg)
          case "${2:-}" in
            PS256 | RS256) alg="$2" ;;
            *) usage "--alg must be PS256 or RS256" ;;
          esac
          shift 2
          ;;
        *) usage "token: unexpected argument '$1'" ;;
      esac
    done
    ;;
  check)
    while [ $# -gt 0 ]; do
      case "$1" in
        --counts)
          [ "$counts" -eq 0 ] || usage "--counts given twice"
          counts=1
          shift
          ;;
        --other-mailbox)
          [[ "${2:-}" =~ $ZY_M365_UPN_RE ]] || usage "--other-mailbox needs a user principal name"
          [ -z "$other" ] || usage "--other-mailbox given twice"
          other="$2"
          shift 2
          ;;
        --drive)
          [[ "${2:-}" =~ $ZY_M365_DRIVE_ID_RE ]] || usage "--drive needs a drive id"
          [ -z "$drive" ] || usage "--drive given twice"
          drive="$2"
          shift 2
          ;;
        *) usage "check: unexpected argument '$1'" ;;
      esac
    done
    ;;
  mail-folders | drives)
    [ $# -eq 0 ] || usage "$verb takes no argument"
    ;;
  drafts-since | sent-since)
    [ $# -eq 1 ] || usage "$verb needs one <ISO> timestamp"
    [[ "$1" =~ $ZY_M365_ISO_RE ]] || usage "'$1' is not an ISO timestamp (YYYY-MM-DDTHH:MM:SSZ)"
    arg="$1"
    ;;
  message-sender)
    [ $# -eq 1 ] || usage "message-sender needs one <id>"
    [[ "$1" =~ $ZY_M365_ID_RE ]] || usage "'$1' is not a message id"
    arg="$1"
    ;;
  snapshot | get)
    [ $# -eq 2 ] || usage "$verb needs draft|message <id>"
    case "$1" in
      draft | message) kind="$1" ;;
      *) usage "$verb: '$1' is not draft or message" ;;
    esac
    [[ "$2" =~ $ZY_M365_ID_RE ]] || usage "'$2' is not a message id"
    arg="$2"
    ;;
  send-draft | move | delete)
    if [ $# -ne 2 ] || [ "$1" != --approved ]; then
      usage "$verb needs exactly --approved <hash> (nothing leaves the mailbox without an approved row)"
    fi
    [[ "$2" =~ $ZY_M365_HASH_RE ]] || usage "'$2' is not a sha256 hash"
    approved="$2"
    ;;
  *) usage "unknown verb '$verb'" ;;
esac

# --- 2. the attended-only verb, the principal, the tools, the configuration, the curl seam ---------------------------

if [ "$verb" = cert-init ] && zy_hooks_off; then
  die 5 "refused: unattended run (ZYGGY_HOOKS=off)"
fi

zy_require_config
for tool in curl jq openssl; do
  command -v "$tool" > /dev/null || die 3 "$tool not found"
done
if [ "$verb" = cert-init ]; then
  zy_m365_load_config --base
else
  zy_m365_load_config
fi
curl_bin="$(command -v curl)"
zy_m365_curl_guard "$curl_bin"

work="$(mktemp -d -t zyggy-m365.XXXXXX)"
trap 'rm -rf "$work"' EXIT
body="$work/body"
hdrs="$work/hdrs"
curl_err="$work/curl-err"
auth_file="$work/auth"
HTTP_STDIN=/dev/null
HTTP_STATUS=""
token=""
token_minted=""

# --- the curl seam -----------------------------------------------------------------------------------------------

# The single curl call site: nothing of this environment but PATH, HOME and LC_ALL; TLS only; a hard timeout; the
# response body and headers land in the work directory and the status code on stdout. stdin is HTTP_STDIN (the
# assertion file for the token request, /dev/null otherwise), so no credential is ever an argument.
curl_run() { # curl_run <curl arguments…>
  HTTP_STATUS="$(env -i PATH="/usr/bin:/bin:$(dirname "$curl_bin")" HOME="$HOME" LC_ALL=C "$curl_bin" -sS --proto =https \
    --max-time "$ZY_M365_CURL_TIMEOUT" -o "$body" -D "$hdrs" -w '%{http_code}' "$@" < "$HTTP_STDIN" 2> "$curl_err")"
}

# The Retry-After seconds of the last response, or nothing.
retry_after() {
  grep -i '^Retry-After:' "$hdrs" | tr -d '\r' | awk 'NR == 1 { print $2 }' | grep -E '^[0-9]+$' || true
}

# One exchange with retries on 429/503 (Retry-After, else 2^n seconds, 5 at most). Returns 0 on 2xx or a tolerated
# status (ERE in $1, "-" for none), 1 otherwise; HTTP_STATUS holds the status. A transport failure is exit 6.
http() { # http <tolerated-status-ERE> <method> <url> [curl arguments…]
  local tolerate="$1" method="$2" url="$3" attempt=0 wait line
  shift 3
  while :; do
    if ! curl_run -X "$method" "$@" "$url"; then
      line="$(head -n 1 "$curl_err")"
      if zy_secret_match "$line"; then
        line="curl error text withheld: matches secret pattern $ZY_SECRET_NAME"
      fi
      die 6 "request failed (${line:-curl failed without a message})"
    fi
    case "$HTTP_STATUS" in
      429 | 503)
        attempt=$((attempt + 1))
        if [ "$attempt" -gt "$ZY_M365_RETRIES" ]; then
          die 6 "throttled ($HTTP_STATUS) after $ZY_M365_RETRIES retries — runbook 13 \"Throttling\""
        fi
        wait="$(retry_after)"
        [ -n "$wait" ] || wait=$((1 << attempt))
        zy_m365_sleep "$wait"
        continue
        ;;
    esac
    if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]] || [[ "$HTTP_STATUS" =~ ^($tolerate)$ ]]; then
      return 0
    fi
    return 1
  done
}

# --- the identity -------------------------------------------------------------------------------------------------

b64url() { # stdin → base64url without padding
  base64 -w0 | tr '+/' '-_' | tr -d '='
}

# The client assertion for the token request, written to $work/assertion: header {alg, typ, x5t#S256 | x5t},
# claims {aud, iss, sub, jti, nbf, iat, exp = +300 s}, signature PS256 (RSA-PSS, salt = digest length) or RS256.
# The only place the private key is used: openssl reads it from its path.
build_assertion() {
  local cer="$ZY_M365_CER_FILE" header payload now jti thumb
  local -a sigopts=()
  [ "$key_variant" != new ] || cer="$cer.new"
  [ -f "$cer" ] || die 3 "certificate $cer not found"
  if [ "$alg" = PS256 ]; then
    thumb="$(openssl x509 -in "$cer" -outform DER | openssl dgst -sha256 -binary | b64url)"
    header="$(jq -nc --arg t "$thumb" '{alg: "PS256", typ: "JWT", "x5t#S256": $t}')"
    sigopts=(-sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-1)
  else
    thumb="$(openssl x509 -in "$cer" -outform DER | openssl dgst -sha1 -binary | b64url)"
    header="$(jq -nc --arg t "$thumb" '{alg: "RS256", typ: "JWT", x5t: $t}')"
  fi
  now="$(zy_date UTC +%s)"
  jti="$(openssl rand -hex 16 | sed -E 's/^(.{8})(.{4}).(.{3}).(.{3})(.{12})$/\1-\2-4\3-8\4-\5/')"
  payload="$(jq -nc --arg aud "$ZY_M365_LOGIN/$M365_TENANT_ID/oauth2/v2.0/token" --arg c "$M365_CLIENT_ID" --arg jti "$jti" \
    --argjson now "$now" --argjson exp "$((now + ZY_M365_ASSERTION_SECONDS))" \
    '{aud: $aud, iss: $c, sub: $c, jti: $jti, nbf: $now, iat: $now, exp: $exp}')"
  printf '%s.%s' "$(printf '%s' "$header" | b64url)" "$(printf '%s' "$payload" | b64url)" > "$work/input"
  openssl dgst -sha256 "${sigopts[@]+"${sigopts[@]}"}" -sign "$M365_KEY_PATH" -binary -out "$work/sig" "$work/input" 2> "$curl_err" ||
    die 6 "signing failed ($(head -n 1 "$curl_err"))"
  printf '%s.%s' "$(cat "$work/input")" "$(b64url < "$work/sig")" > "$work/assertion"
  rm -f "$work/sig" "$work/input"
}

# Mint a one-hour app-only access token: POST client_credentials with the assertion on stdin. Sets token and the
# 0600 header file curl reads; identity failures are exit 6 with the runbook entry named.
mint_token() {
  local err
  build_assertion
  HTTP_STDIN="$work/assertion"
  http '4[0-9][0-9]' POST "$ZY_M365_LOGIN/$M365_TENANT_ID/oauth2/v2.0/token" \
    --data-urlencode grant_type=client_credentials --data-urlencode "scope=$ZY_M365_SCOPE" \
    --data-urlencode "client_id=$M365_CLIENT_ID" --data-urlencode "client_assertion_type=$ZY_M365_ASSERTION_TYPE" \
    --data-urlencode client_assertion@- || die 6 "token request failed ($HTTP_STATUS)"
  HTTP_STDIN=/dev/null
  rm -f "$work/assertion"
  if [ "$HTTP_STATUS" != 200 ]; then
    if grep -qs AADSTS700024 "$body"; then
      die 6 "auth failed (clock skew, AADSTS700024) — check timedatectl on this machine"
    fi
    err="$(jq -r '.error // empty' "$body" 2> /dev/null || true)"
    die 6 "auth failed (${err:-http $HTTP_STATUS}) — runbook 13 \"Certificate rejected\""
  fi
  token="$(jq -r '.access_token // empty' "$body")"
  [ -n "$token" ] || die 6 "auth failed (no access_token in the response) — runbook 13 \"Certificate rejected\""
  token_minted="$(zy_now_utc)"
  (umask 077 && printf 'Authorization: Bearer %s\n' "$token" > "$auth_file")
}

# A Graph request with the Bearer header from the header file; one re-mint on 401; 403 and every other failure
# exit 6 unless tolerated (ERE in $1, e.g. "403|404").
graph_call() { # graph_call <tolerated-status-ERE> <method> <url> [curl arguments…]
  local tolerate="$1" reminted=0 code
  shift
  while :; do
    if http "$tolerate|401" "$@" -H "@$auth_file" -H 'Accept: application/json'; then
      if [ "$HTTP_STATUS" = 401 ] && [[ ! 401 =~ ^($tolerate)$ ]]; then
        if [ "$reminted" -eq 1 ]; then
          die 6 "unauthorized (401) after a fresh token — runbook 13 \"Certificate rejected\""
        fi
        mint_token
        reminted=1
        continue
      fi
      return 0
    fi
    code="$(jq -r '.error.code // empty' "$body" 2> /dev/null || true)"
    case "$HTTP_STATUS" in
      403) die 6 "forbidden (${code:-403}) — runbook 13 \"Scope or grant missing\"" ;;
      *) die 6 "Graph request failed ($HTTP_STATUS${code:+ $code})" ;;
    esac
  done
}

mailbox_url() {
  printf '%s/users/%s' "$ZY_M365_GRAPH" "$M365_MAILBOX"
}

# --- the key pair (cert-init) ---------------------------------------------------------------------------------------

# Thumbprints, expiry and path of a certificate: public material only.
print_cert() { # print_cert <cer path>
  local end
  printf 'thumbprint sha1: %s\n' "$(openssl x509 -in "$1" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
  printf 'thumbprint sha256: %s\n' "$(openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d :)"
  end="$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)"
  printf 'expires: %s\n' "$(date -u -d "$end" +%F)"
  printf 'certificate: %s\n' "$1"
}

# A new RSA 2048 key (0600, in a 0700 directory) and its X.509 certificate (0644, CN cert.subject, cert.days).
generate_pair() { # generate_pair <key path> <cer path>
  local dir
  dir="$(dirname "$1")"
  (umask 077 && mkdir -p "$dir")
  chmod 700 "$dir"
  (umask 077 && openssl req -x509 -newkey rsa:2048 -nodes -days "$M365_CERT_DAYS" -subj "/CN=$M365_CERT_SUBJECT" \
    -keyout "$1" -out "$2" 2> "$work/openssl-err") || die 6 "openssl failed ($(head -n 1 "$work/openssl-err"))"
  chmod 600 "$1"
  chmod 644 "$2"
  print_cert "$2"
}

cert_init() {
  local key="$ZY_M365_KEY_FILE" cer="$ZY_M365_CER_FILE"
  case "$mode" in
    "")
      [ ! -e "$key" ] || die 5 "refused: key exists — use --rotate ($key)"
      generate_pair "$key" "$cer"
      ;;
    rotate)
      if [ -e "$key.new" ] || [ -e "$cer.new" ]; then
        die 5 "refused: a rotation is pending — use --commit or remove $key.new"
      fi
      generate_pair "$key.new" "$cer.new"
      ;;
    commit)
      if [ ! -f "$key.new" ] || [ ! -f "$cer.new" ]; then
        usage "--commit: no $key.new to commit"
      fi
      mv -f "$key.new" "$key"
      mv -f "$cer.new" "$cer"
      chmod 600 "$key"
      chmod 644 "$cer"
      print_cert "$cer"
      ;;
  esac
}

# --- the reads ------------------------------------------------------------------------------------------------------

# Every mail folder (top level plus one level of children) → $work/folders.json
# [{id, displayName, wellKnownName, totalItemCount, excluded}], excluded = well-known name in mail_backfill.exclude_folders.
load_folders() {
  local ids fid
  graph_call - GET "$(mailbox_url)/mailFolders?\$top=$ZY_M365_PAGE"
  jq -c '.value[]?' "$body" > "$work/folders.jsonl"
  ids="$(jq -r '.value[]? | select((.childFolderCount // 0) > 0) | .id' "$body")"
  while IFS= read -r fid; do
    [ -n "$fid" ] || continue
    [[ "$fid" =~ $ZY_M365_ID_RE ]] || die 6 "Graph returned an unexpected folder id"
    graph_call - GET "$(mailbox_url)/mailFolders/$fid/childFolders?\$top=$ZY_M365_PAGE"
    jq -c '.value[]?' "$body" >> "$work/folders.jsonl"
  done <<< "$ids"
  jq -s --argjson ex "$M365_EXCLUDE_FOLDERS_JSON" '[.[] | {id, displayName, wellKnownName: (.wellKnownName // null),
    totalItemCount: (.totalItemCount // 0), excluded: ((.wellKnownName // "") as $w | ($ex | index($w)) != null)}]' \
    "$work/folders.jsonl" > "$work/folders.json"
}

# The OneDrive and every granted site's document libraries → $work/drives.json [{id, name, site}], first occurrence
# of an id kept, drives.exclude_drives (ids or names) dropped.
load_drives() {
  local site
  graph_call - GET "$(mailbox_url)/drive?\$select=id,name,webUrl"
  jq -c '{id, name, site: "onedrive"}' "$body" > "$work/drives.jsonl"
  while IFS= read -r site; do
    [ -n "$site" ] || continue
    graph_call - GET "$ZY_M365_GRAPH/sites/$site/drives?\$select=id,name,webUrl"
    jq -c --arg s "$site" '.value[]? | {id, name, site: $s}' "$body" >> "$work/drives.jsonl"
  done <<< "$M365_SITES_GRANTED"
  jq -s --argjson ex "$M365_EXCLUDE_DRIVES_JSON" 'reduce .[] as $d ([]; if any(.[]; .id == $d.id) then . else . + [$d] end)
    | [.[] | select(((.id as $i | $ex | index($i)) == null) and ((.name as $n | $ex | index($n)) == null))]' \
    "$work/drives.jsonl" > "$work/drives.json"
}

# One message by id with a $select; 404 is "not found (<id>)", exit 6.
load_message() { # load_message <id> <select> [curl arguments…]
  local id="$1" select="$2"
  shift 2
  graph_call 404 GET "$(mailbox_url)/messages/$id?\$select=$select" "$@"
  [ "$HTTP_STATUS" != 404 ] || die 6 "not found ($id)"
}

run_check() {
  local excluded names
  load_folders
  load_drives
  excluded="$(jq '[.[] | select(.excluded)] | length' "$work/folders.json")"
  names="$(jq -r 'map(.name) | join(", ")' "$work/drives.json")"
  printf 'm365: app %s (tenant %s), mailbox %s: folders %s (%s excluded), drives %s (%s), token minted %s, state dir %s\n' \
    "$M365_CERT_SUBJECT" "$M365_TENANT_ID" "$M365_MAILBOX" "$(jq length "$work/folders.json")" "$excluded" \
    "$(jq length "$work/drives.json")" "$names" "$token_minted" "$ZY_M365_STATE_DIR"
  jq -r '.[] | "drive \(.id) \(.name) site=\(.site)"' "$work/drives.json"
  if [ "$counts" -eq 1 ]; then
    jq -r '.[] | "folder \(.id) \(.displayName) \(.wellKnownName // "-") \(.totalItemCount)" + (if .excluded then " excluded" else "" end)' \
      "$work/folders.json"
    graph_call - GET "$(mailbox_url)/mailFolders/drafts/messages?\$select=id,subject&\$top=$ZY_M365_TOP"
    printf 'zyggy-drafts %s\n' "$(jq --arg s "$ZY_M365_BRIEF_SUBJECT" '[.value[]? | select((.subject // "") | startswith($s))] | length' "$body")"
  fi
  if [ -n "$other" ]; then
    graph_call '403|404' GET "$ZY_M365_GRAPH/users/$other/mailFolders/inbox"
    if [[ "$HTTP_STATUS" =~ ^2 ]]; then
      printf 'other mailbox %s: %s — SCOPE NOT ENFORCED\n' "$other" "$HTTP_STATUS"
      die 5 "refused: scope not enforced — $other is readable; runbook 13 \"Scope or grant missing\""
    fi
    printf 'other mailbox %s: %s (expected: scope holds)\n' "$other" "$HTTP_STATUS"
  fi
  if [ -n "$drive" ]; then
    graph_call '403|404' GET "$ZY_M365_GRAPH/drives/$drive/root"
    case "$HTTP_STATUS" in
      403) printf 'drive %s: %s (not granted)\n' "$drive" "$HTTP_STATUS" ;;
      404) printf 'drive %s: %s (not found)\n' "$drive" "$HTTP_STATUS" ;;
      *) printf 'drive %s: %s (granted)\n' "$drive" "$HTTP_STATUS" ;;
    esac
  fi
}

run_snapshot() {
  local snapshot canonical
  load_message "$arg" "$ZY_M365_SNAPSHOT_SELECT"
  snapshot="$(jq -c --arg kind "$kind" '{kind: $kind, id: (.id // ""), subject: (.subject // ""),
    to: ([.toRecipients[]?.emailAddress.address // empty | ascii_downcase] | sort),
    cc: ([.ccRecipients[]?.emailAddress.address // empty | ascii_downcase] | sort),
    bcc: ([.bccRecipients[]?.emailAddress.address // empty | ascii_downcase] | sort),
    from: ((.from.emailAddress.address // "") | ascii_downcase), receivedDateTime: (.receivedDateTime // ""),
    parentFolderId: (.parentFolderId // ""), changeKey: (.changeKey // ""), isDraft: (.isDraft // false)}' "$body")"
  canonical="$(zy_m365_canonical "$snapshot")"
  printf '%s\nhash: %s\n' "$canonical" "$(zy_m365_hash "$canonical")"
}

# --- 3. the write verbs: Step 3 lands here ---------------------------------------------------------------------------

# The consented execution of send-draft, move or delete against an approved, unexpired, hash-matching row on an
# attended terminal (Step 3). Until then no row is ever approved: every call is refused before the key is read.
write_verb() { # write_verb <verb> <hash>
  die 5 "no approval for row"
}

case "$verb" in
  send-draft | move | delete) write_verb "$verb" "$approved" ;;
esac

# --- 4. the key, then the verb -----------------------------------------------------------------------------------------

if [ "$verb" != cert-init ]; then
  zy_m365_read_key "$key_variant"
  printf 'key: %s\n' "$M365_KEY_SRC" >&2
fi

case "$verb" in
  cert-init) cert_init ;;
  token)
    mint_token
    printf '%s\n' "$token"
    ;;
  check)
    mint_token
    run_check
    ;;
  mail-folders)
    mint_token
    load_folders
    jq -c . "$work/folders.json"
    ;;
  drives)
    mint_token
    load_drives
    jq -c . "$work/drives.json"
    ;;
  drafts-since)
    mint_token
    graph_call - GET "$(mailbox_url)/mailFolders/drafts/messages?\$filter=createdDateTime%20ge%20$arg&\$select=$ZY_M365_DRAFTS_SELECT&\$top=$ZY_M365_TOP" \
      -H "$ZY_M365_PREFER_TEXT"
    jq -c '.value // []' "$body"
    ;;
  sent-since)
    mint_token
    graph_call - GET "$(mailbox_url)/mailFolders/sentitems/messages?\$filter=sentDateTime%20ge%20$arg&\$select=$ZY_M365_SENT_SELECT&\$top=$ZY_M365_TOP"
    jq -c '[.value[]? | {id, subject, toRecipients, sentDateTime, internetMessageId}]' "$body"
    ;;
  message-sender)
    mint_token
    load_message "$arg" from,replyTo,conversationId
    jq -c '{from: ((.from.emailAddress.address // "") | ascii_downcase),
      replyTo: [.replyTo[]?.emailAddress.address // empty | ascii_downcase], conversationId: (.conversationId // "")}' "$body"
    ;;
  snapshot)
    mint_token
    run_snapshot
    ;;
  get)
    # The body text goes to stdout only (for the approve terminal); the response file lives in the work directory
    # the trap removes and is never copied anywhere.
    mint_token
    load_message "$arg" id,subject,body -H "$ZY_M365_PREFER_TEXT"
    jq -r '.body.content // ""' "$body"
    ;;
esac

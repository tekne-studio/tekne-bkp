#!/bin/bash
# zip-site — the download a site's owner opens without restic: one zip with the site folder and the database dump,
# uploaded to S3-compatible storage and listed by email with signed links. For a WordPress or a Craft site.
# Usage: zip-site.sh [--run | --list | --email]
#   Without an argument, prints the plan and exits without changing anything.
# Without installing: ssh <user>@<server> 'bash -s' < bin/zip-site.sh
# Docs: docs/zip-site.md
set -Eeuo pipefail

# cron starts a job with /usr/bin:/bin alone: restic and wp live in ~/bin or in /usr/local/bin
export PATH="$HOME/bin:/usr/local/bin:$PATH"

# The site comes from ~/.restic-env, as in the backup; restic itself is not used here.
RESTIC_ENV="${RESTIC_ENV:-$HOME/.restic-env}"
# shellcheck source=/dev/null
if [ -f "$RESTIC_ENV" ]; then source "$RESTIC_ENV"; fi

DUMP="${DB_DUMP:-}"  # where backup-<cms>.sh writes the dump
ENDPOINT="${ZIP_ENDPOINT:-}"
BUCKET="${ZIP_BUCKET:-}"
REGION="${ZIP_REGION:-us-east-1}"
# The keys default to restic's: one storage account often holds the repository and the zips.
KEY_ID="${ZIP_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
SECRET="${ZIP_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
NAME="${ZIP_NAME:-}"
KEEP_DAYS="${ZIP_KEEP_DAYS:-90}"
KEEP_MIN="${ZIP_KEEP_MIN:-3}"
EXCLUDE="${ZIP_EXCLUDE:-}"
TMP_BASE="${ZIP_TMP:-$HOME/tmp}"
LINK_DAYS="${ZIP_LINK_DAYS:-7}"
MAIL_TO="${EMAIL_TO:-}"
# A failed run goes to EMAIL_ALERT_TO: the people who fix it, not the site's owner.
ALERT_TO="${EMAIL_ALERT_TO:-$MAIL_TO}"
MAIL_FROM="${EMAIL_FROM:-}"
MAIL_PREFIX="${EMAIL_SUBJECT_PREFIX:-[BACKUP]}"

# One PUT per zip: the limit of an S3 upload without multipart.
MAX_BYTES=$((5 * 1024 ** 3))
EMPTY_SHA=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

usage() {
  cat <<'EOF'
usage: zip-site.sh [--run | --list | --email]
  (no argument)   prints the plan: what goes in the zip, where it goes and what the retention deletes
  --run           zips the site folder and the dump, uploads, applies the retention and emails the report
  --list          lists the zips in the bucket, each with a signed link
  --email         emails the list, with new links
Required, in the environment or in ~/.restic-env (RESTIC_ENV): WP_PATH or CRAFT_PATH, ZIP_ENDPOINT, ZIP_BUCKET
Optional: DB_DUMP, ZIP_REGION, ZIP_ACCESS_KEY_ID, ZIP_SECRET_ACCESS_KEY, ZIP_NAME, ZIP_KEEP_DAYS, ZIP_KEEP_MIN,
  ZIP_EXCLUDE, ZIP_TMP, ZIP_LINK_DAYS, EMAIL_TO, EMAIL_ALERT_TO, EMAIL_FROM, EMAIL_SUBJECT_PREFIX
EOF
}

# --- output ------------------------------------------------------------------

MODE=plan
FAILED_AT=
T0=$SECONDS

info() { printf '   → %s\n' "$*"; }
die() { FAILED_AT="$*"; printf '\n✗ %s\n' "$*" >&2; exit 1; }
duration() { if (($1 < 60)); then echo "${1}s"; else printf '%dmin%02ds' $(($1 / 60)) $(($1 % 60)); fi; }
human() { numfmt --to=iec-i --suffix=B "${1:-0}"; }
zips() { if (($1 == 1)); then echo "1 zip"; else echo "$1 zips"; fi; }
free_bytes() { df -B1 --output=avail "$1" | tail -1; }

# --- storage -----------------------------------------------------------------

# Signature Version 4, in PHP: every WordPress and Craft server has it, and the secret reaches it through the environment,
# out of every command line. Prints a curl config (url, headers) for a request, or a signed URL for a download.
# sigv4 headers <METHOD> <path> <query> <payload sha256>   ·   sigv4 presign GET <path> <query> <seconds>
SIGV4_PHP='
  list(, $mode, $method, $path, $query, $last) = $argv;
  $id = getenv("S3_KEY_ID"); $secret = getenv("S3_SECRET"); $base = getenv("S3_BASE"); $region = getenv("S3_REGION");
  $host = preg_replace("~^https?://~", "", $base);
  $amz = gmdate("Ymd\THis\Z"); $day = substr($amz, 0, 8);
  $scope = "$day/$region/s3/aws4_request";
  $q = array();
  foreach (array_filter(explode("&", $query), "strlen") as $pair) {
    $kv = explode("=", $pair, 2); $q[$kv[0]] = isset($kv[1]) ? $kv[1] : "";
  }
  if ($mode === "presign") {
    $q += array("X-Amz-Algorithm" => "AWS4-HMAC-SHA256", "X-Amz-Credential" => "$id/$scope", "X-Amz-Date" => $amz,
      "X-Amz-Expires" => $last, "X-Amz-SignedHeaders" => "host");
    $headers = array("host" => $host); $payload = "UNSIGNED-PAYLOAD";
  } else {
    $headers = array("host" => $host, "x-amz-content-sha256" => $last, "x-amz-date" => $amz); $payload = $last;
  }
  ksort($q);
  $pairs = array();
  foreach ($q as $k => $v) $pairs[] = rawurlencode($k) . "=" . rawurlencode($v);
  $qs = implode("&", $pairs);
  $uri = implode("/", array_map("rawurlencode", explode("/", $path)));
  $canonical = "";
  foreach ($headers as $k => $v) $canonical .= "$k:$v\n";
  $signed = implode(";", array_keys($headers));
  $key = "AWS4$secret";
  foreach (array($day, $region, "s3", "aws4_request") as $part) $key = hash_hmac("sha256", $part, $key, true);
  $request = "$method\n$uri\n$qs\n$canonical\n$signed\n$payload";
  $signature = hash_hmac("sha256", "AWS4-HMAC-SHA256\n$amz\n$scope\n" . hash("sha256", $request), $key);
  $url = $base . $uri . ($qs === "" ? "" : "?$qs");
  if ($mode === "presign") { echo "$url&X-Amz-Signature=$signature\n"; exit; }
  echo "url = \"$url\"\n";
  if ($method === "DELETE") echo "request = \"DELETE\"\n";
  foreach ($headers as $k => $v) if ($k !== "host") echo "header = \"$k: $v\"\n";
  echo "header = \"Authorization: AWS4-HMAC-SHA256 Credential=$id/$scope, SignedHeaders=$signed, Signature=$signature\"\n";
'
sigv4() { S3_KEY_ID="$KEY_ID" S3_SECRET="$SECRET" S3_BASE="$ENDPOINT" S3_REGION="$REGION" php -r "$SIGV4_PHP" "$@"; }

# The zips under <name>/ in the bucket, newest first: KEYS and SIZES. The date in the name orders them and dates the retention.
s3_list() {
  local xml size key
  # curl takes the signed request as a config on stdin: no header shows on a command line
  xml=$(sigv4 headers GET "/$BUCKET" "list-type=2&prefix=$NAME/" "$EMPTY_SHA" | curl -fsS -m 60 -K -) ||
    die "the bucket did not list $NAME/ (check ZIP_ENDPOINT, ZIP_BUCKET, ZIP_REGION and the keys)"
  case "$xml" in *'<IsTruncated>true</IsTruncated>'*) die "more than 1000 objects under $NAME/ in the bucket" ;; esac
  KEYS=(); SIZES=()
  while IFS=$'\t' read -r size key; do
    [[ "$key" =~ ^$NAME/$NAME--[0-9]{4}-[0-9]{2}-[0-9]{2}--[0-9]{2}-[0-9]{2}\.zip$ ]] || continue
    KEYS+=("$key"); SIZES+=("$size")
  done < <(awk 'BEGIN { RS = "<Contents>" } NR > 1 {
      k = ""; s = 0
      if (match($0, /<Key>[^<]*<\/Key>/)) k = substr($0, RSTART + 5, RLENGTH - 11)
      if (match($0, /<Size>[0-9]*<\/Size>/)) s = substr($0, RSTART + 6, RLENGTH - 13)
      print s "\t" k }' <<<"$xml" | sort -t$'\t' -k2,2r)
}

# s3_put <file> <key>: the storage checks the body against the signed SHA-256 and refuses a damaged upload
s3_put() {
  local sha try=1
  sha=$(sha256sum "$1" | cut -d' ' -f1)
  # each try is signed again: a signature is good for 15 minutes
  until sigv4 headers PUT "/$BUCKET/$2" "" "$sha" |
    curl -fsS --connect-timeout 30 --speed-limit 1024 --speed-time 300 -H 'Content-Type: application/zip' -T "$1" -K - >"$TMP/put.log" 2>&1; do
    ((try < 3)) || { tail -3 "$TMP/put.log" >&2; die "the upload of $2 failed 3 times"; }
    info "upload failed (try $try): $(tail -1 "$TMP/put.log")"
    sleep $((try * 20)); try=$((try + 1))
  done
}

s3_delete() { sigv4 headers DELETE "/$BUCKET/$1" "" "$EMPTY_SHA" | curl -fsS -m 60 -K - >/dev/null; }

signed_url() { sigv4 presign GET "/$BUCKET/$1" "" $((LINK_DAYS * 86400)); }

# --- the zips ----------------------------------------------------------------

# epoch of the date in a key: <name>--YYYY-MM-DD--HH-MM.zip, in the server's time
key_time() { local s=${1%.zip}; s=${s: -17}; date -d "${s:0:10} ${s:12:2}:${s:15:2}" +%s; }

# EXPIRED: what the retention deletes, the zips past ZIP_KEEP_DAYS beyond the newest ZIP_KEEP_MIN
find_expired() {
  local i cutoff=$(($(date +%s) - KEEP_DAYS * 86400))
  EXPIRED=()
  for ((i = KEEP_MIN; i < ${#KEYS[@]}; i++)); do
    if (($(key_time "${KEYS[$i]}") < cutoff)); then EXPIRED+=("${KEYS[$i]}"); fi
  done
}

total_bytes() { local t=0 s; for s in ${SIZES[@]+"${SIZES[@]}"}; do t=$((t + s)); done; echo "$t"; }

links_until() { date -d "@$(($(date +%s) + LINK_DAYS * 86400))" '+%Y-%m-%d %H:%M %Z'; }

# The list with a signed link under each zip
print_list() {
  local i
  if ((${#KEYS[@]} == 0)); then echo "No zip under $NAME/ in the bucket."; return; fi
  for i in "${!KEYS[@]}"; do
    printf -- '- %s (%s)\n  %s\n' "${KEYS[$i]#"$NAME"/}" "$(human "${SIZES[$i]}")" "$(signed_url "${KEYS[$i]}")"
  done
}

# --- email -------------------------------------------------------------------

# send_email <recipients> <subject>, the body on stdin: one message per recipient
send_email() {
  local body to
  body=$(cat)
  # shellcheck disable=SC2086  # a space-separated list
  for to in $1; do
    mail -s "$2" ${MAIL_FROM:+-r "$MAIL_FROM"} "$to" <<<"$body"
  done
}

# report <SUCCESS|FAILED>: the email of a run
report() {
  local title="Website Backup Report for ${NAME^^}"
  printf '%s\n%s\n\n' "$title" "${title//?/=}"
  printf 'Status: %s\nDate: %s\nDuration: %s\n\n' "$1" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$(duration $((SECONDS - T0)))"
  if [ "$1" = SUCCESS ]; then
    printf 'Latest backup: %s\nSize: %s\nDatabase dump of: %s\n\n' "$FILE" "$(human "$ZIP_BYTES")" "$DUMP_DATE"
  else
    printf 'The zip was not created or not uploaded.\nFailed at: %s\nHost: %s\n\n' "${FAILED_AT:-unknown}" "$(hostname)"
    # without a list, the failure came before the bucket answered
    if ((${#KEYS[@]} == 0)); then return; fi
  fi
  inventory
}

inventory() {
  printf 'Available downloads (%s, %s; the links work until %s):\n\n' "$(zips "${#KEYS[@]}")" "$(human "$(total_bytes)")" "$(links_until)"
  print_list
}

# --- checks ------------------------------------------------------------------

check() {
  local c
  for c in zip curl php sha256sum numfmt awk flock; do
    command -v "$c" >/dev/null || die "missing command: $c"
  done
  if [ -n "${WP_PATH:-}" ] && [ -n "${CRAFT_PATH:-}" ]; then die "WP_PATH and CRAFT_PATH are both set in $RESTIC_ENV: a site is one or the other"; fi
  if [ -n "${WP_PATH:-}" ]; then SITE=$WP_PATH; KIND=WordPress
  elif [ -n "${CRAFT_PATH:-}" ]; then SITE=$CRAFT_PATH; KIND=Craft
  elif [ -n "${MOODLE_PATH:-}" ]; then die "zip-site.sh serves WordPress and Craft: a Moodle site with moodledata is too large for one zip"
  else die "set WP_PATH or CRAFT_PATH in $RESTIC_ENV: the site folder"; fi
  [ -d "$SITE" ] || die "the site folder does not exist: $SITE"
  SITE=$(realpath "$SITE")
  [ -n "$NAME" ] || NAME=$(basename "$SITE")
  [[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "ZIP_NAME takes letters, digits, dot, dash and underscore (it has: $NAME)"
  # the same default as the backup scripts
  [ -n "$DUMP" ] || DUMP="$HOME/backups/$(basename "$SITE").sql"

  [ -n "$ENDPOINT" ] || die "set ZIP_ENDPOINT in $RESTIC_ENV: the storage endpoint, like https://s3.example.com"
  [[ "$ENDPOINT" =~ ^https?://[A-Za-z0-9.:-]+/?$ ]] || die "ZIP_ENDPOINT is scheme and host only, like https://s3.example.com (it has: $ENDPOINT)"
  ENDPOINT=${ENDPOINT%/}
  [ -n "$BUCKET" ] || die "set ZIP_BUCKET in $RESTIC_ENV: the bucket that holds the zips"
  [ -n "$KEY_ID" ] && [ -n "$SECRET" ] || die "no storage keys: set ZIP_ACCESS_KEY_ID and ZIP_SECRET_ACCESS_KEY, or AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, in $RESTIC_ENV"
  [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || die "ZIP_KEEP_DAYS is a number of days (it has: $KEEP_DAYS)"
  [[ "$KEEP_MIN" =~ ^[0-9]+$ ]] || die "ZIP_KEEP_MIN is a number of zips (it has: $KEEP_MIN)"
  [[ "$LINK_DAYS" =~ ^[1-7]$ ]] || die "ZIP_LINK_DAYS goes from 1 to 7, the longest a signed link lasts (it has: $LINK_DAYS)"
  if [ -n "$MAIL_TO$ALERT_TO" ]; then command -v mail >/dev/null || die "EMAIL_TO or EMAIL_ALERT_TO is set and there is no mail command"; fi
  LOCK="$HOME/.zip-site.$NAME.lock"
}

# --- plan --------------------------------------------------------------------

plan() {
  local p
  printf 'Zip of the site · %s · %s\n\n' "$MODE" "$(date -u '+%Y-%m-%d %H:%M UTC')"
  SITE_BYTES=$(du -sb "$SITE" | cut -f1)
  printf 'Site       %s (%s), %s\n' "$SITE" "$KIND" "$(human "$SITE_BYTES")"
  if [ -f "$DUMP" ]; then
    printf 'Dump       %s, %s, of %s\n' "$DUMP" "$(human "$(stat -c %s "$DUMP")")" "$(date -r "$DUMP" '+%Y-%m-%d %H:%M')"
  else
    printf 'Dump       %s: missing, the backup script writes it\n' "$DUMP"
  fi
  printf 'Left out   %s\n' "${EXCLUDE:-nothing (ZIP_EXCLUDE is empty)}"
  printf 'Zip        %s--<date>--<hour>.zip, built in %s (free: %s)\n' "$NAME" "$TMP_BASE" "$(human "$(free_bytes "$(dirname "$TMP_BASE")")")"
  printf 'Bucket     %s/%s, under %s/: %s, %s\n' "$ENDPOINT" "$BUCKET" "$NAME" "$(zips "${#KEYS[@]}")" "$(human "$(total_bytes)")"
  printf 'Retention  %s days and at least %s: %d to delete now\n' "$KEEP_DAYS" "$(zips "$KEEP_MIN")" "${#EXPIRED[@]}"
  for p in ${EXPIRED[@]+"${EXPIRED[@]}"}; do printf '           - %s\n' "${p#"$NAME"/}"; done
  printf 'Links      signed, good for %s days\n' "$LINK_DAYS"
  printf 'Email      report to %s\n' "${MAIL_TO:-nobody (EMAIL_TO is empty)}"
  printf '           a failure to %s\n\n' "${ALERT_TO:-nobody (EMAIL_ALERT_TO and EMAIL_TO are empty)}"
  echo 'The run:'
  echo "  1. zips the site folder and the dump in $TMP_BASE, without what ZIP_EXCLUDE names"
  echo "  2. uploads the zip to $NAME/ in the bucket and checks its size there"
  echo "  3. deletes the zips past the retention"
  echo "  4. emails the report with a signed link to each zip, and deletes the local zip"
}

# --- steps -------------------------------------------------------------------

make_zip() {
  local base p args x=()
  [ -f "$DUMP" ] || die "no database dump at $DUMP: run the backup script first, it writes the dump"
  DUMP_DATE=$(date -r "$DUMP" '+%Y-%m-%d %H:%M')
  mkdir -p "$TMP_BASE"
  TMP=$(mktemp -d "$TMP_BASE/zip-site.XXXXXX")
  # a folder that does not compress takes its own size
  (($(free_bytes "$TMP") > SITE_BYTES)) || die "disk at $TMP_BASE: needs about $(human "$SITE_BYTES"), has $(human "$(free_bytes "$TMP")")"
  FILE="$NAME--$(date +%Y-%m-%d--%H-%M).zip"
  ZIP="$TMP/$FILE"
  base=$(basename "$SITE")
  # ZIP_EXCLUDE patterns are relative to the site folder; zip matches them against <folder>/<path>
  set -f
  for p in $EXCLUDE; do x+=("$base/$p"); done
  set +f
  # -y keeps a symlink as a symlink: following it could walk out of the site
  args=(-r -q -y "$ZIP" "$base")
  if ((${#x[@]})); then args+=(-x "${x[@]}"); fi
  (cd "$(dirname "$SITE")" && zip "${args[@]}")
  # the dump sits beside the site folder in the zip, under its own file name
  (cd "$(dirname "$DUMP")" && zip -q "$ZIP" "$(basename "$DUMP")")
  ZIP_BYTES=$(stat -c %s "$ZIP")
  ((ZIP_BYTES <= MAX_BYTES)) || die "the zip has $(human "$ZIP_BYTES"), over the $(human "$MAX_BYTES") of one upload: leave more out with ZIP_EXCLUDE"
  info "$FILE, $(human "$ZIP_BYTES"), dump of $DUMP_DATE ($(duration $((SECONDS - T0))))"
}

upload() {
  local i t=$SECONDS
  s3_put "$ZIP" "$NAME/$FILE"
  s3_list
  for i in "${!KEYS[@]}"; do
    if [ "${KEYS[$i]}" = "$NAME/$FILE" ]; then
      [ "${SIZES[$i]}" = "$ZIP_BYTES" ] || die "$FILE has ${SIZES[$i]} bytes in the bucket and $ZIP_BYTES here"
      info "uploaded to $BUCKET/$NAME/ ($(duration $((SECONDS - t))))"
      return
    fi
  done
  die "$FILE is not in the bucket after the upload"
}

retention() {
  local k
  find_expired
  for k in ${EXPIRED[@]+"${EXPIRED[@]}"}; do
    s3_delete "$k" || die "the bucket did not delete $k"
    info "deleted ${k#"$NAME"/}"
  done
  if ((${#EXPIRED[@]})); then s3_list; fi
  info "$(zips "${#KEYS[@]}") in the bucket, $(human "$(total_bytes)")"
}

# --- main --------------------------------------------------------------------

cleanup() {
  local s=$?
  trap - ERR
  if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then rm -rf -- "$TMP"; fi
  if ((s != 0)) && [ "$MODE" = run ] && [ -n "$ALERT_TO" ]; then
    # the list is best effort: the failure may be the storage itself
    report FAILED 2>/dev/null | send_email "$ALERT_TO" "$MAIL_PREFIX ${NAME^^} - Backup FAILED" || true
  fi
}

main() {
  case "${1:-}" in
    '') ;;
    --run) MODE=run ;;
    --list) MODE=list ;;
    --email) MODE=email ;;
    -h | --help) usage; return ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  KEYS=(); SIZES=(); EXPIRED=()
  trap 'FAILED_AT="line $LINENO: $BASH_COMMAND"' ERR
  trap cleanup EXIT

  check
  s3_list
  case "$MODE" in
    list)
      inventory
      return ;;
    email)
      [ -n "$MAIL_TO" ] || die "set EMAIL_TO in $RESTIC_ENV: who gets the list"
      { local title="Backup inventory for ${NAME^^}"; printf '%s\n%s\n\n' "$title" "${title//?/=}"; inventory; } |
        send_email "$MAIL_TO" "$MAIL_PREFIX ${NAME^^} - Backup Inventory Report"
      echo "List sent to $MAIL_TO."
      return ;;
  esac
  find_expired
  plan
  if [ "$MODE" = plan ]; then
    printf '\nNothing changed. To zip and upload: --run.\n'
    return
  fi

  exec 9>"$LOCK"
  flock -n 9 || die "another zip-site.sh is running ($LOCK)"
  echo
  make_zip
  upload
  retention
  if [ -n "$MAIL_TO" ]; then
    report SUCCESS | send_email "$MAIL_TO" "$MAIL_PREFIX ${NAME^^} - Backup SUCCESS"
    info "report sent to $MAIL_TO"
  fi
  printf '\nZip uploaded in %s.\n' "$(duration $((SECONDS - T0)))"
}

# stdin from /dev/null: through 'bash -s', the rest of the script comes on stdin, and a command reading it would eat it
main "$@" </dev/null

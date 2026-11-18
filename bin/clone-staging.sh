#!/bin/bash
# clone-staging — makes staging match production: database, plugins, uploads and languages, with no email going out.
# The source is live production or a restic snapshot; the target must define WP_ENVIRONMENT_TYPE = staging.
# Usage: clone-staging.sh [--dry-run | --run] [--snapshot latest|<ID>]
#   Without --dry-run or --run, prints the plan and exits without changing anything.
# Without installing: ssh <user>@<server> 'bash -s -- --dry-run' < bin/clone-staging.sh
# Docs: docs/clone-staging.md
set -euo pipefail

# cron starts a job with /usr/bin:/bin alone: restic and wp live in ~/bin or in /usr/local/bin
export PATH="$HOME/bin:/usr/local/bin:$PATH"

# The site comes from ~/.restic-env, as in the backup. restic is needed only with --snapshot.
RESTIC_ENV="${RESTIC_ENV:-$HOME/.restic-env}"
# shellcheck source=/dev/null
if [ -f "$RESTIC_ENV" ]; then source "$RESTIC_ENV"; fi

SOURCE="${WP_PATH:-}"
TARGET="${STAGING_PATH:-}"
TARGET_URL="${STAGING_URL:-}"
SNAPSHOT_DUMP="${DB_DUMP:-}"  # where backup-wp.sh writes the dump: the same path inside the snapshot
TMP_BASE="${CLONE_TMP:-$HOME/tmp}"
DEACTIVATE="${CLONE_DEACTIVATE:-}"
# Tables left out of search-replace (a --skip-tables pattern): an audit log, for example, only costs time.
SKIP_TABLES="${CLONE_SKIP_TABLES:-}"
# Folders in wp-content/ the target rebuilds: a page builder's cache, for example.
read -ra CLEAN <<<"${CLONE_CLEAN:-}"
# Command run in the target folder at the end of the clone: a check of the site's own.
AFTER="${CLONE_AFTER:-}"

# themes/ and mu-plugins/ arrive with the code deploy; the rest of wp-content/ is cache or temporary and is rebuilt.
FOLDERS=(plugins languages uploads)
# From the web root, by default only the PHP-FPM limits. robots.txt stays out: production's would open staging to search engines.
read -ra ROOT_FILES <<<"${CLONE_ROOT_FILES-.user.ini}"
MU_EMAIL=no-email.php

usage() {
  cat <<'EOF'
usage: clone-staging.sh [--dry-run | --run] [--snapshot latest|<ID>]
  (no argument)      prints the plan: source, target, sizes and what leaves staging
  --dry-run          reads the source and runs rsync with --dry-run, writing nothing to staging
  --run              clones
  --snapshot <ID>    source in a restic snapshot (latest or an ID) instead of live production
Required, in the environment or in ~/.restic-env (RESTIC_ENV): WP_PATH, STAGING_PATH, STAGING_URL
Optional: DB_DUMP, CLONE_TMP, CLONE_DEACTIVATE, CLONE_SKIP_TABLES, CLONE_CLEAN, CLONE_ROOT_FILES, CLONE_AFTER
EOF
}

# --- output ------------------------------------------------------------------

STEP=0
STEP_NAME=
STEP_T=0
WARNINGS=()

step() {
  STEP=$((STEP + 1)); STEP_NAME="$1"; STEP_T=$SECONDS
  printf '\n%s  %d. %s%s\n' "$(date +%H:%M:%S)" "$STEP" "$1" "$([ "$MODE" = dry-run ] && echo ' (dry run)')"
}
info() { printf '   → %s\n' "$*"; }
ok() { printf '   ✓ %s (%s)\n' "$1" "$(duration $((SECONDS - STEP_T)))"; }
warn() { printf '   ! %s\n' "$*"; WARNINGS+=("$*"); }
die() { printf '\n✗ %s\n' "$*" >&2; exit 1; }
duration() { if (($1 < 60)); then echo "${1}s"; else printf '%dmin%02ds' $(($1 / 60)) $(($1 % 60)); fi; }
human() { numfmt --to=iec-i --suffix=B "${1:-0}"; }
size() { if [ -e "$1" ]; then du -sb "$1" | cut -f1; else echo 0; fi; }
free_bytes() { df -B1 --output=avail "$1" | tail -1; }
host_of() { local u=${1#*://}; u=${u%%/*}; echo "${u,,}"; }

# --- WP-CLI ------------------------------------------------------------------

# No plugins or theme: no third-party code runs, and the theme does not break on a plugin missing in the target.
swp() { wp --path="$SOURCE" --skip-plugins --skip-themes "$@"; }
twp() { wp --path="$TARGET" --skip-plugins --skip-themes "$@"; }

# "<tables>\t<bytes>" of one side's database (swp or twp)
db_info() {
  "$1" db query "SELECT COUNT(*), COALESCE(SUM(data_length + index_length), 0)
    FROM information_schema.tables WHERE table_schema = DATABASE()" --skip-column-names
}

# --- checks ------------------------------------------------------------------

check() {
  local s t tmp c
  for c in wp rsync flock numfmt jq php curl; do
    command -v "$c" >/dev/null || die "missing command: $c"
  done
  [ -n "$SOURCE" ] || die "set WP_PATH in $RESTIC_ENV: the production WordPress folder"
  [ -n "$TARGET" ] || die "set STAGING_PATH in $RESTIC_ENV: the staging WordPress folder"
  [ -n "$TARGET_URL" ] || die "set STAGING_URL in $RESTIC_ENV: the staging URL, like https://staging.example.org"
  [ -f "$SOURCE/wp-config.php" ] || die "no production WordPress in $SOURCE (WP_PATH)"
  [ -f "$TARGET/wp-config.php" ] || die "no staging WordPress in $TARGET (STAGING_PATH)"
  # the same default as backup-wp.sh, and one lock per target: two sites on one server do not run over each other
  [ -n "$SNAPSHOT_DUMP" ] || SNAPSHOT_DUMP="$HOME/backups/$(basename "$SOURCE").sql"
  LOCK="$HOME/.clone-staging.$(basename "$TARGET").lock"
  s=$(realpath "$SOURCE"); t=$(realpath "$TARGET"); tmp=$(realpath -m "$TMP_BASE")
  case "$t/" in "$s/"*) die "the target ($t) is production or lies inside it" ;; esac
  case "$s/" in "$t/"*) die "production ($s) lies inside the target" ;; esac
  case "$tmp/" in "$s/"* | "$t/"*) die "CLONE_TMP ($tmp) lies inside one of the sites" ;; esac
  SOURCE_REAL=$s; TARGET_REAL=$t

  ENVIRONMENT=$(twp config get WP_ENVIRONMENT_TYPE 2>/dev/null || true)
  [ "$ENVIRONMENT" = staging ] ||
    die "the target does not define WP_ENVIRONMENT_TYPE = staging (it has: ${ENVIRONMENT:-no constant}); the clone writes only to staging"
  # same server and same database name = production's database; the values are not printed
  [ "$(swp config get DB_HOST)/$(swp config get DB_NAME)" != "$(twp config get DB_HOST)/$(twp config get DB_NAME)" ] ||
    die "the target uses production's database"

  TARGET_URL=${TARGET_URL%/}
  [[ "$TARGET_URL" =~ ^https?://[a-z0-9.-]+$ ]] || die "STAGING_URL is scheme and domain only, like https://staging.example.org"
  TARGET_HOST=$(host_of "$TARGET_URL")
  SOURCE_URL_LIVE=$(swp option get home)
  [ "$(host_of "$SOURCE_URL_LIVE")" != "$TARGET_HOST" ] || die "STAGING_URL is production's URL ($SOURCE_URL_LIVE)"
}

# Never two restic at once: the repository lock conflicts.
restic_ready() {
  pgrep -x restic >/dev/null && die "a restic is running (pgrep -a restic): wait for it to finish"
  pgrep -f '/backup-[a-z]+\.sh' >/dev/null && die "a backup or milestone is running: wait for it to finish"
  [ -n "${RESTIC_REPOSITORY:-}" ] || die "no RESTIC_REPOSITORY: set up $RESTIC_ENV (see .restic-env.example)"
}

# A long restore near the daily backup would make its prune fail on the lock: stay out of the hour before and the cron hour.
outside_backup_window() {
  local h now
  h=$(crontab -l 2>/dev/null | awk '$1 !~ /^#/ && /backup-wp\.sh/ {print $2; exit}')
  [[ "$h" =~ ^[0-9]+$ ]] || return 0
  now=$((10#$(date +%H)))
  if ((now == h || now == (h + 23) % 24)); then
    die "the daily backup runs at $(printf %02d "$h"):00: restore outside $(printf %02d $(((h + 23) % 24))):00 to $(printf %02d $(((h + 1) % 24))):00"
  fi
}

snapshot_info() {
  local json c
  json=$(restic snapshots --no-lock --json "$SNAP") || die "restic did not find snapshot $SNAP"
  [ "$(jq length <<<"$json")" -ge 1 ] || die "restic did not find snapshot $SNAP"
  SNAP_ID=$(jq -r '.[-1].id' <<<"$json")
  SNAP_SHORT=$(jq -r '.[-1].short_id' <<<"$json")
  SNAP_DESC=$(jq -r '.[-1] | (.time[0:19] | sub("T"; " ")) + ", tags " + ((.tags // ["none"]) | join(","))' <<<"$json")
  SNAP_APP=
  for c in "$SOURCE" "$SOURCE_REAL"; do
    if jq -e --arg p "$c" '.[-1].paths | index($p)' >/dev/null <<<"$json"; then SNAP_APP=$c; break; fi
  done
  [ -n "$SNAP_APP" ] || die "snapshot $SNAP_SHORT does not have $SOURCE (it has: $(jq -r '.[-1].paths | join(", ")' <<<"$json"))"
  jq -e --arg p "$SNAPSHOT_DUMP" '.[-1].paths | index($p)' >/dev/null <<<"$json" ||
    die "snapshot $SNAP_SHORT does not have the dump $SNAPSHOT_DUMP (DB_DUMP)"
}

# --- plan --------------------------------------------------------------------

plan() {
  local n b f ss ts
  printf 'Clone to staging · %s · %s\n\n' "$MODE" "$(date -u '+%Y-%m-%d %H:%M UTC')"
  if [ -z "$SNAP" ]; then
    IFS=$'\t' read -r n b < <(db_info swp)
    printf 'Source   live production, %s\n' "$SOURCE_REAL"
    printf '         %s · database with %s tables, %s, prefix %s\n' "$SOURCE_URL_LIVE" "$n" "$(human "$b")" "$(swp config get table_prefix)"
  else
    printf 'Source   restic snapshot %s (%s)\n' "$SNAP_SHORT" "$SNAP_DESC"
    printf '         %s and the dump %s\n' "$SNAP_APP" "$SNAPSHOT_DUMP"
  fi
  IFS=$'\t' read -r TARGET_TABLES b < <(db_info twp)
  printf 'Target   %s · %s · %s\n' "$TARGET_REAL" "$TARGET_URL" "$ENVIRONMENT"
  printf '         database now with %s tables, %s, prefix %s\n\n' "$TARGET_TABLES" "$(human "$b")" "$(twp config get table_prefix)"

  printf '%-12s %12s %14s\n' Files "source${SNAP:+*}" "target now"
  SOURCE_BYTES=0; TARGET_BYTES=0
  for f in "${FOLDERS[@]}"; do
    ss=$(size "$SOURCE/wp-content/$f"); ts=$(size "$TARGET/wp-content/$f")
    SOURCE_BYTES=$((SOURCE_BYTES + ss)); TARGET_BYTES=$((TARGET_BYTES + ts))
    printf '  %-10s %12s %14s\n' "$f" "$(human "$ss")" "$(human "$ts")"
  done
  if [ -n "$SNAP" ]; then echo '  * live production sizes, as an estimate of the snapshot'; fi
  printf 'Free disk: %s\n\n' "$(human "$(free_bytes "$TARGET")")"

  echo 'The clone:'
  echo "  1. checks the target and locks against another clone"
  if [ -z "$SNAP" ]; then
    echo "  2. exports production's database (read only) to a temporary folder in $TMP_BASE"
  else
    echo "  2. restores the dump, wp-config.php and the folders from the snapshot to a temporary folder in $TMP_BASE"
  fi
  echo "  3. writes wp-content/mu-plugins/$MU_EMAIL to the target: outside production, wp_mail() sends nothing"
  echo "  4. mirrors ${FOLDERS[*]} with rsync --delete${ROOT_FILES[*]:+ and copies ${ROOT_FILES[*]}}"
  echo "  5. swaps the database: drops the $TARGET_TABLES tables, imports the dump, source prefix in wp-config.php,"
  echo "     ${DEACTIVATE:+deactivates $DEACTIVATE, }blog_public 0 and search-replace of the URL"
  echo "  6. clears cache, transients${CLEAN[*]:+, ${CLEAN[*]}} and rewrite; checks theme and email${AFTER:+; runs '$AFTER'}"
  echo
  echo "Leaves staging: every table in the database; in ${FOLDERS[*]}, whatever the source lacks."
  echo "Stays in staging: wp-config.php (only table_prefix changes), themes/, mu-plugins/ and the rest of the web root."
  echo "Not copied: the rest of wp-content/ (themes/, mu-plugins/, caches and temporary files), uploads/tmp, wp-config.php"
  echo "  and the web root files${ROOT_FILES[*]:+ other than ${ROOT_FILES[*]}}."
}

# --- steps -------------------------------------------------------------------

lock() {
  step "Checks"
  exec 9>"$LOCK"
  flock -n 9 || die "another clone is running ($LOCK)"
  mkdir -p "$TMP_BASE"
  TMP=$(mktemp -d "$TMP_BASE/clone-staging.XXXXXX")
  # rsync brings the folders' difference; from a snapshot, the folders go through the temporary folder first; 2 GiB for the dump and import
  local delta=$((SOURCE_BYTES - TARGET_BYTES)) temp=0 margin=$((2 * 1024 ** 3))
  ((delta > 0)) || delta=0
  if [ -n "$SNAP" ]; then temp=$SOURCE_BYTES; fi
  if [ "$(stat -c %d "$TMP")" = "$(stat -c %d "$TARGET")" ]; then
    disk "$TMP" $((delta + temp + margin))
  else
    disk "$TARGET" $((delta + margin))
    disk "$TMP" $((temp + margin))
  fi
  info "staging target, with database and path different from production"
  info "temporary folder $TMP"
  ok "ready to clone"
}

disk() {
  local f m; f=$(free_bytes "$1"); m=$(df --output=target "$1" | tail -1)
  ((f > $2)) || die "disk at $m: needs about $(human "$2"), has $(human "$f")"
  info "disk at $m: needs about $(human "$2"), has $(human "$f")"
}

prepare_source() {
  local inc=() f
  if [ -z "$SNAP" ]; then
    step "Production dump"
    FROM=$SOURCE_REAL
    DUMP="$TMP/source.sql"
    # --single-transaction: the tables are InnoDB, and the dump comes out consistent without locking the site
    swp db export "$DUMP" --single-transaction --quiet
    PREFIX=$(swp config get table_prefix)
  else
    step "Restore of snapshot $SNAP_SHORT"
    restic_ready
    outside_backup_window
    FROM="$TMP/restic$SNAP_APP"
    DUMP="$TMP/restic$SNAPSHOT_DUMP"
    inc=(--include "$SNAP_APP/wp-config.php" --include "$SNAPSHOT_DUMP")
    for f in "${ROOT_FILES[@]}"; do inc+=(--include "$SNAP_APP/$f"); done
    if [ "$MODE" = dry-run ]; then
      # in a dry run, only the dump and wp-config.php are restored; for the folders, restic tells what would come
      restic restore "$SNAP_ID" --target "$TMP/restic" "${inc[@]}" >"$TMP/restic.log"
      inc=()
      for f in "${FOLDERS[@]}"; do inc+=(--include "$SNAP_APP/wp-content/$f"); done
      restic restore "$SNAP_ID" --target "$TMP/restic" "${inc[@]}" --dry-run >"$TMP/restic-folders.log"
      info "folders, restic --dry-run: $(grep -i '^summary' "$TMP/restic-folders.log" || echo 'no summary')"
    else
      for f in "${FOLDERS[@]}"; do inc+=(--include "$SNAP_APP/wp-content/$f"); done
      restic restore "$SNAP_ID" --target "$TMP/restic" "${inc[@]}" >"$TMP/restic.log"
      info "restic: $(grep -i '^summary' "$TMP/restic.log" || echo 'no summary')"
    fi
    [ -f "$FROM/wp-config.php" ] || die "the snapshot did not bring $SNAP_APP/wp-config.php"
    PREFIX=$(wp config get table_prefix --config-file="$FROM/wp-config.php")
  fi
  [ -f "$DUMP" ] || die "no dump at $DUMP"
  [[ "$PREFIX" =~ ^[A-Za-z0-9_]+$ ]] || die "unexpected table prefix in the source: $PREFIX"

  # The URL comes from the dump (the 'home' row of the prefix's options table), the same for production and a snapshot.
  SOURCE_URL=$(grep -a "^INSERT INTO \`${PREFIX}options\`" "$DUMP" |
    grep -aoE "\([0-9]+,'home','[^']*'" | sed -n "1s/.*,'home','\(.*\)'/\1/p")
  [ -n "$SOURCE_URL" ] || die "no home option of ${PREFIX}options in the dump"
  SOURCE_URL=${SOURCE_URL%/}
  [ "$(host_of "$SOURCE_URL")" != "$TARGET_HOST" ] || die "the dump is already staging's ($SOURCE_URL)"
  build_pairs
  info "dump of $(human "$(stat -c %s "$DUMP")"), prefix $PREFIX, home $SOURCE_URL"
  ok "source ready"
}

# search-replace pairs. Replacing the bare domain would change the @domain emails; with the slashes in front, only URLs.
# \/\/ is the URL inside JSON (Yoast stores images this way), %2F%2F the URL encoded in a parameter.
# Each form goes in only if it appears in the tables search-replace walks: an empty pass costs the same time.
build_pairs() {
  local b=${SOURCE_URL#*://} pre from n sample="$TMP/count.sql"
  b=${b%%/*}; b=${b#www.}
  if [ -n "$SKIP_TABLES" ]; then
    { grep -a "^INSERT INTO \`${PREFIX}" "$DUMP" | grep -av "^INSERT INTO \`[^\`]*${SKIP_TABLES//\*/}" || true; } >"$sample"
  else
    { grep -a "^INSERT INTO \`${PREFIX}" "$DUMP" || true; } >"$sample"
  fi
  PAIRS_FROM=(); PAIRS_TO=(); PAIRS_N=()
  for pre in '//' '\/\/' '%2F%2F'; do
    for from in "${pre}www.$b" "$pre$b"; do
      # in the mysqldump output, each \ in the database shows as \\
      n=$({ grep -aoF -- "${from//\\/\\\\}" "$sample" || true; } | wc -l)
      ((n > 0)) || continue
      PAIRS_FROM+=("$from"); PAIRS_TO+=("$pre$TARGET_HOST"); PAIRS_N+=("$n")
    done
  done
  rm -f "$sample"
}

write_no_email() {
  step "Email blocked in the target"
  local dir="$TARGET_REAL/wp-content/mu-plugins" t
  if [ "$MODE" = dry-run ]; then
    info "would write $dir/$MU_EMAIL"
    ok "nothing written"
    return
  fi
  mkdir -p "$dir"
  # no .php name while writing: WordPress never loads a half-written file
  t=$(mktemp "$dir/.$MU_EMAIL.XXXXXX")
  cat >"$t" <<'PHP'
<?php
/**
 * Plugin Name: No email outside production
 * Description: Outside production, wp_mail() logs to the PHP error log and sends nothing. Written by tekne-bkp's clone-staging.sh on every clone.
 */

// A mu-plugin loads before plugins and pluggable.php: defined here, this wp_mail() wins over an email plugin's
// and over core's, which would fall back to PHP's mail().
if (function_exists('wp_get_environment_type') && wp_get_environment_type() !== 'production') {
    if (!function_exists('wp_mail')) {
        function wp_mail($to, $subject, $message, $headers = '', $attachments = array())
        {
            error_log(sprintf('no-email (%s): not sent "%s" to %s', wp_get_environment_type(), $subject, implode(', ', (array) $to)));
            return true;
        }
    } else {
        // another mu-plugin already defined wp_mail(): core's filter stops its sending, if it honors the filter
        add_filter('pre_wp_mail', '__return_true');
    }
}
PHP
  # -n: without the server's .ini files; with ioncube loaded, php -l can crash with a segmentation fault
  php -n -l "$t" >/dev/null || { rm -f "$t"; die "the email mu-plugin failed php -l"; }
  chmod 644 "$t"
  mv -f "$t" "$dir/$MU_EMAIL"
  ok "$dir/$MU_EMAIL"
}

# rsync of a folder or file, with the summary on one line
mirror() {
  local from=$1 to=$2 label=$3 n b d
  shift 3
  local args=(-a --delete --stats "$@")
  [ "$MODE" = dry-run ] && args+=(--dry-run)
  if [ ! -e "$from" ]; then warn "$label does not exist in the source"; return; fi
  rsync "${args[@]}" "$from" "$to" >"$TMP/rsync-$label.log"
  read -r n b d < <(awk -F': ' '
    /^Number of regular files transferred/ {gsub(/[^0-9]/, "", $2); n = $2}
    /^Total transferred file size/ {gsub(/[^0-9]/, "", $2); b = $2}
    /^Number of deleted files/ {gsub(/[^0-9]/, "", $2); d = $2}
    END {print n + 0, b + 0, d + 0}' "$TMP/rsync-$label.log")
  info "$(printf '%-10s' "$label") new or changed: $n ($(human "$b")) · deleted: $d"
}

copy_files() {
  step "Files"
  local f
  if [ "$MODE" = dry-run ] && [ -n "$SNAP" ]; then
    info "the snapshot folders were not restored in the dry run: restic's summary in step 2 shows what would come"
    ok "nothing written"
    return
  fi
  for f in "${FOLDERS[@]}"; do
    [ "$MODE" = dry-run ] || mkdir -p "$TARGET_REAL/wp-content/$f"
    if [ "$f" = uploads ]; then
      # uploads/tmp holds temporary uploads: it stays out of the backup and the clone
      mirror "$FROM/wp-content/$f/" "$TARGET_REAL/wp-content/$f/" "$f" --exclude=/tmp/
    else
      mirror "$FROM/wp-content/$f/" "$TARGET_REAL/wp-content/$f/" "$f"
    fi
  done
  for f in "${ROOT_FILES[@]}"; do
    mirror "$FROM/$f" "$TARGET_REAL/$f" "$f"
  done
  if [ "$MODE" = dry-run ]; then ok "nothing written"; else ok "files in the target"; fi
}

swap_database() {
  step "Database"
  local i p tables current rev_core rev_db n
  if [ "$MODE" = dry-run ]; then
    info "would drop the target's $TARGET_TABLES tables and import the dump"
    current=$(twp config get table_prefix)
    if [ "$current" != "$PREFIX" ]; then info "would change the target's table_prefix: $current → $PREFIX"; fi
    info "would ${DEACTIVATE:+deactivate $DEACTIVATE; }set blog_public 0; delete the transients"
    for i in "${!PAIRS_FROM[@]}"; do
      info "search-replace ${PAIRS_FROM[$i]} → ${PAIRS_TO[$i]} (${PAIRS_N[$i]} occurrences in the dump)"
    done
    ok "nothing written"
    return
  fi

  tables=$(twp db query "SELECT table_name FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'" --skip-column-names)
  if [ -n "$tables" ]; then
    # shellcheck disable=SC2016  # the backticks quote the names in SQL
    twp db query "SET FOREIGN_KEY_CHECKS = 0; DROP TABLE $(awk '{printf "%s`%s`", (NR > 1 ? "," : ""), $0}' <<<"$tables");"
    info "$(grep -c . <<<"$tables") tables dropped"
  fi
  twp db import "$DUMP" --quiet
  info "dump imported ($(duration $((SECONDS - STEP_T))))"

  # The target's wp-config.php takes the source prefix: renaming the tables would also mean renaming
  # the <prefix>user_roles and <prefix>capabilities keys and the plugins' ones.
  current=$(twp config get table_prefix)
  if [ "$current" != "$PREFIX" ]; then
    twp config set table_prefix "$PREFIX" --type=variable --quiet
    info "target table_prefix: $current → $PREFIX"
  fi
  [ "$(twp config get WP_ENVIRONMENT_TYPE)" = staging ] || die "the target's wp-config.php lost staging"

  # --skip-plugins: the plugin leaves the active list without running its own deactivation code,
  # which in W3 Total Cache would edit wp-config.php
  for p in $DEACTIVATE; do
    if twp plugin is-active "$p" 2>/dev/null; then
      twp plugin deactivate "$p" --quiet
      info "deactivated: $p"
    fi
  done
  twp option update blog_public 0 --quiet
  # transients before search-replace: Yoast's sitemap cache stores objects that, without the plugin loaded,
  # search-replace skips with a warning
  twp transient delete --all --quiet

  rev_core=$(twp core version --extra | awk -F': *' '/Database revision/ {print $2}')
  rev_db=$(twp option get db_version)
  if ((rev_db < rev_core)); then
    twp core update-db --quiet
    info "database upgraded to staging's core ($rev_db → $rev_core)"
  elif ((rev_db > rev_core)); then
    warn "the database is from a newer WordPress ($rev_db) than staging's core ($rev_core): run wp core update in staging"
  fi

  for i in "${!PAIRS_FROM[@]}"; do
    n=$(twp search-replace "${PAIRS_FROM[$i]}" "${PAIRS_TO[$i]}" --all-tables-with-prefix ${SKIP_TABLES:+--skip-tables="$SKIP_TABLES"} --format=count)
    info "search-replace ${PAIRS_FROM[$i]} → ${PAIRS_TO[$i]}: $n replacements"
  done
  current=$(twp option get home)
  if [ "${current%/}" != "$TARGET_URL" ]; then
    twp option update home "$TARGET_URL" --quiet
    info "home: $current → $TARGET_URL"
  fi
  ok "source database in the target"
}

finish() {
  step "Finish"
  local t f c file code
  if [ "$MODE" = dry-run ]; then
    info "would clear cache, transients${CLEAN[*]:+, ${CLEAN[*]}} and rewrite; would check theme and email${AFTER:+; would run '$AFTER'}"
    ok "nothing written"
    return
  fi
  twp cache flush --quiet
  twp transient delete --all --quiet
  for c in "${CLEAN[@]}"; do
    case "$c" in */* | .* | '') die "CLONE_CLEAN takes folder names inside wp-content/, not '$c'" ;; esac
    rm -rf -- "$TARGET_REAL/wp-content/$c"
  done
  # rewrite rules come from the theme and plugins (languages, post types): here WordPress loads in full
  wp --path="$TARGET" rewrite flush --quiet || warn "wp rewrite flush failed in the target"

  for t in $( (twp option get template; twp option get stylesheet) | sort -u); do
    if [ ! -d "$TARGET_REAL/wp-content/themes/$t" ]; then
      warn "the active theme $t does not exist in the target: deploy the theme to staging"
    fi
  done
  for f in "$SOURCE_REAL"/wp-content/mu-plugins/*.php; do
    if [ -e "$f" ] && [ ! -e "$TARGET_REAL/wp-content/mu-plugins/${f##*/}" ]; then
      warn "production's mu-plugin ${f##*/} is missing in the target"
    fi
  done
  file=$(wp --path="$TARGET" --skip-themes eval 'echo (new ReflectionFunction("wp_mail"))->getFileName();' 2>/dev/null || true)
  if [ "${file##*/}" = "$MU_EMAIL" ]; then
    info "wp_mail() comes from $MU_EMAIL: nothing goes out"
  else
    warn "wp_mail() comes from ${file:-?}, not from $MU_EMAIL"
  fi
  info "blog_public $(twp option get blog_public) · home $(twp option get home) · siteurl $(twp option get siteurl) · $(twp config get WP_ENVIRONMENT_TYPE)"
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 60 "$TARGET_URL/" || true)
  info "$TARGET_URL/ answers $code"
  if [ -n "$AFTER" ]; then
    # in the target folder, so a `wp <command>` finds the site
    (cd "$TARGET_REAL" && bash -c "$AFTER") 2>&1 | sed 's/^/     /' || warn "CLONE_AFTER failed in the target: $AFTER"
  fi
  ok "staging ready"
}

# --- main --------------------------------------------------------------------

cleanup() {
  local s=$?
  if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then rm -rf -- "$TMP"; fi
  if ((s != 0)) && [ "$MODE" = run ] && ((STEP >= 3)); then
    printf '✗ stopped at step %d (%s); staging may be half done: run again.\n' "$STEP" "$STEP_NAME" >&2
  fi
}

main() {
  MODE=plan; SNAP=
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) MODE=dry-run ;;
      --run) MODE=run ;;
      --snapshot) [ $# -ge 2 ] || die "--snapshot takes latest or a restic ID"; SNAP=$2; shift ;;
      --snapshot=*) SNAP="${1#*=}" ;;
      -h | --help) usage; return ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
  [ -z "$SNAP" ] || [[ "$SNAP" =~ ^(latest|[0-9a-f]{8,64})$ ]] || die "--snapshot takes latest or a restic ID"
  trap cleanup EXIT

  check
  if [ -n "$SNAP" ]; then restic_ready; snapshot_info; fi
  plan
  if [ "$MODE" = plan ]; then
    printf '\nNothing changed. To rehearse: --dry-run; to clone: --run.\n'
    return
  fi

  lock
  prepare_source
  write_no_email
  copy_files
  swap_database
  finish

  if [ "$MODE" = dry-run ]; then
    printf '\nDry run done in %s, nothing written to staging.\n' "$(duration "$SECONDS")"
  else
    printf '\nStaging cloned in %s.\n' "$(duration "$SECONDS")"
  fi
  if ((${#WARNINGS[@]})); then
    echo 'Warnings:'
    printf '  ! %s\n' "${WARNINGS[@]}"
  fi
}

# stdin from /dev/null: through 'bash -s', the rest of the script comes on stdin, and a command reading it would eat it
main "$@" </dev/null

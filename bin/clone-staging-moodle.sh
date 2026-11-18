#!/bin/bash
# clone-staging-moodle — makes a staging Moodle match production: code, moodledata and database, with no email going out.
# The source is live production or a restic snapshot; the target keeps its own config.php, which must set noemailever.
# Usage: clone-staging-moodle.sh [--dry-run | --run] [--snapshot latest|<ID>]
#   Without --dry-run or --run, prints the plan and exits without changing anything.
# Without installing: ssh <user>@<server> 'bash -s -- --dry-run' < bin/clone-staging-moodle.sh
# Docs: docs/clone-staging-moodle.md
set -euo pipefail

# cron starts a job with /usr/bin:/bin alone: restic and wp live in ~/bin or in /usr/local/bin
export PATH="$HOME/bin:/usr/local/bin:$PATH"

# The site comes from ~/.restic-env, as in the backup. restic is needed only with --snapshot.
RESTIC_ENV="${RESTIC_ENV:-$HOME/.restic-env}"
# shellcheck source=/dev/null
if [ -f "$RESTIC_ENV" ]; then source "$RESTIC_ENV"; fi

SOURCE="${MOODLE_PATH:-}"
TARGET="${STAGING_PATH:-}"
SNAPSHOT_DUMP="${DB_DUMP:-}"  # where backup-moodle.sh writes the dump: the same path inside the snapshot
TMP_BASE="${CLONE_TMP:-$HOME/tmp}"
# The system user that owns the sites' files, like www-data: the clone reads and writes the target as that user, through sudo.
WEB_USER="${CLONE_USER:-}"
# Command run in the target folder at the end of the clone: the site's own setup or check.
AFTER="${CLONE_AFTER:-}"

# What Moodle rebuilds in moodledata: it stays out of the backup and of the clone.
DATA_SKIP=(cache localcache sessions temp trashdir lock)

usage() {
  cat <<'EOF'
usage: clone-staging-moodle.sh [--dry-run | --run] [--snapshot latest|<ID>]
  (no argument)      prints the plan: source, target, sizes and what leaves staging
  --dry-run          reads the source and runs rsync with --dry-run, writing nothing to staging
  --run              clones
  --snapshot <ID>    source in a restic snapshot (latest or an ID) instead of live production
Required, in the environment or in ~/.restic-env (RESTIC_ENV): MOODLE_PATH, STAGING_PATH
Optional: DB_DUMP, CLONE_TMP, CLONE_USER, CLONE_AFTER
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
free_bytes() { df -B1 --output=avail "$1" | tail -1; }
host_of() { local u=${1#*://}; u=${u%%/*}; echo "${u,,}"; }

# --- the sites ---------------------------------------------------------------

# As the files' owner: the web server's user owns both sites, and Moodle's own scripts refuse to leave root's files behind.
web() {
  if [ -n "$WEB_USER" ] && [ "$WEB_USER" != "$(id -un)" ]; then sudo -n -u "$WEB_USER" -- "$@"; else "$@"; fi
}
size() { if web test -e "$1"; then web du -sb "$1" | cut -f1; else echo 0; fi; }

# config.php is the one home of a site's database, dataroot and URL. Its last line loads Moodle (lib/setup.php);
# without that line the file only sets $CFG, so it is read with no Moodle bootstrap, and a lone config.php from a snapshot reads too.
CONFIG_PHP='
  $code = file_get_contents($argv[1]);
  if ($code === false) exit(1);
  eval(preg_replace(["/^\s*<\?php/", "/\?>\s*$/", "/^.*\bsetup\.php\b.*$/m"], "", $code));
'
# config <config.php> <php that echoes from $CFG>
config() { web php -r "$CONFIG_PHP$2" "$1"; }

# The [client] section for mysql and mysqldump: the credentials go in a 600 file, never on the command line.
CNF_PHP='
  $o = (array) ($CFG->dboptions ?? []);
  $q = fn($v) => "\"" . addcslashes((string) $v, "\\\"") . "\"";
  echo "[client]\nuser=", $q($CFG->dbuser), "\npassword=", $q($CFG->dbpass), "\n";
  if (!empty($o["dbsocket"]) && is_string($o["dbsocket"])) echo "socket=", $q($o["dbsocket"]), "\n";
  else { echo "host=", $q($CFG->dbhost), "\n"; if (!empty($o["dbport"])) echo "port=", (int) $o["dbport"], "\n"; }
'
write_cnf() { (umask 077; config "$1" "$CNF_PHP" >"$2"); }
sdb() { mysql --defaults-extra-file="$TMP/source.cnf" --batch --skip-column-names "$SOURCE_DB" "$@"; }
tdb() { mysql --defaults-extra-file="$TMP/target.cnf" --batch --skip-column-names "$TARGET_DB" "$@"; }

# "<tables>\t<bytes>" of one side's database (sdb or tdb)
db_info() {
  "$1" -e "SELECT COUNT(*), COALESCE(SUM(data_length + index_length), 0)
    FROM information_schema.tables WHERE table_schema = DATABASE()"
}

# The dump and the import speak MySQL: mysqldump on one side, mysql on the other.
mysql_type() { case "$1" in mariadb | mysqli | auroramysql) return 0 ;; *) return 1 ;; esac; }

# --- checks ------------------------------------------------------------------

check() {
  local c s t tmp
  for c in mysql mysqldump rsync flock numfmt jq php curl; do
    command -v "$c" >/dev/null || die "missing command: $c"
  done
  [ -n "$SOURCE" ] || die "set MOODLE_PATH in $RESTIC_ENV: the production Moodle folder"
  [ -n "$TARGET" ] || die "set STAGING_PATH in $RESTIC_ENV: the staging Moodle folder"
  if [ -n "$WEB_USER" ] && [ "$WEB_USER" != "$(id -un)" ]; then
    sudo -n -u "$WEB_USER" true 2>/dev/null || die "CLONE_USER is $WEB_USER, and sudo -n -u $WEB_USER does not work for $(id -un)"
  fi
  web test -f "$SOURCE/config.php" || die "no production Moodle in $SOURCE (MOODLE_PATH)"
  web test -f "$TARGET/config.php" ||
    die "no staging Moodle in $TARGET (STAGING_PATH): staging has a config.php of its own, written once (docs/clone-staging-moodle.md)"
  # the same default as backup-moodle.sh, and one lock per target: two sites on one server do not run over each other
  [ -n "$SNAPSHOT_DUMP" ] || SNAPSHOT_DUMP="$HOME/backups/$(basename "$SOURCE").sql"
  LOCK="$HOME/.clone-staging.$(basename "$TARGET").lock"

  SOURCE_DATA=$(config "$SOURCE/config.php" 'echo $CFG->dataroot;')
  TARGET_DATA=$(config "$TARGET/config.php" 'echo $CFG->dataroot;')
  web test -d "$SOURCE_DATA" || die "production's dataroot is not a folder: $SOURCE_DATA"
  web test -d "$TARGET_DATA" || die "staging's dataroot is not a folder: $TARGET_DATA (create it, owned by the web server's user)"
  SOURCE_REAL=$(realpath "$SOURCE"); TARGET_REAL=$(realpath "$TARGET")
  SOURCE_DATA=$(realpath "$SOURCE_DATA"); TARGET_DATA=$(realpath "$TARGET_DATA")
  tmp=$(realpath -m "$TMP_BASE")
  for s in "$SOURCE_REAL" "$SOURCE_DATA"; do
    for t in "$TARGET_REAL" "$TARGET_DATA"; do
      case "$t/" in "$s/"*) die "the target ($t) is production's $s or lies inside it" ;; esac
      case "$s/" in "$t/"*) die "production's $s lies inside the target ($t)" ;; esac
    done
  done
  for s in "$SOURCE_REAL" "$SOURCE_DATA" "$TARGET_REAL" "$TARGET_DATA"; do
    case "$tmp/" in "$s/"*) die "CLONE_TMP ($tmp) lies inside one of the sites" ;; esac
  done

  # The target's config.php is what makes it staging: noemailever stops every email, whatever the database says.
  [ "$(config "$TARGET/config.php" 'echo empty($CFG->noemailever) ? "" : "yes";')" = yes ] ||
    die "the target's config.php does not set \$CFG->noemailever = true; the clone writes only to a Moodle that sends no email"
  mysql_type "$(config "$SOURCE/config.php" 'echo $CFG->dbtype;')" || die "production's database is not MySQL or MariaDB"
  mysql_type "$(config "$TARGET/config.php" 'echo $CFG->dbtype;')" || die "staging's database is not MySQL or MariaDB"
  SOURCE_DB=$(config "$SOURCE/config.php" 'echo $CFG->dbname;')
  TARGET_DB=$(config "$TARGET/config.php" 'echo $CFG->dbname;')
  # same server and same database name = production's database; the values are not printed
  [ "$(config "$SOURCE/config.php" 'echo $CFG->dbhost, "/", $CFG->dbname;')" != "$(config "$TARGET/config.php" 'echo $CFG->dbhost, "/", $CFG->dbname;')" ] ||
    die "the target uses production's database"
  PREFIX=$(config "$SOURCE/config.php" 'echo $CFG->prefix;')
  [[ "$PREFIX" =~ ^[A-Za-z0-9_]+$ ]] || die "unexpected table prefix in production: $PREFIX"
  [ "$(config "$TARGET/config.php" 'echo $CFG->prefix;')" = "$PREFIX" ] ||
    die "the target's config.php has another table prefix: set \$CFG->prefix = '$PREFIX', production's"

  TARGET_URL=$(config "$TARGET/config.php" 'echo $CFG->wwwroot;'); TARGET_URL=${TARGET_URL%/}
  SOURCE_URL_LIVE=$(config "$SOURCE/config.php" 'echo $CFG->wwwroot;'); SOURCE_URL_LIVE=${SOURCE_URL_LIVE%/}
  [[ "$TARGET_URL" =~ ^https?://[A-Za-z0-9.-]+$ ]] || die "the target's wwwroot is scheme and domain only, like https://staging.example.org (it has: $TARGET_URL)"
  TARGET_HOST=$(host_of "$TARGET_URL")
  [ "$(host_of "$SOURCE_URL_LIVE")" != "$TARGET_HOST" ] || die "the target's wwwroot is production's URL ($SOURCE_URL_LIVE)"

  # The temporary folder holds the credential files and the dump, each 600; with a snapshot, the restored tree too,
  # which the files' owner reads: the folder is traversable, never listable.
  mkdir -p "$TMP_BASE"
  TMP=$(mktemp -d "$TMP_BASE/clone-staging-moodle.XXXXXX")
  chmod 711 "$TMP"
  web test -x "$TMP" || die "CLONE_TMP ($tmp) is out of reach of ${WEB_USER:-$(id -un)}: point CLONE_TMP at a folder outside your home"
  write_cnf "$SOURCE/config.php" "$TMP/source.cnf"
  write_cnf "$TARGET/config.php" "$TMP/target.cnf"
  tdb -e 'SELECT 1' >/dev/null || die "staging's database does not answer with the credentials of the target's config.php"
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
  h=$(crontab -l 2>/dev/null | awk '$1 !~ /^#/ && /backup-moodle\.sh/ {print $2; exit}')
  [[ "$h" =~ ^[0-9]+$ ]] || return 0
  now=$((10#$(date +%H)))
  if ((now == h || now == (h + 23) % 24)); then
    die "the daily backup runs at $(printf %02d "$h"):00: restore outside $(printf %02d $(((h + 23) % 24))):00 to $(printf %02d $(((h + 1) % 24))):00"
  fi
}

snapshot_info() {
  local json p
  json=$(restic snapshots --no-lock --json "$SNAP") || die "restic did not find snapshot $SNAP"
  [ "$(jq length <<<"$json")" -ge 1 ] || die "restic did not find snapshot $SNAP"
  SNAP_ID=$(jq -r '.[-1].id' <<<"$json")
  SNAP_SHORT=$(jq -r '.[-1].short_id' <<<"$json")
  SNAP_DESC=$(jq -r '.[-1] | (.time[0:19] | sub("T"; " ")) + ", tags " + ((.tags // ["none"]) | join(","))' <<<"$json")
  # backup-moodle.sh snapshots the paths as config.php and ~/.restic-env give them
  SNAP_APP=$SOURCE; SNAP_DATA=$(config "$SOURCE/config.php" 'echo $CFG->dataroot;')
  for p in "$SNAP_APP" "$SNAP_DATA" "$SNAPSHOT_DUMP"; do
    jq -e --arg p "$p" '.[-1].paths | index($p)' >/dev/null <<<"$json" ||
      die "snapshot $SNAP_SHORT does not have $p (it has: $(jq -r '.[-1].paths | join(", ")' <<<"$json"))"
  done
}

# --- plan --------------------------------------------------------------------

plan() {
  local n b
  printf 'Clone to staging · Moodle · %s · %s\n\n' "$MODE" "$(date -u '+%Y-%m-%d %H:%M UTC')"
  if [ -z "$SNAP" ]; then
    IFS=$'\t' read -r n b < <(db_info sdb)
    printf 'Source   live production, %s and %s\n' "$SOURCE_REAL" "$SOURCE_DATA"
    printf '         %s · database with %s tables, %s, prefix %s\n' "$SOURCE_URL_LIVE" "$n" "$(human "$b")" "$PREFIX"
  else
    printf 'Source   restic snapshot %s (%s)\n' "$SNAP_SHORT" "$SNAP_DESC"
    printf '         %s, %s and the dump %s\n' "$SNAP_APP" "$SNAP_DATA" "$SNAPSHOT_DUMP"
  fi
  IFS=$'\t' read -r TARGET_TABLES b < <(db_info tdb)
  printf 'Target   %s and %s\n' "$TARGET_REAL" "$TARGET_DATA"
  printf '         %s · noemailever · database now with %s tables, %s\n\n' "$TARGET_URL" "$TARGET_TABLES" "$(human "$b")"

  printf '%-12s %12s %14s\n' Files "source${SNAP:+*}" "target now"
  local sc sd tc td
  sc=$(size "$SOURCE_REAL"); sd=$(size "$SOURCE_DATA"); tc=$(size "$TARGET_REAL"); td=$(size "$TARGET_DATA")
  SOURCE_BYTES=$((sc + sd)); TARGET_BYTES=$((tc + td))
  printf '  %-10s %12s %14s\n' code "$(human "$sc")" "$(human "$tc")"
  printf '  %-10s %12s %14s\n' moodledata "$(human "$sd")" "$(human "$td")"
  if [ -n "$SNAP" ]; then echo '  * live production sizes, as an estimate of the snapshot'; fi
  printf 'Free disk: %s\n\n' "$(human "$(free_bytes "$TARGET_DATA")")"

  echo 'The clone:'
  echo "  1. checks the target and locks against another clone"
  if [ -z "$SNAP" ]; then
    echo "  2. dumps production's database (read only) to a temporary folder in $TMP_BASE"
  else
    echo "  2. restores the dump, the code and moodledata from the snapshot to a temporary folder in $TMP_BASE"
  fi
  echo "  3. mirrors the code (without config.php and its copies) and moodledata (without ${DATA_SKIP[*]}) with rsync --delete"
  echo "  4. swaps the database: drops the $TARGET_TABLES tables, imports the dump, replaces the URL,"
  echo "     deletes web service tokens, user keys and sessions, and closes the site to search engines"
  echo "  5. purges the caches and checks the URL and the email${AFTER:+; runs '$AFTER'}"
  echo
  echo "Leaves staging: every table in the database; in the code and in moodledata, whatever the source lacks,"
  echo "  a plugin installed only in staging included."
  echo "Stays in staging: config.php, and in moodledata ${DATA_SKIP[*]}."
}

# --- steps -------------------------------------------------------------------

lock() {
  step "Checks"
  exec 9>"$LOCK"
  flock -n 9 || die "another clone is running ($LOCK)"
  # rsync brings the difference; from a snapshot, everything goes through the temporary folder first; 2 GiB for the dump and import
  local delta=$((SOURCE_BYTES - TARGET_BYTES)) temp=0 margin=$((2 * 1024 ** 3))
  ((delta > 0)) || delta=0
  if [ -n "$SNAP" ]; then temp=$SOURCE_BYTES; fi
  if [ "$(stat -c %d "$TMP")" = "$(stat -c %d "$TARGET_DATA")" ]; then
    disk "$TMP" $((delta + temp + margin))
  else
    disk "$TARGET_DATA" $((delta + margin))
    disk "$TMP" $((temp + margin))
  fi
  info "target with noemailever, and with database, folders and URL different from production"
  info "temporary folder $TMP"
  ok "ready to clone"
}

disk() {
  local f m; f=$(free_bytes "$1"); m=$(df --output=target "$1" | tail -1)
  ((f > $2)) || die "disk at $m: needs about $(human "$2"), has $(human "$f")"
  info "disk at $m: needs about $(human "$2"), has $(human "$f")"
}

prepare_source() {
  local inc from_config
  if [ -z "$SNAP" ]; then
    step "Production dump"
    FROM=$SOURCE_REAL; FROM_DATA=$SOURCE_DATA
    DUMP="$TMP/source.sql"
    # --single-transaction: the tables are InnoDB, and the dump comes out consistent without locking the site
    (umask 077; mysqldump --defaults-extra-file="$TMP/source.cnf" --single-transaction --quick --no-tablespaces \
      --default-character-set=utf8mb4 --result-file="$DUMP" "$SOURCE_DB")
    from_config="$SOURCE/config.php"
  else
    step "Restore of snapshot $SNAP_SHORT"
    restic_ready
    outside_backup_window
    FROM="$TMP/restic$SNAP_APP"; FROM_DATA="$TMP/restic$SNAP_DATA"
    DUMP="$TMP/restic$SNAPSHOT_DUMP"
    inc=(--include "$SNAP_APP/config.php" --include "$SNAPSHOT_DUMP")
    if [ "$MODE" = dry-run ]; then
      # in a dry run, only the dump and config.php are restored; for the folders, restic tells what would come
      restic restore "$SNAP_ID" --target "$TMP/restic" "${inc[@]}" >"$TMP/restic.log"
      restic restore "$SNAP_ID" --target "$TMP/restic" --include "$SNAP_APP" --include "$SNAP_DATA" --dry-run >"$TMP/restic-folders.log"
      info "folders, restic --dry-run: $(grep -i '^summary' "$TMP/restic-folders.log" || echo 'no summary')"
    else
      restic restore "$SNAP_ID" --target "$TMP/restic" --include "$SNAP_APP" --include "$SNAP_DATA" --include "$SNAPSHOT_DUMP" >"$TMP/restic.log"
      info "restic: $(grep -i '^summary' "$TMP/restic.log" || echo 'no summary')"
    fi
    [ -f "$FROM/config.php" ] || die "the snapshot did not bring $SNAP_APP/config.php"
    open_path "$FROM"; open_path "$FROM_DATA"
    [ -f "$DUMP" ] && chmod 600 "$DUMP"
    from_config="$FROM/config.php"
    [ "$(config "$from_config" 'echo $CFG->prefix;')" = "$PREFIX" ] || die "the snapshot's table prefix is not $PREFIX, the target's"
  fi
  [ -f "$DUMP" ] || die "no dump at $DUMP"

  SOURCE_URL=$(config "$from_config" 'echo $CFG->wwwroot;'); SOURCE_URL=${SOURCE_URL%/}
  [ -n "$SOURCE_URL" ] || die "no wwwroot in $from_config"
  [ "$(host_of "$SOURCE_URL")" != "$TARGET_HOST" ] || die "the source is already staging's ($SOURCE_URL)"
  build_pairs
  info "dump of $(human "$(stat -c %s "$DUMP")"), prefix $PREFIX, wwwroot $SOURCE_URL"
  ok "source ready"
}

# restic creates the folders above the restored paths closed to others: the files' owner walks through them to read the tree.
open_path() {
  local p; p=$(dirname "$1")
  while [ "$p" != "$TMP" ] && [ "$p" != / ]; do if [ -d "$p" ]; then chmod a+x "$p"; fi; p=$(dirname "$p"); done
}

# Replacement pairs. Replacing the bare domain would change the @domain emails; with the slashes in front, only URLs.
# \/\/ is the URL inside JSON. Each form goes in only if it appears in the dump: an empty pass walks every table all the same.
build_pairs() {
  local b pre n
  b=$(host_of "$SOURCE_URL")
  PAIRS_FROM=(); PAIRS_TO=(); PAIRS_N=()
  for pre in '//' '\/\/'; do
    # in the mysqldump output, each \ in the database shows as \\
    n=$({ grep -aoF -- "${pre//\\/\\\\}$b" "$DUMP" || true; } | wc -l)
    ((n > 0)) || continue
    PAIRS_FROM+=("$pre$b"); PAIRS_TO+=("$pre$TARGET_HOST"); PAIRS_N+=("$n")
  done
}

# rsync of a folder, as the files' owner, with the summary on one line
mirror() {
  local from=$1 to=$2 label=$3 n b d
  shift 3
  local args=(-a --delete --stats "$@")
  [ "$MODE" = dry-run ] && args+=(--dry-run)
  if ! web test -e "$from"; then warn "$label does not exist in the source"; return; fi
  web rsync "${args[@]}" "$from" "$to" >"$TMP/rsync-$label.log"
  read -r n b d < <(awk -F': ' '
    /^Number of regular files transferred/ {gsub(/[^0-9]/, "", $2); n = $2}
    /^Total transferred file size/ {gsub(/[^0-9]/, "", $2); b = $2}
    /^Number of deleted files/ {gsub(/[^0-9]/, "", $2); d = $2}
    END {print n + 0, b + 0, d + 0}' "$TMP/rsync-$label.log")
  info "$(printf '%-10s' "$label") new or changed: $n ($(human "$b")) · deleted: $d"
}

copy_files() {
  step "Files"
  local skip=() d
  if [ "$MODE" = dry-run ] && [ -n "$SNAP" ]; then
    info "the snapshot folders were not restored in the dry run: restic's summary in step 2 shows what would come"
    ok "nothing written"
    return
  fi
  for d in "${DATA_SKIP[@]}"; do skip+=("--exclude=/$d/"); done
  # config.php is the target's own: database, folders, URL and noemailever. A copy an editor left beside production's
  # (config.php.save, config.php~) holds production's database password and stays out too.
  mirror "$FROM/" "$TARGET_REAL/" code '--exclude=/config.php*'
  mirror "$FROM_DATA/" "$TARGET_DATA/" moodledata "${skip[@]}"
  if [ "$MODE" = dry-run ]; then ok "nothing written"; else ok "files in the target"; fi
}

swap_database() {
  step "Database"
  local i tables n
  if [ "$MODE" = dry-run ]; then
    info "would drop the target's $TARGET_TABLES tables and import the dump"
    for i in "${!PAIRS_FROM[@]}"; do
      info "replace ${PAIRS_FROM[$i]} → ${PAIRS_TO[$i]} (${PAIRS_N[$i]} occurrences in the dump)"
    done
    info "would delete web service tokens, user keys and sessions, and set allowindexing to 2"
    ok "nothing written"
    return
  fi

  tables=$(tdb -e "SELECT table_name FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'")
  if [ -n "$tables" ]; then
    # shellcheck disable=SC2016  # the backticks quote the names in SQL
    tdb -e "SET FOREIGN_KEY_CHECKS = 0; DROP TABLE $(awk '{printf "%s`%s`", (NR > 1 ? "," : ""), $0}' <<<"$tables");"
    info "$(grep -c . <<<"$tables") tables dropped"
  fi
  tdb <"$DUMP"
  info "dump imported ($(duration $((SECONDS - STEP_T))))"

  # Production's secrets do not work in staging: a web service token, a login key and an open session
  # would each let whoever holds production's enter the copy.
  n=$(tdb -e "SELECT (SELECT COUNT(*) FROM ${PREFIX}external_tokens) + (SELECT COUNT(*) FROM ${PREFIX}user_private_key)")
  tdb -e "DELETE FROM ${PREFIX}external_tokens; DELETE FROM ${PREFIX}user_private_key; DELETE FROM ${PREFIX}sessions;"
  info "$n web service tokens and user keys deleted, and every session"

  # Moodle's own tool: it walks every text column and knows the tables to leave alone
  for i in "${!PAIRS_FROM[@]}"; do
    web php "$TARGET_REAL/admin/tool/replace/cli/replace.php" --search="${PAIRS_FROM[$i]}" --replace="${PAIRS_TO[$i]}" \
      --shorten --non-interactive >"$TMP/replace-$i.log" 2>&1 ||
      { tail -5 "$TMP/replace-$i.log" >&2; die "the URL replacement failed"; }
    info "replace ${PAIRS_FROM[$i]} → ${PAIRS_TO[$i]} (${PAIRS_N[$i]} occurrences in the dump)"
  done
  # allowindexing 2: no page of the copy is offered to search engines
  web php "$TARGET_REAL/admin/cli/cfg.php" --name=allowindexing --set=2 >/dev/null
  ok "source database in the target"
}

finish() {
  step "Finish"
  local code n
  if [ "$MODE" = dry-run ]; then
    info "would purge the caches; would check the URL and the email${AFTER:+; would run '$AFTER'}"
    ok "nothing written"
    return
  fi
  web php "$TARGET_REAL/admin/cli/purge_caches.php" >/dev/null
  [ "$(config "$TARGET/config.php" 'echo empty($CFG->noemailever) ? "" : "yes";')" = yes ] || die "the target's config.php lost noemailever"
  n=$(tdb -e "SELECT COUNT(*) FROM ${PREFIX}external_tokens")
  info "noemailever in config.php: nothing goes out · $n web service tokens · allowindexing $(web php "$TARGET_REAL/admin/cli/cfg.php" --name=allowindexing)"
  n=$(tdb -e "SELECT COUNT(*) FROM ${PREFIX}course")
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 60 "$TARGET_URL/login/index.php" || true)
  info "$n courses · $TARGET_URL/login/index.php answers $code"
  [ "$code" = 200 ] || warn "$TARGET_URL/login/index.php answers $code, not 200"
  if [ -n "$AFTER" ]; then
    # in the target folder, so a `php admin/cli/<script>` finds the site
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

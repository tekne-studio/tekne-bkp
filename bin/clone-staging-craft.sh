#!/bin/bash
# clone-staging-craft — brings production's data to a staging Craft: the database and the upload folders.
# The code stays staging's own: it comes from the site's deploy, and so do its .env, its config and its URL.
# The source is live production or a restic snapshot.
# Usage: clone-staging-craft.sh [--dry-run | --run] [--snapshot latest|<ID>]
#   Without --dry-run or --run, prints the plan and exits without changing anything.
# Without installing: ssh <user>@<server> 'bash -s -- --dry-run' < bin/clone-staging-craft.sh
# Docs: docs/clone-staging-craft.md
set -euo pipefail

# cron starts a job with /usr/bin:/bin alone: restic and wp live in ~/bin or in /usr/local/bin
export PATH="$HOME/bin:/usr/local/bin:$PATH"

# The site comes from ~/.restic-env, as in the backup. restic is needed only with --snapshot.
RESTIC_ENV="${RESTIC_ENV:-$HOME/.restic-env}"
# shellcheck source=/dev/null
if [ -f "$RESTIC_ENV" ]; then source "$RESTIC_ENV"; fi

SOURCE="${CRAFT_PATH:-}"
SOURCE_ENV="${CRAFT_ENV_FILE:-}"
TARGET="${STAGING_PATH:-}"
SNAPSHOT_DUMP="${DB_DUMP:-}"  # where backup-craft.sh writes the dump: the same path inside the snapshot
TMP_BASE="${CLONE_TMP:-$HOME/tmp}"
# Folders mirrored from production, relative to the site folder: the asset volumes and other uploads.
SYNC="${CLONE_SYNC:-}"
# Command run in the target folder at the end of the clone: the site's own migration or check.
AFTER="${CLONE_AFTER:-}"

usage() {
  cat <<'EOF'
usage: clone-staging-craft.sh [--dry-run | --run] [--snapshot latest|<ID>]
  (no argument)      prints the plan: source, target, sizes and what leaves staging
  --dry-run          reads the source and runs rsync with --dry-run, writing nothing to staging
  --run              clones
  --snapshot <ID>    source in a restic snapshot (latest or an ID) instead of live production
Required, in the environment or in ~/.restic-env (RESTIC_ENV): CRAFT_PATH, STAGING_PATH
Optional: CRAFT_ENV_FILE, CLONE_SYNC, DB_DUMP, CLONE_TMP, CLONE_AFTER
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
size() { if [ -e "$1" ]; then du -sb "$1" | cut -f1; else echo 0; fi; }

# --- the sites ---------------------------------------------------------------

# A site's .env is the one home of its database and URL. It is read as text, never sourced: KEY=value, quotes optional.
# Craft 3 names the keys DB_*; Craft 4 and 5, CRAFT_DB_*.
# dotenv <.env> <KEY>
dotenv() {
  local v
  v=$(sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?(CRAFT_)?$2[[:space:]]*=[[:space:]]*//p" "$1" | tail -1)
  v=${v%$'\r'}
  case "$v" in
    \"*\") v=${v#\"}; v=${v%\"} ;;
    \'*\') v=${v#\'}; v=${v%\'} ;;
    *) v=$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<<"$v") ;;
  esac
  printf '%s' "$v"
}

# The [client] section for mysql and mysqldump: the credentials go in a 600 file, never on the command line.
cnf_quote() { local v=${1//\\/\\\\}; printf '"%s"' "${v//\"/\\\"}"; }
write_cnf() {
  local port
  (
    umask 077
    {
      printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' "$(cnf_quote "$(dotenv "$1" DB_USER)")" \
        "$(cnf_quote "$(dotenv "$1" DB_PASSWORD)")" "$(cnf_quote "$(dotenv "$1" DB_SERVER)")"
      port=$(dotenv "$1" DB_PORT)
      if [ -n "$port" ]; then printf 'port=%d\n' "$port"; fi
    } >"$2"
  )
}
sdb() { mysql --defaults-extra-file="$TMP/source.cnf" --batch --skip-column-names "$SOURCE_DB" "$@"; }
tdb() { mysql --defaults-extra-file="$TMP/target.cnf" --batch --skip-column-names "$TARGET_DB" "$@"; }

# "<tables>\t<bytes>" of one side's database (sdb or tdb)
db_info() {
  "$1" -e "SELECT COUNT(*), COALESCE(SUM(data_length + index_length), 0)
    FROM information_schema.tables WHERE table_schema = DATABASE()"
}

mysql_driver() { case "$(dotenv "$1" DB_DRIVER)" in '' | mysql) return 0 ;; *) return 1 ;; esac; }

# --- checks ------------------------------------------------------------------

check() {
  local c d rel tmp
  for c in mysql mysqldump rsync flock numfmt php curl; do
    command -v "$c" >/dev/null || die "missing command: $c"
  done
  [ -n "$SOURCE" ] || die "set CRAFT_PATH in $RESTIC_ENV: the production site folder"
  [ -n "$TARGET" ] || die "set STAGING_PATH in $RESTIC_ENV: the staging site folder"
  [ -d "$SOURCE" ] || die "no production site in $SOURCE (CRAFT_PATH)"
  [ -d "$TARGET" ] || die "no staging site in $TARGET (STAGING_PATH): staging is deployed once, by the site's own deploy (docs/clone-staging-craft.md)"
  [ -n "$SOURCE_ENV" ] || SOURCE_ENV="$SOURCE/.env"
  [ -f "$SOURCE_ENV" ] || die "no Craft .env at $SOURCE_ENV: set CRAFT_ENV_FILE"
  # staging keeps its .env at the same place inside its folder
  case "$SOURCE_ENV" in "$SOURCE"/*) rel=${SOURCE_ENV#"$SOURCE"/} ;; *) die "CRAFT_ENV_FILE ($SOURCE_ENV) is outside CRAFT_PATH ($SOURCE)" ;; esac
  TARGET_ENV="$TARGET/$rel"
  [ -f "$TARGET_ENV" ] || die "no .env at $TARGET_ENV: staging has a .env of its own, with its database and its URL"
  TARGET_CRAFT=$(dirname "$TARGET_ENV")
  [ -f "$TARGET_CRAFT/craft" ] || die "no craft console at $TARGET_CRAFT/craft"
  # the same default as backup-craft.sh, and one lock per target: two sites on one server do not run over each other
  [ -n "$SNAPSHOT_DUMP" ] || SNAPSHOT_DUMP="$HOME/backups/$(basename "$SOURCE").sql"
  LOCK="$HOME/.clone-staging.$(basename "$TARGET").lock"

  SOURCE_REAL=$(realpath "$SOURCE"); TARGET_REAL=$(realpath "$TARGET")
  tmp=$(realpath -m "$TMP_BASE")
  case "$TARGET_REAL/" in "$SOURCE_REAL/"*) die "the target ($TARGET_REAL) is production's folder or lies inside it" ;; esac
  case "$SOURCE_REAL/" in "$TARGET_REAL/"*) die "production's folder lies inside the target ($TARGET_REAL)" ;; esac
  for d in "$SOURCE_REAL" "$TARGET_REAL"; do
    case "$tmp/" in "$d/"*) die "CLONE_TMP ($tmp) lies inside one of the sites" ;; esac
  done
  SYNC_DIRS=()
  set -f
  for d in $SYNC; do
    case "/$d/" in /*/../* | //*) die "CLONE_SYNC takes folders inside the site folder, like 'web/uploads' (it has: $d)" ;; esac
    SYNC_DIRS+=("${d%/}")
  done
  set +f

  mysql_driver "$SOURCE_ENV" || die "production's database is not MySQL or MariaDB"
  mysql_driver "$TARGET_ENV" || die "staging's database is not MySQL or MariaDB"
  SOURCE_DB=$(dotenv "$SOURCE_ENV" DB_DATABASE)
  TARGET_DB=$(dotenv "$TARGET_ENV" DB_DATABASE)
  [ -n "$SOURCE_DB" ] || die "no DB_DATABASE in $SOURCE_ENV: the database is read from DB_SERVER, DB_PORT, DB_DATABASE, DB_USER and DB_PASSWORD, not from a DSN"
  [ -n "$TARGET_DB" ] || die "no DB_DATABASE in $TARGET_ENV"
  # same server and same database name = production's database
  [ "$(dotenv "$SOURCE_ENV" DB_SERVER):$(dotenv "$SOURCE_ENV" DB_PORT)/$SOURCE_DB" != "$(dotenv "$TARGET_ENV" DB_SERVER):$(dotenv "$TARGET_ENV" DB_PORT)/$TARGET_DB" ] ||
    die "the target uses production's database"
  PREFIX=$(dotenv "$SOURCE_ENV" DB_TABLE_PREFIX)
  [[ "$PREFIX" =~ ^[A-Za-z0-9_]*$ ]] || die "unexpected table prefix in production: $PREFIX"
  [ "$(dotenv "$TARGET_ENV" DB_TABLE_PREFIX)" = "$PREFIX" ] ||
    die "the target's .env has another table prefix: set DB_TABLE_PREFIX to production's ('$PREFIX')"

  # PRIMARY_SITE_URL is a convention of Craft's starter .env, not a rule: when both sites set it, the two differ
  SOURCE_URL=$(dotenv "$SOURCE_ENV" PRIMARY_SITE_URL); SOURCE_URL=${SOURCE_URL%/}
  TARGET_URL=$(dotenv "$TARGET_ENV" PRIMARY_SITE_URL); TARGET_URL=${TARGET_URL%/}
  if [ -n "$SOURCE_URL" ] && [ -n "$TARGET_URL" ]; then
    [ "$(host_of "$SOURCE_URL")" != "$(host_of "$TARGET_URL")" ] || die "the target's PRIMARY_SITE_URL is production's ($SOURCE_URL)"
  fi

  # The temporary folder holds the credential files and the dump, each 600.
  mkdir -p "$TMP_BASE"
  TMP=$(mktemp -d "$TMP_BASE/clone-staging-craft.XXXXXX")
  write_cnf "$SOURCE_ENV" "$TMP/source.cnf"
  write_cnf "$TARGET_ENV" "$TMP/target.cnf"
  tdb -e 'SELECT 1' >/dev/null || die "staging's database does not answer with the credentials of $TARGET_ENV"
}

# Never two restic at once: the repository lock conflicts.
restic_ready() {
  command -v jq >/dev/null || die "missing command: jq"
  pgrep -x restic >/dev/null && die "a restic is running (pgrep -a restic): wait for it to finish"
  pgrep -f '/backup-[a-z]+\.sh' >/dev/null && die "a backup or milestone is running: wait for it to finish"
  [ -n "${RESTIC_REPOSITORY:-}" ] || die "no RESTIC_REPOSITORY: set up $RESTIC_ENV (see .restic-env.example)"
}

# A long restore near the daily backup would make its prune fail on the lock: stay out of the hour before and the cron hour.
outside_backup_window() {
  local h now
  h=$(crontab -l 2>/dev/null | awk '$1 !~ /^#/ && /backup-craft\.sh/ {print $2; exit}')
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
  # backup-craft.sh snapshots the paths as ~/.restic-env gives them
  for p in "$SOURCE" "$SNAPSHOT_DUMP"; do
    jq -e --arg p "$p" '.[-1].paths | index($p)' >/dev/null <<<"$json" ||
      die "snapshot $SNAP_SHORT does not have $p (it has: $(jq -r '.[-1].paths | join(", ")' <<<"$json"))"
  done
}

# --- plan --------------------------------------------------------------------

plan() {
  local n b d s t
  printf 'Clone to staging · Craft · %s · %s\n\n' "$MODE" "$(date -u '+%Y-%m-%d %H:%M UTC')"
  if [ -z "$SNAP" ]; then
    IFS=$'\t' read -r n b < <(db_info sdb)
    printf 'Source   live production, %s\n' "$SOURCE_REAL"
    printf '         %s · database %s with %s tables, %s\n' "${SOURCE_URL:-no PRIMARY_SITE_URL}" "$SOURCE_DB" "$n" "$(human "$b")"
  else
    printf 'Source   restic snapshot %s (%s)\n' "$SNAP_SHORT" "$SNAP_DESC"
    printf '         %s and the dump %s\n' "$SOURCE" "$SNAPSHOT_DUMP"
  fi
  IFS=$'\t' read -r TARGET_TABLES b < <(db_info tdb)
  printf 'Target   %s\n' "$TARGET_REAL"
  printf '         %s · database %s now with %s tables, %s\n\n' "${TARGET_URL:-no PRIMARY_SITE_URL}" "$TARGET_DB" "$TARGET_TABLES" "$(human "$b")"

  SOURCE_BYTES=0; TARGET_BYTES=0
  if ((${#SYNC_DIRS[@]})); then
    printf '%-24s %12s %14s\n' Folders "source${SNAP:+*}" "target now"
    for d in "${SYNC_DIRS[@]}"; do
      s=$(size "$SOURCE_REAL/$d"); t=$(size "$TARGET_REAL/$d")
      SOURCE_BYTES=$((SOURCE_BYTES + s)); TARGET_BYTES=$((TARGET_BYTES + t))
      printf '  %-22s %12s %14s\n' "$d" "$(human "$s")" "$(human "$t")"
    done
    if [ -n "$SNAP" ]; then echo '  * live production sizes, as an estimate of the snapshot'; fi
  else
    echo 'Folders  none: CLONE_SYNC is empty, only the database is cloned'
  fi
  printf 'Free disk: %s\n\n' "$(human "$(free_bytes "$TARGET_REAL")")"

  echo 'The clone:'
  echo "  1. checks the target and locks against another clone"
  if [ -z "$SNAP" ]; then
    echo "  2. dumps production's database (read only) to a temporary folder in $TMP_BASE"
  else
    echo "  2. restores the dump and the folders from the snapshot to a temporary folder in $TMP_BASE"
  fi
  echo "  3. mirrors the folders of CLONE_SYNC with rsync --delete"
  echo "  4. swaps the database: drops the $TARGET_TABLES tables, imports the dump and deletes the sessions"
  echo "  5. clears Craft's caches and checks the URL${AFTER:+; runs '$AFTER'}"
  echo
  echo "Leaves staging: every table in the database; in the folders of CLONE_SYNC, whatever the source lacks."
  echo "Stays in staging: the code, the .env, the config and everything outside CLONE_SYNC."
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
  if [ "$(stat -c %d "$TMP")" = "$(stat -c %d "$TARGET_REAL")" ]; then
    disk "$TMP" $((delta + temp + margin))
  else
    disk "$TARGET_REAL" $((delta + margin))
    disk "$TMP" $((temp + margin))
  fi
  # What stops email is testToEmailAddress, in the site's config; Craft 4 and 5 also read it from .env
  if ! grep -qs testToEmailAddress "$TARGET_CRAFT/config/general.php" && [ -z "$(dotenv "$TARGET_ENV" TEST_TO_EMAIL_ADDRESS)" ]; then
    warn "staging sends email as production does: set testToEmailAddress in its config/general.php"
  fi
  info "target with folder and database different from production"
  info "temporary folder $TMP"
  ok "ready to clone"
}

disk() {
  local f m; f=$(free_bytes "$1"); m=$(df --output=target "$1" | tail -1)
  ((f > $2)) || die "disk at $m: needs about $(human "$2"), has $(human "$f")"
  info "disk at $m: needs about $(human "$2"), has $(human "$f")"
}

prepare_source() {
  local inc=() d
  if [ -z "$SNAP" ]; then
    step "Production dump"
    FROM=$SOURCE_REAL
    DUMP="$TMP/source.sql"
    # --single-transaction: the dump comes out consistent without locking the site
    (umask 077; mysqldump --defaults-extra-file="$TMP/source.cnf" --single-transaction --quick --no-tablespaces \
      --default-character-set=utf8mb4 --result-file="$DUMP" "$SOURCE_DB")
  else
    step "Restore of snapshot $SNAP_SHORT"
    restic_ready
    outside_backup_window
    FROM="$TMP/restic$SOURCE"
    DUMP="$TMP/restic$SNAPSHOT_DUMP"
    if ((${#SYNC_DIRS[@]})); then for d in "${SYNC_DIRS[@]}"; do inc+=(--include "$SOURCE/$d"); done; fi
    if [ "$MODE" = dry-run ]; then
      # in a dry run, only the dump is restored; for the folders, restic tells what would come
      restic restore "$SNAP_ID" --target "$TMP/restic" --include "$SNAPSHOT_DUMP" >"$TMP/restic.log"
      if ((${#inc[@]})); then
        restic restore "$SNAP_ID" --target "$TMP/restic" "${inc[@]}" --dry-run >"$TMP/restic-folders.log"
        info "folders, restic --dry-run: $(grep -i '^summary' "$TMP/restic-folders.log" || echo 'no summary')"
      fi
    else
      restic restore "$SNAP_ID" --target "$TMP/restic" --include "$SNAPSHOT_DUMP" ${inc[@]+"${inc[@]}"} >"$TMP/restic.log"
      info "restic: $(grep -i '^summary' "$TMP/restic.log" || echo 'no summary')"
    fi
    [ -f "$DUMP" ] && chmod 600 "$DUMP"
  fi
  [ -f "$DUMP" ] || die "no dump at $DUMP"
  info "dump of $(human "$(stat -c %s "$DUMP")")"
  ok "source ready"
}

# rsync of a folder, with the summary on one line
mirror() {
  local from=$1 to=$2 label=$3 n b d log
  local args=(-a --delete --stats)
  [ "$MODE" = dry-run ] && args+=(--dry-run)
  if [ ! -d "$from" ]; then warn "$label does not exist in the source"; return; fi
  if [ "$MODE" = run ]; then mkdir -p "$to"; fi
  if [ ! -d "$to" ]; then info "$(printf '%-22s' "$label") new in the target"; return; fi
  log="$TMP/rsync-${label//\//_}.log"
  rsync "${args[@]}" "$from/" "$to/" >"$log"
  read -r n b d < <(awk -F': ' '
    /^Number of regular files transferred/ {gsub(/[^0-9]/, "", $2); n = $2}
    /^Total transferred file size/ {gsub(/[^0-9]/, "", $2); b = $2}
    /^Number of deleted files/ {gsub(/[^0-9]/, "", $2); d = $2}
    END {print n + 0, b + 0, d + 0}' "$log")
  info "$(printf '%-22s' "$label") new or changed: $n ($(human "$b")) · deleted: $d"
}

copy_files() {
  step "Folders"
  local d
  if ((${#SYNC_DIRS[@]} == 0)); then
    info "CLONE_SYNC is empty: no folder is mirrored"
    ok "nothing to copy"
    return
  fi
  if [ "$MODE" = dry-run ] && [ -n "$SNAP" ]; then
    info "the snapshot folders were not restored in the dry run: restic's summary in step 2 shows what would come"
    ok "nothing written"
    return
  fi
  for d in "${SYNC_DIRS[@]}"; do mirror "$FROM/$d" "$TARGET_REAL/$d" "$d"; done
  if [ "$MODE" = dry-run ]; then ok "nothing written"; else ok "folders in the target"; fi
}

swap_database() {
  step "Database"
  local tables
  if [ "$MODE" = dry-run ]; then
    info "would drop the target's $TARGET_TABLES tables, import the dump and delete the sessions"
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

  # An open session of production would let whoever holds it enter the copy.
  if [ -n "$(tdb -e "SHOW TABLES LIKE '${PREFIX}sessions'")" ]; then
    tdb -e "DELETE FROM ${PREFIX}sessions"
    info "every session deleted"
  fi
  ok "source database in the target"
}

finish() {
  step "Finish"
  local code n
  if [ "$MODE" = dry-run ]; then
    info "would clear Craft's caches and check the URL${AFTER:+; would run '$AFTER'}"
    ok "nothing written"
    return
  fi
  (cd "$TARGET_CRAFT" && php craft clear-caches/all) >"$TMP/caches.log" 2>&1 ||
    { tail -5 "$TMP/caches.log" >&2; warn "craft clear-caches/all failed in the target"; }
  IFS=$'\t' read -r n _ < <(db_info tdb)
  if [ -n "$TARGET_URL" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 60 "$TARGET_URL/" || true)
    info "$n tables · $TARGET_URL/ answers $code"
    [ "$code" = 200 ] || warn "$TARGET_URL/ answers $code, not 200"
  else
    info "$n tables · no PRIMARY_SITE_URL in the target's .env to check"
  fi
  if [ -n "$AFTER" ]; then
    # in the target folder, so a `php craft <command>` of the site finds it
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

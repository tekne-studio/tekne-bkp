#!/bin/bash
# tekne-bkp — backup of a Craft CMS site with restic: database dump + snapshot of the site folder.
# Set up ~/.restic-env (see .restic-env.example) and run from cron.
# Usage: backup-craft.sh                      daily backup: 'craft' snapshot, retention, log and heartbeat
#        backup-craft.sh --milestone <label>  'milestone' snapshot before a risky change; retention keeps it.
#                                             Only dump + snapshot: no retention, log, heartbeat or email, so it never hides a cron failure.
# Docs: docs/backup-craft.md
set -Eeuo pipefail

source "${RESTIC_ENV:-$HOME/.restic-env}"
# cron starts a job with /usr/bin:/bin alone: restic and wp live in ~/bin or in /usr/local/bin
export PATH="$HOME/bin:/usr/local/bin:$PATH"

MILESTONE=
case "${1:-}" in
  '') ;;
  --milestone) MILESTONE="${2:?usage: backup-craft.sh --milestone <label>   e.g. pre-update-craft}" ;;
  *) echo "usage: backup-craft.sh [--milestone <label>]" >&2; exit 2 ;;
esac

APP="${CRAFT_PATH:?set CRAFT_PATH in ${RESTIC_ENV:-$HOME/.restic-env}: the site folder, with the web root, the Craft folder and the uploads}"
ENV_FILE="${CRAFT_ENV_FILE:-$APP/.env}"
DUMP="${DB_DUMP:-$HOME/backups/$(basename "$APP").sql}"
LOG="${BACKUP_LOG:-$HOME/logs/backup.log}"

mkdir -p "$(dirname "$DUMP")" "$(dirname "$LOG")"

# Optional heartbeat (Better Stack, Healthchecks.io, Cronitor, Uptime Kuma): GET the URL at the end, GET <URL>/fail on failure,
# so the monitor alerts at once instead of when the ping fails to arrive. A milestone does not ping.
ping_monitor() { if [ -n "${HEALTHCHECK_URL:-}" ] && [ -z "$MILESTONE" ]; then curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL$1" >/dev/null; fi; }
# Optional email on failure, with the command that failed, to each address in EMAIL_ALERT_TO, or in EMAIL_TO without it.
# A milestone does not email.
email_failure() {
  local to site list="${EMAIL_ALERT_TO:-${EMAIL_TO:-}}"
  if [ -z "$list" ] || [ -n "$MILESTONE" ]; then return 0; fi
  site=$(basename "$APP")
  # shellcheck disable=SC2086  # a space-separated list
  for to in $list; do
    printf 'The backup of %s failed: no new snapshot is guaranteed.\n\nFailed at: %s\nScript: backup-craft.sh\nHost: %s\nDate: %s\n' \
      "$site" "${FAILED_AT:-unknown}" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %Z')" |
      mail -s "${EMAIL_SUBJECT_PREFIX:-[BACKUP]} ${site^^} - Backup FAILED" ${EMAIL_FROM:+-r "$EMAIL_FROM"} "$to"
  done
}
CNF=
FAILED_AT=
fail() { FAILED_AT="$*"; echo "$*" >&2; exit 1; }
trap 'FAILED_AT="line $LINENO: $BASH_COMMAND"' ERR
trap 'if [ $? -ne 0 ]; then ping_monitor /fail || true; email_failure || true; fi; rm -f "$CNF"' EXIT

# Craft's .env is the one home of the database credentials. It is read as text, never sourced: KEY=value, quotes optional.
# Craft 3 names the keys DB_*; Craft 4 and 5, CRAFT_DB_*.
[ -f "$ENV_FILE" ] || fail "no Craft .env at $ENV_FILE: set CRAFT_ENV_FILE"
dotenv() {
  local v
  v=$(sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?(CRAFT_)?$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -1)
  v=${v%$'\r'}
  case "$v" in
    \"*\") v=${v#\"}; v=${v%\"} ;;
    \'*\') v=${v#\'}; v=${v%\'} ;;
    *) v=$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<<"$v") ;;
  esac
  printf '%s' "$v"
}
cnf_quote() { local v=${1//\\/\\\\}; printf '"%s"' "${v//\"/\\\"}"; }
DB=$(dotenv DB_DATABASE)
[ -n "$DB" ] || fail "no DB_DATABASE in $ENV_FILE: the database is read from DB_SERVER, DB_PORT, DB_DATABASE, DB_USER and DB_PASSWORD, not from a DSN"
case "$(dotenv DB_DRIVER)" in '' | mysql) ;; *) fail "the database of $ENV_FILE is not MySQL or MariaDB" ;; esac

# 1 · database dump (overwritten; restic keeps the versions). The credentials go in a 600 file, never on the command line.
# --single-transaction reads one consistent state without locking the site.
CNF=$(mktemp)
{
  printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' "$(cnf_quote "$(dotenv DB_USER)")" "$(cnf_quote "$(dotenv DB_PASSWORD)")" "$(cnf_quote "$(dotenv DB_SERVER)")"
  PORT=$(dotenv DB_PORT)
  if [ -n "$PORT" ]; then printf 'port=%d\n' "$PORT"; fi
} > "$CNF"
mysqldump --defaults-extra-file="$CNF" --single-transaction --quick --no-tablespaces \
  --default-character-set=utf8mb4 --result-file="$DUMP" "$DB"
chmod 600 "$DUMP"

# 2 · snapshot: 'craft' tag for the daily one, 'milestone' + label for a milestone.
# Left out: what Craft rebuilds (runtime, logs, the control panel's published resources) and its own dumps, which the snapshot's dump replaces.
if [ -n "$MILESTONE" ]; then TAGS=(--tag milestone --tag "$MILESTONE"); else TAGS=(--tag craft --quiet); fi
restic backup "$APP" "$DUMP" \
  --exclude="storage/runtime" \
  --exclude="storage/logs" \
  --exclude="storage/backups" \
  --exclude="cpresources" \
  "${TAGS[@]}"

if [ -n "$MILESTONE" ]; then
  echo "milestone created: $MILESTONE"
  exit 0
fi

# 3 · retention: 7 daily + 16 weekly + 12 monthly; 'milestone' snapshots stay
restic forget \
  --keep-daily 7 \
  --keep-weekly 16 \
  --keep-monthly 12 \
  --keep-tag milestone \
  --prune \
  --quiet

echo "$(date -Iseconds) OK" >> "$LOG"

# 4 · monitoring heartbeat
ping_monitor ""

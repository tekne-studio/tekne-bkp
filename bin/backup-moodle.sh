#!/bin/bash
# tekne-bkp — backup of a Moodle site with restic: database dump + snapshot of the code and of moodledata.
# Set up ~/.restic-env (see .restic-env.example) and run from cron.
# Usage: backup-moodle.sh                      daily backup: 'moodle' snapshot, retention, log and heartbeat
#        backup-moodle.sh --milestone <label>  'milestone' snapshot before a risky change; retention keeps it.
#                                              Only dump + snapshot: no retention, log, heartbeat or email, so it never hides a cron failure.
# Docs: docs/backup-moodle.md
set -Eeuo pipefail

source "${RESTIC_ENV:-$HOME/.restic-env}"
# cron starts a job with /usr/bin:/bin alone: restic and wp live in ~/bin or in /usr/local/bin
export PATH="$HOME/bin:/usr/local/bin:$PATH"

MILESTONE=
case "${1:-}" in
  '') ;;
  --milestone) MILESTONE="${2:?usage: backup-moodle.sh --milestone <label>   e.g. pre-install-auth-userkey}" ;;
  *) echo "usage: backup-moodle.sh [--milestone <label>]" >&2; exit 2 ;;
esac

APP="${MOODLE_PATH:?set MOODLE_PATH in ${RESTIC_ENV:-$HOME/.restic-env}: the Moodle folder, the one with config.php}"
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
    printf 'The backup of %s failed: no new snapshot is guaranteed.\n\nFailed at: %s\nScript: backup-moodle.sh\nHost: %s\nDate: %s\n' \
      "$site" "${FAILED_AT:-unknown}" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %Z')" |
      mail -s "${EMAIL_SUBJECT_PREFIX:-[BACKUP]} ${site^^} - Backup FAILED" ${EMAIL_FROM:+-r "$EMAIL_FROM"} "$to"
  done
}
CNF=
FAILED_AT=
trap 'FAILED_AT="line $LINENO: $BASH_COMMAND"' ERR
trap 'if [ $? -ne 0 ]; then ping_monitor /fail || true; email_failure || true; fi; rm -f "$CNF"' EXIT

# config.php is the one home of the database credentials and of dataroot. Its last line loads Moodle (lib/setup.php);
# without that line the file only sets $CFG, so it is read with no Moodle bootstrap and no database connection.
moodle_config() {
  php -r '
    $code = file_get_contents($argv[1]);
    if ($code === false) exit(1);
    eval(preg_replace(["/^\s*<\?php/", "/\?>\s*$/", "/^.*\bsetup\.php\b.*$/m"], "", $code));
    '"$1" "$APP/config.php"
}
DATA=$(moodle_config 'echo $CFG->dataroot;')
DB=$(moodle_config 'echo $CFG->dbname;')
[ -d "$DATA" ] || { FAILED_AT="dataroot of $APP/config.php is not a folder: $DATA"; echo "$FAILED_AT" >&2; exit 1; }

# 1 · database dump (overwritten; restic keeps the versions). The credentials go in a 600 file, never on the command line.
# --single-transaction reads one consistent state without locking the site: a file uploaded after it is only an extra in filedir.
CNF=$(mktemp)
moodle_config '
  $o = (array) ($CFG->dboptions ?? []);
  $q = fn($v) => "\"" . addcslashes((string) $v, "\\\"") . "\"";
  echo "[client]\nuser=", $q($CFG->dbuser), "\npassword=", $q($CFG->dbpass), "\n";
  if (!empty($o["dbsocket"]) && is_string($o["dbsocket"])) echo "socket=", $q($o["dbsocket"]), "\n";
  else { echo "host=", $q($CFG->dbhost), "\n"; if (!empty($o["dbport"])) echo "port=", (int) $o["dbport"], "\n"; }
' > "$CNF"
mysqldump --defaults-extra-file="$CNF" --single-transaction --quick --no-tablespaces \
  --default-character-set=utf8mb4 --result-file="$DUMP" "$DB"
chmod 600 "$DUMP"

# 2 · snapshot: 'moodle' tag for the daily one, 'milestone' + label for a milestone
if [ -n "$MILESTONE" ]; then TAGS=(--tag milestone --tag "$MILESTONE"); else TAGS=(--tag moodle --quiet); fi
restic backup "$APP" "$DATA" "$DUMP" \
  --exclude="$DATA/cache" \
  --exclude="$DATA/localcache" \
  --exclude="$DATA/sessions" \
  --exclude="$DATA/temp" \
  --exclude="$DATA/trashdir" \
  --exclude="$DATA/lock" \
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

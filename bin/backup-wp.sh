#!/bin/bash
# tekne-bkp — backup of a WordPress site with restic: database dump + snapshot.
# Set up ~/.restic-env (see .restic-env.example) and run from cron.
# Usage: backup-wp.sh                      daily backup: 'wordpress' snapshot, retention, log and heartbeat
#        backup-wp.sh --milestone <label>  'milestone' snapshot before a risky change; retention keeps it.
#                                          Only dump + snapshot: no retention, log, heartbeat or email, so it never hides a cron failure.
# Docs: docs/backup.md
set -Eeuo pipefail

source "${RESTIC_ENV:-$HOME/.restic-env}"
# cron starts a job with /usr/bin:/bin alone: restic and wp live in ~/bin or in /usr/local/bin
export PATH="$HOME/bin:/usr/local/bin:$PATH"

MILESTONE=
case "${1:-}" in
  '') ;;
  --milestone) MILESTONE="${2:?usage: backup-wp.sh --milestone <label>   e.g. pre-update-wp-plugins}" ;;
  *) echo "usage: backup-wp.sh [--milestone <label>]" >&2; exit 2 ;;
esac

APP="${WP_PATH:?set WP_PATH in ${RESTIC_ENV:-$HOME/.restic-env}: the WordPress folder}"
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
    printf 'The backup of %s failed: no new snapshot is guaranteed.\n\nFailed at: %s\nScript: backup-wp.sh\nHost: %s\nDate: %s\n' \
      "$site" "${FAILED_AT:-unknown}" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %Z')" |
      mail -s "${EMAIL_SUBJECT_PREFIX:-[BACKUP]} ${site^^} - Backup FAILED" ${EMAIL_FROM:+-r "$EMAIL_FROM"} "$to"
  done
}
FAILED_AT=
trap 'FAILED_AT="line $LINENO: $BASH_COMMAND"' ERR
trap 'if [ $? -ne 0 ]; then ping_monitor /fail || true; email_failure || true; fi' EXIT

# 1 · database dump (overwritten; restic keeps the versions)
cd "$APP"
wp db export "$DUMP" --quiet

# 2 · snapshot: 'wordpress' tag for the daily one, 'milestone' + label for a milestone
if [ -n "$MILESTONE" ]; then TAGS=(--tag milestone --tag "$MILESTONE"); else TAGS=(--tag wordpress --quiet); fi
restic backup "$APP" "$DUMP" \
  --exclude="wp-content/cache" \
  --exclude="wp-content/upgrade" \
  --exclude="wp-content/upgrade-temp-backup" \
  --exclude="wp-content/uploads/tmp" \
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

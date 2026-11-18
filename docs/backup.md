---
title: Backup
group: Guides
summary: the daily backup, milestones, restore, retention, the heartbeat and the email on failure
order: 2
---

# Backup

`backup-wp.sh` runs from cron once a day:

1. Exports the database with `wp db export` to a single dump, overwritten on each run: restic keeps the versions.
2. Takes a restic snapshot of the WordPress folder and the dump, tagged `wordpress`, without caches and temporary files.
3. Applies the [retention](#retention) and prunes.
4. Writes `<date> OK` to `BACKUP_LOG` and pings the [heartbeat](#monitoring).

The restic repository lives in S3-compatible object storage. Paths, repository and secrets come from `~/.restic-env`: [Configuration](./configuration.md).

## Commands

Every manual `restic` command loads the environment first:

```bash
source ~/.restic-env
```

| To | Command |
|---|---|
| back up now | `~/bin/backup-wp.sh` |
| list snapshots | `restic snapshots --compact` |
| list milestones | `restic snapshots --tag milestone` |
| check integrity | `restic check` |
| see what retention would remove | `restic forget --keep-daily 7 --keep-weekly 16 --keep-monthly 12 --keep-tag milestone --dry-run` |

## Milestone

A snapshot tagged `milestone` and a label, before a WordPress or plugin update or a migration. Retention keeps it forever.

```bash
~/bin/backup-wp.sh --milestone pre-update-wp-plugins
```

A milestone takes the same dump and the same snapshot as the daily backup, and stops there: no retention, no `OK` line in the log, no heartbeat and no email, so a milestone on a day the cron failed never hides the failure.

## Restore

Restore to a separate folder and move what you need; never restore straight over the site.

The database dump of a snapshot, and its import:

```bash
restic restore <ID> --target /tmp/restore --include "$DB_DUMP"
cd "$WP_PATH" && wp db import "/tmp/restore$DB_DUMP"
```

A file or folder:

```bash
restic restore <ID> --target /tmp/restore --include "$WP_PATH/wp-content/uploads/2026/11"
```

Browse the repository as a file system:

```bash
mkdir -p /tmp/restic-mount && restic mount /tmp/restic-mount
```

A full restore that ends in a working site is a [clone to staging from a snapshot](./clone-staging.md#source).

## Retention

| Rule | Keeps |
|---|---|
| `--keep-daily 7` | the last 7 days |
| `--keep-weekly 16` | the last 16 weeks |
| `--keep-monthly 12` | the last 12 months |
| `--keep-tag milestone` | every milestone snapshot |

## Monitoring

With `HEALTHCHECK_URL` set, the backup pings it at the end, and pings `<URL>/fail` when any step fails. The monitor (Better Stack, Healthchecks.io, Cronitor, Uptime Kuma) opens an incident at the failure instead of waiting for a missed ping, and the next good backup resolves it.

To see the alert path work, run once with a configuration that fails:

```bash
sed 's#^export WP_PATH=.*#export WP_PATH="/does-not-exist"#' ~/.restic-env > ~/tmp/env-fail && chmod 600 ~/tmp/env-fail
RESTIC_ENV=~/tmp/env-fail ~/bin/backup-wp.sh; rm ~/tmp/env-fail
~/bin/backup-wp.sh   # the good backup resolves the incident
```

With `EMAIL_ALERT_TO` set, or `EMAIL_TO` without it, a backup that fails also emails each address: the site, the command that failed, the host and the date, through the server's `mail` command. The heartbeat catches a backup that never ran; the email says what broke. The variables: [Configuration](./configuration.md#email).

## Security

- `~/.restic-env` and `~/.restic-password` stay out of git. Losing the repository password makes the backups unrecoverable: keep a copy in a password manager.
- `HEALTHCHECK_URL` carries a token: it lives in `~/.restic-env`, never in a script.

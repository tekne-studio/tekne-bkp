---
title: Cheat sheet
group: Day to day
summary: the commands of every day, for the backup, restic, the zip and staging
order: 1
---

# Cheat sheet

The commands, by what you want to do. Every `restic` command needs the site's environment first:

```bash
source ~/.restic-env
```

`<cms>` is `wp`, `moodle` or `craft`.

## Back up

| To | Command |
|---|---|
| back up now | `~/bin/backup-<cms>.sh` |
| mark a state before a risky change | `~/bin/backup-<cms>.sh --milestone pre-update` |
| see the last runs | `tail ~/logs/backup.log` |
| see what cron printed | `tail -50 ~/logs/backup-cron.log` |
| see the schedule | `crontab -l` |

## Look at the snapshots

| To | Command |
|---|---|
| list them | `restic snapshots --compact` |
| list the milestones | `restic snapshots --tag milestone` |
| see the files of one | `restic ls <ID> \| less` |
| find a file in every snapshot | `restic find "<name>"` |
| compare two | `restic diff <ID> <ID>` |
| see how much the repository holds | `restic stats --mode raw-data` |

## Restore

Always to a separate folder, never straight over the site.

| To | Command |
|---|---|
| restore a file or a folder | `restic restore <ID> --target ~/tmp/restore --include "<full path>"` |
| restore the database dump | `restic restore <ID> --target ~/tmp/restore --include "$DB_DUMP"` |
| import it, WordPress | `cd "$WP_PATH" && wp db import ~/tmp/restore"$DB_DUMP"` |
| import it, Moodle or Craft | `mysql <database> < ~/tmp/restore"$DB_DUMP"` |
| restore a whole site that works | the clone from a snapshot: [Refresh staging](./refresh-staging.md) |

With `DB_DUMP` unset, the dump is `~/backups/<site folder name>.sql`.

## Keep the repository healthy

| To | Command |
|---|---|
| check its integrity | `restic check` |
| see what the retention would remove | `restic forget --keep-daily 7 --keep-weekly 16 --keep-monthly 12 --keep-tag milestone --dry-run` |
| remove one snapshot | `restic forget <ID> --prune` |
| remove a lock a dead restic left | `pgrep -a restic` shows none, then `restic unlock` |
| update restic | `restic self-update` |

Never two restic at once on a server: the second one stops on the repository lock.

## The owner's zip

| To | Command |
|---|---|
| see the plan | `~/bin/zip-site.sh` |
| list the zips, with fresh links | `~/bin/zip-site.sh --list` |
| email the list again | `~/bin/zip-site.sh --email` |
| zip and upload now | `~/bin/zip-site.sh --run` |

## Staging

| To | Command |
|---|---|
| see the plan | `~/bin/clone-staging-<cms>.sh` (WordPress: `clone-staging.sh`) |
| rehearse, writing nothing | `… --dry-run` |
| clone from live production | `… --run` |
| clone from a snapshot | `… --run --snapshot latest` |

## Update the scripts on a server

```bash
cd tekne-bkp && git pull && install -m 755 bin/*.sh ~/bin/ && md5sum bin/*.sh ~/bin/*.sh
```

A script you have not run on this server yet runs first in plan mode, over ssh, from your machine: `ssh <user>@<server> 'bash -s' < bin/<script>`.

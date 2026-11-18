---
title: Backup of a Moodle site
group: Guides
summary: the daily backup of a Moodle site, what goes in the snapshot and how to restore it
order: 3
---

# Backup of a Moodle site

`backup-moodle.sh` runs from cron once a day:

1. Reads `dataroot` and the database credentials from the site's `config.php`: no secret is repeated in `~/.restic-env`.
2. Dumps the database with `mysqldump --single-transaction` to a single dump, overwritten on each run: restic keeps the versions. The site stays up, and the credentials go in a temporary `600` file, never on the command line.
3. Takes a restic snapshot of the Moodle folder, `dataroot` and the dump, tagged `moodle`, without `cache`, `localcache`, `sessions`, `temp`, `trashdir` and `lock`.
4. Applies the [retention](./backup.md#retention) and prunes.
5. Writes `<date> OK` to `BACKUP_LOG` and pings the [heartbeat](./backup.md#monitoring).

The commands, the milestone, the retention, the heartbeat and the security notes are the ones of [Backup](./backup.md), with `backup-moodle.sh` in place of `backup-wp.sh`. The variables: [Configuration](./configuration.md#backup).

## What it needs

- MySQL or MariaDB with InnoDB tables, and `mysqldump` and `php` on the `PATH`.
- A user that reads every file of the Moodle folder and of `dataroot`: one in the web server's group, say. A file it cannot read makes restic end with an error, and the backup stops before the retention, with no `OK` line and with the `/fail` ping: the snapshot exists, without that file.
- The dump is `600`: it holds every user's data.

## Consistency

The dump comes first and reads one state of the database. A file uploaded while the backup runs lands in `filedir`, which Moodle addresses by content hash: the snapshot holds a file the dump does not name yet, and nothing the dump names is missing.

## Milestone

```bash
~/bin/backup-moodle.sh --milestone pre-install-auth-userkey
```

## Restore

Restore to a separate folder and move what you need; never restore straight over the site.

The database dump of a snapshot, and its import into a database of your choosing:

```bash
restic restore <ID> --target /tmp/restore --include "$DB_DUMP"
mysql <database> < "/tmp/restore$DB_DUMP"
```

A course's files live in `filedir` under their content hash: restore the whole `dataroot` together with the dump of the same snapshot.

```bash
restic restore <ID> --target /tmp/restore --include /path/to/moodledata
```

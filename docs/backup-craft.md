---
title: Backup of a Craft site
group: Guides
summary: the daily backup of a Craft CMS site, what goes in the snapshot and how to restore it
order: 3
---

# Backup of a Craft site

`backup-craft.sh` runs from cron once a day:

1. Reads the database credentials from Craft's `.env`: no secret is repeated in `~/.restic-env`. The file is read as text, never sourced.
2. Dumps the database with `mysqldump --single-transaction` to a single dump, overwritten on each run: restic keeps the versions. The site stays up, and the credentials go in a temporary `600` file, never on the command line.
3. Takes a restic snapshot of the site folder and the dump, tagged `craft`, without `storage/runtime`, `storage/logs`, `storage/backups` and `cpresources`: Craft rebuilds the first, second and last, and the snapshot's dump replaces Craft's own.
4. Applies the [retention](./backup.md#retention) and prunes.
5. Writes `<date> OK` to `BACKUP_LOG` and pings the [heartbeat](./backup.md#monitoring).

The commands, the milestone, the retention, the heartbeat, the email on failure and the security notes are the ones of [Backup](./backup.md), with `backup-craft.sh` in place of `backup-wp.sh`. The variables: [Configuration](./configuration.md#backup).

## The site folder

`CRAFT_PATH` is the folder the snapshot takes: the one that holds the web root, the Craft folder and the uploads, whatever their layout.

| Layout | `CRAFT_PATH` | `CRAFT_ENV_FILE` |
|---|---|---|
| Craft's own: `.env`, `craft` and `web/` side by side | the project folder | default, `$CRAFT_PATH/.env` |
| the web root on top, Craft in a folder inside it | the web root | `$CRAFT_PATH/<craft folder>/.env` |

## What it needs

- MySQL or MariaDB, and `mysqldump` on the `PATH`.
- The database in `DB_SERVER`, `DB_PORT`, `DB_DATABASE`, `DB_USER` and `DB_PASSWORD` of the `.env` (Craft 3), or the same keys with the `CRAFT_` prefix (Craft 4 and 5). A `DB_DSN` is not read.
- The dump is `600`: it holds every user's data.

## Milestone

```bash
~/bin/backup-craft.sh --milestone pre-update-craft
```

## Restore

Restore to a separate folder and move what you need; never restore straight over the site.

The database dump of a snapshot, and its import into a database of your choosing:

```bash
restic restore <ID> --target /tmp/restore --include "$DB_DUMP"
mysql <database> < "/tmp/restore$DB_DUMP"
```

A file or folder:

```bash
restic restore <ID> --target /tmp/restore --include "$CRAFT_PATH/<folder>"
```

A restore that ends in a working site is a [clone to staging from a snapshot](./clone-staging-craft.md#source).

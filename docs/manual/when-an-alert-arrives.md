---
title: When an alert arrives
group: Trouble
summary: what to check when a backup or a zip fails, when the monitor alerts and when the owner misses a report
order: 1
---

# When an alert arrives

Three signals say something is wrong: a `Backup FAILED` email, an alert from the heartbeat monitor, and the site's owner asking for a report that did not come. Each one names where to look.

## A backup failed

The email says which command stopped the script, in `Failed at`. Log in to the server and run the backup by hand to see the whole error:

```bash
~/bin/backup-<cms>.sh
```

| `Failed at` names | Usual cause | Do |
|---|---|---|
| `wp db export`, `mysqldump` | the database is down, or its password changed | check the site opens; the credentials come from the site's own config |
| `restic backup` | the storage did not answer, the keys expired, or a file could not be read | `source ~/.restic-env && restic snapshots`; a file the user cannot read still leaves a snapshot, without that file |
| `restic forget` | the repository is locked by another restic | `pgrep -a restic`; with none running, `restic unlock` |
| `mkdir`, `--result-file` | the disk is full | `df -h ~` |
| `curl` | the backup worked and the heartbeat did not answer | check `HEALTHCHECK_URL` |
| a command, and the cron log says `command not found` | cron does not find a tool that your shell finds | put it in `~/bin`, or add a `PATH=` line at the top of the crontab |

The next good backup clears the monitor's incident by itself.

## The monitor alerts and no email came

The backup did not run, or stopped before it could report.

```bash
crontab -l                           # is the line there?
bash -n ~/.restic-env                # does the env file still parse?
tail -50 ~/logs/backup-cron.log      # what did the last run print?
```

A server that was down at the cron hour ran nothing: run the backup by hand.

## The zip failed

| `Failed at` says | Do |
|---|---|
| the bucket did not list | check `ZIP_ENDPOINT`, `ZIP_BUCKET`, `ZIP_REGION` and the keys |
| no database dump | run the backup first: it writes the dump |
| the zip is over 5 GiB | leave more out with `ZIP_EXCLUDE` |
| the upload failed 3 times | run `~/bin/zip-site.sh --run` again |
| disk | free space in `ZIP_TMP` |

Then run it by hand; the owner gets the report of the run that works.

## The owner misses a report

1. Look for a `Backup FAILED` in your inbox from that day.
2. `tail -30 ~/logs/zip-cron.log` on the server.
3. `~/bin/zip-site.sh --list`: is the week's zip in the bucket?
4. Send the list: `~/bin/zip-site.sh --email`.

## Someone needs a file back

[Cheat sheet, Restore](./cheat-sheet.md#restore).

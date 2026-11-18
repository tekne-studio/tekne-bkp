---
title: Zip for the site's owner
group: Guides
summary: zip-site.sh uploads one zip of the site folder and the database dump, keeps the last ones and emails a signed link to each
order: 5
---

# Zip for the site's owner

`zip-site.sh` makes the copy a person opens without restic: one zip with the site folder and the database dump, in S3-compatible storage, with a download link by email. restic keeps the history; the zip is the convenience. It serves a WordPress or a Craft site; a Moodle with its `moodledata` is too large for one zip.

Without an argument, the script only prints the plan:

```bash
~/bin/zip-site.sh           # plan: what goes in the zip, where it goes, what the retention deletes
~/bin/zip-site.sh --run     # zips, uploads, applies the retention and emails the report
~/bin/zip-site.sh --list    # the zips in the bucket, each with a signed link
~/bin/zip-site.sh --email   # emails the list, with new links
```

Without installing, from a local checkout, over ssh:

```bash
ssh <user>@<server> 'bash -s' < bin/zip-site.sh
```

It runs from cron after the backup, which writes the dump it zips:

```
0 4 * * * $HOME/bin/backup-wp.sh >> $HOME/logs/backup-cron.log 2>&1
30 4 * * 0 $HOME/bin/zip-site.sh --run >> $HOME/logs/zip-cron.log 2>&1
```

The variables: [Configuration](./configuration.md#zip).

## What it does

1. Zips the site folder (`WP_PATH` or `CRAFT_PATH`) and the dump (`DB_DUMP`) into `<name>--YYYY-MM-DD--HH-MM.zip`, in `ZIP_TMP`, without what `ZIP_EXCLUDE` names. Inside the zip, the dump sits beside the site folder.
2. Uploads it to `<name>/` in the bucket, in one request signed with its SHA-256, and checks its size there.
3. Deletes the zips older than `ZIP_KEEP_DAYS`, always keeping the newest `ZIP_KEEP_MIN`. The date comes from the file name.
4. Emails the report to `EMAIL_TO`: status, duration, the new zip and every zip in the bucket with a signed link. A run that fails emails `FAILED`, with the command that failed, to `EMAIL_ALERT_TO`: the site's owner gets only the reports, and a week without one is their sign to ask.

A zip goes up to 5 GiB, the limit of one upload; above it the script stops before uploading.

## Signed links

The bucket is private. Each link carries a signature that works for `ZIP_LINK_DAYS` (7, the longest the storage accepts); the file itself is a plain zip. Every report and every `--list` signs all the links again: with a weekly run, the last email always opens every zip in the bucket.

The zip holds the site's secrets (`wp-config.php` or `.env`) and the whole database: a public bucket would hand them to whoever guesses a file name.

## Exclude patterns

`ZIP_EXCLUDE` is space-separated, relative to the site folder, in `zip`'s own syntax, where `*` also crosses `/`:

| Pattern | Leaves out |
|---|---|
| `.git/*` | the repository at the top of the site folder |
| `wp-content/cache/*` | one folder |
| `*/cache/*` | every `cache` folder below the top level |

## What it needs

`zip`, `curl`, `php`, `sha256sum`, `flock` and, to send email, a `mail` command that delivers. PHP signs the requests (Signature Version 4): every WordPress and Craft server has it, and the secret key reaches it through the environment, never on a command line.

On Backblaze B2, set the bucket's lifecycle to keep only the last version of a file: a deleted zip then leaves the bucket a day later.

## Restore

Unzip to a separate folder: the site folder and `<site>.sql` come out side by side. Import the dump into a database of your choosing with `mysql <database> < <site>.sql`.

---
title: Send the owner a zip
group: Day to day
summary: turn on the weekly zip for a site's owner, send the links again and choose who gets which email
order: 3
---

# Send the owner a zip

A site's owner gets an email each week with a link to download the whole site: the files and the database in one zip. It serves a WordPress or a Craft site. How it works inside: [Zip for the site's owner](../zip-site.md).

## Turn it on

1. **Create a private bucket** in the storage, or use the one that holds the restic repository. On Backblaze B2, set its lifecycle to keep only the last version of a file.
2. **Fill in the env file**: `ZIP_ENDPOINT`, `ZIP_BUCKET`, and `ZIP_REGION` when the endpoint names one. [The variables](../configuration.md#zip).
3. **Choose who gets what:**

   ```bash
   export EMAIL_TO="you@example.org owner@example.org"   # the weekly report, with the links
   export EMAIL_ALERT_TO="you@example.org"               # the failures
   ```

4. **Read the plan**, then run once by hand:

   ```bash
   ~/bin/zip-site.sh
   ~/bin/zip-site.sh --run
   ```

5. **Schedule it** after the backup, which writes the database dump the zip takes:

   ```
   30 4 * * 0 $HOME/bin/zip-site.sh --run >> $HOME/logs/zip-cron.log 2>&1
   ```

## What each person sees

| Who | Gets |
|---|---|
| everyone in `EMAIL_TO` | `[BACKUP] <SITE> - Backup SUCCESS`: the new zip, its size and every zip in the bucket, each with a link |
| everyone in `EMAIL_ALERT_TO` | `[BACKUP] <SITE> - Backup FAILED`: the command that failed |

A link works for 7 days. The next report brings new links to every zip, the old ones included.

## Common questions

**The owner's link does not open.** It is older than 7 days. Send the list again: `~/bin/zip-site.sh --email`.

**The owner got no report this week.** A failed run emails only `EMAIL_ALERT_TO`: look at your own inbox, then at [When an alert arrives](./when-an-alert-arrives.md#the-zip-failed).

**I need a link right now.** `~/bin/zip-site.sh --list` prints one for each zip.

**How many zips are kept?** Those newer than `ZIP_KEEP_DAYS`, and never fewer than `ZIP_KEEP_MIN`. The plan shows what the next run deletes.

**The zip is too big.** One zip goes up to 5 GiB. Leave folders out with `ZIP_EXCLUDE`: [Exclude patterns](../zip-site.md#exclude-patterns).

## The scripts

<!-- generated:usage -->
`zip-site.sh`

```text
zip-site — the download a site's owner opens without restic: one zip with the site folder and the database dump,
uploaded to S3-compatible storage and listed by email with signed links. For a WordPress or a Craft site.
Usage: zip-site.sh [--run | --list | --email]
  Without an argument, prints the plan and exits without changing anything.
Without installing: ssh <user>@<server> 'bash -s' < bin/zip-site.sh
```
<!-- /generated:usage -->

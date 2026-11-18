---
title: Configuration
group: Reference
summary: ~/.restic-env holds a site's values and secrets; every variable the scripts read
order: 1
---

# Configuration

## The env file

A site is its `~/.restic-env` on the server: the restic repository, the secrets and the site's paths, URL and plugins. A WordPress site sets `WP_PATH`, a Moodle site `MOODLE_PATH`, a Craft site `CRAFT_PATH`. The scripts carry no site values; [`.restic-env.example`](https://github.com/tekne-studio/tekne-bkp/blob/master/.restic-env.example) is the template.

- The scripts `source` the file, and the file wins over the environment: `WP_PATH=/other ~/bin/backup-wp.sh` runs with the file's `WP_PATH`. To run with another configuration, point `RESTIC_ENV` at another file: `RESTIC_ENV=~/.restic-env-other-site ~/bin/backup-wp.sh`.
- cron sources the same file: check it with `bash -n ~/.restic-env` after each edit, and keep it at `chmod 600`.
- A missing required variable stops the script with a message naming it.

## restic

| Variable | What it is |
|---|---|
| `RESTIC_REPOSITORY` | the repository, like `s3:https://<endpoint>/<bucket>` |
| `RESTIC_PASSWORD_FILE` | the repository password file, `~/.restic-password` |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | the object storage keys |

## Backup

| Variable | Default | What it is |
|---|---|---|
| `WP_PATH` | required by `backup-wp.sh` | the production WordPress folder |
| `MOODLE_PATH` | required by `backup-moodle.sh` | the production Moodle folder, the one with `config.php`; `dataroot` and the database come from that file |
| `CRAFT_PATH` | required by `backup-craft.sh` | the production site folder: the web root, the Craft folder and the uploads: [The site folder](./backup-craft.md#the-site-folder) |
| `CRAFT_ENV_FILE` | `$CRAFT_PATH/.env` | Craft's `.env`, the home of the database credentials |
| `DB_DUMP` | `~/backups/<site folder name>.sql` | the database dump, and its path inside each snapshot |
| `BACKUP_LOG` | `~/logs/backup.log` | gets `<date> OK` after each daily backup |
| `HEALTHCHECK_URL` | none | the heartbeat URL, pinged at the end and at `<URL>/fail` on failure: [Monitoring](./backup.md#monitoring) |

## Clone to staging, WordPress

| Variable | Default | What it is |
|---|---|---|
| `STAGING_PATH` | required | the staging WordPress folder, with `WP_ENVIRONMENT_TYPE` = `staging` |
| `STAGING_URL` | required | staging's URL, scheme and domain only |
| `CLONE_TMP` | `~/tmp` | where the temporary folder lives |
| `CLONE_DEACTIVATE` | none | plugins deactivated in staging, space-separated: an email or cache plugin, say |
| `CLONE_SKIP_TABLES` | none | tables left out of search-replace, a `--skip-tables` pattern: an audit log, say |
| `CLONE_CLEAN` | none | `wp-content/` folders deleted in staging at the end: a page builder's cache, say |
| `CLONE_ROOT_FILES` | `.user.ini` | web root files copied; empty copies none; on Apache, `.user.ini .htaccess` |
| `CLONE_AFTER` | none | a command run in the staging folder at the end, like a check of the site's own |

## Clone to staging, Moodle

| Variable | Default | What it is |
|---|---|---|
| `MOODLE_PATH` | required | the production Moodle folder |
| `STAGING_PATH` | required | the staging Moodle folder, with a `config.php` of its own that sets `noemailever`: [The target](./clone-staging-moodle.md#the-target) |
| `CLONE_TMP` | `~/tmp` | where the temporary folder lives; with `CLONE_USER`, a folder that user reaches, outside your home |
| `CLONE_USER` | none | the system user that owns the sites' files, like `www-data`: the clone reads and writes the sites as that user, through `sudo -n -u` |
| `CLONE_AFTER` | none | a command run in the staging folder at the end, like the creation of a web service token for staging |

Staging's URL, database and `dataroot` come from its `config.php`.

## Clone to staging, Craft

| Variable | Default | What it is |
|---|---|---|
| `CRAFT_PATH` | required | the production site folder |
| `STAGING_PATH` | required | the staging site folder, deployed by the site's own deploy, with a `.env` of its own: [The target](./clone-staging-craft.md#the-target) |
| `CLONE_SYNC` | none | folders mirrored from production, space-separated and relative to the site folder: the asset volumes, like `web/uploads`; empty clones only the database |
| `CLONE_TMP` | `~/tmp` | where the temporary folder lives |
| `CLONE_AFTER` | none | a command run in the staging folder at the end, like `php craft migrate/all` |

Staging's database and URL come from its `.env`.

## Zip

Read by [`zip-site.sh`](./zip-site.md), for a WordPress or a Craft site.

| Variable | Default | What it is |
|---|---|---|
| `ZIP_ENDPOINT` | required | the storage endpoint, scheme and host only, like `https://s3.example.com` |
| `ZIP_BUCKET` | required | the bucket that holds the zips, private |
| `ZIP_REGION` | `us-east-1` | the region the storage signs with: the one in its endpoint, when it names one |
| `ZIP_ACCESS_KEY_ID`, `ZIP_SECRET_ACCESS_KEY` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | the storage keys, when the zips live in another account than the restic repository |
| `ZIP_NAME` | the site folder's name | the zip's name and its folder in the bucket: `<name>/<name>--YYYY-MM-DD--HH-MM.zip` |
| `ZIP_KEEP_DAYS` | `90` | zips older than this are deleted |
| `ZIP_KEEP_MIN` | `3` | the newest zips kept whatever their age |
| `ZIP_EXCLUDE` | none | what stays out of the zip: [Patterns](./zip-site.md#exclude-patterns) |
| `ZIP_TMP` | `~/tmp` | where the zip is built before the upload |
| `ZIP_LINK_DAYS` | `7` | how long a signed link works, 1 to 7 days |

## Email

| Variable | Default | What it is |
|---|---|---|
| `EMAIL_TO` | none | who gets the reports of `zip-site.sh`, space-separated: the site's owner among them |
| `EMAIL_ALERT_TO` | `EMAIL_TO` | who gets the failures, space-separated: the people who fix them |
| `EMAIL_FROM` | the server's own sender | the sender address, when the server's mail accepts another |
| `EMAIL_SUBJECT_PREFIX` | `[BACKUP]` | the start of every subject |

A backup that fails, or a `zip-site.sh --run` that fails, emails `EMAIL_ALERT_TO` what failed ([Monitoring](./backup.md#monitoring)). Each `zip-site.sh --run` that works emails its report to `EMAIL_TO` ([What it does](./zip-site.md#what-it-does)). A backup that works sends no email: the heartbeat tells that one. With both lists empty, no email goes out.

`CLONE_DEACTIVATE` can stay empty: `no-email.php` blocks `wp_mail()` with or without an email plugin ([What it does](./clone-staging.md#what-it-does)).

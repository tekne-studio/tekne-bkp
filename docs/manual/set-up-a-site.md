---
title: Set up a site
group: Setup
summary: a new site from zero, with restic, the scripts, the env file, the first backup, the cron and the monitor
order: 1
---

# Set up a site

A site gets its backup in nine steps, all as the site's own user on its server, with no root. At the end a snapshot exists, the cron takes one each night and a monitor tells you when it stops.

## Step by step

### 1. Check what the server has

```bash
for c in bash curl php mysqldump mysql rsync flock jq zip mail wp restic; do command -v $c >/dev/null && echo "ok   $c" || echo "MISS $c"; done; bash --version | head -1
```

Every site needs `bash` 4, `curl` and `restic`. A WordPress site needs `wp`; a Moodle or a Craft site, `php`, `mysqldump` and `mysql`. The clone to staging adds `rsync`, `flock` and `jq`; the zip adds `zip` and `php`; every email, a `mail` command that delivers.

### 2. Install restic and the scripts

restic is one binary. Take the current version from [restic's releases](https://github.com/restic/restic/releases) and put it in `~/bin`:

```bash
mkdir -p ~/bin ~/tmp ~/backups
curl -L https://github.com/restic/restic/releases/download/v0.18.1/restic_0.18.1_linux_amd64.bz2 | bunzip2 > ~/bin/restic
chmod +x ~/bin/restic && ~/bin/restic version
```

The scripts, from a clone on the server:

```bash
git clone https://github.com/tekne-studio/tekne-bkp.git
install -m 755 tekne-bkp/bin/*.sh ~/bin/
```

Or from your machine, one script at a time, comparing the checksum with the repo's:

```bash
scp bin/backup-wp.sh <user>@<server>:bin/ && ssh <user>@<server> 'chmod 755 ~/bin/backup-wp.sh; md5sum ~/bin/backup-wp.sh'
```

### 3. Write the env file

```bash
cp tekne-bkp/.restic-env.example ~/.restic-env && chmod 600 ~/.restic-env
```

Fill in the repository, the storage keys and the site's folder: `WP_PATH`, `MOODLE_PATH` or `CRAFT_PATH`, one of the three. Every variable: [Configuration](../configuration.md). After each edit:

```bash
bash -n ~/.restic-env   # cron sources this file: a syntax error stops every backup
```

### 4. Create the repository

```bash
head -c 32 /dev/urandom | base64 > ~/.restic-password && chmod 600 ~/.restic-password
source ~/.restic-env && restic init
```

Copy `~/.restic-password` to a password manager now: without it no snapshot opens again.

### 5. Take the first backup by hand

```bash
~/bin/backup-wp.sh          # or backup-moodle.sh, backup-craft.sh
restic snapshots --compact
tail -1 ~/logs/backup.log   # <date> OK
```

On a host where `~/logs` belongs to the system, set `BACKUP_LOG` to a file in a folder of yours, like `~/backups/backup.log`.

### 6. Schedule it

`crontab -e`, at an hour the site is quiet:

```
0 4 * * * $HOME/bin/backup-wp.sh >> $HOME/logs/backup-cron.log 2>&1
```

cron starts a job with `/usr/bin:/bin` alone. The scripts add `~/bin` and `/usr/local/bin`; a tool that lives anywhere else needs a `PATH=` line at the top of the crontab. The day after, check that the scheduled run wrote its `OK` line: a backup that works by hand can still fail from cron.

### 7. Add the monitor

Create a heartbeat monitor that expects one ping a day (Better Stack, Healthchecks.io, Cronitor, Uptime Kuma), paste its URL in `HEALTHCHECK_URL` and run the backup once more: the monitor turns green. How to see the alert work: [Monitoring](../backup.md#monitoring).

### 8. Add the failure email

Set `EMAIL_ALERT_TO` to your address: a backup that fails emails the command that failed. [Email](../configuration.md#email).

### 9. Turn on what the site needs

- A download for the site's owner: [Send the owner a zip](./send-the-zip.md).
- A staging that matches production: [Refresh staging](./refresh-staging.md).

## Common questions

**The server has no `git`.** Copy the scripts with `scp`, as in step 2.

**Two sites on one server.** Each has its own env file, restic repository and cron line, at different hours: `RESTIC_ENV=~/.restic-env-other ~/bin/backup-wp.sh`.

**restic is old.** `restic self-update` replaces the binary in `~/bin`.

## The scripts

<!-- generated:usage -->
`backup-wp.sh`

```text
tekne-bkp — backup of a WordPress site with restic: database dump + snapshot.
Set up ~/.restic-env (see .restic-env.example) and run from cron.
Usage: backup-wp.sh                      daily backup: 'wordpress' snapshot, retention, log and heartbeat
       backup-wp.sh --milestone <label>  'milestone' snapshot before a risky change; retention keeps it.
                                         Only dump + snapshot: no retention, log, heartbeat or email, so it never hides a cron failure.
```

`backup-moodle.sh`

```text
tekne-bkp — backup of a Moodle site with restic: database dump + snapshot of the code and of moodledata.
Set up ~/.restic-env (see .restic-env.example) and run from cron.
Usage: backup-moodle.sh                      daily backup: 'moodle' snapshot, retention, log and heartbeat
       backup-moodle.sh --milestone <label>  'milestone' snapshot before a risky change; retention keeps it.
                                             Only dump + snapshot: no retention, log, heartbeat or email, so it never hides a cron failure.
```

`backup-craft.sh`

```text
tekne-bkp — backup of a Craft CMS site with restic: database dump + snapshot of the site folder.
Set up ~/.restic-env (see .restic-env.example) and run from cron.
Usage: backup-craft.sh                      daily backup: 'craft' snapshot, retention, log and heartbeat
       backup-craft.sh --milestone <label>  'milestone' snapshot before a risky change; retention keeps it.
                                            Only dump + snapshot: no retention, log, heartbeat or email, so it never hides a cron failure.
```
<!-- /generated:usage -->

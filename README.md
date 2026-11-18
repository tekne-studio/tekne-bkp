# tekne-bkp

Backup of WordPress, Moodle and Craft sites with [restic](https://restic.net): database dump + incremental snapshot of the files, automatic retention, heartbeat monitoring and an email when a backup fails. It also clones production to staging, from the live site or from a snapshot, and uploads a zip of the site for its owner, with signed download links by email.

The scripts carry no site values: what belongs to a site lives in the server's `~/.restic-env`.

| Script | What it does | Docs |
|---|---|---|
| `bin/backup-wp.sh` | daily backup from cron, and a `--milestone <label>` snapshot before a risky change | [Backup](docs/backup.md) |
| `bin/backup-moodle.sh` | the same backup for a Moodle site: code, `moodledata` and the database | [Backup of a Moodle site](docs/backup-moodle.md) |
| `bin/backup-craft.sh` | the same backup for a Craft site: the site folder and the database | [Backup of a Craft site](docs/backup-craft.md) |
| `bin/clone-staging-craft.sh` | brings production's database and upload folders to a staging Craft; the code stays staging's own | [Clone to staging, Craft](docs/clone-staging-craft.md) |
| `bin/clone-staging-moodle.sh` | makes a staging Moodle match production: code, `moodledata` and database, with no email going out and no production token | [Clone to staging, Moodle](docs/clone-staging-moodle.md) |
| `bin/clone-staging.sh` | makes staging match production: database, plugins, uploads and languages, with no email going out | [Clone to staging](docs/clone-staging.md) |
| `bin/zip-site.sh` | one zip of the site folder and the dump in object storage, the last ones kept, a signed link to each by email; WordPress or Craft | [Zip for the site's owner](docs/zip-site.md) |

The manual, with the setup step by step, a cheat sheet and what to do when an alert arrives: **[tekne-studio.github.io/tekne-bkp](https://tekne-studio.github.io/tekne-bkp/)**. Every variable: [Configuration](docs/configuration.md).

## Requirements

Linux with GNU coreutils (`numfmt`, `du -sb`, `df --output`, `stat -c`, `realpath -m`) and bash 4. In `~/bin`, in `/usr/local/bin` or on cron's `PATH`, no root needed: `restic`, `wp`, `rsync`, `flock`, `jq`, `php`, `curl`. A Moodle site needs `restic`, `php`, `mysqldump`, `mysql`, `rsync`, `flock`, `jq` and `curl`; a Craft site, the same. `zip-site.sh` needs `zip`, `php`, `curl`, `sha256sum` and `flock`, and every email a `mail` command that delivers.

## Install

```bash
git clone https://github.com/tekne-studio/tekne-bkp.git
install -m 755 tekne-bkp/bin/*.sh ~/bin/
```

Set up the environment (once), with the repository, the keys and the site's paths:

```bash
cp tekne-bkp/.restic-env.example ~/.restic-env && chmod 600 ~/.restic-env
bash -n ~/.restic-env   # after each edit: cron sources this file
```

Create the restic repository password and initialize the repository (once):

```bash
head -c 32 /dev/urandom | base64 > ~/.restic-password && chmod 600 ~/.restic-password
source ~/.restic-env && restic init
```

Schedule the daily backup (`crontab -e`, 04:00):

```
0 4 * * * $HOME/bin/backup-wp.sh >> $HOME/logs/backup-cron.log 2>&1
```

A Moodle site schedules `backup-moodle.sh` the same way, and a Craft site `backup-craft.sh`. The zip runs after the backup: [Zip for the site's owner](docs/zip-site.md).

## Working on this repo

The site is VitePress over `docs/`: `bun install`, then `bun run docs:dev` serves it, and a push to `master` publishes it to GitHub Pages. The manual lives in `docs/manual/`. A pull request runs the lint of the scripts and the site's build.

## License

[MIT](LICENSE)

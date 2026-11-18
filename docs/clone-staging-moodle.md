---
title: Clone to staging, Moodle
group: Guides
summary: clone-staging-moodle.sh makes a staging Moodle match production, from the live site or a restic snapshot, with no email going out and no production token
order: 4
---

# Clone to staging, Moodle

`clone-staging-moodle.sh` makes a staging Moodle match production: code, `moodledata` and database, with no email going out. The movement is always production to staging: a plugin is tried in staging and installed in production, and the next clone brings it back. Paths come from `~/.restic-env`: [Configuration](./configuration.md#clone-to-staging-moodle).

Without an argument, the script only prints the plan. `--dry-run` dumps the database to a temporary folder and runs rsync with `--dry-run`; `--run` clones:

```bash
~/bin/clone-staging-moodle.sh                           # plan: source, target, sizes and what leaves staging
~/bin/clone-staging-moodle.sh --dry-run                 # reads the source, writes nothing to staging
~/bin/clone-staging-moodle.sh --run                     # clones from live production
~/bin/clone-staging-moodle.sh --run --snapshot latest   # clones from a snapshot (latest or an ID)
```

Without installing, from a local checkout, over ssh:

```bash
ssh <user>@<server> 'bash -s -- --dry-run' < bin/clone-staging-moodle.sh
```

The first run copies all of `moodledata`; the next ones, only the difference.

## The target

Staging is set up once, by hand, and the clone never creates it:

- a folder for the code and one for `moodledata`, owned by the web server's user, and a virtual host for staging's domain;
- an empty database with a user of its own, with every privilege on that database only;
- a `config.php` in the code folder, written for staging and never copied from production: staging's `wwwroot`, `dataroot`, database and user, production's `prefix`, and `$CFG->noemailever = true;`.

`noemailever` in `config.php` is what makes a Moodle a staging target: it stops every email whatever the database says, and the clone refuses a target without it. No cron runs Moodle's scheduled tasks in staging.

## Source

| | Source | Use |
|---|---|---|
| `--run` | live production | day to day: staging with today's content, rsync copies only the difference |
| `--run --snapshot latest\|<ID>` | a restic snapshot | an older state (a milestone, say), or proof that the backup restores to a working site |

From a snapshot, the script restores the dump, the code and `moodledata` to a temporary folder first, so it needs as much free disk as production takes. It aborts when a restic or a backup is running, and during the hour before and the hour of the backup cron.

## What it does

1. Checks the target and locks against another clone (`flock`, one lock per target).
2. Dumps production's database with `--single-transaction`, read only; or restores the dump, the code and `moodledata` from the snapshot. All of it in a temporary folder in `CLONE_TMP`, deleted at the end.
3. Mirrors the code, without `config.php` and the copies an editor leaves beside it (`config.php.save`, which holds production's database password), and `moodledata`, without `cache`, `localcache`, `sessions`, `temp`, `trashdir` and `lock`, with `rsync --delete`.
4. Swaps the database: drops every table in the target and imports the dump. Deletes the web service tokens, the user keys and the sessions, so nothing that opens production opens the copy. Replaces the URL with Moodle's own `admin/tool/replace/cli/replace.php`: `//<domain>` and its JSON form `\/\/<domain>`, never the bare domain, so the `@<domain>` emails stay. Sets `allowindexing` to 2: no page is offered to search engines.
5. Purges the caches, checks `noemailever`, the tokens and the answer of `/login/index.php`, then runs `CLONE_AFTER`.

## The files' owner

With `CLONE_USER` set, the clone reads the sites, runs rsync and runs Moodle's scripts as that user, through `sudo -n -u`: the files stay owned by the web server's user. The dump, the import and restic run as the user that started the clone. The temporary folder is traversable and not listable, and the dump and the credential files in it are `600`.

## What stays out

- **Production:** the script only reads from it (dump, `SELECT`, the files). It aborts before writing when the target lacks `noemailever`, or has production's folders, database or URL.
- **`config.php`:** the target's own, never overwritten.
- **Caches, sessions and temporary files:** rebuilt in the target.
- **What exists only in staging:** a plugin installed there, a web service token created there. The clone removes them; `CLONE_AFTER` recreates what staging needs after each clone.
- **Login by OAuth 2:** the issuers come with production's return URLs, and login through them fails in staging until someone registers staging's URL with the provider.

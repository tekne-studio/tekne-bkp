---
title: Clone to staging, Craft
group: Guides
summary: clone-staging-craft.sh brings production's database and upload folders to a staging Craft, from the live site or a restic snapshot; the code stays staging's own
order: 4
---

# Clone to staging, Craft

`clone-staging-craft.sh` brings production's data to a staging Craft: the database and the upload folders. The code stays staging's own, because it comes from the site's deploy: a clone that copied code would undo the deploy under test. Paths come from `~/.restic-env`: [Configuration](./configuration.md#clone-to-staging-craft).

Without an argument, the script only prints the plan. `--dry-run` dumps the database to a temporary folder and runs rsync with `--dry-run`; `--run` clones:

```bash
~/bin/clone-staging-craft.sh                           # plan: source, target, sizes and what leaves staging
~/bin/clone-staging-craft.sh --dry-run                 # reads the source, writes nothing to staging
~/bin/clone-staging-craft.sh --run                     # clones from live production
~/bin/clone-staging-craft.sh --run --snapshot latest   # clones from a snapshot (latest or an ID)
```

Without installing, from a local checkout, over ssh:

```bash
ssh <user>@<server> 'bash -s -- --dry-run' < bin/clone-staging-craft.sh
```

## The target

Staging is set up once, by the site's own deploy, and the clone never creates it:

- the site folder, with the code of the branch under test;
- an empty database with a user of its own;
- a `.env` at the same place inside the folder as production's, with staging's database and URL and production's `DB_TABLE_PREFIX`.

The clone refuses a target that is production's folder, uses production's database or has production's `PRIMARY_SITE_URL`.

A staging that must send no email sets `testToEmailAddress` in its `config/general.php`, or `CRAFT_TEST_TO_EMAIL_ADDRESS` in its `.env` on Craft 4 and 5: every message then goes to that address. Without it the clone warns and goes on.

## Source

| | Source | Use |
|---|---|---|
| `--run` | live production | day to day: staging with today's content, rsync copies only the difference |
| `--run --snapshot latest\|<ID>` | a restic snapshot | an older state (a milestone, say), or proof that the backup restores to a working site |

From a snapshot, the script restores the dump and the folders of `CLONE_SYNC` to a temporary folder first. It aborts when a restic or a backup is running, and during the hour before and the hour of the backup cron.

## What it does

1. Checks the target and locks against another clone (`flock`, one lock per target).
2. Dumps production's database with `--single-transaction`, read only; or restores the dump and the folders from the snapshot. All of it in a temporary folder in `CLONE_TMP`, deleted at the end.
3. Mirrors each folder of `CLONE_SYNC` with `rsync --delete`: the asset volumes and other uploads, relative to the site folder.
4. Swaps the database: drops every table in the target, imports the dump and deletes the sessions, so a session that opens production does not open the copy.
5. Runs `craft clear-caches/all` in the target, checks the answer of `PRIMARY_SITE_URL`, then runs `CLONE_AFTER`.

## What stays out

- **Production:** the script only reads from it (dump, `SELECT`, the files).
- **The code, the `.env` and the config:** staging's own, never overwritten. URLs come from staging's `.env`, so the database needs no replacement.
- **A schema ahead of or behind the code:** `CLONE_AFTER` runs the site's own command after each clone, like `php craft migrate/all` or `php craft project-config/apply`.
- **Folders outside `CLONE_SYNC`:** untouched. With `CLONE_SYNC` empty, only the database is cloned.

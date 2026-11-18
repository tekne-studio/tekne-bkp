---
title: Clone to staging
group: Guides
summary: clone-staging.sh makes staging match production, from the live site or a restic snapshot, with no email going out
order: 3
---

# Clone to staging

`clone-staging.sh` makes staging match production: database, plugins, uploads and languages, with no email going out. The target is a WordPress whose `wp-config.php` defines `WP_ENVIRONMENT_TYPE` as `staging`. Paths, URL and the site's plugins come from `~/.restic-env`: [Configuration](./configuration.md#clone-to-staging-wordpress).

Without an argument, the script only prints the plan. `--dry-run` exports the database to a temporary folder and runs rsync with `--dry-run`; `--run` clones:

```bash
~/bin/clone-staging.sh                           # plan: source, target, sizes and what leaves staging
~/bin/clone-staging.sh --dry-run                 # reads the source, writes nothing to staging
~/bin/clone-staging.sh --run                     # clones from live production
~/bin/clone-staging.sh --run --snapshot latest   # clones from a snapshot (latest or an ID)
```

Without installing, from a local checkout, over ssh:

```bash
ssh <user>@<server> 'bash -s -- --dry-run' < bin/clone-staging.sh
```

The first run copies all uploads; the next ones, only the difference.

## Source

| | Source | Use |
|---|---|---|
| `--run` | live production | day to day: staging with today's content, rsync copies only the difference |
| `--run --snapshot latest\|<ID>` | a restic snapshot | an older state (a milestone, say), or proof that the backup restores to a working site |

From a snapshot, the script restores the dump, `wp-config.php` and the folders to a temporary folder first, so it needs as much free disk as the uploads. It aborts when a restic or a backup is running, and during the hour before and the hour of the backup cron.

## What it does

1. Checks the target and locks against another clone (`flock`, one lock per target).
2. Exports production's database with `--single-transaction`, read only; or restores the dump, `wp-config.php` and the folders from the snapshot. All of it in a temporary folder in `CLONE_TMP`, deleted at the end.
3. Writes `wp-content/mu-plugins/no-email.php` to the target: outside production, `wp_mail()` logs to the PHP error log and returns success without sending. A theme deploy keeps what is in `mu-plugins/`, and every clone writes the file again.
4. Mirrors `plugins/`, `languages/` and `uploads/` with `rsync --delete`, and copies `CLONE_ROOT_FILES`.
5. Swaps the database: drops every table in the target, imports the dump and puts the source prefix in the target's `wp-config.php`, which keeps the rest (credentials, salts, `staging`). Deactivates `CLONE_DEACTIVATE`, sets `blog_public` to 0, deletes the transients and replaces the URLs with `wp search-replace`.
6. Clears cache, transients, `CLONE_CLEAN` and the rewrite rules. Checks the active theme, production's mu-plugins, where `wp_mail()` comes from and staging's answer, then runs `CLONE_AFTER`.

## URLs in search-replace

search-replace swaps `//<domain>` and `//www.<domain>` for staging's domain, and never the bare domain: the `@<domain>` emails stay. It also swaps the JSON form (`\/\/<domain>`, as Yoast stores images) and the encoded one (`%2F%2F<domain>`). It walks every table with the prefix, plugin tables and the `guid` column included, except `CLONE_SKIP_TABLES`; each form goes in only when it appears in those tables in the dump.

## What stays out

- **Production:** the script only reads from it (dump, `SELECT`, `wp option get`). It aborts before writing when the target is not `staging`, or has production's path, database or URL.
- **Code:** `themes/` and `mu-plugins/` arrive with the code deploy. The clone warns when the source's active theme is missing in the target.
- **Caches and temporary files:** the rest of `wp-content/` and `uploads/tmp` are rebuilt in the target.
- **Web root:** only `CLONE_ROOT_FILES`, by default `.user.ini` with the PHP-FPM limits. Production's `robots.txt` would open staging to search engines; without it, WordPress answers `Disallow: /` with `blog_public` at 0.

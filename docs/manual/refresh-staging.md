---
title: Refresh staging
group: Day to day
summary: make staging match production before a test, and prove that a snapshot restores to a working site
order: 2
---

# Refresh staging

Before trying an update or a new feature, staging gets production's content. The same command, pointed at a snapshot, is the restore test of the backup: it ends in a site you can open.

| Site | Script | What it brings |
|---|---|---|
| WordPress | `clone-staging.sh` | database, plugins, uploads and languages: [Clone to staging](../clone-staging.md) |
| Moodle | `clone-staging-moodle.sh` | code, `moodledata` and database: [Clone to staging, Moodle](../clone-staging-moodle.md) |
| Craft | `clone-staging-craft.sh` | database and upload folders; the code stays staging's own: [Clone to staging, Craft](../clone-staging-craft.md) |

## Step by step

1. **Read the plan.** With no argument the script changes nothing: it prints the source, the target, the sizes and what leaves staging.

   ```bash
   ~/bin/clone-staging.sh
   ```

2. **Rehearse.** `--dry-run` reads production and runs rsync without writing.

   ```bash
   ~/bin/clone-staging.sh --dry-run
   ```

3. **Clone.**

   ```bash
   ~/bin/clone-staging.sh --run
   ```

4. **Open staging** and check what you came to test. The script ends with the answer of staging's URL and a list of warnings, when there are any.

## The restore test

```bash
~/bin/clone-staging.sh --run --snapshot latest
```

It restores the snapshot to a temporary folder and clones from there. Staging opening with yesterday's content is the proof that the backup restores. Run it outside the backup's hour: the script refuses while a restic or a backup runs.

## Common questions

**What do I lose in staging?** Its database, always, and whatever the plan lists under "Leaves staging". Its configuration file stays.

**Does staging send email?** A WordPress and a Moodle staging send none: the clone refuses a target that could. A Craft staging sends unless its config sets `testToEmailAddress`, and the clone warns about it.

**The clone stopped halfway.** Run it again: each step starts from production.

## The scripts

<!-- generated:usage -->
`clone-staging.sh`

```text
clone-staging — makes staging match production: database, plugins, uploads and languages, with no email going out.
The source is live production or a restic snapshot; the target must define WP_ENVIRONMENT_TYPE = staging.
Usage: clone-staging.sh [--dry-run | --run] [--snapshot latest|<ID>]
  Without --dry-run or --run, prints the plan and exits without changing anything.
Without installing: ssh <user>@<server> 'bash -s -- --dry-run' < bin/clone-staging.sh
```

`clone-staging-moodle.sh`

```text
clone-staging-moodle — makes a staging Moodle match production: code, moodledata and database, with no email going out.
The source is live production or a restic snapshot; the target keeps its own config.php, which must set noemailever.
Usage: clone-staging-moodle.sh [--dry-run | --run] [--snapshot latest|<ID>]
  Without --dry-run or --run, prints the plan and exits without changing anything.
Without installing: ssh <user>@<server> 'bash -s -- --dry-run' < bin/clone-staging-moodle.sh
```

`clone-staging-craft.sh`

```text
clone-staging-craft — brings production's data to a staging Craft: the database and the upload folders.
The code stays staging's own: it comes from the site's deploy, and so do its .env, its config and its URL.
The source is live production or a restic snapshot.
Usage: clone-staging-craft.sh [--dry-run | --run] [--snapshot latest|<ID>]
  Without --dry-run or --run, prints the plan and exits without changing anything.
Without installing: ssh <user>@<server> 'bash -s -- --dry-run' < bin/clone-staging-craft.sh
```
<!-- /generated:usage -->

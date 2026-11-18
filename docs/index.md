---
title: tekne-bkp
summary: the site's home, with the manual and the technical docs
layout: home
hero:
  name: tekne-bkp
  text: Backups a person can restore
  tagline: A database dump and a restic snapshot per site, a clone of production to staging, and a zip for the site's owner. For WordPress, Moodle and Craft.
  actions:
    - theme: brand
      text: Manual
      link: /manual/
    - theme: alt
      text: Set up a site
      link: /manual/set-up-a-site
    - theme: alt
      text: GitHub
      link: https://github.com/tekne-studio/tekne-bkp
features:
  - title: Backup
    details: One script per CMS, run from cron. Retention, milestones before a risky change, a heartbeat and an email when it fails.
    link: /backup
  - title: Clone to staging
    details: From live production or from a snapshot, which makes it the restore test of the backup.
    link: /clone-staging
  - title: Zip for the owner
    details: The whole site in one zip in a private bucket, with a signed download link by email each week.
    link: /zip-site
---

## The docs

How each script works and every variable it reads.

<!-- generated:docs -->
### Guides

| Page | Contents |
|---|---|
| [Backup](./backup.md) | the daily backup, milestones, restore, retention, the heartbeat and the email on failure |
| [Backup of a Craft site](./backup-craft.md) | the daily backup of a Craft CMS site, what goes in the snapshot and how to restore it |
| [Backup of a Moodle site](./backup-moodle.md) | the daily backup of a Moodle site, what goes in the snapshot and how to restore it |
| [Clone to staging](./clone-staging.md) | clone-staging.sh makes staging match production, from the live site or a restic snapshot, with no email going out |
| [Clone to staging, Craft](./clone-staging-craft.md) | clone-staging-craft.sh brings production's database and upload folders to a staging Craft, from the live site or a restic snapshot; the code stays staging's own |
| [Clone to staging, Moodle](./clone-staging-moodle.md) | clone-staging-moodle.sh makes a staging Moodle match production, from the live site or a restic snapshot, with no email going out and no production token |
| [Zip for the site's owner](./zip-site.md) | zip-site.sh uploads one zip of the site folder and the database dump, keeps the last ones and emails a signed link to each |

### Reference

| Page | Contents |
|---|---|
| [Configuration](./configuration.md) | ~/.restic-env holds a site's values and secrets; every variable the scripts read |
<!-- /generated:docs -->

---
title: Manual
summary: how to set up a site, run the scripts day to day and act on an alert
layout: home
hero:
  name: tekne-bkp
  text: The manual
  tagline: Set up a site, run the scripts day to day, act on an alert.
features:
  - title: Setup
    details: A new site from zero, from restic to the cron.
    link: /manual/set-up-a-site
  - title: Day to day
    details: The commands you forget, a fresh staging and the owner's download.
    link: /manual/cheat-sheet
  - title: Trouble
    details: What to check when a failure email or a monitor alert arrives.
    link: /manual/when-an-alert-arrives
---

## Who is who

- **The operator** installs the scripts on a site's server, reads the alerts and restores what is asked for. This manual is written for the operator.
- **The site's owner** gets the weekly report with a download link to each zip, and nothing else.

## The main path

1. [Set up a site](./set-up-a-site.md): restic, the env file, the first backup, the cron and the monitor.
2. Each night the backup takes a snapshot; each week, when the site has it on, [the zip goes to the owner](./send-the-zip.md).
3. Before a risky change, a milestone; before a test, [a fresh staging](./refresh-staging.md). The commands: [Cheat sheet](./cheat-sheet.md).
4. When an email or the monitor says a backup failed: [When an alert arrives](./when-an-alert-arrives.md).

How each script works inside lives in the [docs](../backup.md).

## The pages

<!-- generated:pages -->
### Setup

| Page | Contents |
|---|---|
| [Set up a site](./set-up-a-site.md) | a new site from zero, with restic, the scripts, the env file, the first backup, the cron and the monitor |

### Day to day

| Page | Contents |
|---|---|
| [Cheat sheet](./cheat-sheet.md) | the commands of every day, for the backup, restic, the zip and staging |
| [Refresh staging](./refresh-staging.md) | make staging match production before a test, and prove that a snapshot restores to a working site |
| [Send the owner a zip](./send-the-zip.md) | turn on the weekly zip for a site's owner, send the links again and choose who gets which email |

### Trouble

| Page | Contents |
|---|---|
| [When an alert arrives](./when-an-alert-arrives.md) | what to check when a backup or a zip fails, when the monitor alerts and when the owner misses a report |
<!-- /generated:pages -->

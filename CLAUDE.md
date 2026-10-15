# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`contentshell` is the PHP web app that serves and manages offline educational content on RACHEL
devices (see README.md). It is plain PHP 8 + SQLite + jQuery 1.10 — **no package manager, no build
step, no test suite, no linter config**. Files are deployed as-is to the device's webroot. Every
asset is vendored under `js/` and `css/`; the device has no internet, so never introduce a CDN
reference, npm dependency, or build artifact.

## Commands

There is nothing to build. Useful commands:

```bash
# Syntax-check a file before deploying (the only "test" available)
php -l admin/storage.php

# Local preview (webroot must be the repo root)
php -S localhost:8000

# CLI entry points (these require admin/common.php's path detection to succeed)
php installmods.php full dev       # install+sort modules from scripts/full.modules via rsync
php sortmods.php scripts/full.modules  # re-sort/hide only, no install
php admin/do_tasks.php             # drain the task queue (normally auto-spawned)
```

CLI invocations are treated as authorized (`authorized()` returns true when
`php_sapi_name() == "cli"`), so admin scripts run without a login from the shell.

To make the UI render as if on specific hardware, touch a flag file: `/tmp/fake-rachelplus`,
`/tmp/fake-rachelpi`, `/tmp/fake-rachelplusv3`, `/tmp/fake-rachelplusv5`. Note the caveat in
`admin/common.php`: faking a device changes `getAbsModPath()` to a path that doesn't exist locally,
which breaks DB access, so this is only useful for eyeballing device-conditional markup.

## Architecture

### Modules: filesystem is truth, SQLite is an overlay

A "module" is a directory under `modules/` containing a `rachel-index.php` (legacy name:
`index.htmlf`). That file is **an HTML fragment, not a page** — it is `include`d directly into
`index.php`'s `<main>`, and can use `$dir` (the module's relative path) for asset URLs. Its `<h2>`
text becomes the module title and an `<!-- version=vX.Y -->` comment supplies the version; both are
scraped with regexes in `getmods_fs()`.

`getmods_fs()` (filesystem scan) and `getmods_db()` (the `modules` table) are merged on every page
load: the filesystem decides what exists, the database only supplies `position` and `hidden`.
A module directory with no index fragment is listed but force-hidden. `syncmods_fs2db()` reconciles
the two. Consequence: dropping a directory into `modules/` is a complete install; deleting one is a
complete uninstall.

`.modules` files (`scripts/*.modules`) are the portable manifest format — one moddir per line, `#`
comments, leading `.` means "install but hide". `export-modfile.php` emits one describing the
current device; `installmods.php` consumes one.

### The admin stack

Every admin page follows the `admin/minimal.php` template: `require_once("common.php")` →
`if (!authorized()) exit()` → set `$page_title`/`$page_script`/`$page_nav` → `include "head.php"` →
output → `include "foot.php"`.

Only three pages are linked from `admin/nav.php`:

- `admin/storage.php` (~4.7k lines) — "Content Management". A single page with hash-routed tabs
  (`#upload`, `#usb`, `#builder`, `#worldpossible`, `#delete`, `#rearrange`, `#hide`, `#categories`,
  `#quizzes`, `#results`). It self-handles `POST` and `$_FILES` requests at the top of the file
  before emitting HTML, and its JS calls `background.php` for most things.
- `admin/device.php` — "Device Settings", also tabbed (`#password`, `#system`, `#storage`, `#wifi`,
  `#power`, `#sponsor`, `#services`, `#advanced`).
- `admin/stats.php` — "DataPost"; wraps goaccess output from nginx logs.

`admin/install.php` and `admin/version.php` are now just redirects to `storage.php`.

**`admin/modules.php` is not linked from the nav but must not be deleted.** `storage.php`'s
rearrange/reset tab still calls it as a live AJAX endpoint (`?moddirs=`, `?resetdefault=1`,
`?backupdefault=1`). This was deleted once in `f3c8121` and restored in `1f3ca1f`.
`admin/js/upload.js` and `admin/upload_common.php`, by contrast, are orphans from the deleted
`settings.php`/`upload.php`/`process.php` cluster.

### `admin/background.php` is the AJAX backend

~1.9k lines, dispatched by a long `if (isset($_GET['...']))` chain at the top of the file: module
list/install/delete, task queue control, wifi, self-update, battery, stats, visibility, the whole
quiz API, sponsor settings, and the category API. Anything unmatched falls through to a logged 500.
Adding an endpoint means adding a branch to that chain *and* a function below it.

### Files in `admin/js/` are PHP, not static JS

`head.php` does `include "$page_script"` **inside a `<script>` tag**, so `admin/js/modules.js` and
`hardware.js` contain `<?php echo $lang['save_changes'] ?>` interpolations. They are never served as
static files and will not work if linked with `<script src=>`.

### Background task queue

Long-running work (rsync module installs) never runs in the request. `installmods()` inserts rows
into the `tasks` table and shells out to `admin/do_tasks.php &`. That script pid-locks on
`/var/run/rachel_do_tasks.pid`, reads stdout one character at a time to parse rsync progress
(`files_done`, `data_done`, `data_rate`), writes progress to the DB at most every 3 seconds, runs
each module's optional `finish_install.sh`, and calls `kiwix_restart()` when the queue drains. The
UI polls `background.php?getTasks=1`.

### Database

One SQLite file at `getAbsAdminPath() . "/admin.sqlite"`, opened by `getdb()`, which is also where
the **entire schema lives** — `CREATE TABLE IF NOT EXISTS` plus inline `PRAGMA table_info` migrations
run on every single connection. There are no migration files; to add a column, add the table check
and the `ALTER TABLE` guard in `getdb()`. Tables: `modules`, `tasks`, `users`, `uploads`, `prefs`
(key/value, used for sponsor settings and feature toggles), `quizzes`, `quiz_questions`,
`quiz_submissions`, `quiz_answers`, `module_categories`.

Queries are built by string interpolation with `$db->escapeString()`, not prepared statements.
Match the surrounding style (`$db_foo = $db->escapeString($foo)`) rather than mixing idioms.

Auth is a single `admin` user, md5-hashed, with a plain `rachel-auth=admin` cookie set at path `/`.
Do not "improve" this incidentally — it is what the deployed devices expect.

### Hardware and path detection

`admin/common.php` detects the device by probing for directories, since each generation uses a
different content root: `is_rachelpi()` (`/var/www/rachel/modules`), `is_rachelplus()`
(`/media/RACHEL/rachel/modules`), `is_rachelplusv3()` / `is_rachelplusv5()` (`/.data/RACHEL`, v5
distinguished by `CMAL150` in `/etc/issue`). Always reach paths through `getAbsModPath()`,
`getAbsAdminPath()`, `getRelModPath()`, `getRelAdminPath()`, `getAbsBaseUrl()` — these are written to
work from the webroot, from `admin/`, over HTTP, and from the CLI. Several newer files
(`storage.php`, `upload_common.php`, parts of `background.php`) hardcode `/.data/RACHEL/...`
instead; that is v3/v5-only and is a known inconsistency, not a pattern to copy.

`panic-banner.php` (included by `index.php`) and `sda-recover.php` handle the degraded-storage case
where the internal SSD failed and the device booted onto eMMC, flagged by `/.data/.emmc-fallback`.

### World Possible attribution gating

`wp_verify_attribution()` in `admin/common.php` greps `index.php` for the strings "World Possible",
"RACHEL", and "worldpossible". If any are missing, `wp_feature_enabled()` returns false and the
sidebar, category filtering, quiz media upload, USB export, and sponsor customization all disable
themselves (`403` from the relevant `background.php` endpoints). Editing `index.php` in a way that
drops those strings silently breaks a large slice of the UI.

### Categories

Two sources merged at read time: the shipped defaults in `admin/category-map.json` (category
definitions with icon/label/color, plus a large moddir→categories map) and per-module admin
overrides in the `module_categories` table, which win. `index.php` only renders a filter button for
a category that has at least one installed module.

### i18n

`$lang` is a flat array loaded by `common.php` from `admin/lang/lang.{en,es,fr}.php` based on
`Accept-Language`. Keys use underscores so they interpolate inside double-quoted strings
(`"$lang[home]"`). Those files must not contain blank lines outside the PHP block or header control
breaks.

## Deployment reality

The canonical deployment is a physical device (referred to in commit messages as ".100"), and it has
historically drifted ahead of this repo — `ab35aaa` and `1f3ca1f` are both reconciliations of live
changes back into git. Before assuming a file is dead or a behavior is wrong, check the commit
history for whether it was deliberately restored. When reconciling, watch for CRLF→LF normalization
masking a diff as a full-file rewrite.

`css/variables.css` defines a design-token system but is currently referenced by nothing; the actual
styling is inline `<style>` blocks and hardcoded hex values throughout `index.php`, `storage.php`,
and `device.php`.

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
# Syntax-check a file before deploying
php -l admin/storage.php

# Syntax-check everything
find . -name '*.php' -not -path './.git/*' -print0 | xargs -0 -n1 php -l | grep -v '^No syntax errors'

# Black-box access checks against PHP's built-in server (read-only; RACHEL_TEST_PASS
# overrides the default admin password). The login checks fail until the session
# rework in issues.todo lands.
tests/smoke.sh

# Local preview (webroot must be the repo root)
php -S localhost:8000

# CLI entry points (these require admin/common.php's path detection to succeed)
php installmods.php full dev       # install+sort scripts/full.modules via rsync from dev.worldpossible.org (needs network)
php sortmods.php scripts/full.modules  # re-sort/hide only, no install
php admin/do_tasks.php             # drain the task queue (normally auto-spawned; writes /var/run, so needs root)
```

Local PHP is 8.5 while devices run 8.3/8.4, and the built-in server shows warnings inline, so
a deprecation notice here breaks JSON responses even if devices never see it. Keep new code free
of 8.5 deprecations (e.g. use `new finfo()` rather than `finfo_close()`).

CLI invocations are treated as authorized (`authorized()` returns true when
`php_sapi_name() == "cli"`), so admin scripts run without a login from the shell.

### This checkout *is* a RACHEL-Plus as far as the code knows

The repo lives at `/media/RACHEL/rachel`, which is exactly `RACHELPLUS_MODPATH`'s parent, so
`is_rachelplus()` is true on this machine with no flag files. `getAbsModPath()` therefore resolves
to this repo's `modules/`, and `getdb()` opens this repo's `admin/admin.sqlite` — the local UI,
CLI scripts, and module installs all read and write the working tree directly. RACHEL-Plus-only UI
(e.g. the battery meter in `admin/nav.php` polling `getBatteryInfo`) is active locally.

The `/tmp/fake-rachelplusv3` and `/tmp/fake-rachelplusv5` flag files toggle v3/v5-conditional markup
without changing paths. `/tmp/fake-rachelpi` has no path effect here because `is_rachelplus()` is
checked first.

`admin/admin.sqlite` is git-ignored (as are `admin/quiz_uploads/` and `admin/sessions/`); `getdb()`
recreates it with default data when missing. Because this checkout *is* the live data location,
anything you exercise locally (quiz submissions, module installs, the builder) writes to it and to
`modules/`. Back the database up before testing, and remove test modules afterwards.

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

The Content Management "builder" tab (`buildCustomModule()` in `storage.php`) writes new modules
like `modules/FOTA` and `modules/test`: an `index.html`, page files, a logo, and a `rachel-index.php`
that sets `$rachel_title`/`$rachel_description`. Nothing reads those variables; the displayed title
still comes from the `<h2>`.

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
`?backupdefault=1`). Only `moddirs` is actually handled; the other two get the page HTML back.
It was deleted in upstream `f3c8121` and restored in `1f3ca1f`, so grep for callers before treating
an admin file as dead. `admin/js/upload.js` and `admin/upload_common.php`, by contrast, are orphans from the deleted
`settings.php`/`upload.php`/`process.php` cluster.

### `admin/background.php` is the AJAX backend

~1.9k lines, dispatched by a long `if (isset($_GET['...']))` chain at the top of the file: module
list/install/delete, task queue control, wifi, self-update, battery, stats, visibility, the whole
quiz API, sponsor settings, and the category API. Anything unmatched falls through to a logged 500.
Adding an endpoint means adding a branch to that chain *and* a function below it. **Every handler
must `exit` itself**: control returns to the bottom of the chain, which unconditionally logs
"Unknown request" and sends a 500 after any handler that only `return`s.

`background.php` never calls `authorized()`. The student-facing `quiz.php` depends on this, because
it calls `getQuizzes`, `startQuiz`, `checkQuizPassword`, and `submitQuiz` without a login, so a
blanket auth gate at the top would break quizzes. Admin-only endpoints need their own check if one
is added. `storage.php`'s own POST handlers (USB scan/install/export, builder) are behind its
`authorized()` check on line 9.

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

Older code builds queries by string interpolation with `$db->escapeString()`. New or rewritten
code uses the prepared-statement helpers in `common.php` — `db_query()`, `db_row()`, `db_rows()`,
`db_value()`, which take `array(':name' => value)` and throw on errors — so a function can wrap a
transaction in try/catch and `ROLLBACK`. When rewriting a function, convert it wholesale rather
than mixing both styles inside it.

Other shared helpers in `common.php` to reuse rather than reimplement:
- `checked_upload_ext($file, $allowed, $max_bytes)`: validates a `$_FILES` entry against a
  MIME => extension allowlist, reading the type from the content; throws with code 400.
  `media_upload_types()` is the admin media allowlist; `random_filename($ext)` names the file.
- `module_path($moddir)`: absolute path of an existing folder directly inside `modules/`, or
  false. Use it before any filesystem operation on a module name from a request.

Endpoints that validate input throw `Exception($msg, 400)` and map code 400 to
`HTTP/1.1 400 Bad Request`, anything else to 500 with an `error_log()`.

Auth is a single `admin` user, md5-hashed, with a plain `rachel-auth=admin` cookie set at path `/`.
Replacing it is a planned, separate change (tasks at the top of `issues.todo`); don't change it
incidentally while working on something else.

### Hardware and path detection

`admin/common.php` detects the device by probing for directories, since each generation uses a
different content root: `is_rachelpi()` (`/var/www/rachel/modules`), `is_rachelplus()`
(`/media/RACHEL/rachel/modules`), `is_rachelplusv3()` / `is_rachelplusv5()` (`/.data/RACHEL`, v5
distinguished by `CMAL150` in `/etc/issue`). Always reach paths through `getAbsModPath()`,
`getAbsAdminPath()`, `getRelModPath()`, `getRelAdminPath()`, `getAbsBaseUrl()` — these are written to
work from the webroot, from `admin/`, over HTTP, and from the CLI. Some code hardcodes device
paths instead, and these won't exist locally: `storage.php` only accepts USB sources under
`/media/usb*` or `/media/root*`, `background.php`'s stats read `/var/log/nginx/access.log` and
write `/tmp/report.html`, and `device.php` switches its storage partition list on `/.data/RACHEL`.

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

### Other root-level entry points

`listmods.php` (JSON module list from the DB), `export-modfile.php` (emits a `.modules` file),
`captiveportal-redirect.php`, and `quiz.php` (student quiz UI) are web-facing. The `.shtml` files are
`#!/bin/sh` CGI scripts for the device's captive portal, not HTML.

## Relationship to upstream

This is a fork of [worldpossible/contentshell](https://github.com/worldpossible/contentshell). The
`trunk` branch sits on top of upstream `1f3ca1f` (2026-07-13), the `upstream` remote points there,
and the fork itself is the `rachel` remote. To take upstream changes:
`git fetch upstream && git merge upstream/master`. Upstream's July 2026 commits (`f3c8121`,
`ab35aaa`, `1f3ca1f`) reconcile changes made on a live device (".100") back into git, so check
history before assuming a file is dead or a behavior is accidental.

Deliberate local divergences — keep them when merging upstream:

- `admin/storage.php` (`MODULES_DIR`), `admin/upload_common.php`, and `getModuleCategories()` in
  `admin/background.php` use the path helpers instead of upstream's hardcoded `/.data/RACHEL/...`,
  so the code runs on hardware other than a RACHEL 5 (e.g. a Raspberry Pi test unit).
- `modules/en-datapost/rachel-index.php` no longer probes the DataPost API on port 3000. That
  synchronous request blocked the homepage for 60+ seconds whenever the port didn't answer. Every
  module fragment runs inline in `index.php`, so avoid blocking network calls in fragments, or give
  them a short timeout. `en-kolibri-index` still calls Kolibri without one.
- `modules/en-kolibri-index/rachel-index.php` targets Kolibri on port 8080 (upstream: 9090).

The "update contentshell" action (`selfUpdate()` in `background.php`) rsyncs upstream's
`contentshell4` over the webroot with `--del`; on a device it would discard all of the above.

## Styling

`css/variables.css` defines a design-token system but is currently referenced by nothing; the actual
styling is inline `<style>` blocks and hardcoded hex values throughout `index.php`, `storage.php`,
and `device.php`.

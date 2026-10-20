# How contentshell works

This document explains how the files in this repository fit together and how they serve RACHEL's purpose: giving people with no internet access a local library of educational content, a way to manage it, and a way to assess learning.

## 1. RACHEL and this repo

**RACHEL** (Remote Area Community Hotspot for Education and Learning) is an offline server built by World Possible. The device creates its own Wi-Fi network. Anyone who connects with a phone, tablet or laptop opens one web page and finds a library of educational material. No internet is needed.

**contentshell** (this repo) is the web application on that device. It does three jobs:

1. **Show the library:** the homepage lists every installed content "module" (Wikipedia, Khan Academy, Kolibri, Moodle, ebooks, locally built lessons) and links into each one.
2. **Manage the library:** a password-protected admin area installs, deletes, orders, hides and categorizes modules, and configures the device.
3. **Assess learning:** teachers build quizzes, students take them, and teachers grade the results.

It is plain PHP 8 and SQLite with vendored jQuery. There is no build step, no package manager and no internet dependency. Files are deployed as they are. This repo is a fork of [worldpossible/contentshell](https://github.com/worldpossible/contentshell); see section 11.

## 2. The big picture

```
 Phones / laptops on the device's Wi-Fi
              │  HTTP
              ▼
   ┌──────────────────────────────  nginx + php-fpm  ──────────────────────────────┐
   │                                                                                │
   │  PUBLIC                                    ADMIN (login required)              │
   │  index.php ─ homepage + sidebar            admin/storage.php  Content Mgmt     │
   │  quiz.php  ─ student quiz UI               admin/device.php   Device Settings  │
   │  about.html, captiveportal-redirect.php    admin/stats.php    Usage stats      │
   │  listmods.php, export-modfile.php          admin/modules.php  reorder endpoint │
   │        │                                          │                            │
   │        └──────────────┬───────────────────────────┘                            │
   │                       ▼                                                        │
   │        admin/background.php  ── the AJAX backend (quizzes, installs, wifi…)    │
   │                       │                                                        │
   │                       ▼                                                        │
   │        admin/common.php  ── shared library: DB, auth, paths, language,        │
   │                              module scan, install/sort helpers                 │
   └───────────┬───────────────────────────┬───────────────────────────┬────────────┘
               ▼                           ▼                           ▼
     admin/admin.sqlite            modules/<name>/               background process
     (settings overlay,            (the actual content;          admin/do_tasks.php
      quizzes, tasks, users)        the source of truth)         (runs rsync installs)
                                                                       │
                                        World Possible rsync server ◄──┘
```

External services that sit beside contentshell, not inside it: **Kiwix** (serves ZIM archives such as Wikipedia), **Kolibri**, **Moodle**, **KA Lite**, **DataPost** webmail (Roundcube), **goaccess** (usage reports from nginx logs) and **rsync**. Modules link to them, and the admin code restarts or queries some of them.

## 3. The central idea: the filesystem is the truth

A **module** is a folder under `modules/`. That is the whole install format.

- The folder must contain a `rachel-index.php` (older name: `index.htmlf`). This is an **HTML fragment, not a page**. The homepage includes it inline inside its `<main>` element, where it can use the variable `$dir` for asset URLs.
- The fragment's `<h2>` text becomes the module's title. An HTML comment such as `<!-- version=v1.2 -->` supplies its version. `getmods_fs()` in `admin/common.php` reads both with regular expressions.
- Folders without a fragment are listed but forced hidden.

SQLite only stores an **overlay** on top of what the filesystem says exists: the `position` (sort order) and `hidden` flag of each module. The homepage merges the two on every load. Consequences:

- Copying a folder into `modules/` installs it. Deleting the folder uninstalls it.
- `syncmods_fs2db()` reconciles the table with the folders.
- Module content never touches contentshell's code, so content updates and code updates are independent.

## 4. File map

### Public pages

| File | Role |
|---|---|
| `index.php` | The homepage. Loads `common.php`, builds the category sidebar, scans modules, sorts them by `bypos()`, and `include`s each visible fragment inside a wrapper `<div>` carrying its categories (the sidebar filter reads these). Also includes `panic-banner.php`. |
| `quiz.php` | Student quiz interface: list quizzes, enter name and optional password, answer, submit. Talks only to `admin/background.php`. |
| `about.html` | Static about page. |
| `captiveportal-redirect.php`, `redirect.shtml`, `pass_ticket.shtml` | Captive-portal support. Phones that detect "no internet" get redirected to a welcome page. The two `.shtml` files are shell CGI scripts that adjust the device's firewall. |
| `listmods.php`, `export-modfile.php` | Machine-readable views of the module list (JSON, and a `.modules` text file). Another RACHEL can fetch the latter to clone this device's content. |
| `panic-banner.php`, `sda-recover.php` | Degraded-storage handling on RACHEL 5. If the internal SSD failed and the device booted on its eMMC fallback (flag file `/.data/.emmc-fallback`), the homepage shows a banner. Its button calls `sda-recover.php`, which tries to repair and remount the SSD. |

### Admin pages (`admin/`)

Every admin page follows the template in `admin/minimal.php`: load `common.php`, check `authorized()`, set `$page_title`, `$page_script` and `$page_nav`, include `head.php`, output the page, include `foot.php`. `head.php` loads the vendored jQuery and CSS and renders `nav.php`.

| File | Role |
|---|---|
| `storage.php` | **Content Management.** One large page with hash-routed tabs: upload, USB install, module builder, World Possible downloads, delete, rearrange, visibility, categories, quiz manager, quiz results. It handles its own file-upload and USB `POST` requests at the top of the file before any HTML, and uses `background.php` for the rest. |
| `device.php` | **Device Settings.** Tabs for admin password, system info, storage usage, Wi-Fi, power (reboot and shutdown), sponsorship, links to other services, and advanced hardware. |
| `stats.php` | **DataPost/usage stats.** Displays a goaccess report built from the nginx access log. |
| `modules.php` | Not linked in the nav, but `storage.php`'s Rearrange tab calls it as an AJAX endpoint to save the module order. |
| `logout.php`, `install.php`, `version.php` | Logout, plus two leftover redirects to `storage.php`. |
| `upload_common.php`, `js/upload.js` | Leftovers from an older chunked-upload system. Nothing uses them now. |

### The shared library: `admin/common.php`

Included by nearly everything. It provides:

- **Database:** `getdb()` opens `admin/admin.sqlite` and creates or migrates every table on each connection. There are no migration files.
- **Authentication:** `authorized()`, `check_password()`, `set_password()`. See section 8.
- **Language:** `$lang` is loaded from `admin/lang/lang.{en,es,fr}.php` based on the browser's `Accept-Language` header.
- **Hardware and paths:** `is_rachelpi()`, `is_rachelplus()`, `is_rachelplusv3()`, `is_rachelplusv5()`, and path helpers (see section 7).
- **Modules:** `getmods_fs()`, `getmods_db()`, `syncmods_fs2db()`, `bypos()` for sorting.
- **Installing:** `parseModulesFile()`, `installmods()`, `sortmods()`.
- **Utilities:** `showip()`, `kiwix_restart()`, and `wp_verify_attribution()` (section 9).

### The AJAX backend: `admin/background.php`

A long `if (isset($_GET['…']))` chain at the top dispatches to functions below it. Groups of endpoints:

- **Modules and tasks:** remote and local module lists, add (install), delete, cancel, retry, task status, self-update, clone from another RACHEL.
- **Device:** Wi-Fi on and off, battery, clear logs, rsync daemon, usage stats.
- **Visibility:** hide or block modules.
- **Quizzes:** create, read, save, delete, start, check password, submit, grade, list submissions.
- **Sponsor:** read and save settings, upload logo, generate the sponsor module.
- **Categories:** read, assign, create, delete.

Anything unmatched is logged and answered with an HTTP 500.

### Other files

| Path | Role |
|---|---|
| `admin/do_tasks.php` | Background worker that runs the install queue (section 6). |
| `admin/category-map.json` | Shipped category definitions and a module-to-categories map. |
| `admin/js/hardware.js`, `admin/js/modules.js` | Page scripts that are really PHP files. `head.php` includes them *inside* a `<script>` tag so they can use `$lang` values. They cannot be loaded with `<script src>`. |
| `installmods.php`, `sortmods.php` | Command-line wrappers for `installmods()` and `sortmods()`. |
| `scripts/*.modules` | Manifests listing which modules a device should have. One module per line, `#` for comments, a leading `.` means "install but hide". `censorjustice.sh` is a shell script for trimmed content sets. |
| `css/`, `js/`, `art/`, `admin/css`, `admin/art` | Vendored styling, jQuery and images. Nothing loads from a CDN, because the device is offline. |
| `modules/` | The content. Treated as data. See section 3. |

## 5. Main workflows

### A visitor opens the homepage

1. `index.php` loads `common.php`, which picks the language and finds the module path.
2. It reads `admin/category-map.json` and the `module_categories` table to build the sidebar filter. Only categories with installed modules appear.
3. It scans `modules/`, merges position and hidden flags from SQLite, sorts, and skips hidden modules.
4. Each visible module's fragment is included inline. A slow fragment slows the whole page. Fragments should avoid network calls without short timeouts.

### An admin installs content from World Possible

1. In the Content Management page, `storage.php` asks `background.php` for the remote module list. This is fetched over HTTP from `dev.worldpossible.org` (the only action that needs internet).
2. The admin picks modules. `addModules()` inserts one `tasks` row per module with an `rsync` command, then starts `do_tasks.php` in the background.
3. The browser polls `background.php?getTasks=1` and shows a progress bar (section 6).
4. When the module folder lands in `modules/`, it is installed. `kiwix_restart()` lets Kiwix pick up any new ZIM files.

### An admin installs content locally

- **Upload:** `storage.php` receives a ZIP, extracts it into `modules/<name>/`, flattens a single wrapper folder, and writes a `rachel-index.php` with `createRachelIndex()` if there isn't one.
- **USB:** `storage.php` lists mounted drives (`/media/usb*` or `/media/root*`), scans them for ZIPs and folders, then extracts or copies the chosen one into `modules/`. Export to USB works in reverse with `rsync`.
- **Builder:** the Build Module tab creates a module from typed text, images, video and PDFs. It writes `page1.html`, `page2.html`, an `index.html` and a fragment.
- New local modules are tagged with the `local` category automatically.

### A teacher creates a quiz and a student takes it

1. In the Quizzes tab, `storage.php` sends the quiz as JSON to `background.php?saveQuiz`. It is stored in `quizzes` and `quiz_questions`. Media for questions is uploaded to `modules/quiz-media/`.
2. `updateQuizModule()` regenerates `modules/student-quizzes/`, which appears on the homepage and links to `quiz.php`.
3. A student opens `quiz.php`, which lists active quizzes. After choosing one, they enter a name and, if the quiz has one, a password. `startQuiz` returns the questions.
4. On submit, `submitQuiz` stores the submission and answers, auto-grades multiple-choice questions, and saves uploaded files.
5. In the Results tab, the teacher reads submissions, grades the written answers with `gradeSubmission`, and can delete submissions.

### An admin sets up sponsorship

The Sponsorship tab in `device.php` saves values in the `prefs` table and generates a `zz-sponsor-module` that appears at the top or bottom of the homepage. Its logo goes in `modules/sponsor-assets/`.

### A device clones or updates itself

- **Clone:** `cloneServer` downloads another RACHEL's `export-modfile.php`, then `installmods()` queues the same modules.
- **Self-update:** `selfUpdate` rsyncs the `contentshell4` directory from World Possible's server over this directory, sparing `modules/`, the database and hidden files.

## 6. The background task queue

Installs can take hours, so they never run inside a web request.

1. `installmods()` or `addModules()` inserts rows into the `tasks` table, then launches `admin/do_tasks.php` detached.
2. `do_tasks.php` takes a lock via `/var/run/rachel_do_tasks.pid` so only one worker runs. It claims the next unstarted task and runs the command with `proc_open`.
3. It reads rsync's output one character at a time to track `files_done`, `data_done` and `data_rate`, writing them to the database at most every three seconds.
4. After each task it runs the module's optional `finish_install.sh`. When the queue is empty it calls `kiwix_restart()`.
5. The browser polls `getTasks`. Completed tasks are auto-dismissed. `cancelTask`, `cancelAll` and `retryTask` stop or re-queue work by killing the child process and updating the row.

`installmods()` also queues a final task that runs `sortmods.php` on the `.modules` file so the new modules land in the right order.

## 7. Data and configuration

### Database tables (`admin/admin.sqlite`)

| Table | Holds |
|---|---|
| `modules` | `moddir`, `position`, `hidden`, and `blocked` (added when visibility is first saved) |
| `tasks` | the install queue and its progress |
| `users` | the single `admin` login |
| `prefs` | key/value settings: sponsor fields, local-content link, webmail link, rsync daemon |
| `module_categories` | category overrides per module (win over `category-map.json`) |
| `quizzes`, `quiz_questions`, `quiz_submissions`, `quiz_answers` | the quiz system |
| `uploads` | state for the old chunked-upload system |

### Hardware detection and paths

RACHEL has shipped on several hardware generations, each with a different content location. `common.php` decides which device it is by checking which directory exists:

| Device | Detected by | Content path |
|---|---|---|
| RACHEL-Pi | `/var/www/rachel/modules` | that directory |
| RACHEL-Plus (Intel CAP, CMAL100) | `/media/RACHEL/rachel/modules` | that directory |
| v3 / v5 (CMAL150, "RACHEL 5") | `/.data/RACHEL` exists; v5 if `/etc/issue` starts with `CMAL150` | reached through the `/media/RACHEL` link |
| anything else | none of the above | `./modules` or `../modules` relative to the script |

Code should reach paths only through `getAbsModPath()`, `getAbsAdminPath()`, `getRelModPath()`, `getRelAdminPath()` and `getAbsBaseUrl()`. They work from the webroot, from `admin/`, over HTTP and from the command line. Device-specific UI (Wi-Fi tab, battery meter, advanced settings) is switched on by these detectors. Touching `/tmp/fake-rachelplus` and similar files makes the UI imitate other hardware.

## 8. Authentication

- A single `admin` account is stored in `users` with a hashed password.
- `authorized()` in `common.php` returns true for command-line runs, for a request carrying the admin cookie, or after a correct login form post (which sets the cookie). Otherwise it prints the login page.
- Admin pages call `authorized()` at the top. `logout.php` clears the cookie.
- `background.php` serves both admin actions and the public quiz actions used by `quiz.php`, so the authentication model for it needs care.

The known weaknesses in this design are listed in `issues.todo`.

## 9. Features that depend on branding

`wp_verify_attribution()` checks that `index.php` still contains the strings "World Possible", "RACHEL" and "worldpossible". If any are removed, `wp_feature_enabled()` returns false. The sidebar, category filtering, USB export, quiz-media upload and sponsorship features then switch themselves off. This matches the CC BY-SA-NC license in the README. Keep the attribution in `index.php`.

## 10. Languages, categories and styling

- **Languages:** English, Spanish and French in `admin/lang/`. Keys use underscores so they work inside double-quoted strings. These files must have no blank lines outside the PHP block, or headers break.
- **Categories:** definitions and a module map ship in `category-map.json`. Admin changes go in `module_categories` and win on conflict.
- **Styling:** `css/style.css` and inline `<style>` blocks. `css/variables.css` defines design tokens, but nothing uses it yet.

## 11. Fork relationship and things to watch

This repo is a fork of `worldpossible/contentshell`. The `trunk` branch sits on upstream commit `1f3ca1f`. Local changes:

- `admin/storage.php`, `admin/upload_common.php` and part of `background.php` use the path helpers instead of the RACHEL 5 paths, so the code runs on other hardware (such as a Raspberry Pi).
- The DataPost module no longer calls an API on port 3000 while the homepage loads. The blocking call delayed page loads by more than a minute.
- The Kolibri module targets port 8080.

Things worth knowing:

- `selfUpdate()` would overwrite local changes with upstream code.
- `admin/admin.sqlite` is tracked in git and changes whenever the app is used. It contains real state: the password hash, module order and quiz data.
- The constant `MODPATH` is used by the sponsor features in `background.php` but is not defined anywhere in the repo, so those code paths will fail until it is defined or replaced with `getAbsModPath()`.
- The Kolibri module still fetches its channel list during the page load without a timeout.
- `resetdefault` and `backupdefault`, called from the Rearrange tab, have no handler in `modules.php`.

For the full list of known problems and their fixes, see `issues.todo`. For commands and conventions to follow when editing, see `CLAUDE.md`.

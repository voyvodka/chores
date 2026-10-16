# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/). A release is a `vX.Y.Z` tag on `main`; installed apps
update themselves to it.

## [Unreleased]

### Added

- A running job's log is shown live, followed to its end, in the window and on its menu page until a past run is picked.
- Search in the window's sidebar: by title, id, description, category or the last run's summary, ignoring case and accents.
- Stop a running job: the stop button on a running job's card (on hover), on its menu page and in the window toolbar, or `chores stop <id>`. The run is recorded as a fail "Stopped by the user" and never notifies; Ctrl-C on `chores run` counts the same.
- An app icon: a check over the coloured run strip, made in Icon Composer so macOS draws it in Liquid Glass and its dark, clear and tinted styles. It is compiled ahead of time (`scripts/compile-icon.sh`) and shown in Settings › About.

### Changed

- The skill's job categories are English (`watch`, `maintenance`, `sync`, `report`) and the app shows them in its own language; any other category is shown as written.
- `templates/inbox-watch` 1.2.0 is in English. Its report language is `config.json › language` (`en` or `tr`): new installs start in English, existing installs keep Turkish. Answers in the old Turkish level names are still understood.

### Fixed

- A job without runs no longer shows its header in the middle of the window.
- Settings tabs no longer rubber-band and flash a scroller when their content fits the window.
- A `runAtLoad` job that was off when Chores started no longer runs the moment it is turned back on in the same boot; like any other run missed while off, it waits for the next boot.
- The tests remove the temporary job folders they create.

## [1.0.1] - 2026-10-16

### Fixed

- A self-update now quits the running app before installing and reopens the new version. `install.sh` runs as a descendant of the app during an update, and `pkill` leaves its own ancestors alone, so the old app kept running and the next daily check would have installed the same release again.

## [1.0.0] - 2026-10-16

The first public release.

### Added

- `chores` runner and job contract: each job lives in its own folder (`job.json`, `runs.jsonl`, `logs/`, reports); every run is recorded with its start, end, exit code, outcome, one-line summary, log, report, trigger and job version. The script reports `ok|warn|fail <summary>` (and optionally `report <path>`) through `$CHORES_RESULT`; a non-zero exit is always a failure, and `chores run` exits with the recorded outcome (0 ok, 1 fail, 3 warn, 2 not started).
- The runner forwards SIGTERM/SIGINT/SIGHUP to the job's process group and still records the run, escalates to SIGKILL after a timeout or a stop, stops processes a job leaves behind, never runs a job twice at once, and prunes history to the newest 500 runs under a lock.
- One scheduler agent embedded in Chores.app schedules every job (calendar entries with a single catch-up after sleep, intervals counted from the last run, once-per-boot `runAtLoad`), so System Settings › Login Items shows a single Chores row. Turning a job off is a setting; the scheduler keeps a heartbeat, runs as a single instance and is re-registered by `install.sh`.
- Jobs carry a version with a changelog, a category, required commands, a project folder and links.
- CLI: `run`, `start`, `disable`, `enable`, `delete-runs`, `install`, `uninstall`, `validate`, `list`, `retire` (moves a pre-Chores launch agent's plist aside and prints the undo command), `scheduler`, `paths`.
- `chores` Claude Code skill (`skill/SKILL.md`) that creates jobs and migrates launch agents to the contract, with recipes for `claude -p` jobs.
- Menu-bar app (macOS 26): overall status icon; jobs grouped by category with a coloured edge, the last ten runs and a hover run button; ok/warn/fail counts that filter the list; turned-off jobs behind a link; a job page that slides into the panel with stats, recent runs, report or log, and job info; a warning with a restart button when the scheduler stops.
- Job window: sidebar of jobs, Run and ⋯ in the toolbar, summary tiles, a sortable history table with the job version per run, and the selected run's summary above its report or log. The Report/Log choice and the History/Info tab are remembered.
- Deleting runs: select rows in the history (Shift/⌘ for several) and press Delete or use the context menu, or clear a job's history from ⋯. Logs and the reports inside the job folder go with them.
- Notifications for finished runs according to each job's `notify` setting (default warn and fail), opening the job when clicked, with an `osascript` fallback when the app is not running. A problem that repeats unchanged is notified when it starts and then at most about once an hour.
- Settings (⌘,): language (System, English, Türkçe), open at login, showing turned-off jobs in the menu, notification settings, updates, and an About tab with the version, build, scheduler state, jobs folder, runner and source.
- Self-update from git: once a day the installed app fetches release tags into its own clone of the repository it was built from; for a newer one it builds it, waits until no job is running, installs it with `scripts/update.sh`, reopens and notifies the result.
- English and Turkish: English is the source language and Turkish ships in a string catalog (`scripts/sync-strings.sh` keeps it in line with the code, a test checks every key is translated). Dates, durations, percentages and schedules follow the app's language; the CLI is English.
- `templates/inbox-watch`: a shareable job that reads a Gmail inbox twice a day (read-only OAuth, secrets in the Keychain) and has `claude -p` report only the mails that need action, with Gmail links; `setup.sh` installs or updates it on any Mac running Chores.
- `ChoresApp --snapshot` renders the menu and window off-screen with a layout report; `--show-menu-preview`, `--show-window` and `--show-settings` open them from a debug build.

[Unreleased]: https://github.com/voyvodka/chores/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/voyvodka/chores/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/voyvodka/chores/releases/tag/v1.0.0

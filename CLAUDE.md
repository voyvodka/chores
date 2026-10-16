# Chores

> Main context source for this repository. Read this first, then `devdocs/product/00-state.md`.
> Everything in this repository is in English; the private development documents in `devdocs/` are in Turkish.

## What this is

A personal, native macOS menu-bar app that schedules, monitors and manages the user's background
jobs — the bash/AI scripts that Claude Code sets up — through one scheduler agent inside the app. It ships with a runner (`chores`)
that every job runs through, and a Claude Code skill that creates jobs in the shape the app
expects. Single user, single Mac, built and installed locally. Jobs meant for other people's Macs
too live in `templates/<id>/` with their own `setup.sh` (decision "Paylaşılan job şablonları").

## Stack

| Layer | Choice | Why |
|---|---|---|
| Language | Swift, one SwiftPM package | Native macOS was a hard requirement; runner and app share the contract types, so drift is a compile error |
| Contract + logic | `ChoresKit` library | UI-free, fully covered by `swift test` |
| Runner | `chores` CLI, in the app bundle and at `~/.local/bin/chores` | launchd keeps no run history; the runner records every run |
| Scheduler | One agent embedded in Chores.app (`dev.voyvodka.chores.scheduler`, `chores scheduler`) | One "Chores" row in Login Items › Background App Activity instead of one per job |
| App | SwiftUI `MenuBarExtra` + `Window`, AppKit where SwiftUI falls short; macOS 26+ | Menu bar + detail window; `LSUIElement` app; Liquid Glass only through system controls (toolbar, bordered buttons, segmented pickers) |
| Packaging | `swift build` + script-built `.app`, ad-hoc signed, installed to `~/Applications` | Verified by a spike: notifications work and permission survives rebuilds |
| Job authoring | Claude Code skill in `skill/`, symlinked into each Claude account's skills dir | Jobs are created by Claude Code, never by the app |

Reasoning in full: `devdocs/product/02-decisions.md`. Do not swap a
component without reading its "Elenenler" line — the alternatives were considered and rejected.

## Where the truth lives

`devdocs/` is private and excluded from git: a symlink to a separate private repository holding
product decisions, roadmap and research. Never commit it or unignore it. Outside this file and `AGENTS.md`, never
name a `devdocs/` path in tracked files, commit messages, PRs or release notes. Where `devdocs/` is missing (a public
clone), read `CHANGELOG.md` and the code instead.

`devdocs/README.md` indexes every document and what each one answers; keep it current. Read
`devdocs/product/00-state.md` before proposing any implementation plan, then the decisions in
`devdocs/product/02-decisions.md`. The roadmap and progress ledger is `devdocs/product/03-mvp.md`.
Changes to `devdocs/` are committed and pushed in that repository.

When code and documents disagree, raise it — do not silently follow one of them.

## Rules

- **The job contract is defined once, in `ChoresKit`.** The runner, the app and `skill/SKILL.md`
  all follow it. A contract change updates all three plus the "Job sözleşmesi" decision in the
  same change.
- **No per-job launch agents.** Scheduling is the embedded scheduler's job; `Scheduler.due` holds
  every rule and is unit-tested. Turning a job off is `settings.json`, not launchctl. `launchctl`
  is only used to boot out pre-Chores agents (`chores retire`, `chores install`). The app and
  runner never read its `print` output, which Apple documents as not API; the one exception is
  `scripts/install.sh`, which greps it to wait until the scheduler is running.
- **The app never writes job definitions** (`job.json`, scripts). Only the skill (and `chores install`)
  does. Run history changes only through `JobStore` under the history lock (`append`, `prune`,
  `deleteRuns`).
- **After replacing the bundle, re-register the scheduler agent** (`scripts/install.sh` does it):
  the new signature makes launchd refuse the old registration with EX_CONFIG. Right after the
  bundle is replaced a fresh registration can still end in EX_CONFIG, so the script retries until
  launchd reports the agent running.
- **No hand-applied `glassEffect`.** Use system controls (`.bordered` buttons, toolbar items,
  segmented pickers) and let macOS draw Liquid Glass. Custom glass inside the menu panel, which is
  itself glass, looked flat, and Apple's HIG says to use it sparingly on custom controls and never
  in the content layer. SwiftUI `Menu` ignores the circle border shape; use `PanelIconMenu`.
- **Iterate on the UI with the debug build, install once at the end.** `.build/debug/ChoresApp
  --show-menu-preview` (add `--menu-detail <id>`) or `--show-window`, with `CHORES_HOME=<test root>`,
  opens real windows with Liquid Glass and motion; an unbundled run skips notifications, the login
  item and scheduler registration (`JobsModel.isInstalledBundle`), so it no longer crashes. Stop it
  by its PID. Leave the installed app alone: do not quit or relaunch it to test, because every
  `scripts/install.sh` swaps the bundle and re-registers the scheduler. Check motion with a recording
  of that one window (`screencapture -v -l <window id>`); `--snapshot` shows neither glass nor
  motion.
- **Do not trigger real jobs to test something.** Real jobs have side effects (some spend
  Claude quota). Put a test job in a `CHORES_HOME` test root (the scheduler never schedules it),
  run it with `chores run`, and delete the root afterwards.
- **The installed bundle lives in `~/Applications`,** never in `.build/` or `/tmp`: macOS silently
  refuses notification permission to bundles LaunchServices has not registered.
- **Public-ready repo.** No absolute home paths, hostnames, tokens, workplace references or real
  job names in tracked files; use `$HOME` / `FileManager.default.homeDirectoryForCurrentUser`.
  Commits use the `voyvodka` noreply identity.
- **UI strings are English source, translated in `Sources/ChoresApp/Resources/Localizable.xcstrings`.**
  Write them as `Text("…")`, `LocalizedStringKey` parameters or `String(localized:)`; never a
  translated literal in code. After adding or changing one, run `scripts/sync-strings.sh` and fill
  in its Turkish; `StringCatalogTests` fails on a missing translation, a stale key or a dropped
  placeholder. `ChoresKit` has no resources: texts it builds for the app take a `Language`
  (`Fmt.language`), the CLI stays English, and summaries written to `runs.jsonl` are data. To see
  the debug build in a language, link `.build/debug/tr.lproj` to
  `Chores_ChoresApp.bundle/Contents/Resources/tr.lproj`, create an empty `.build/debug/en.lproj`,
  and pass `-AppleLanguages '(tr)'`.
- **Shell:** `cp`, `mv`, `rm` are aliased to `-i` in the login shell and will hang a tool call —
  use `command cp -f` etc.
- **A release is a `vX.Y.Z` tag on `main`.** Installed apps update themselves to the newest one
  (`Updater`, `scripts/update.sh`), so a tag ships to every Mac running Chores within a day: tag
  only a `main` that builds, passes the tests and has its `CHANGELOG.md` section dated.
- **Changes go through PRs** (branch → conventional commit → PR with type + area labels → merge
  after CI) and get a `CHANGELOG.md` line under `[Unreleased]`.

Verify with `swift build`, `swift test`, then `scripts/install.sh` to build the `.app`, install it
and the runner, and relaunch. Two local hooks, not tracked, run the first two on their own: a Claude Code Stop
hook runs `swift build` when Swift sources changed, and the git `pre-push` hook runs `swift build`
and `swift test` (`CHORES_SKIP_PREPUSH=1` bypasses it). To check the UI without clicking the menu bar, run
`.build/debug/ChoresApp --snapshot <dir>` (add `CHORES_HOME=<test root>` for test data; the real scheduler never schedules a test root) and read
the PNGs; it hosts views in an off-screen window because `ImageRenderer` draws AppKit-backed
controls as placeholders. For glass and motion use the debug build's `--show-menu-preview` and
`--show-window` (see Rules), and `--show-settings` (add `--settings-tab about`); these flags are read only at launch, so `open ~/Applications/Chores.app
--args …` does nothing while the installed app is running. Capture only that window
(`screencapture -l <window id>`), never the whole screen — it shows the user's other work.

## Standing assumptions

> These were never confirmed. When work touches one, ask rather than guess.

| ID | Assumption | What breaks if wrong |
|---|---|---|
| V3 | Only the current macOS version is supported (minimum macOS 26) | Older systems lack Liquid Glass and the `SMAppService` behaviour relied on |
| V5 | `com.claude-mem.worker` is not migrated and not listed | The app will not show it when the worker stops |

Live list: `devdocs/product/00-state.md`.

## Out of scope

> Deliberately excluded from the MVP. Do not helpfully add these.

- Third-party launch agents, `/Library/LaunchDaemons`, anything needing root
- cron
- Creating or editing jobs from the app
- Prebuilt binary distribution, notarization (updates come from source, see `scripts/update.sh`)
- UI automation tests (XCUITest)

Full list with reasons: `devdocs/product/03-mvp.md`.

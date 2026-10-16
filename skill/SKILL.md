---
name: chores
description: Create, migrate or change a scheduled background job on this Mac (a recurring bash script, a daily `claude -p` check, a sync that runs every N minutes) so it shows up in the Chores menu-bar app. Use whenever the user asks to run something periodically, in the background, "every day/hour", on login, or asks to move an existing launchd agent under Chores. Do not hand-write launchd plists — this skill replaces that.
---

# Chores jobs

Chores runs every background job through one runner (`~/.local/bin/chores`) so each run is
recorded — start, end, exit code, outcome, one-line summary, log, report — and shown in the
Chores menu-bar app. Scheduling is done by the one scheduler agent inside Chores.app, which is
why System Settings › Login Items shows a single "Chores" row instead of one per job.

**You never write a launchd plist.** You write a job folder; `chores install` hands it to the
scheduler. A hand-written LaunchAgent would bypass Chores and add a row to Login Items.

The CLI lives at `~/.local/bin/chores`. If `chores` is not on the shell's `PATH`, call it by that
full path. `chores paths` prints where jobs and state live; `chores list` also says whether the
scheduler is running.

## 1. Pick an id

Lowercase letters, digits and dashes, starting with a letter or digit, at most 64 characters:
`api-docs-watch`, `backup-photos`. It becomes the folder name.
Check it is free: `chores list`.

## 2. Create the job folder

`~/.local/share/chores/jobs/<id>/` holding:

```
job.json     the definition — see below
run.sh       the script (or whatever `command` points at)
```

The runner creates `logs/`, `runs.jsonl` and the report folder itself.

### job.json

```json
{
  "id": "api-docs-watch",
  "title": "API docs watch",
  "summary": "Checks a provider's API docs and GitHub repo for changes in the last 48 hours.",
  "command": ["/bin/bash", "run.sh"],
  "schedule": { "calendar": [ { "hour": 10, "minute": 0 } ] },
  "timeoutSeconds": 4000,
  "reportDirectory": "reports",
  "notify": "always",
  "permissions": "Claude agent: Read, Grep, Glob, WebFetch, Bash(gh api:*). Cannot write files.",
  "notes": [
    "Report: reports/YYYY-MM-DD.md; its first line becomes the notification.",
    "Tries each Claude account in turn and uses the first that answers."
  ],
  "createdBy": "claude-code",
  "createdAt": "2026-09-24T10:00:00Z",
  "version": "1.0.0",
  "changelog": [
    { "version": "1.0.0", "date": "2026-09-24", "notes": ["First version: daily check, one report per day."] }
  ],
  "category": "watch",
  "requires": ["claude", "gh", "jq"],
  "project": "~/Projects/my-app",
  "links": [
    { "title": "Provider API docs", "url": "https://docs.example.com/" },
    { "title": "Reports", "url": "~/.local/share/chores/jobs/api-docs-watch/reports" }
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Must equal the folder name |
| `title` | yes | Short name shown in the menu bar list |
| `summary` | yes | One or two sentences: what the job does and why |
| `command` | yes | argv, run via `/usr/bin/env` with the job folder as working directory |
| `schedule` | yes | `{"calendar": [...]}`, `{"intervalSeconds": N}`, both, or `{}` for on-demand only |
| `runAtLoad` | no | Also run once per boot, the first time the scheduler sees the job after a restart |
| `timeoutSeconds` | no | The runner kills the job after this; set it for anything that calls a network or an agent |
| `environment` | no | Extra environment variables. `PATH` already includes `~/.local/bin` and Homebrew; a `PATH` set here replaces that default instead of extending it |
| `reportDirectory` | no | Folder the job writes reports into: relative to the job folder (preferred), absolute, or `~/…` |
| `notify` | no | `always`, `problems` (default: warn/fail only) or `never` |
| `permissions` | no | Plain-language statement of what an agent inside the job may do |
| `notes` | no | Anything the user should see later — put your setup summary here, not only in chat |
| `createdBy`, `createdAt` | no | `"claude-code"` and the real current time from `date -u +%Y-%m-%dT%H:%M:%SZ` — never an invented one |
| `version` | yes in practice | The job's own version (`1.0.0`). `chores validate` warns without it. Every run records it |
| `changelog` | yes in practice | Newest first: `{version, date "YYYY-MM-DD", notes: [..]}`. Must contain an entry for `version` |
| `category` | yes in practice | Groups jobs in the app. Use one of `watch` (checks and watches), `maintenance` (cleanup, upkeep), `sync` (sync, mirror) or `report` (produces reports); the app shows these four in its own language. Use a new short lowercase English word only if none fits |
| `requires` | no | Commands the job needs, as names on the job's `PATH` or absolute paths. Missing ones make the job show a warning |
| `project` | no | Folder of the project the job serves (`~` allowed) |
| `links` | no | `{title, url}` — web pages, repos, or local folders (`~` allowed) the user may want to open |

`environment` values must be strings. They apply to every run, scheduled or manual.

**Choosing a schedule:** "every N minutes/hours" → `intervalSeconds`. "At 10:00", "on Sundays",
"on the 1st" → `calendar`. Calendar entries follow launchd/cron semantics: fields `minute`, `hour`,
`day`, `weekday` (0 and 7 are Sunday), `month`; a missing field is a wildcard; `day` and `weekday`
together mean either. A calendar run missed while the Mac slept runs once on wake. An interval
counts from the end of the previous run, so a new interval job first runs one interval after install unless `runAtLoad` is set. `runAtLoad` runs once per boot (logging out and back in
does not repeat it). Runs start within about 15 seconds of their time.

**Choosing `notify`:** a job whose point is to warn about something → `problems` (the default;
the job reports `warn`/`fail` when there is something to say). A job whose every run produces a
report the user wants to read → `always`. Anything running more often than hourly → `problems`
or `never`, or the user drowns in notifications. The example above uses `always` only because it
is a daily report.

A warn or fail whose summary is identical to the runs right before it counts as the same problem
still going on: Chores notifies it when it starts and then at most about once an hour. So keep the
summary of an unchanged problem byte-for-byte stable (no timestamps or counters in it), and let it
change when the problem does.

**`command`:** `["/bin/bash", "run.sh"]` needs no `chmod`. A bare `["./run.sh"]` does. Set
`timeoutSeconds` to two or three times the longest run you expect.

**Changing an existing job:** bump `version` (patch for fixes, minor for behaviour changes,
major when the result or report format changes) and add a `changelog` entry at the top in the
same edit. The app shows which version produced each run, so an unbumped change is invisible.

## 3. Write the script to the contract

The runner gives the script these environment variables:

| Variable | Use |
|---|---|
| `CHORES_RESULT` | File to write the outcome into (below) |
| `CHORES_REPORT_DIR` | Report folder, when `reportDirectory` is set; already created |
| `CHORES_JOB_DIR`, `CHORES_JOB_ID`, `CHORES_RUN_ID` | Where and what is running |

**Report the outcome** by writing to `$CHORES_RESULT`. The first line is one of the words `ok`,
`warn` or `fail`, a space, and a one-line summary. An optional further line is the literal word
`report`, a space, and a path (absolute, or relative to the job folder); without it the newest
file written to `$CHORES_REPORT_DIR` during the run is used.

```bash
printf 'warn %s\n' "Disk 8% free on /System/Volumes/Data" >"$CHORES_RESULT"
printf 'report %s\n' "$CHORES_REPORT_DIR/$(date +%F).md" >>"$CHORES_RESULT"
```

- A non-zero exit is always `fail`, whatever the result file says. A script can downgrade a clean
  exit to `warn`/`fail`, never upgrade a failure.
- No result file: exit 0 → `ok`, anything else → `fail`.
- The summary is what the notification and the list show. Make it say what happened
  ("2 new releases", "No changes"), not "done".

**Rules for the script:**

- Everything it prints goes to the run's log. Print progress and errors to stdout/stderr; do not
  keep a private log file.
- **No `osascript` notifications.** The runner and the app notify, according to `notify`.
- Write reports into `$CHORES_REPORT_DIR`, never into the job folder root.
- Nothing outlives the run. When the script exits, the runner stops whatever it left running in
  the background (`cmd &`, `nohup`): SIGTERM, then SIGKILL a few seconds later. `wait` for
  background work before exiting; a job cannot start a long-lived daemon.
- Start with `set -u`. Use absolute paths or paths relative to the job folder; the working
  directory is the job folder.
- Idempotent where possible: a missed calendar run is replayed once after wake.

**A job that runs `claude -p`:** pick one of two shapes, always with an explicit `--model`,
`--no-session-persistence` and a per-attempt timeout as well as `timeoutSeconds`:

- **The script gathers the data, Claude only judges it** (classify, summarise): `--tools ""
  --safe-mode --output-format json`, the instructions in `--system-prompt`, and
  `MAX_THINKING_TOKENS=0` in the environment. No tools means nothing to permit; `--safe-mode` keeps
  hooks and plugins from recording the job's sessions; thinking off is most of the cost saved.
  `templates/inbox-watch/` in the Chores repository is a worked example.
- **Claude has to act** (read files, call `gh`): `--permission-mode dontAsk` with a minimal
  `--allowedTools` list.

Treat "exit 0 with prose" as a possible rate-limit or login error — check the answer against the
format your prompt demands before calling the run `ok`. Keep the prompt in its own file
(`prompt.md`) in the job folder.

A job meant for other people's Macs too is not set up by hand: it lives in the Chores repository
as `templates/<id>/` with a `setup.sh` that installs it.

## 4. Validate, install, verify

```bash
chores validate <id>
chores install <id>      # hands the job to the scheduler (and removes an old per-job agent, if any)
chores list
```

Then verify one run **only if running it now is harmless**: `chores run <id>` runs it in the
foreground with the same `PATH` and `HOME` a scheduled run gets, then prints the outcome, log and
report paths. Its exit status is the recorded outcome: 0 `ok`, 1 `fail`, 3 `warn`, and 2 when no
run was started (unknown or invalid job, or already running). A manual run is recorded like a scheduled one and notifies according to `notify` as
well. If the job costs money or quota, sends messages, or changes data, do not run
it — say when its first scheduled run is and let that be the check.

A job never runs twice at once: `chores run` or `chores start` on a job that is already running
is refused (exit 2) and records nothing. Other commands: `chores start <id>` starts a run in the
background (recorded as manual) and fails if the run does not start,
`chores disable <id>` stops scheduling it until `chores enable <id>` (it survives logout and
reboot; runs missed while off are not caught up, and an interval job runs one interval after it
is turned back on), and `chores uninstall <id>` does the same as
`disable` (the job then shows as disabled; the folder stays, delete it separately if wanted).
Prefer `disable` when the user wants a job "off for now".

**Testing without touching real jobs:** prefix every `chores` command with
`CHORES_HOME=/tmp/some-dir`. Jobs then live in `/tmp/some-dir/jobs/`; the real scheduler never
looks there, so try them with `chores run <id>` and delete the folder afterwards.

## Migrating an existing launchd agent

1. Read its plist and script. Recreate it as a Chores job folder; copy the script and adapt it to
   the contract (result file, report dir, no `osascript`, no private log). Copy any state it needs
   (earlier reports, prompt files) — **never move or edit the old folder**, it is the rollback.
2. `chores validate` and `chores install` the new job.
3. `chores retire <old-label>` — unloads the old agent and moves its plist to
   `~/.local/share/chores/retired/`, printing the undo command. Never delete an old plist. This
   also removes the old agent's row from Login Items.
4. Verify as in step 4, with the same caution about side effects.

## Tell the user

End with a short summary: id, schedule in plain words, where reports go, what an agent inside it
may do, how to run it by hand (`chores run <id>`), and that it now appears in Chores. The same
facts belong in `job.json` `notes` so they survive the conversation.

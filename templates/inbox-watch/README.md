# inbox-watch — inbox summary

Reads the mail that reaches a Gmail inbox twice a day (09:00, 17:00) and reports in Chores only the
mails that **really need action**. With nothing to do it stays quiet; otherwise it notifies, and the
report gives each mail a one-sentence "what to do" and a Gmail link.

- **Gmail:** read-only access. Nothing is deleted, moved or marked as read.
- **Claude:** your own Claude Code subscription (`claude -p`), Haiku by default. No extra cost; each
  run takes a tiny share of your quota. Claude has no tools at all; it only reads and classifies
  the mail text.
- **What is sent:** the headers and the first 2000 characters of the cleaned text of the mails that
  arrived since the last run. Inbox and spam are read; the Promotions and Social tabs are skipped.

## Install (each person on their own Mac)

Requires Chores (`scripts/install.sh`) and Claude Code, signed in.

1. Get the `client_secret_….json` file from whoever set up the Google side (below; done once).
2. Run:

   ```bash
   templates/inbox-watch/setup.sh --client ~/Downloads/client_secret_….json
   ```

3. Pick the Google account in the browser. A **"Google hasn't verified this app"** screen appears;
   that is expected: continue with *Advanced › Go to (app name)*. On the consent screen make sure
   the **Gmail box is ticked**.
4. With more than one Claude account signed in, setup asks in which order to try them.

Done: "Inbox" shows up in the Chores menu. To try it right away, `chores run inbox-watch`.

Setup is safe to run again (also after pulling the repository): it leaves your settings
(`config.json`), the last read time (`state.json`) and your rules (`rules.md`) alone.

## Your own rules

`~/.local/share/chores/jobs/inbox-watch/rules.md`, plain language, one preference per line:

```
- Ignore sign-in notices from new devices; we sign in ourselves.
- Invoices from X are always urgent.
- Never show Y's weekly reports.
```

In `config.json`:

| Key | Default | |
|---|---|---|
| `language` | `en` | Report language: `en` or `tr`. Installs made before this setting keep `tr` |
| `model` | `haiku` | `sonnet` if it misses things |
| `maxChars` | `2000` | Characters of each mail's text sent to Claude |

## When something goes wrong

| Chores shows | What to do |
|---|---|
| Gmail connection lost | `setup.sh --reconnect`. When the inbox password changes, Google closes every connection; everyone has to do this once |
| Could not reach Gmail | Check the log. Without internet the next run catches up; `403` means the Gmail API is off in the project |
| Claude did not answer | The quota may be used up or the session expired: sign in with `claude`. Those mails are read again on the next run |
| Not set up | `setup.sh` |

## The Google side (once, with the inbox's own account)

With the inbox's Google account, at <https://console.cloud.google.com>:

1. **Create a project** (e.g. `inbox-watch`).
2. **Enable the Gmail API:** *APIs & Services › Library › Gmail API › Enable*.
3. **Google Auth Platform › Branding:** app name and support email. *Audience:* **External**.
4. **Data Access › Add or Remove Scopes:** add `https://www.googleapis.com/auth/gmail.readonly`, save.
5. **Clients › Create Client:** type **Desktop app**. **Download the JSON right away**: Google shows
   the secret only at this moment.
6. **Audience › Publish app:** set the app to **In production**. No verification request is
   needed. Left in *Testing*, the connection drops every 7 days.

Share the JSON file privately with the team; never commit it. Setup stores it in the Keychain, after
which the file can be deleted.

Worth knowing:
- An unverified app can be granted access by at most 100 different Google accounts over its
  lifetime. Every Mac connecting the same inbox counts as one account.
- If **Advanced Protection** is turned on for the inbox account, unverified apps are blocked.
- Mail contents go to Anthropic through your Claude account. You may want to turn off "Help improve
  Claude" in claude.ai › Settings › Privacy.

#!/usr/bin/env python3
"""Gmail side of the inbox-watch job: sign-in, fetch, classify with `claude -p`, report.

Standard library only, and Python 3.9 compatible: it runs on the /usr/bin/python3 that ships with
the Command Line Tools, so a teammate's Mac needs nothing beyond what building Chores already needs.

    inbox.py setup [--client FILE] [--reconnect]   interactive, run by setup.sh
    inbox.py run                                   the scheduled job (Chores contract)
    inbox.py fetch --since EPOCH                   print what a run would send, without Claude
"""
import argparse
import base64
import glob
import hashlib
import html.parser
import http.server
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

JOB_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(JOB_DIR, "config.json")
STATE_PATH = os.path.join(JOB_DIR, "state.json")
PROMPT_PATH = os.path.join(JOB_DIR, "prompt.md")
RULES_PATH = os.path.join(JOB_DIR, "rules.md")

KEYCHAIN_SERVICE = "chores.inbox-watch"
SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me"

DEFAULT_MODEL = "haiku"
DEFAULT_MAX_CHARS = 2000
MAX_MESSAGES = 150
FIRST_RUN_LOOKBACK = 24 * 3600
CLAUDE_TIMEOUT = 600


class AuthBroken(Exception):
    """The stored Google sign-in no longer works; only setup can fix it."""


# --- Keychain -------------------------------------------------------------------------------------

def keychain_get(account):
    out = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
        capture_output=True, text=True)
    return out.stdout.rstrip("\n") if out.returncode == 0 else None


def keychain_set(account, value):
    subprocess.run(
        ["/usr/bin/security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a", account,
         "-w", value],
        check=True, capture_output=True)


# --- HTTP / OAuth ---------------------------------------------------------------------------------

def http_json(url, data=None, token=None):
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", "replace")
        if err.code in (400, 401) and ("invalid_grant" in detail or "invalid_client" in detail):
            raise AuthBroken(detail[:200])
        if err.code == 401:
            raise AuthBroken(detail[:200])
        raise RuntimeError("HTTP %d from %s: %s" % (err.code, url.split("?")[0], detail[:300]))


def load_client():
    raw = keychain_get("oauth-client")
    if not raw:
        raise AuthBroken("no OAuth client in Keychain")
    return json.loads(raw)["installed"]


def access_token():
    client = load_client()
    refresh = keychain_get("refresh-token")
    if not refresh:
        raise AuthBroken("no refresh token in Keychain")
    answer = http_json(client["token_uri"], {
        "grant_type": "refresh_token",
        "client_id": client["client_id"],
        "client_secret": client.get("client_secret", ""),
        "refresh_token": refresh,
    })
    return answer["access_token"]


def sign_in(client):
    """Loopback + PKCE sign-in; returns the token response."""
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    received = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if "state" not in query and "code" not in query and "error" not in query:
                self.send_response(404)
                self.end_headers()
                return
            received.update({k: v[0] for k, v in query.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write("<p>Tamam, bu sekmeyi kapatıp terminale dönebilirsin.</p>".encode())

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    server.timeout = 300
    redirect = "http://127.0.0.1:%d" % server.server_address[1]
    url = client["auth_uri"] + "?" + urllib.parse.urlencode({
        "client_id": client["client_id"],
        "redirect_uri": redirect,
        "response_type": "code",
        "scope": SCOPE,
        "access_type": "offline",
        # Without consent Google omits the refresh token on a second sign-in.
        "prompt": "consent",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    })
    print("Tarayıcıda Google izin sayfası açılıyor. Açılmazsa bu adresi kopyala:\n  " + url)
    subprocess.run(["/usr/bin/open", url], check=False)
    deadline = time.time() + 300
    while "state" not in received and "error" not in received and time.time() < deadline:
        server.handle_request()
    server.server_close()

    if received.get("error"):
        sys.exit("Google izni vermedi: " + received["error"])
    if received.get("state") != state or "code" not in received:
        sys.exit("Google'dan geçerli bir yanıt gelmedi (5 dakika içinde izin verilmeli).")
    tokens = http_json(client["token_uri"], {
        "grant_type": "authorization_code",
        "code": received["code"],
        "client_id": client["client_id"],
        "client_secret": client.get("client_secret", ""),
        "redirect_uri": redirect,
        "code_verifier": verifier,
    })
    # Granular consent lets the Gmail box be left unticked; the sign-in then "succeeds" uselessly.
    if SCOPE not in tokens.get("scope", "").split():
        sys.exit("Gmail okuma izni verilmedi. İzin ekranında Gmail kutucuğunu işaretleyip tekrar dene.")
    if "refresh_token" not in tokens:
        sys.exit("Google yenileme anahtarı vermedi. myaccount.google.com/permissions'tan uygulamayı kaldırıp tekrar dene.")
    return tokens


# --- Message text ---------------------------------------------------------------------------------

class _TextFromHTML(html.parser.HTMLParser):
    BREAKS = {"br", "p", "div", "tr", "li", "h1", "h2", "h3", "h4", "table"}

    def __init__(self):
        super().__init__()
        self.parts = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "head"):
            self.skip += 1
        elif tag in self.BREAKS:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style", "head") and self.skip:
            self.skip -= 1
        elif tag in self.BREAKS:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def html_to_text(markup):
    parser = _TextFromHTML()
    parser.feed(markup)
    return "".join(parser.parts)


def _decode(part):
    data = part.get("body", {}).get("data")
    if not data:
        return ""
    raw = base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))
    charset = "utf-8"
    for header in part.get("headers", []):
        if header["name"].lower() == "content-type":
            found = re.search(r'charset="?([\w.-]+)', header["value"], re.I)
            if found:
                charset = found.group(1)
    try:
        return raw.decode(charset, "replace")
    except LookupError:
        return raw.decode("utf-8", "replace")


def body_text(payload):
    plain, markup = [], []

    def walk(part):
        mime = part.get("mimeType", "")
        if part.get("filename"):
            return
        if mime == "text/plain":
            plain.append(_decode(part))
        elif mime == "text/html":
            markup.append(_decode(part))
        for child in part.get("parts", []) or []:
            walk(child)

    walk(payload)
    if any(p.strip() for p in plain):
        return "\n".join(plain)
    return html_to_text("\n".join(markup))


REPLY_MARKERS = re.compile(
    r"^(On .+ wrote:|.+ tarihinde .+ şunu yazdı:|-----Original Message-----|_{20,})\s*$", re.I)
LONG_URL = re.compile(r"https?://\S{50,}")


def clean(text, limit):
    """Drop quoted history, signature and noise so the limit is spent on what this mail says."""
    lines = []
    for line in text.replace("\r\n", "\n").replace(" ", " ").split("\n"):
        stripped = line.strip()
        if REPLY_MARKERS.match(stripped) or stripped == "--":
            break
        if stripped.startswith(">"):
            continue
        stripped = LONG_URL.sub("[link]", re.sub(r"[ \t​‌͏]+", " ", stripped))
        if stripped or (lines and lines[-1]):
            lines.append(stripped)
    out = "\n".join(lines).strip()
    return out if len(out) <= limit else out[:limit].rstrip() + " …"


# --- Gmail ----------------------------------------------------------------------------------------

def header(headers, name):
    for item in headers:
        if item["name"].lower() == name:
            return item["value"]
    return ""


def fetch(email, since, max_chars):
    token = access_token()
    query = ("after:%d -in:sent -in:drafts -in:chats -in:trash "
             "-category:promotions -category:social" % since)
    ids, threads, page = [], set(), None
    while True:
        params = {"q": query, "includeSpamTrash": "true", "maxResults": "100"}
        if page:
            params["pageToken"] = page
        listing = http_json(GMAIL + "/messages?" + urllib.parse.urlencode(params), token=token)
        # Newest first: one entry per thread, its latest message, so a reminder does not repeat a row.
        for m in listing.get("messages", []):
            if m["threadId"] not in threads:
                threads.add(m["threadId"])
                ids.append(m["id"])
        page = listing.get("nextPageToken")
        if not page or len(ids) >= MAX_MESSAGES:
            break
    truncated = bool(page) or len(ids) > MAX_MESSAGES
    ids = ids[:MAX_MESSAGES]

    mails = []
    for index, message_id in enumerate(ids, 1):
        msg = http_json(GMAIL + "/messages/" + message_id + "?format=full", token=token)
        payload = msg.get("payload", {})
        headers = payload.get("headers", [])
        labels = msg.get("labelIds", [])
        to = ", ".join(filter(None, [header(headers, "to"), header(headers, "cc")]))
        mails.append({
            "n": index,
            "threadId": msg["threadId"],
            "from": header(headers, "from"),
            "to": to,
            # Mail forwarded to this box (a shared alias) arrives with the alias in To.
            "via": header(headers, "to") if "@" in to and email.lower() not in to.lower() else "",
            "subject": header(headers, "subject") or "(konusuz)",
            "date": datetime.fromtimestamp(int(msg["internalDate"]) / 1000).strftime("%d.%m %H:%M"),
            "spam": "SPAM" in labels,
            "unread": "UNREAD" in labels,
            "bulk": bool(header(headers, "list-unsubscribe")),
            "body": clean(body_text(payload) or msg.get("snippet", ""), max_chars),
        })
    return mails, truncated


# --- Claude ---------------------------------------------------------------------------------------

def claude_input(mails):
    parts = ["# Kurallar (kullanıcının kendi tercihleri)", ""]
    if os.path.exists(RULES_PATH):
        with open(RULES_PATH, encoding="utf-8") as f:
            parts.append(f.read().strip())
    parts += ["", "# Mailler (%d)" % len(mails), ""]
    for m in mails:
        flags = [f for f, on in (("SPAM", m["spam"]), ("toplu gönderim", m["bulk"])) if on]
        parts.append("<mail n=\"%d\">" % m["n"])
        parts.append("Kimden: " + m["from"])
        parts.append("Kime: " + m["to"])
        parts.append("Tarih: " + m["date"] + (" · " + ", ".join(flags) if flags else ""))
        parts.append("Konu: " + m["subject"])
        parts.append("")
        parts.append(m["body"].replace("</mail>", "</ mail>"))
        parts.append("</mail>")
        parts.append("")
    return "\n".join(parts)


def parse_answer(text, count):
    text = text.strip()
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < start:
        return None
    try:
        data = json.loads(text[start:end + 1])
    except ValueError:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("items"), list):
        return None
    items = []
    for item in data["items"]:
        if (isinstance(item, dict) and isinstance(item.get("n"), int) and 1 <= item["n"] <= count
                and item.get("level") in ("acil", "hafta")):
            items.append({"n": item["n"], "level": item["level"], "why": str(item.get("why", "")).strip()})
    return {"items": items, "skipped": str(data.get("skipped", "")).strip()}


def classify(config, mails):
    with open(PROMPT_PATH, encoding="utf-8") as f:
        system = f.read()
    stdin = claude_input(mails)
    tried = []
    for account in config["accounts"]:
        env = dict(os.environ)
        env.pop("CLAUDE_CONFIG_DIR", None)
        if account.get("configDir"):
            env["CLAUDE_CONFIG_DIR"] = account["configDir"]
        # Claude Code thinks by default; on nine mails that was 12k tokens, ~85% of the cost, and
        # flagged more noise than the same model answering directly.
        env["MAX_THINKING_TOKENS"] = "0"
        cmd = [config["claude"], "-p", "--model", config.get("model", DEFAULT_MODEL),
               "--system-prompt", system,
               # No tools: the mails are untrusted text, and a model that can act could be steered
               # by one. Safe mode keeps hooks and plugins (claude-mem) from recording them.
               "--tools", "", "--safe-mode", "--no-session-persistence", "--output-format", "json"]
        print("claude: account=%s model=%s mails=%d" % (account["label"], cmd[3], len(mails)))
        try:
            done = subprocess.run(cmd, input=stdin, capture_output=True, text=True,
                                  timeout=CLAUDE_TIMEOUT, env=env, cwd=JOB_DIR)
        except subprocess.TimeoutExpired:
            tried.append(account["label"] + ": zaman aşımı")
            continue
        try:
            envelope = json.loads(done.stdout)
        except ValueError:
            envelope = {}
        if done.returncode != 0 or envelope.get("is_error"):
            tried.append("%s: rc=%d %s" % (account["label"], done.returncode,
                                           (envelope.get("result") or done.stderr or "")[:160]))
            continue
        # A usage-limit or login message can arrive as a successful run; the JSON shape is the test.
        answer = parse_answer(envelope.get("result") or "", len(mails))
        if answer is None:
            tried.append(account["label"] + ": beklenen JSON gelmedi: " + (envelope.get("result") or "")[:160])
            continue
        print("claude: ok account=%s cost=$%s" % (account["label"], envelope.get("total_cost_usd", "?")))
        answer["account"] = account["label"]
        return answer
    for line in tried:
        print("claude: fail " + line)
    return None


# --- Report ---------------------------------------------------------------------------------------

def sender_name(value):
    name = value.split("<")[0].strip().strip('"')
    return name or value.strip("<> ")


def gmail_link(email, thread_id):
    # /mail/u/<email>/ answers "Temporary Error (404)"; authuser accepts the address.
    return "https://mail.google.com/mail/?authuser=%s#all/%s" % (urllib.parse.quote(email, safe="@"), thread_id)


def render(email, mails, answer, truncated, window):
    by_n = {m["n"]: m for m in mails}
    urgent = [i for i in answer["items"] if i["level"] == "acil"]
    week = [i for i in answer["items"] if i["level"] == "hafta"]

    if urgent or week:
        counts = ", ".join(filter(None, [
            "%d acil" % len(urgent) if urgent else "",
            "%d bu hafta" % len(week) if week else "",
        ]))
        title = "AKSİYON VAR — " + counts
    else:
        title = "Aksiyon yok"

    lines = ["# " + title, "",
             "%s · %s · %d mail incelendi (%s)" % (email, window, len(mails), answer["account"]), ""]
    for heading, items in (("Acil", urgent), ("Bu hafta", week)):
        if not items:
            continue
        lines += ["## " + heading, ""]
        for item in items:
            m = by_n[item["n"]]
            extra = "".join([
                " · spam klasöründe" if m["spam"] else "",
                " · " + m["via"] + " adresine" if m["via"] else "",
            ])
            lines.append("- **%s** · %s%s  \n  %s [Gmail'de aç](%s)" % (
                sender_name(m["from"]), m["subject"], extra, item["why"], gmail_link(email, m["threadId"])))
        lines.append("")
    lines += ["## Geri kalan", ""]
    rest = len(mails) - len(urgent) - len(week)
    lines.append("%d mail aksiyon gerektirmiyor. %s" % (rest, answer["skipped"]))
    if truncated:
        lines.append("")
        lines.append("Pencerede daha fazla mail vardı, bu çalışmada sadece ilk %d tanesi okundu." % len(mails))

    if urgent or week:
        names = []
        for item in urgent + week:
            name = sender_name(by_n[item["n"]]["from"])
            if name not in names:
                names.append(name)
        shown = ", ".join(names[:3]) + (" +%d" % (len(names) - 3) if len(names) > 3 else "")
        summary = "warn %d aksiyon: %s" % (len(urgent) + len(week), shown)
    else:
        summary = "ok Aksiyon yok · %d mail" % len(mails)
    return "\n".join(lines) + "\n", summary


# --- Commands -------------------------------------------------------------------------------------

def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(value, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def result(line, report=None):
    target = os.environ.get("CHORES_RESULT")
    text = line + "\n" + ("report %s\n" % report if report else "")
    if target:
        with open(target, "w", encoding="utf-8") as f:
            f.write(text)
    print("result: " + line)


def cmd_run(_args):
    config = load_json(CONFIG_PATH, None)
    if not config:
        result("fail Kurulum yapılmamış: templates/inbox-watch/setup.sh çalıştır")
        return 0
    started = int(time.time())
    since = load_json(STATE_PATH, {}).get("since") or started - FIRST_RUN_LOOKBACK
    window = "%s → %s" % (datetime.fromtimestamp(since).strftime("%d.%m %H:%M"),
                          datetime.fromtimestamp(started).strftime("%d.%m %H:%M"))
    try:
        mails, truncated = fetch(config["email"], since, int(config.get("maxChars", DEFAULT_MAX_CHARS)))
    except AuthBroken as err:
        print("gmail: auth broken: %s" % err)
        result("fail Gmail bağlantısı düştü: setup.sh --reconnect çalıştır")
        return 0
    except (RuntimeError, OSError) as err:
        print("gmail: %s" % err)
        result("fail Gmail'e ulaşılamadı, log'a bak")
        return 0
    print("gmail: %d mail since %s" % (len(mails), window))

    if not mails:
        write_json(STATE_PATH, {"since": started})
        result("ok Yeni mail yok")
        return 0

    answer = classify(config, mails)
    if answer is None:
        # State stays put, so the next run reads these mails again.
        result("fail Claude yanıt vermedi (%d hesap denendi), log'a bak" % len(config["accounts"]))
        return 0

    report_dir = os.environ.get("CHORES_REPORT_DIR") or os.path.join(JOB_DIR, "reports")
    os.makedirs(report_dir, exist_ok=True)
    report = os.path.join(report_dir, datetime.fromtimestamp(started).strftime("%Y-%m-%d-%H%M") + ".md")
    text, summary = render(config["email"], mails, answer, truncated, window)
    with open(report, "w", encoding="utf-8") as f:
        f.write(text)
    write_json(STATE_PATH, {"since": started})
    result(summary, report)
    return 0


def cmd_fetch(args):
    config = load_json(CONFIG_PATH, {})
    mails, truncated = fetch(config["email"], args.since, int(config.get("maxChars", DEFAULT_MAX_CHARS)))
    text = claude_input(mails)
    print(text)
    print("-- %d mail, %d karakter%s" % (len(mails), len(text), ", pencere kesildi" if truncated else ""))
    return 0


def find_claude():
    candidates = [shutil.which("claude"), os.path.expanduser("~/.local/bin/claude"),
                  os.path.expanduser("~/.claude/local/claude"), "/opt/homebrew/bin/claude",
                  "/usr/local/bin/claude"]
    for path in candidates:
        if path and os.access(path, os.X_OK):
            return path
    return None


def claude_accounts(claude):
    """Logged-in Claude configurations: the default one plus every ~/.claude-* directory.

    The default must stay without CLAUDE_CONFIG_DIR: Claude keys its Keychain entry by the
    directory, so pointing it at ~/.claude explicitly looks logged out.
    """
    candidates = [("default", None)]
    for path in sorted(glob.glob(os.path.expanduser("~/.claude-*"))):
        # Only real config directories: `auth status` may write into whatever it is pointed at.
        if any(os.path.exists(os.path.join(path, name)) for name in ("settings.json", ".claude.json")):
            candidates.append((os.path.basename(path)[len(".claude-"):], path))
    found = []
    for label, config_dir in candidates:
        env = dict(os.environ)
        env.pop("CLAUDE_CONFIG_DIR", None)
        if config_dir:
            env["CLAUDE_CONFIG_DIR"] = config_dir
        try:
            out = subprocess.run([claude, "auth", "status", "--json"], capture_output=True, text=True,
                                 timeout=30, env=env)
            status = json.loads(out.stdout)
        except (subprocess.TimeoutExpired, ValueError):
            continue
        if status.get("loggedIn"):
            found.append({"label": label, "configDir": config_dir,
                          "who": status.get("email") or status.get("orgName") or ""})
    return found


def ask(prompt, default=""):
    try:
        answer = input(prompt).strip()
    except EOFError:
        answer = ""
    return answer or default


def cmd_setup(args):
    config = load_json(CONFIG_PATH, {})

    # 1. OAuth client
    client_path = args.client
    if not client_path and not keychain_get("oauth-client"):
        newest = sorted(glob.glob(os.path.expanduser("~/Downloads/client_secret_*.json")), key=os.path.getmtime)
        client_path = ask("Google OAuth istemci dosyası (client_secret_….json)%s: " % (
            " [%s]" % newest[-1] if newest else ""), newest[-1] if newest else "")
    if client_path:
        with open(os.path.expanduser(client_path), encoding="utf-8") as f:
            client = json.load(f)
        if "installed" not in client:
            sys.exit("Bu dosya bir 'Masaüstü uygulaması' istemcisi değil (içinde 'installed' yok).")
        keychain_set("oauth-client", json.dumps(client))
        print("OAuth istemcisi Keychain'e kaydedildi. İstersen dosyayı artık silebilirsin.")

    # 2. Gmail sign-in
    email = None
    if not args.reconnect and keychain_get("refresh-token"):
        try:
            email = http_json(GMAIL + "/profile", token=access_token())["emailAddress"]
            print("Gmail zaten bağlı: " + email)
        except AuthBroken:
            print("Kayıtlı Gmail bağlantısı artık geçersiz, yeniden bağlanılıyor.")
    if not email:
        tokens = sign_in(load_client())
        keychain_set("refresh-token", tokens["refresh_token"])
        email = http_json(GMAIL + "/profile", token=tokens["access_token"])["emailAddress"]
        print("Gmail bağlandı: " + email)

    # 3. Claude
    claude = find_claude()
    if not claude:
        sys.exit("claude bulunamadı. Claude Code'u kurup `claude` ile bir kez giriş yap.")
    accounts = claude_accounts(claude)
    if not accounts:
        sys.exit("Giriş yapılmış bir Claude hesabı yok. Önce `claude` ile giriş yap.")
    if len(accounts) > 1:
        print("\nGiriş yapılmış Claude hesapları (job bu sırayla dener, ilk yanıt veren kullanılır):")
        for i, account in enumerate(accounts, 1):
            print("  %d) %s  %s" % (i, account["label"], account["who"]))
        default_order = " ".join(str(i) for i in range(1, len(accounts) + 1))
        order = ask("Sıra (boşlukla ayır, istemediğini yazma) [%s]: " % default_order, default_order)
        try:
            picked = [accounts[int(x) - 1] for x in order.split()]
        except (ValueError, IndexError):
            sys.exit("Geçersiz sıra: " + order)
        accounts = picked or accounts
    for account in accounts:
        account.pop("who", None)

    config.update({
        "email": email,
        "claude": claude,
        "accounts": accounts,
        "model": config.get("model", DEFAULT_MODEL),
        "maxChars": config.get("maxChars", DEFAULT_MAX_CHARS),
    })
    write_json(CONFIG_PATH, config)
    print("\nAyarlar yazıldı: %s\n  Gmail: %s\n  Claude: %s\n  Model: %s" % (
        CONFIG_PATH, email, " → ".join(a["label"] for a in accounts), config["model"]))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    setup = sub.add_parser("setup")
    setup.add_argument("--client")
    setup.add_argument("--reconnect", action="store_true")
    sub.add_parser("run")
    fetch_cmd = sub.add_parser("fetch")
    fetch_cmd.add_argument("--since", type=int, default=int(time.time()) - FIRST_RUN_LOOKBACK)
    args = parser.parse_args()
    return {"setup": cmd_setup, "run": cmd_run, "fetch": cmd_fetch}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())

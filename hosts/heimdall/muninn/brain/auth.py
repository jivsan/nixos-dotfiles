#!/usr/bin/env python3
# muninn brain's door. nginx asks it about every request to brain.oryxserver.org (brain-auth.nix).
# a caller gets in with its own token: as "Authorization: Bearer <token>", or as the login cookie
# that /_brain/login sets from the same token. an address in MUNINN_BRAIN_ALLOW gets in without one.
# heimdall keeps only sha256 hashes of the tokens, one line per token in a root-only file:
#   <name> <sha256 hex> <paths it may use, comma separated, "/" for all> <date>
# with MUNINN_BRAIN_ENFORCE=0 nobody is refused, it only logs who would be.
#
#   auth.py serve                        the check, on 127.0.0.1:8094 for nginx's auth_request.
#                                        SIGHUP reads the hashes again (systemctl reload)
#   auth.py add NAME [PATH...] [--qr]    make a token, keep its hash, print the token once
#   auth.py revoke NAME
#   auth.py list
import datetime, hashlib, hmac, ipaddress, os, re, secrets, signal, subprocess, sys, tempfile, threading, time
from collections import namedtuple
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

TOKENS_FILE = os.environ.get("MUNINN_BRAIN_TOKENS", "/var/lib/secrets/muninn-brain-tokens")
PORT = int(os.environ.get("MUNINN_BRAIN_AUTH_PORT", "8094"))
ENFORCE = os.environ.get("MUNINN_BRAIN_ENFORCE", "0") == "1"
ORIGIN = os.environ.get("MUNINN_BRAIN_ORIGIN", "https://brain.oryxserver.org")
SUMMARY_EVERY = int(os.environ.get("MUNINN_BRAIN_AUTH_SUMMARY", "3600"))
COOKIE = "__Host-brain"   # __Host-: only this exact site can set it, no other *.oryxserver.org app
COOKIE_AGE = 365 * 86400
# traefik runs on heimdall itself, so only a peer on loopback may tell us who the caller is.
# nginx can't tell traefik from any other program on heimdall that connects to 127.0.0.1:8090,
# so such a program can claim any address: one more reason MUNINN_BRAIN_ALLOW stays empty
TRUSTED_PEERS = {"127.0.0.1", "::1"}
# open to all, so the blackbox probe and homarr's ping still go through this check:
# with enforce on, a dead check fails the probe like it fails the whole brain
PING = "/_brain/ping"

Token = namedtuple("Token", "name digest paths")
NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,39}")
DIGEST = re.compile(r"[0-9a-f]{64}")
TOKEN_CHARS = re.compile(r"[A-Za-z0-9_-]{16,200}")
# a token for some paths only gets plain paths: no %-escapes, dot segments, double slashes or ";",
# so the path nginx routes on and the path checked here are the same string
PLAIN_PATH = re.compile(r"/|(/[A-Za-z0-9_][A-Za-z0-9_.-]*)+/?")


def parse_tokens(text):
    out = []
    for line in text.splitlines():
        f = line.split()
        if len(f) < 3 or f[0].startswith("#"):
            continue
        paths = tuple(p for p in f[2].split(",") if p)
        if NAME.fullmatch(f[0]) and DIGEST.fullmatch(f[1].lower()) and paths:
            out.append(Token(f[0], f[1].lower(), paths))
    return out


def digest(token):
    return hashlib.sha256(token.encode("utf-8", "replace")).hexdigest()


def find_token(tokens, presented):
    """the token whose hash matches, compared in constant time against every stored hash."""
    if not presented:
        return None
    d = digest(presented)
    found = None
    for t in tokens:
        if hmac.compare_digest(t.digest, d) and found is None:
            found = t
    return found


def client_ip(peer, xff):
    """who the caller is: nginx's peer, or, when that peer is traefik on loopback, the last
    X-Forwarded-For entry. traefik 3.7 drops forwarded headers from clients it doesn't trust (no
    trustedIPs here) and appends the address it saw, so the last entry is that address even if a
    client sent its own header. X-Real-IP is never read. any other program on heimdall that talks
    to nginx directly looks like traefik here and can name any address."""
    peer = (peer or "").strip()
    if peer not in TRUSTED_PEERS:
        return peer
    if not (xff or "").strip():
        return peer   # straight to nginx on heimdall, not through traefik
    try:
        return str(ipaddress.ip_address(xff.split(",")[-1].strip()))
    except ValueError:
        return ""


def path_allowed(paths, uri):
    if "/" in paths:
        return True
    path = (uri or "").split("?", 1)[0]
    if not PLAIN_PATH.fullmatch(path):
        return False
    path = path.rstrip("/") or "/"
    return any(path == p.rstrip("/") or path.startswith(p.rstrip("/") + "/") for p in paths)


def bearer(value):
    """the token from an Authorization header, "" for an empty one, None when there is none."""
    if value is None:
        return None
    scheme, _, rest = value.strip().partition(" ")
    return rest.strip() if scheme.lower() == "bearer" else None


def cookie_token(value):
    for part in (value or "").split(";"):
        k, _, v = part.strip().partition("=")
        if k == COOKIE:
            return v.strip().strip('"')
    return None


def in_allow(ip, allow):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(a in n for n in allow)


def parse_allow(text):
    return [ipaddress.ip_network(x, strict=False) for x in (text or "").split()]


def decide(tokens, allow, peer, xff, authorization, cookie, uri):
    """(ok, token name or None, how or why not, caller's address)"""
    ip = client_ip(peer, xff)
    if (uri or "").split("?", 1)[0] == PING:
        return True, None, "ping", ip
    for how, presented in (("token", bearer(authorization)), ("cookie", cookie_token(cookie))):
        if presented is None:
            continue
        t = find_token(tokens, presented)
        if t is None:
            return False, None, "unknown " + how, ip
        if not path_allowed(t.paths, uri):
            return False, t.name, "outside its paths", ip
        return True, t.name, how, ip
    if ip and in_allow(ip, allow):
        return True, None, "address", ip
    return False, None, "no token", ip


def head(uri):
    """the start of a path for the log: /bridge/usage, /api/read, /vault, never a note name or query."""
    parts = [p for p in (uri or "").split("?", 1)[0].split("/") if p][:2]
    if not parts:
        return "/"
    keep = parts if parts[0] in ("bridge", "api", "_brain") else parts[:1]
    return "/" + "/".join(re.sub(r"[^A-Za-z0-9._-]", "?", p)[:40] for p in keep)


class Tally:
    """logs each new (outcome, caller, method, path) at once, then counts per hour, never tokens."""
    def __init__(self, out=print, cap=2000):
        self.out, self.cap = out, cap
        self.lock = threading.Lock()
        self.seen, self.counts = set(), {}

    def add(self, key):
        with self.lock:
            new = key not in self.seen and len(self.seen) < self.cap
            if new:
                self.seen.add(key)
            if key in self.counts or len(self.counts) < self.cap:
                self.counts[key] = self.counts.get(key, 0) + 1
        if new:
            self.out(" ".join(key), flush=True)

    def flush(self):
        with self.lock:
            counts, self.counts = self.counts, {}
        for key, n in sorted(counts.items()):
            self.out(f"last {SUMMARY_EVERY // 60} min: {n}x " + " ".join(key), flush=True)


STATE = {"tokens": [], "allow": []}
TALLY = Tally()

PAGE = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>muninn brain</title><style>
body{{background:#0b0d12;color:#d8dce6;font:16px system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;padding:16px;box-sizing:border-box}}
form{{max-width:420px;width:100%}}input{{width:100%;box-sizing:border-box;padding:10px;margin:12px 0;background:#151922;color:inherit;border:1px solid #2a3140;border-radius:6px;font:inherit}}
button{{padding:10px 16px;background:#a277ff;color:#0b0d12;border:0;border-radius:6px;font:inherit;cursor:pointer}}p.msg{{color:#ff8a8a}}
</style></head><body><form method="post" action="/_brain/login">
<h1>muninn brain</h1><p>this page needs a login. paste your token (from <code>muninn-brain-token</code> on heimdall).</p>
{msg}<input type="password" name="token" autocomplete="current-password" autofocus aria-label="token">
<button type="submit">log in</button></form></body></html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "muninn-brain-auth"
    sys_version = ""

    def log_message(self, *a):
        pass

    def send(self, status, body=b"", ctype="text/plain; charset=utf-8", headers=()):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def page(self, status, msg=""):
        body = PAGE.format(msg=f'<p class="msg">{msg}</p>' if msg else "").encode()
        self.send(status, body, "text/html; charset=utf-8", (
            ("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'"),
            # not no-referrer: then browsers send "Origin: null" with the form and login() refuses it
            ("Referrer-Policy", "same-origin"),
        ))

    def caller(self):
        return client_ip(self.headers.get("X-Brain-Peer", ""), ",".join(self.headers.get_all("X-Forwarded-For") or []))

    def route(self):
        path = self.path.split("?", 1)[0]
        if path == "/check":
            return self.check()
        if path == "/_brain/login" and self.command == "POST":
            return self.login()
        if path == "/_brain/login" and self.command in ("GET", "HEAD"):
            return self.page(200)
        if path == "/_brain/logout" and self.command in ("GET", "HEAD", "POST"):
            return self.send(303, headers=(("Location", "/_brain/login"),
                                           ("Set-Cookie", f"{COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict")))
        self.send(404, b"not found\n")

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = route

    def check(self):
        h = self.headers
        ok, name, how, ip = decide(STATE["tokens"], STATE["allow"], h.get("X-Brain-Peer", ""),
                                   ",".join(h.get_all("X-Forwarded-For") or []),
                                   h.get("Authorization"), h.get("Cookie"), h.get("X-Original-URI", "/"))
        method = h.get("X-Original-Method", "")
        method = method if re.fullmatch(r"[A-Z]{1,10}", method) else "?"
        outcome = "ok " + name if ok and name else "ok" if ok else "refused" if ENFORCE else "would refuse"
        if how != "ping":   # the probe every 15 s, not worth a log line
            TALLY.add((outcome, ip or "?", method, head(h.get("X-Original-URI", "/")), f"({how})"))
        self.send(204 if ok or not ENFORCE else 401)

    def login(self):
        origin = self.headers.get("Origin")
        if origin and origin != ORIGIN:
            return self.page(403, "this login only works from the brain's own page.")
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        if n < 0 or n > 4096:
            return self.page(413, "too long.")
        form = parse_qs(self.rfile.read(n).decode("utf-8", "replace"))
        presented = (form.get("token") or [""])[0].strip()
        t = find_token(STATE["tokens"], presented) if TOKEN_CHARS.fullmatch(presented) else None
        if t is None:
            print(f"login refused {self.caller() or '?'}", flush=True)
            time.sleep(1)
            return self.page(401, "that token is not known here.")
        print(f"login ok {t.name} {self.caller() or '?'}", flush=True)
        self.send(303, headers=(("Location", "/"),
                                ("Set-Cookie", f"{COOKIE}={presented}; Path=/; Max-Age={COOKIE_AGE}; HttpOnly; Secure; SameSite=Strict")))


def load_tokens(path):
    """reads the hashes into STATE. a file that can't be read keeps the tokens already loaded."""
    try:
        with open(path, encoding="utf-8") as fh:
            STATE["tokens"] = parse_tokens(fh.read())
    except OSError as e:
        print(f"muninn-brain-auth: can't read the tokens at {path}: {e.strerror}", flush=True)
    return len(STATE["tokens"])


def serve():
    creds = os.environ.get("CREDENTIALS_DIRECTORY")
    path = os.path.join(creds, "tokens") if creds else TOKENS_FILE
    load_tokens(path)
    STATE["allow"] = parse_allow(os.environ.get("MUNINN_BRAIN_ALLOW", ""))

    # systemctl reload hands the service a fresh copy of the file (RefreshOnReload) and sends SIGHUP,
    # so a new or revoked token counts without a restart, and nginx never finds the check gone.
    # read once more 2 s later in case the fresh copy lands after the signal
    def reload():
        print(f"muninn-brain-auth: reloaded, {load_tokens(path)} tokens", flush=True)

    def on_hup(*_):
        reload()
        threading.Timer(2, reload).start()
    signal.signal(signal.SIGHUP, on_hup)

    def summaries():
        while True:
            time.sleep(SUMMARY_EVERY)
            TALLY.flush()
    threading.Thread(target=summaries, daemon=True).start()
    print(f"muninn-brain-auth: 127.0.0.1:{PORT} {'refusing' if ENFORCE else 'log only, refusing nobody'}, "
          f"{len(STATE['tokens'])} tokens, {len(STATE['allow'])} allowed addresses", flush=True)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    srv.serve_forever()


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def read_tokens_file():
    try:
        with open(TOKENS_FILE, encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""
    except PermissionError:
        die(f"can't read {TOKENS_FILE}: run it with sudo")


def write_tokens_file(text):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(TOKENS_FILE), prefix=".muninn-brain-tokens.")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, TOKENS_FILE)
    except BaseException:
        os.unlink(tmp)
        raise


def cmd_add(args):
    qr = "--qr" in args
    args = [a for a in args if a != "--qr"]
    if not args or not NAME.fullmatch(args[0]):
        die("usage: muninn-brain-token add NAME [PATH...] [--qr]   (name: lowercase, digits, -)")
    name, paths = args[0], args[1:] or ["/"]
    for p in paths:
        if not PLAIN_PATH.fullmatch(p):
            die(f"not a plain path: {p}")
    text = read_tokens_file()
    if any(t.name == name for t in parse_tokens(text)):
        die(f"{name} already has a token. revoke it first.")
    token = "mb_" + secrets.token_urlsafe(32)
    line = f"{name} {digest(token)} {','.join(paths)} {datetime.date.today().isoformat()}\n"
    try:
        write_tokens_file(text + ("\n" if text and not text.endswith("\n") else "") + line)
    except PermissionError:
        die(f"can't write {TOKENS_FILE}: run it with sudo")
    if qr:
        qrencode = os.environ.get("MUNINN_QRENCODE", "qrencode")
        try:
            subprocess.run([qrencode, "-t", "ansiutf8"], input=token.encode(), stdout=sys.stderr, check=True)
        except (OSError, subprocess.CalledProcessError):
            print("(no qr code: qrencode failed)", file=sys.stderr)
    if sys.stdout.isatty():
        print(f"token for {name}, shown once and not kept here:", file=sys.stderr)
    print(token, flush=True)


def cmd_revoke(args):
    if len(args) != 1:
        die("usage: muninn-brain-token revoke NAME")
    text = read_tokens_file()
    keep = [line for line in text.splitlines(keepends=True) if not (line.split()[:1] == [args[0]])]
    if len(keep) == len(text.splitlines(keepends=True)):
        die(f"no token named {args[0]}")
    try:
        write_tokens_file("".join(keep))
    except PermissionError:
        die(f"can't write {TOKENS_FILE}: run it with sudo")
    print(f"revoked {args[0]}", file=sys.stderr)


def cmd_list(args):
    for line in read_tokens_file().splitlines():
        f = line.split()
        if len(f) >= 3 and not f[0].startswith("#"):
            print(f"{f[0]:<24} {f[2]:<40} {f[3] if len(f) > 3 else ''}")


def main(argv):
    cmds = {"serve": lambda a: serve(), "add": cmd_add, "revoke": cmd_revoke, "list": cmd_list}
    if not argv or argv[0] not in cmds:
        die("usage: muninn-brain-token add NAME [PATH...] [--qr] | revoke NAME | list")
    cmds[argv[0]](argv[1:])


if __name__ == "__main__":
    main(sys.argv[1:])

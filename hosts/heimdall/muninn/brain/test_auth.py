"""Tests for the brain's door (auth.py): who gets in, who doesn't, and the token file.

Run with: python3 -m unittest discover -s hosts/heimdall/muninn/brain -p 'test_auth.py'
"""
import http.client
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

import auth

HERE = Path(__file__).resolve().parent
BROWSER = "mb_browser-token-0123456789abcdefghijklmnop"
USAGE = "mb_usage-token-0123456789abcdefghijklmnopqrs"
READ = "mb_read-token-0123456789abcdefghijklmnopqrstu"
TOKENS = auth.parse_tokens(
    f"# a comment\n"
    f"mjolnir-browser {auth.digest(BROWSER)} / 2026-11-01\n"
    f"mjolnir-usage {auth.digest(USAGE)} /bridge/usage 2026-11-01\n"
    f"mjolnir-read {auth.digest(READ)} /bridge/jobs,/bridge/skills,/bridge/health 2026-11-01\n"
    f"broken-line nothex /\n"
)
NO_ALLOW = []
PHONE = auth.parse_allow("10.0.50.10")


def check(peer="127.0.0.1", xff="10.0.20.100", authorization=None, cookie=None, uri="/", allow=NO_ALLOW):
    return auth.decide(TOKENS, allow, peer, xff, authorization, cookie, uri)


class TokenFileTests(unittest.TestCase):
    def test_parse_keeps_good_lines_only(self):
        self.assertEqual([t.name for t in TOKENS], ["mjolnir-browser", "mjolnir-usage", "mjolnir-read"])
        self.assertEqual(TOKENS[1].paths, ("/bridge/usage",))
        self.assertEqual(TOKENS[2].paths, ("/bridge/jobs", "/bridge/skills", "/bridge/health"))

    def test_load_tokens_keeps_the_old_ones_when_the_file_is_gone(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(auth.STATE, {"tokens": []}), \
                mock.patch("builtins.print"):
            path = Path(d) / "tokens"
            path.write_text(f"a {auth.digest(USAGE)} /bridge/usage\n")
            self.assertEqual(auth.load_tokens(str(path)), 1)
            path.unlink()
            self.assertEqual(auth.load_tokens(str(path)), 1)
            self.assertEqual(auth.STATE["tokens"][0].name, "a")

    def test_find_token_compares_hashes(self):
        self.assertEqual(auth.find_token(TOKENS, BROWSER).name, "mjolnir-browser")
        self.assertIsNone(auth.find_token(TOKENS, BROWSER + "x"))
        self.assertIsNone(auth.find_token(TOKENS, ""))
        self.assertIsNone(auth.find_token(TOKENS, None))
        # the stored value is a hash, so presenting the hash itself is no good
        self.assertIsNone(auth.find_token(TOKENS, auth.digest(BROWSER)))


class DecideTests(unittest.TestCase):
    def test_bearer_token_gets_in(self):
        self.assertEqual(check(authorization="Bearer " + BROWSER)[:3], (True, "mjolnir-browser", "token"))
        self.assertTrue(check(authorization="bearer   " + BROWSER)[0])

    def test_cookie_gets_in(self):
        self.assertEqual(check(cookie=f"other=1; {auth.COOKIE}={BROWSER}")[:3], (True, "mjolnir-browser", "cookie"))

    def test_no_token_is_refused(self):
        self.assertEqual(check()[:3], (False, None, "no token"))

    def test_wrong_token_is_refused(self):
        self.assertEqual(check(authorization="Bearer mb_wrong")[:3], (False, None, "unknown token"))
        self.assertEqual(check(cookie=f"{auth.COOKIE}=mb_wrong")[:3], (False, None, "unknown cookie"))

    def test_empty_token_is_refused(self):
        for a in ("Bearer", "Bearer ", "Bearer    "):
            self.assertEqual(check(authorization=a)[:3], (False, None, "unknown token"), a)
        self.assertEqual(check(cookie=f"{auth.COOKIE}=")[:3], (False, None, "unknown cookie"))

    def test_other_auth_schemes_count_as_none(self):
        self.assertEqual(check(authorization="Basic " + BROWSER)[:3], (False, None, "no token"))

    def test_wrong_token_does_not_fall_back_to_cookie_or_address(self):
        self.assertFalse(check(authorization="Bearer mb_wrong", cookie=f"{auth.COOKIE}={BROWSER}")[0])
        self.assertFalse(check(authorization="Bearer mb_wrong", xff="10.0.50.10", allow=PHONE)[0])

    def test_scoped_token_only_on_its_paths(self):
        a = "Bearer " + USAGE
        for uri in ("/bridge/usage", "/bridge/usage/", "/bridge/usage?x=1"):
            self.assertTrue(check(authorization=a, uri=uri)[0], uri)
        # the usage token every host has can't talk, run or reach hermes
        for uri in ("/", "/bridge/talk", "/bridge/hermes", "/bridge/run", "/bridge/usagex", "/api/read?path=x",
                    "/vault/a.md", "/bridge/usage/../hermes", "/bridge/usage/%2e%2e/hermes", "/bridge//usage",
                    "/bridge/usage/./x", "/bridge/%75sage", "/bridge/usage;/../hermes", "bridge/usage", ""):
            self.assertEqual(check(authorization=a, uri=uri)[:3], (False, "mjolnir-usage", "outside its paths"), uri)

    def test_token_with_several_paths(self):
        a = "Bearer " + READ
        for uri in ("/bridge/jobs", "/bridge/jobs/0123abcd", "/bridge/skills", "/bridge/health"):
            self.assertTrue(check(authorization=a, uri=uri)[0], uri)
        for uri in ("/bridge/talk", "/bridge/usage", "/bridge/jobs/../talk"):
            self.assertFalse(check(authorization=a, uri=uri)[0], uri)

    def test_ping_is_open(self):
        for kw in ({}, {"authorization": "Bearer mb_wrong"}, {"peer": "10.0.20.66"}):
            self.assertEqual(check(uri="/_brain/ping", **kw)[:3], (True, None, "ping"), kw)
        self.assertTrue(check(uri="/_brain/ping?x=1")[0])
        # only that exact path
        for uri in ("/_brain/ping/x", "/_brain/pingx", "/_brain/%70ing", "/_brain//ping", "/x/_brain/ping"):
            self.assertFalse(check(uri=uri)[0], uri)

    def test_address_allow_only_through_traefik(self):
        # traefik on loopback says the caller is the phone
        self.assertEqual(check(xff="10.0.50.10", allow=PHONE)[:4], (True, None, "address", "10.0.50.10"))
        # the last entry is what traefik saw, whatever the client put before it
        self.assertFalse(check(xff="10.0.50.10, 10.0.20.66", allow=PHONE)[0])
        self.assertTrue(check(xff="1.2.3.4, 10.0.50.10", allow=PHONE)[0])
        # a peer that isn't loopback can't name another address
        self.assertEqual(check(peer="10.0.20.66", xff="10.0.50.10", allow=PHONE)[:4], (False, None, "no token", "10.0.20.66"))
        self.assertEqual(check(peer="10.88.200.10", xff="10.0.50.10", allow=PHONE)[3], "10.88.200.10")
        # garbage in the header gives no address at all
        self.assertEqual(check(xff="10.0.50.10, not-an-ip", allow=PHONE)[:4], (False, None, "no token", ""))
        # empty allow list lets no address in
        self.assertFalse(check(xff="10.0.50.10")[0])

    def test_missing_peer_header_trusts_nothing(self):
        self.assertEqual(check(peer="", xff="10.0.50.10", allow=PHONE)[:4], (False, None, "no token", ""))

    def test_head_never_logs_notes_or_queries(self):
        self.assertEqual(auth.head("/vault/journal/2026-11-01.md"), "/vault")
        self.assertEqual(auth.head("/bridge/jobs/abc123?x=secret"), "/bridge/jobs")
        self.assertEqual(auth.head("/api/read?path=journal/x.md"), "/api/read")
        self.assertEqual(auth.head("/graph.json?_=1"), "/graph.json")
        self.assertEqual(auth.head("/"), "/")
        self.assertEqual(auth.head("/bridge/a\r\nb"), "/bridge/a??b")


class TallyTests(unittest.TestCase):
    def test_new_keys_logged_once_then_counted(self):
        lines = []
        t = auth.Tally(out=lambda s, flush=False: lines.append(s))
        for _ in range(3):
            t.add(("would refuse", "10.0.20.21", "POST", "/bridge/usage", "(no token)"))
        self.assertEqual(lines, ["would refuse 10.0.20.21 POST /bridge/usage (no token)"])
        t.flush()
        self.assertTrue(lines[-1].endswith("3x would refuse 10.0.20.21 POST /bridge/usage (no token)"))


class ServerTests(unittest.TestCase):
    """the real handler on a spare port, asked the way nginx asks it."""

    def start(self, enforce):
        patches = [mock.patch.object(auth, "ENFORCE", enforce),
                   mock.patch.dict(auth.STATE, {"tokens": TOKENS, "allow": PHONE}),
                   mock.patch.object(auth, "TALLY", auth.Tally(out=lambda s, flush=False: None)),
                   mock.patch("builtins.print"), mock.patch.object(auth.time, "sleep")]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        srv = auth.ThreadingHTTPServer(("127.0.0.1", 0), auth.Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        self.port = srv.server_address[1]

    def ask(self, method, path, headers=None, body=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request(method, path, body=body, headers=headers or {})
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, dict(r.getheaders()), data

    def nginx(self, **h):
        base = {"X-Brain-Peer": "127.0.0.1", "X-Forwarded-For": "10.0.20.100",
                "X-Original-URI": "/bridge/hermes", "X-Original-Method": "POST"}
        base.update(h)
        return base

    def test_log_only_lets_everyone_in(self):
        self.start(False)
        self.assertEqual(self.ask("GET", "/check", self.nginx())[0], 204)
        self.assertEqual(self.ask("GET", "/check", self.nginx(Authorization="Bearer mb_wrong"))[0], 204)

    def test_ping_is_not_logged(self):
        self.start(False)
        lines = []
        auth.TALLY.out = lambda s, flush=False: lines.append(s)
        self.ask("GET", "/check", self.nginx(**{"X-Original-URI": "/_brain/ping"}))
        self.assertEqual(lines, [])
        self.ask("GET", "/check", self.nginx())
        self.assertEqual(lines, ["would refuse 10.0.20.100 POST /bridge/hermes (no token)"])

    def test_enforce(self):
        self.start(True)
        self.assertEqual(self.ask("GET", "/check", self.nginx())[0], 401)
        self.assertEqual(self.ask("GET", "/check", self.nginx(Authorization="Bearer mb_wrong"))[0], 401)
        self.assertEqual(self.ask("GET", "/check", self.nginx(Authorization="Bearer "))[0], 401)
        self.assertEqual(self.ask("GET", "/check", self.nginx(Authorization="Bearer " + BROWSER))[0], 204)
        self.assertEqual(self.ask("GET", "/check", self.nginx(Cookie=f"{auth.COOKIE}={BROWSER}"))[0], 204)
        self.assertEqual(self.ask("GET", "/check", self.nginx(Authorization="Bearer " + USAGE))[0], 401)
        self.assertEqual(self.ask("GET", "/check", self.nginx(**{"Authorization": "Bearer " + USAGE,
                                                                "X-Original-URI": "/bridge/talk"}))[0], 401)
        self.assertEqual(self.ask("GET", "/check", self.nginx(**{"Authorization": "Bearer " + USAGE,
                                                                "X-Original-URI": "/bridge/usage"}))[0], 204)
        # the ping, with no token
        self.assertEqual(self.ask("GET", "/check", self.nginx(**{"X-Original-URI": "/_brain/ping",
                                                                "X-Original-Method": "GET"}))[0], 204)
        # the phone by address, and a spoofed address from a peer that isn't traefik
        self.assertEqual(self.ask("GET", "/check", self.nginx(**{"X-Forwarded-For": "10.0.50.10"}))[0], 204)
        self.assertEqual(self.ask("GET", "/check", self.nginx(**{"X-Brain-Peer": "10.0.20.66",
                                                                "X-Forwarded-For": "10.0.50.10"}))[0], 401)
        # X-Real-IP is never read
        self.assertEqual(self.ask("GET", "/check", self.nginx(**{"X-Real-IP": "10.0.50.10"}))[0], 401)
        # nginx may ask with any method
        self.assertEqual(self.ask("POST", "/check", self.nginx(Authorization="Bearer " + BROWSER))[0], 204)

    def test_login_sets_cookie(self):
        self.start(True)
        form = {"Content-Type": "application/x-www-form-urlencoded", "Origin": "https://brain.oryxserver.org"}
        status, headers, _ = self.ask("POST", "/_brain/login", form, "token=" + BROWSER)
        self.assertEqual(status, 303)
        self.assertEqual(headers["Location"], "/")
        cookie = headers["Set-Cookie"]
        self.assertTrue(cookie.startswith(f"{auth.COOKIE}={BROWSER};"))
        for flag in ("HttpOnly", "Secure", "SameSite=Strict", "Path=/"):
            self.assertIn(flag, cookie)

    def test_login_refuses(self):
        self.start(True)
        form = {"Content-Type": "application/x-www-form-urlencoded", "Origin": "https://brain.oryxserver.org"}
        self.assertEqual(self.ask("POST", "/_brain/login", form, "token=mb_wrong-but-long-enough")[0], 401)
        self.assertEqual(self.ask("POST", "/_brain/login", form, "token=")[0], 401)
        # a header break in the token never reaches Set-Cookie
        status, headers, _ = self.ask("POST", "/_brain/login", form, "token=" + BROWSER + "%0d%0aX-Evil:%201")
        self.assertEqual(status, 401)
        self.assertNotIn("X-Evil", headers)
        bad_origin = dict(form, Origin="https://evil.example")
        self.assertEqual(self.ask("POST", "/_brain/login", bad_origin, "token=" + BROWSER)[0], 403)
        self.assertEqual(self.ask("POST", "/_brain/login", dict(form, Origin="null"), "token=" + BROWSER)[0], 403)

    def test_login_page_and_logout(self):
        self.start(True)
        status, headers, body = self.ask("GET", "/_brain/login")
        self.assertEqual(status, 200)
        self.assertIn(b'name="token"', body)
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        status, headers, _ = self.ask("GET", "/_brain/logout")
        self.assertEqual(status, 303)
        self.assertIn("Max-Age=0", headers["Set-Cookie"])
        self.assertEqual(self.ask("GET", "/anything")[0], 404)


class TokenToolTests(unittest.TestCase):
    """add, list and revoke against a scratch tokens file."""

    def run_tool(self, *args, path):
        env = dict(os.environ, MUNINN_BRAIN_TOKENS=str(path), PYTHONDONTWRITEBYTECODE="1")
        return subprocess.run([sys.executable, str(HERE / "auth.py"), *args], env=env,
                              capture_output=True, text=True)

    def test_add_list_revoke(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "tokens"
            r = self.run_tool("add", "mjolnir-read", "/bridge/jobs", "/bridge/health", path=path)
            self.assertEqual(r.returncode, 0, r.stderr)
            token = r.stdout.strip()
            self.assertRegex(token, r"^mb_[A-Za-z0-9_-]{43}$")
            text = path.read_text()
            self.assertNotIn(token, text)          # only the hash is kept
            self.assertIn(auth.digest(token), text)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(auth.find_token(auth.parse_tokens(text), token).paths, ("/bridge/jobs", "/bridge/health"))
            self.assertNotEqual(self.run_tool("add", "mjolnir-read", path=path).returncode, 0)   # one per name
            self.assertNotEqual(self.run_tool("add", "Bad Name", path=path).returncode, 0)
            self.assertNotEqual(self.run_tool("add", "x", "/bridge/../hermes", path=path).returncode, 0)
            r2 = self.run_tool("add", "phone", path=path)
            self.assertIn("mjolnir-read", self.run_tool("list", path=path).stdout)
            self.assertNotIn(token, self.run_tool("list", path=path).stdout)
            self.assertEqual(self.run_tool("revoke", "mjolnir-read", path=path).returncode, 0)
            left = auth.parse_tokens(path.read_text())
            self.assertEqual([t.name for t in left], ["phone"])
            self.assertIsNone(auth.find_token(left, token))
            self.assertIsNotNone(auth.find_token(left, r2.stdout.strip()))
            self.assertNotEqual(self.run_tool("revoke", "mjolnir-read", path=path).returncode, 0)


class ReloadTests(unittest.TestCase):
    """auth.py serve as systemd runs it: tokens from $CREDENTIALS_DIRECTORY, read again on SIGHUP."""

    def test_sighup_reads_the_tokens_again(self):
        with tempfile.TemporaryDirectory() as d:
            creds = Path(d)
            (creds / "tokens").write_text(f"mjolnir-usage {auth.digest(USAGE)} /bridge/usage\n")
            with socket.socket() as s:
                s.bind(("127.0.0.1", 0))
                port = s.getsockname()[1]
            env = dict(os.environ, CREDENTIALS_DIRECTORY=d, MUNINN_BRAIN_AUTH_PORT=str(port),
                       MUNINN_BRAIN_ENFORCE="1", MUNINN_BRAIN_TOKENS=str(creds / "not-this-one"),
                       PYTHONDONTWRITEBYTECODE="1")
            p = subprocess.Popen([sys.executable, str(HERE / "auth.py"), "serve"], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self.addCleanup(p.wait, 5)
            self.addCleanup(p.kill)

            def status(token):
                for _ in range(50):
                    try:
                        c = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
                        c.request("GET", "/check", headers={"X-Brain-Peer": "127.0.0.1", "X-Original-URI": "/bridge/usage",
                                                            "Authorization": "Bearer " + token})
                        return c.getresponse().status
                    except OSError:
                        time.sleep(0.1)
                self.fail("auth.py serve never answered")

            self.assertEqual(status(USAGE), 204)
            self.assertEqual(status(READ), 401)
            # what systemctl reload does: a fresh copy of the file, then SIGHUP
            (creds / "tokens").write_text(f"mjolnir-read {auth.digest(READ)} /\n")
            p.send_signal(signal.SIGHUP)
            for _ in range(50):
                if status(READ) == 204:
                    break
                time.sleep(0.1)
            self.assertEqual(status(READ), 204)
            self.assertEqual(status(USAGE), 401)    # revoked without a restart
            self.assertIsNone(p.poll())             # still the same process
            p.kill()
            out = p.communicate(timeout=5)[0]
            self.assertIn("reloaded, 1 tokens", out)
            self.assertNotIn(USAGE, out)
            self.assertNotIn(READ, out)


if __name__ == "__main__":
    unittest.main()

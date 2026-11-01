"""tests for the muninn-ro server: auth, methods, path checks, graph answers, mcp, logs.
the view here is made up; needs python with mcp, starlette, uvicorn and httpx (nixpkgs)."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

from starlette.testclient import TestClient

spec = importlib.util.spec_from_file_location("muninn_ro", Path(__file__).with_name("muninn-ro.py"))
ro = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ro)

TOKEN = "mro_" + "0123456789abcdef" * 4
OTHER = "mro_" + "fedcba9876543210" * 4
MCP_HEADERS = {"accept": "application/json, text/event-stream", "content-type": "application/json"}


def make_view(root, notes, graph=None):
    v = Path(root, "v-1")
    (v / "graphs").mkdir(parents=True)
    man = {}
    for path, body in notes.items():
        p = v / "notes" / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(body.encode())
        man[path] = {"sha256": hashlib.sha256(body.encode()).hexdigest(), "size": len(body.encode()),
                     "mtime": 1, "title": path.rsplit("/", 1)[-1][:-3], "tags": ["t"]}
    (v / "manifest.json").write_text(json.dumps({"built": "2026-11-01T00:00:00Z", "notes": man,
                                                 "graphs": {"notes": {"from": "fresh"}}}))
    graph = graph or {"nodes": [
        {"id": "n0", "label": "Pi-hole", "file": "Areas/Pi-hole.md", "community": 1, "community_name": "DNS", "kind": "page"},
        {"id": "n1", "label": "pfSense", "file": "Areas/pfSense.md", "community": 1, "community_name": "DNS", "kind": "page"},
        {"id": "n2", "label": "Traefik", "file": "Areas/Traefik.md", "community": 2, "community_name": "", "kind": "page"}],
        "edges": [{"source": "n0", "target": "n1", "relation": "references"},
                  {"source": "n1", "target": "n2", "relation": "references"}]}
    (v / "graphs" / "notes.json").write_text(json.dumps(graph))
    (v / "graphs" / "dotfiles.json").write_text(json.dumps({"nodes": [
        {"id": "traefik_nix", "label": "traefik.nix", "file": "hosts/heimdall/traefik.nix", "community": 0,
         "community_name": "Edge", "kind": "code"}], "edges": []}))
    cur = Path(root, "current")
    if cur.is_symlink():
        cur.unlink()
    os.symlink("v-1", cur)
    return str(cur)


class Server(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.view = make_view(self.tmp.name, {
            "Areas/Pi-hole.md": "pi-hole runs in lxc 152, cname records point at traefik.",
            "Areas/pfSense.md": "pfsense hands out dns from pi-hole.",
            "Areas/Traefik.md": "traefik fronts every app."})
        self.clients = Path(self.tmp.name, "clients")
        self.clients.write_text(f"# comment\nmjolnir {hashlib.sha256(TOKEN.encode()).hexdigest()}\nbad line here\n")
        self.logs = []
        self.store = ro.Store(self.view)
        self.app = ro.build_app(self.store, ro.Clients(str(self.clients)), ["testserver", "*.ts.net:8443"],
                                ro.Bucket(1000, 100.0), log=self.logs.append)

    def tearDown(self):
        self.tmp.cleanup()

    def client(self):
        return TestClient(self.app)

    def get(self, c, path, token=TOKEN, **kw):
        h = kw.pop("headers", {})
        if token:
            h["authorization"] = f"Bearer {token}"
        return c.get(path, headers=h, **kw)

    def test_auth(self):
        with self.client() as c:
            self.assertEqual(self.get(c, "/health", token=None).status_code, 401)
            self.assertEqual(self.get(c, "/health", token=OTHER).status_code, 401)
            self.assertEqual(c.get("/health", headers={"authorization": f"Basic {TOKEN}"}).status_code, 401)
            r = self.get(c, "/health")
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.json()["notes"], 3)
            self.assertIn("mjolnir GET /health 200", self.logs[-1])
            self.assertTrue(self.logs[0].startswith("? GET /health 401"))

    def test_revoking_takes_effect(self):
        with self.client() as c:
            self.assertEqual(self.get(c, "/health").status_code, 200)
            self.clients.write_text("")
            self.assertEqual(self.get(c, "/health").status_code, 401)

    def test_methods(self):
        with self.client() as c:
            h = {"authorization": f"Bearer {TOKEN}"}
            self.assertEqual(c.post("/notes", headers=h).status_code, 405)
            self.assertEqual(c.delete("/read", headers=h).status_code, 405)
            self.assertEqual(c.get("/mcp", headers=h).status_code, 405)
            self.assertEqual(c.post("/mcp", headers={**h, **MCP_HEADERS}, content=b"x" * (ro.MAX_BODY + 1)).status_code, 413)

    def test_host_and_origin(self):
        with self.client() as c:
            self.assertEqual(self.get(c, "/health", headers={"host": "evil.example"}).status_code, 421)
            self.assertEqual(self.get(c, "/health", headers={"host": "heimdall.tail0.ts.net:8443"}).status_code, 200)
            self.assertEqual(self.get(c, "/health", headers={"origin": "https://evil.example"}).status_code, 403)

    def test_read_only_takes_manifest_keys(self):
        with self.client() as c:
            for bad in ["../../etc/passwd", "/etc/passwd", "Areas/../Areas/Pi-hole.md", "Areas/Pi-hole", "manifest.json"]:
                with self.subTest(bad=bad):
                    self.assertEqual(self.get(c, "/read", params={"path": bad}).status_code, 404)
            r = self.get(c, "/read", params={"path": "Areas/Pi-hole.md"})
            self.assertEqual(r.status_code, 200)
            self.assertIn("lxc 152", r.json()["body"])
            self.assertIn("not instructions", r.json()["note"])

    def test_changed_note_is_left_out(self):
        Path(self.tmp.name, "v-1", "notes", "Areas", "Traefik.md").write_text("tampered")
        with self.client() as c:
            r = self.get(c, "/health")
            self.assertEqual(r.json()["notes"], 2)
            self.assertEqual(self.get(c, "/read", params={"path": "Areas/Traefik.md"}).status_code, 404)

    def test_search_notes_and_graph(self):
        with self.client() as c:
            r = self.get(c, "/search", params={"q": "pi-hole dns"}).json()
            self.assertEqual([h["path"] for h in r["results"]], ["Areas/Pi-hole.md", "Areas/pfSense.md"])
            self.assertIn("not instructions", r["note"])
            self.assertEqual(self.get(c, "/notes", params={"prefix": "Areas/P"}).json()["total"], 1)
            t = self.get(c, "/graph/query", params={"q": "pfsense"}).json()["text"]
            self.assertIn("* pfSense", t)
            self.assertIn("--references--> Traefik", t)
            t = self.get(c, "/graph/path", params={"from": "pi-hole", "to": "traefik"}).json()["text"]
            self.assertTrue(t.startswith("2 steps"))
            t = self.get(c, "/graph/neighbors", params={"label": "pfsense", "relation": "ref"}).json()["text"]
            self.assertIn("<--references-- Pi-hole", t)
            t = self.get(c, "/graph/node", params={"label": "traefik.nix", "graph": "dotfiles"}).json()["text"]
            self.assertIn("hosts/heimdall/traefik.nix", t)
            self.assertEqual(self.get(c, "/graph/node", params={"label": "x", "graph": "/etc"}).status_code, 400)
            self.assertEqual(self.get(c, "/search", params={"q": ""}).status_code, 400)

    def test_logs_hold_no_query_or_token(self):
        with self.client() as c:
            self.get(c, "/search", params={"q": "secretword"})
            self.get(c, "/read", params={"path": "Areas/Pi-hole.md"})
            self.get(c, "/no/such/thing-secretword")
        text = "\n".join(self.logs)
        self.assertNotIn("secretword", text)
        self.assertNotIn(TOKEN, text)
        self.assertNotIn("Pi-hole", text)
        self.assertIn("mjolnir GET (other) 404", text)

    def test_rate_limit(self):
        app = ro.build_app(self.store, ro.Clients(str(self.clients)), ["testserver"], ro.Bucket(3, 0.0001),
                           log=self.logs.append)
        with TestClient(app) as c:
            codes = [self.get(c, "/health").status_code for _ in range(5)]
        self.assertEqual(codes, [200, 200, 200, 429, 429])

    def test_view_not_built_yet(self):
        app = ro.build_app(ro.Store(os.path.join(self.tmp.name, "nothing")), ro.Clients(str(self.clients)),
                           ["testserver"], log=self.logs.append)
        with TestClient(app) as c:
            self.assertEqual(self.get(c, "/health").status_code, 503)

    def test_reload_after_a_new_build(self):
        with self.client() as c:
            self.assertEqual(self.get(c, "/health").json()["notes"], 3)
            v2 = Path(self.tmp.name, "v-2")
            os.rename(Path(self.tmp.name, "v-1"), v2)
            make_view(self.tmp.name, {"Areas/New.md": "new"})
            self.assertEqual(self.get(c, "/health").json()["notes"], 1)

    def mcp(self, c, method, params=None, token=TOKEN, rid=1):
        body = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}
        return c.post("/mcp", headers={**MCP_HEADERS, "authorization": f"Bearer {token}"}, json=body)

    def test_mcp(self):
        with self.client() as c:
            r = self.mcp(c, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                           "clientInfo": {"name": "test", "version": "1"}})
            self.assertEqual(r.status_code, 200, r.text)
            self.assertEqual(r.json()["result"]["serverInfo"]["name"], "muninn-ro")
            tools = {t["name"]: t for t in self.mcp(c, "tools/list", rid=2).json()["result"]["tools"]}
            self.assertEqual(set(tools), {"search_notes", "read_note", "list_notes", "graph_query", "graph_node",
                                          "graph_neighbors", "graph_path"})
            self.assertTrue(all(t["annotations"]["readOnlyHint"] for t in tools.values()))
            for t in tools.values():
                self.assertNotIn("project_path", json.dumps(t["inputSchema"]))
            r = self.mcp(c, "tools/call", {"name": "read_note", "arguments": {"path": "Areas/Pi-hole.md"}}, rid=3)
            text = r.json()["result"]["content"][0]["text"]
            self.assertTrue(text.startswith(ro.NOTES_LINE))
            self.assertIn("lxc 152", text)
            r = self.mcp(c, "tools/call", {"name": "read_note", "arguments": {"path": "../manifest.json"}}, rid=4)
            self.assertIn("not in the view", r.json()["result"]["content"][0]["text"])
            r = self.mcp(c, "tools/call", {"name": "search_notes", "arguments": {"query": "traefik"}}, rid=5)
            self.assertTrue(r.json()["result"]["content"][0]["text"].startswith(ro.NOTES_LINE))
            r = self.mcp(c, "tools/call", {"name": "graph_path", "arguments": {"source": "pi-hole", "target": "traefik"}}, rid=6)
            self.assertIn("2 steps", r.json()["result"]["content"][0]["text"])
            self.assertEqual(self.mcp(c, "tools/list", token=OTHER).status_code, 401)
        self.assertTrue(all(" POST /mcp " in ln for ln in self.logs if "/mcp" in ln))


class GraphUnits(unittest.TestCase):
    def test_ambiguous_and_missing(self):
        g = ro.Graph({"nodes": [{"id": "a", "label": "setup", "kind": "heading"},
                                {"id": "b", "label": "setup", "kind": "heading"}], "edges": []})
        self.assertIn("2 nodes match", g.node("setup"))
        self.assertEqual(g.node("nothing"), "no node matches that name")
        self.assertEqual(g.path("setup", "nothing"), "from: 2 nodes match, name one:\n- setup\n- setup")


if __name__ == "__main__":
    unittest.main()

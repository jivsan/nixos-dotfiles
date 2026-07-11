{ pkgs, ... }:
# ── muninn brain — live animated knowledge-graph frontend ────────────────────
# A builder regenerates graph.json + activity.json from the vault every 30s
# (fast, no LLM), nginx serves the single-page 3D force-graph app on localhost,
# and Traefik exposes it at brain.oryxserver.org (behind lan-only).
let
  vault = "/mnt/nas/obsidian/muninn";
  www   = "/var/lib/muninn-brain/www";

  # Vendored, pinned JS libs served same-origin — no CDN at runtime (the esm.sh
  # module chain proved flaky in-browser and one failed import killed all page JS).
  # three 0.160.0 is the last release shipping a classic UMD build; 3d-force-graph
  # 1.79.0 accepts three >=0.118 and its official examples use exactly this pairing.
  threeJs = pkgs.fetchurl {
    url = "https://unpkg.com/three@0.160.0/build/three.min.js";
    hash = "sha256-FwxnifQyF8lrMXD0tC+v4TXef3zUhJekIY+XV+4dSfo=";
  };
  forceGraphJs = pkgs.fetchurl {
    url = "https://unpkg.com/3d-force-graph@1.79.0/dist/3d-force-graph.min.js";
    hash = "sha256-Khop08zFFZ8EobULFj/LkDMzwCaxIr/4WKcJZbLDjoc=";
  };

  buildGraph = pkgs.writeShellApplication {
    name = "muninn-brain-build";
    # git + systemctl: activity.json includes the vault audit log and huginn
    # timer/service health
    runtimeInputs = [ pkgs.python3Minimal pkgs.coreutils pkgs.git pkgs.systemd ];
    text = ''python3 ${../../muninn/brain/build-graph.py}'';
  };

  # Tiny stdlib-only capture endpoint.
  # POST /capture with {"text": "..."} or raw text → writes capture-*.md into the vault _inbox/.
  capturePy = pkgs.writeText "muninn-capture.py" ''
#!/usr/bin/env python3
import http.server
import socketserver
import os
import time
import json

VAULT = "/mnt/nas/obsidian/muninn"
INBOX = os.path.join(VAULT, "_inbox")

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/capture":
            self.send_error(404)
            return
        length = int(self.headers.get("content-length", 0) or 0)
        body = self.rfile.read(length).decode("utf-8", errors="replace")
        try:
            data = json.loads(body)
            text = data.get("text", body)
        except Exception:
            text = body
        text = (text or "").strip()
        if not text:
            self.send_error(400, "empty note")
            return
        ts = time.strftime("%Y-%m-%d-%H%M%S")
        fn = f"capture-{ts}.md"
        path = os.path.join(INBOX, fn)
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(text + "\n")
            os.chmod(path, 0o644)
            resp = json.dumps({"ok": True, "file": fn}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
        except Exception as e:
            self.send_error(500, str(e))

    def log_message(self, fmt, *args):
        pass  # quiet

if __name__ == "__main__":
    os.makedirs(INBOX, exist_ok=True)
    PORT = 8091
    with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
        httpd.serve_forever()
'';

  # ── muninn FTS5 search indexer (from muninn-os v0.3) ──────────────────────
  indexerPy = pkgs.writeText "muninn-indexer.py" ''
#!/usr/bin/env python3
import os, sys, time, sqlite3, signal, logging

VAULT = "/mnt/nas/obsidian/muninn"
DB = "/var/lib/muninn-brain/index.db"
STATE = "/var/lib/muninn-brain/indexer-state"

logging.basicConfig(level=logging.INFO, format="%(asctime)s muninn-indexer %(levelname)s %(message)s", stream=sys.stdout)
log = logging.getLogger("muninn-indexer")
SKIP = {".obsidian", "_templates", "agents", "graphify-out", ".git", "node_modules"}

def connect():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    conn = sqlite3.connect(DB, timeout=30)
    conn.execute("PRAGMA journal_mode=WAL"); conn.execute("PRAGMA synchronous=NORMAL")
    return conn

def init(conn): conn.executescript("""
CREATE TABLE IF NOT EXISTS notes (path TEXT PRIMARY KEY, mtime INTEGER, title TEXT, body TEXT, tags TEXT);
CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(path UNINDEXED, title, body, tokenize='porter unicode61');
CREATE TABLE IF NOT EXISTS tags (path TEXT, tag TEXT, PRIMARY KEY(path, tag));
CREATE INDEX IF NOT EXISTS notes_mtime_idx ON notes(mtime);
"""); conn.commit()

def parse_fm(text):
    title, tags = "", []
    body = text
    if text.startswith("---\n"):
        parts = text.split("---", 2)
        if len(parts) >= 3:
            for line in parts[1].splitlines():
                if ":" in line:
                    k, _, v = line.partition(":"); v = v.strip()
                    if k.strip() == "title": title = v
                    elif k.strip() == "tags":
                        tags = [t.strip().strip('"') for t in v.strip("[]").split(",") if t.strip()]
            body = parts[2]
    if not title:
        for line in body.splitlines():
            if line.startswith("# "): title = line[2:].strip(); break
    return body, title, tags

def index_file(conn, path):
    if not path.endswith(".md"): return
    rel = os.path.relpath(path, VAULT)
    if any(p in SKIP or p.startswith(".") for p in rel.split(os.sep)): return
    if not os.path.exists(path):
        for t in ("notes", "notes_fts", "tags"): conn.execute(f"DELETE FROM {t} WHERE path=?", (rel,))
        return
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh: text = fh.read()
        mtime = int(os.path.getmtime(path))
    except OSError: return
    body, title, tags = parse_fm(text)
    conn.execute("INSERT INTO notes(path,mtime,title,body,tags) VALUES(?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime,title=excluded.title,body=excluded.body,tags=excluded.tags", (rel, mtime, title, body, ",".join(tags)))
    conn.execute("DELETE FROM notes_fts WHERE path=?", (rel,))
    conn.execute("INSERT INTO notes_fts(path,title,body) VALUES(?,?,?)", (rel, title, body))
    conn.execute("DELETE FROM tags WHERE path=?", (rel,))
    conn.executemany("INSERT OR IGNORE INTO tags(path,tag) VALUES(?,?)", [(rel, t) for t in tags])

def full_reindex(conn):
    n, seen = 0, set()
    for root, dirs, files in os.walk(VAULT):
        dirs[:] = [d for d in dirs if d not in SKIP and not d.startswith(".")]
        for fn in files:
            if not fn.endswith(".md"): continue
            index_file(conn, os.path.join(root, fn))
            seen.add(os.path.relpath(os.path.join(root, fn), VAULT)); n += 1
    for r in [r[0] for r in conn.execute("SELECT path FROM notes") if r[0] not in seen]:
        for t in ("notes", "notes_fts", "tags"): conn.execute(f"DELETE FROM {t} WHERE path=?", (r,))
    conn.commit()
    log.info("reindex: %d files (%d stale purged)", n, sum(1 for r in conn.execute("SELECT path FROM notes") if r[0] not in seen))

def run():
    conn = connect(); init(conn); full_reindex(conn)
    mtimes = {r[0]: r[1] for r in conn.execute("SELECT path,mtime FROM notes")}
    while True:
        time.sleep(60)
        cur = {}
        for root, dirs, files in os.walk(VAULT):
            dirs[:] = [d for d in dirs if d not in SKIP and not d.startswith(".")]
            for fn in files:
                if not fn.endswith(".md"): continue
                try: cur[os.path.relpath(os.path.join(root, fn), VAULT)] = int(os.path.getmtime(os.path.join(root, fn)))
                except OSError: pass
        ch = [os.path.join(VAULT, r) for r, m in cur.items() if mtimes.get(r) != m]
        rm = set(mtimes) - set(cur)
        for p in ch: index_file(conn, p)
        for rel in rm:
            for t in ("notes", "notes_fts", "tags"): conn.execute(f"DELETE FROM {t} WHERE path=?", (rel,))
        if ch or rm: conn.commit()
        mtimes = cur

def main():
    os.makedirs(VAULT, exist_ok=True); os.makedirs(STATE, exist_ok=True)
    log.info("starting vault=%s db=%s", VAULT, DB)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    run()

if __name__ == "__main__": main()
'';

  # ── muninn REST API (from muninn-os v0.3) ─────────────────────────────────
  apiPy = pkgs.writeText "muninn-api.py" ''
#!/usr/bin/env python3
import hmac, json, os, re, time, datetime, sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

VAULT = "/mnt/nas/obsidian/muninn"
DB = "/var/lib/muninn-brain/index.db"
WIKILINK = re.compile(r"\[\[([^\]|#]+)")
TOKEN = os.environ.get("MUNINN_API_TOKEN", "").strip()

def connect():
    if not os.path.exists(DB): raise FileNotFoundError(f"no index at {DB}")
    conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True); conn.row_factory = sqlite3.Row; return conn

def parse_fm(text):
    title, tags = "", []
    body = text
    if text.startswith("---\n"):
        parts = text.split("---", 2)
        if len(parts) >= 3:
            for line in parts[1].splitlines():
                if ":" in line:
                    k, _, v = line.partition(":"); v = v.strip()
                    if k.strip() == "title": title = v
                    elif k.strip() == "tags":
                        tags = [t.strip().strip('"') for t in v.strip("[]").split(",") if t.strip()]
            body = parts[2]
    if not title:
        for line in body.splitlines():
            if line.startswith("# "): title = line[2:].strip(); break
    return body, title, tags

def wlinks(text): return {m.group(1).strip().split("/")[-1] for m in WIKILINK.finditer(text)}

class H(BaseHTTPRequestHandler):
    def log_message(self, f, *a): pass
    def _j(self, s, p):
        b = json.dumps(p, indent=2, default=str).encode()
        self.send_response(s); self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _auth(self):
        if not TOKEN: return True
        a = self.headers.get("Authorization", "")
        if a.startswith("Bearer ") and hmac.compare_digest(a[7:].strip(), TOKEN): return True
        self._j(401, {"error": "unauthorized"}); return False
    def do_GET(self):
        if not self._auth(): return
        u = urlparse(self.path); p = u.path.rstrip("/") or "/"
        try:
            if p == "/health": return self._health()
            if p == "/search": return self._search(u)
            if p == "/graph": return self._graph(u)
            if p == "/read": return self._read(u)
            if p == "/mocs": return self._mocs()
            if p == "/": return self._j(200, {"service":"muninn-api","endpoints":["/health","/search","/graph","/read","/mocs","/inbox"]})
            self._j(404, {"error": f"unknown: {p}"})
        except Exception as e: self._j(500, {"error": str(e)})
    def do_POST(self):
        if not self._auth(): return
        p = urlparse(self.path).path.rstrip("/")
        if p != "/inbox": return self._j(404, {"error": f"unknown POST: {p}"})
        l = int(self.headers.get("content-length", 0) or 0)
        if l > 262144: return self._j(413, {"error": "body too large"})
        try: b = json.loads(self.rfile.read(l).decode())
        except: return self._j(400, {"error": "invalid JSON"})
        try: self._inbox(b)
        except Exception as e: self._j(500, {"error": str(e)})
    def _health(self):
        c = connect()
        n = c.execute("SELECT COUNT(*) FROM notes").fetchone()[0]
        m = c.execute("SELECT COUNT(*) FROM notes WHERE path LIKE 'MOCs/%'").fetchone()[0]
        i = c.execute("SELECT COUNT(*) FROM notes WHERE path LIKE '_inbox/%'").fetchone()[0]; c.close()
        self._j(200, {"ok":True,"vault":VAULT,"stats":{"notes":n,"mocs":m,"inbox":i}})
    def _search(self, u):
        qs = parse_qs(u.query); q = (qs.get("q") or [""])[0].strip()
        lim = max(1, min(100, int((qs.get("limit") or ["10"])[0])))
        if not q: return self._j(400, {"error":"missing ?q="})
        c = connect()
        try:
            rs = c.execute("SELECT n.path,n.title,n.mtime,n.tags,snippet(notes_fts,1,'<<','>>','...',12) AS snip,bm25(notes_fts) AS score FROM notes_fts JOIN notes n ON n.path=notes_fts.path WHERE notes_fts MATCH ? ORDER BY score LIMIT ?", (q, lim)).fetchall()
        except sqlite3.OperationalError as e: c.close(); return self._j(400, {"error":f"FTS5: {e}"})
        c.close()
        self._j(200, {"query":q,"count":len(rs),"results":[{"path":r["path"],"title":r["title"] or os.path.basename(r["path"])[:-3],"snippet":r["snip"],"tags":[t for t in (r["tags"] or "").split(",") if t],"mtime":r["mtime"],"score":r["score"]} for r in rs]})
    def _graph(self, u):
        qs = parse_qs(u.query); p = (qs.get("path") or [""])[0].strip()
        d = int((qs.get("depth") or ["1"])[0])
        if not p: return self._j(400, {"error":"missing ?path="})
        c = connect(); r = c.execute("SELECT path,title,body FROM notes WHERE path=?",(p,)).fetchone()
        if not r: c.close(); return self._j(404, {"error":f"not found: {p}"})
        body = r["body"] or ""; on = wlinks(body)
        op = set()
        if on:
            ph = ",".join("?"*len(on))
            for x in c.execute(f"SELECT path,title FROM notes WHERE title IN ({ph})", list(on)): op.add((x["path"],x["title"]))
        t = r["title"]; inc = set()
        for x in c.execute("SELECT path,body FROM notes WHERE path!=?",(p,)):
            if t and t in (x["body"] or "") and t in wlinks(x["body"] or ""):
                tr = c.execute("SELECT title FROM notes WHERE path=?",(x["path"],)).fetchone()
                inc.add((x["path"],tr["title"] if tr else ""))
        c.close()
        self._j(200,{"path":p,"title":r["title"],"outgoing":[{"path":p,"title":t}for(p,t)in sorted(op)],"incoming":[{"path":p,"title":t}for(p,t)in sorted(inc)]})
    def _read(self, u):
        qs = parse_qs(u.query); p = (qs.get("path") or [""])[0].strip()
        if not p: return self._j(400, {"error":"missing ?path="})
        full = os.path.realpath(os.path.join(VAULT, p))
        if not full.startswith(os.path.realpath(VAULT)+os.sep): return self._j(400, {"error":"path escapes vault"})
        if not os.path.exists(full): return self._j(404, {"error":f"not found: {p}"})
        try:
            with open(full, encoding="utf-8", errors="ignore") as fh: text = fh.read()
        except OSError as e: return self._j(500, {"error":str(e)})
        body, title, tags = parse_fm(text)
        self._j(200,{"path":p,"title":title,"tags":tags,"body":body,"size":len(text),"mtime":int(os.path.getmtime(full))})
    def _mocs(self):
        c = connect()
        rs = c.execute("SELECT path,title,body FROM notes WHERE path LIKE 'MOCs/%' ORDER BY title").fetchall()
        out = []
        for r in rs:
            ln = wlinks(r["body"] or "")
            lp = []
            if ln:
                ph = ",".join("?"*len(ln))
                for x in c.execute(f"SELECT path,title FROM notes WHERE title IN ({ph})", list(ln)): lp.append({"path":x["path"],"title":x["title"]})
            out.append({"path":r["path"],"title":r["title"],"links_to":lp})
        c.close(); self._j(200,{"mocs":out,"count":len(out)})
    def _inbox(self, b):
        text = (b.get("text") or "").strip()
        if not text: return self._j(400, {"error":"missing text"})
        def clean(v): return re.sub(r"[\r\n\[\]#:,]"," ",str(v)).strip()[:80]
        agent = clean(b.get("agent","anonymous")) or "anonymous"
        tags = [clean(t) for t in b.get("tags",[]) if clean(t)][:10]
        today = datetime.date.today().isoformat()
        fm = f"---\ntype: note\nstatus: inbox\ntags: [{', '.join(tags)}]\ncreated: {today}\nagent: {agent}\nsource: muninn-api\n---\n\n"
        ts = datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
        d = os.path.join(VAULT, "_inbox"); os.makedirs(d, exist_ok=True)
        for i in range(1000):
            fn = f"capture-{ts}.md" if i==0 else f"capture-{ts}-{i}.md"
            p = os.path.join(d, fn)
            try: fd = os.open(p, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o664); break
            except FileExistsError: continue
        else: raise OSError("no free filename")
        with os.fdopen(fd,"w",encoding="utf-8") as fh: fh.write(fm+text+"\n")
        os.chmod(p, 0o664)
        self._j(200,{"ok":True,"file":os.path.relpath(p,VAULT)})

def main():
    print(f"muninn-api: vault={VAULT} db={DB} 127.0.0.1:8092", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 8092), H).serve_forever()

if __name__ == "__main__": main()
'';

in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/muninn-brain 0755 christina users -"
    "d ${www} 0755 christina users -"
    "d /var/lib/muninn-brain/indexer-state 0755 christina users -"
    # index.html + vendored libs are served from the store; refreshed on each rebuild
    "L+ ${www}/index.html - - - - ${../../muninn/brain/index.html}"
    "d ${www}/vendor 0755 christina users -"
    "L+ ${www}/vendor/three.min.js - - - - ${threeJs}"
    "L+ ${www}/vendor/3d-force-graph.min.js - - - - ${forceGraphJs}"
  ];

  # regenerate the graph data from the vault, on a fast cadence for a "live" feel
  systemd.services."muninn-brain-build" = {
    description = "muninn brain: rebuild graph.json + activity.json from the vault";
    unitConfig.RequiresMountsFor = vault;
    serviceConfig = {
      Type = "oneshot";
      User = "christina";
      Group = "users";
      ExecStart = "${buildGraph}/bin/muninn-brain-build";
    };
  };
  systemd.timers."muninn-brain-build" = {
    description = "muninn brain build cadence";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "30s";
    };
  };

  # Live capture endpoint (writes directly to _inbox/)
  systemd.services."muninn-brain-capture" = {
    description = "muninn brain: capture endpoint for dashboard quick notes";
    unitConfig.RequiresMountsFor = vault;
    serviceConfig = {
      Type = "simple";
      User = "christina";
      Group = "users";
      ExecStart = "${pkgs.python3}/bin/python3 ${capturePy}";
      Restart = "always";
      RestartSec = "5s";
    };
    wantedBy = [ "multi-user.target" ];
  };

  # ── FTS5 search indexer (from muninn-os v0.3) ──────────────────────────
  # Real-time SQLite FTS5 index over the vault. Powers muninn-api /search.
  # Runs as christina, same vault perms model as the rest of muninn.
  systemd.services."muninn-indexer" = {
    description = "muninn indexer: keep FTS5 search index in sync with the vault";
    unitConfig.RequiresMountsFor = vault;
    serviceConfig = {
      Type = "simple";
      User = "christina";
      Group = "users";
      ExecStart = "${pkgs.python3}/bin/python3 ${indexerPy}";
      Restart = "always";
      RestartSec = "5s";
      NoNewPrivileges = true;
    };
    wantedBy = [ "multi-user.target" ];
  };

  # ── muninn REST API (from muninn-os v0.3) ─────────────────────────────
  # Stdlib HTTP API on 127.0.0.1:8092. /health, /search, /graph, /read,
  # /mocs, POST /inbox. Reads from the FTS5 index built by muninn-indexer.
  systemd.services."muninn-api" = {
    description = "muninn API: HTTP API for agents to query + write to the vault";
    after = [ "muninn-indexer.service" ];
    requires = [ "muninn-indexer.service" ];
    unitConfig.RequiresMountsFor = vault;
    serviceConfig = {
      Type = "simple";
      User = "christina";
      Group = "users";
      ExecStart = "${pkgs.python3}/bin/python3 ${apiPy}";
      Restart = "always";
      RestartSec = "5s";
      NoNewPrivileges = true;
    };
    wantedBy = [ "multi-user.target" ];
  };

  # static server on localhost; Traefik fronts it (see traefik.nix → brain router)
  services.nginx = {
    enable = true;
    virtualHosts."muninn-brain" = {
      listen = [ { addr = "127.0.0.1"; port = 8090; } ];
      root = www;
      locations."/".index = "index.html";
      locations."~ \\.json$".extraConfig = "add_header Cache-Control no-store;";
      # raw vault markdown for the Memory reader (read-only; behind lan-only Traefik).
      # ^~ = prefix-priority so the .json regex above can't shadow vault files;
      # the nested location denies dotfiles/-dirs (.obsidian, .git, …).
      locations."^~ /vault/" = {
        alias = "${vault}/";
        extraConfig = ''
          default_type text/plain;
          charset utf-8;
          add_header Cache-Control no-store;
          location ~ /\. { return 404; }
        '';
      };
      # muninn REST API (search, graph, read, mocs, inbox) — from muninn-os v0.3
      locations."/api/" = {
        proxyPass = "http://127.0.0.1:8092/";
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header Host $host;
        '';
      };
      # capture endpoint (dashboard quick notes → _inbox/)
      locations."/capture" = {
        proxyPass = "http://127.0.0.1:8091";
        extraConfig = ''
          proxy_http_version 1.1;
        '';
      };
    };
  };
}

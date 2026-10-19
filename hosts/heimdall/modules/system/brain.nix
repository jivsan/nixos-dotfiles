{ pkgs, inputs, ... }:
# muninn brain: my dashboard (a 3d graph of the vault) and the services behind it, all on localhost
# nginx 8090 (brain.oryxserver.org via traefik.nix, lan-only), capture 8091, api 8092, bridge 8093
let
  vault = "/mnt/nas/obsidian/muninn";
  www   = "/var/lib/muninn-brain/www";

  # bridge.py imports jobs.py and embed.py, so they sit next to it; embed.py also runs the embedder
  bridge = pkgs.runCommand "muninn-bridge" {} ''
    mkdir -p "$out"
    cp ${../../muninn/brain/bridge.py} "$out/bridge.py"
    cp ${../../muninn/brain/jobs.py} "$out/jobs.py"
    cp ${../../muninn/brain/embed.py} "$out/embed.py"
  '';

  # pinned js served by my own nginx, no cdn at runtime (one failed cdn import used to kill the whole page)
  # three stays at 0.160.0, the last with a classic umd build; 3d-force-graph 1.79.0 goes with it
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
    # git + systemd: activity.json shows the vault's git log and huginn's timers and units
    runtimeInputs = [ pkgs.python3Minimal pkgs.coreutils pkgs.git pkgs.systemd ];
    text = ''python3 ${../../muninn/brain/build-graph.py}'';
  };

  # the dashboard's quick notes: POST /capture {"text": ...} or raw text writes _inbox/capture-<time>.md
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
  # claude-code is unfree and heimdall doesn't import modules/apps/unfree.nix, so allow just it here
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (pkgs.lib.getName pkg) [ "claude-code" ];

  systemd.tmpfiles.rules = [
    "d /var/lib/muninn-brain 0755 christina users -"
    "d ${www} 0755 christina users -"
    "d /var/lib/muninn-brain/indexer-state 0755 christina users -"
    # links into the store: a change to index.html shows up after a rebuild
    "L+ ${www}/index.html - - - - ${../../muninn/brain/index.html}"
    "d ${www}/vendor 0755 christina users -"
    "L+ ${www}/vendor/three.min.js - - - - ${threeJs}"
    "L+ ${www}/vendor/3d-force-graph.min.js - - - - ${forceGraphJs}"
  ];

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

  # sqlite fts5 index of the vault in /var/lib/muninn-brain/index.db, read by the api and the embedder
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

  # embeds new or changed notes with the model on mimir (hosts/mimir/modules/system/embeddings.nix)
  # if mimir is down it waits and the bridge falls back to keyword search
  # a first run over the whole vault takes about an hour
  systemd.services."muninn-embedder" = {
    description = "muninn embedder: keep the vault's embedding index in sync";
    after = [ "muninn-indexer.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      User = "christina";
      Group = "users";
      ExecStart = "${pkgs.python3}/bin/python3 ${bridge}/embed.py";
      Restart = "always";
      RestartSec = "30s";
      NoNewPrivileges = true;
    };
    wantedBy = [ "multi-user.target" ];
  };

  # rest api for agents (/health /search /graph /read /mocs, POST /inbox), nginx serves it as /api/
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

  # the front door: jev sorts each request into a command, an answer or agent work
  # no NoNewPrivileges here: "run now" starts huginn units through sudo
  systemd.services."muninn-bridge" = {
    description = "muninn bridge: Jev-routed talk, voice proxy and skills for the brain";
    after = [ "muninn-indexer.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = vault;
    # git + shell tools for codex, which works in the vault; util-linux for setpriv, so workers can't sudo
    path = [ pkgs.systemd pkgs.git pkgs.bashInteractive pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.ripgrep pkgs.util-linux ];
    environment.MUNINN_CODEX =
      "${inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.codex}/bin/codex";
    # claude (deep answer tier) uses my claude code subscription: run claude on heimdall once and /login
    environment.MUNINN_CLAUDE = "${pkgs.claude-code}/bin/claude";
    serviceConfig = {
      Type = "simple";
      User = "christina";
      Group = "users";
      EnvironmentFile = [
        "-/var/lib/secrets/graphify-openrouter.env"   # OPENAI_API_KEY (openrouter) for jev and minimax
        "-/var/lib/secrets/muninn-bridge.env"         # HERMES_API_KEY=<API_SERVER_KEY from yggdrasil>
        # minimax goes through my ai-gateway (client "bridge" in ai-gateway.nix); read last so its url wins,
        # drop it to call openrouter direct. jev has its own url and isn't affected
        (pkgs.writeText "bridge-via-gateway.env" "OPENAI_BASE_URL=http://127.0.0.1:4000/client/bridge/v1\n")
      ];
      ExecStart = "${pkgs.python3}/bin/python3 ${bridge}/bridge.py";
      Restart = "always";
      RestartSec = "5s";
    };
    wantedBy = [ "multi-user.target" ];
  };

  services.nginx = {
    enable = true;
    virtualHosts."muninn-brain" = {
      listen = [ { addr = "127.0.0.1"; port = 8090; } ];
      root = www;
      locations."/".index = "index.html";
      locations."~ \\.json$".extraConfig = "add_header Cache-Control no-store;";
      # raw vault markdown for the memory reader, read-only
      # ^~ so the .json regex above can't take vault files
      # the nested location 404s dotfiles (.obsidian, .git)
      locations."^~ /vault/" = {
        alias = "${vault}/";
        extraConfig = ''
          default_type text/plain;
          charset utf-8;
          add_header Cache-Control no-store;
          location ~ /\. { return 404; }
        '';
      };
      locations."/api/" = {
        proxyPass = "http://127.0.0.1:8092/";
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header Host $host;
        '';
      };
      # voice uploads and model calls need the bigger body size and the long timeout
      locations."/bridge/" = {
        proxyPass = "http://127.0.0.1:8093";
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_read_timeout 180s;
          client_max_body_size 25m;
        '';
      };
      locations."/capture" = {
        proxyPass = "http://127.0.0.1:8091";
        extraConfig = ''
          proxy_http_version 1.1;
        '';
      };
    };
  };
}

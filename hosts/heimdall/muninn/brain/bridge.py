#!/usr/bin/env python3
# muninn bridge — the front door of the agentic OS.
# Every request (typed or spoken) goes through Jev first, which sorts it into
# one of three tiers:
#   command  no AI at all: open a view, search, capture, run a skill
#   answer   a quick model (MiniMax) answers from the vault + config graph
#   agent    real work: hermes on hermod (its API server), or Codex headless on
#            heimdall, sandboxed to the vault
# The bridge also proxies the local voice server (Whisper + Kokoro on mimir),
# lists and starts skills, reports subscription usage, and logs every exchange
# back into the vault.
import datetime, glob, json, os, re, shutil, socket, sqlite3, subprocess, tempfile, threading, time
import urllib.error, urllib.request, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VAULT = os.environ.get("MUNINN_VAULT", "/mnt/nas/obsidian/muninn")
DB = os.environ.get("MUNINN_DB", "/var/lib/muninn-brain/index.db")
PORT = int(os.environ.get("MUNINN_BRIDGE_PORT", "8093"))
LOG_DIR = os.environ.get("MUNINN_TALK_LOG_DIR", os.path.join(VAULT, "Resources", "Talk logs"))
KEY = os.environ.get("OPENAI_API_KEY", "").strip()
BASE = os.environ.get("OPENAI_BASE_URL", "https://openrouter.ai/api/v1").rstrip("/")
MODEL = os.environ.get("OPENAI_MODEL", "minimax/minimax-m3")
JEV_URL = os.environ.get("JEV_URL", "https://openrouter.ai/api/v1/systemone")
JEV_MODEL = os.environ.get("JEV_MODEL", "typesafe/jev-1.13")
VOICE = os.environ.get("MUNINN_VOICE_URL", "http://10.0.20.18:8000").rstrip("/")
STT_MODEL = os.environ.get("MUNINN_STT_MODEL", "Systran/faster-whisper-small")
TTS_MODEL = os.environ.get("MUNINN_TTS_MODEL", "speaches-ai/Kokoro-82M-v1.0-ONNX")
TTS_VOICE = os.environ.get("MUNINN_TTS_VOICE", "af_heart")
GRAPHIFY = os.environ.get("MUNINN_GRAPHIFY", "/var/lib/huginn/.local/bin/graphify")
CODE_GRAPH = "/var/lib/huginn/graphs/dotfiles/graph.json"
SUDO = "/run/wrappers/bin/sudo"
CODEX = os.environ.get("MUNINN_CODEX", "codex")
CODEX_HOME = os.path.expanduser(os.environ.get("CODEX_HOME", "~/.codex"))
USAGE_FILE = os.environ.get("MUNINN_USAGE_FILE", "/var/lib/muninn-brain/usage.json")
HERMES_URL = os.environ.get("MUNINN_HERMES_URL", "http://10.0.20.21:8642").rstrip("/")
HERMES_KEY = os.environ.get("HERMES_API_KEY", "").strip()
JOBS, LOCK = {}, threading.Lock()
AGENT_BRIEF = ("You are working inside Christina's Obsidian vault, muninn. Read CLAUDE.md in this directory first "
               "and follow its conventions: frontmatter on every note, link new notes to a MOC, never touch "
               ".obsidian/, _templates/ or agents/. Put deliverables in Resources/Outputs/ unless told otherwise. "
               "End with two plain spoken sentences saying what you did and where the result is.\n\nRequest: ")

# The skill backbone: domain → task → skill → automation. Only things that
# really exist on heimdall; `unit` is the systemd unit a run button starts.
SKILLS = [
    {"id": "inbox-sweep", "domain": "Memory", "task": "file what I capture", "skill": "/inbox-sweep",
     "does": "titles, tags and files inbox notes", "unit": "huginn-inbox-sweep", "auto": "on capture · 08:15 14:15 20:15", "kind": "event"},
    {"id": "daily-digest", "domain": "Memory", "task": "remember the day", "skill": "/daily-digest",
     "does": "summarises today into the journal", "unit": "huginn-daily-digest", "auto": "daily 23:00", "kind": "schedule"},
    {"id": "gardener", "domain": "Memory", "task": "tidy my notes", "skill": "/gardener",
     "does": "orphans, dead links, stale notes", "unit": "huginn-gardener", "auto": "Saturdays 08:30", "kind": "schedule"},
    {"id": "dead-links", "domain": "Memory", "task": "fix broken links", "skill": "/dead-link-fixer",
     "does": "stubs for missing wikilinks", "unit": "huginn-dead-link-fixer", "auto": "Sundays 06:00", "kind": "schedule"},
    {"id": "graph-vault", "domain": "Knowledge", "task": "map my notes", "skill": "/graphify-vault",
     "does": "rebuilds the notes graph", "unit": "huginn-graphify-vault", "auto": "daily 23:30", "kind": "schedule"},
    {"id": "graph-repo", "domain": "Knowledge", "task": "map my config", "skill": "/graphify-repo",
     "does": "rebuilds the nixos-dotfiles graph", "unit": "huginn-graphify-repo", "auto": "Sundays 04:00", "kind": "schedule"},
    {"id": "brain-build", "domain": "Knowledge", "task": "refresh the brain", "skill": "/brain-build",
     "does": "graph + activity for this dashboard", "unit": "muninn-brain-build", "auto": "every 30 s", "kind": "schedule"},
    {"id": "ask", "domain": "Recall", "task": "look something up", "skill": "/ask",
     "does": "answers from notes + config", "unit": None, "auto": "manual · say it or type it", "kind": "manual"},
    {"id": "capture", "domain": "Recall", "task": "jot a thought", "skill": "/capture",
     "does": "drops a note into the inbox", "unit": None, "auto": "manual · say “capture …”", "kind": "manual"},
]
RUNNABLE = {s["id"]: s["unit"] for s in SKILLS if s["unit"]}

VIEWS = {"neural": "galaxy", "galaxy": "galaxy", "graph": "galaxy", "brain": "galaxy", "talk": "galaxy",
         "memory": "memory", "notes": "memory", "vault": "memory", "skills": "skills", "automations": "skills",
         "systems": "systems", "system": "systems", "agents": "systems", "capture": "capture", "inbox": "memory"}

JEV_QUESTIONS = {
    "tier": {
        "type": "choice",
        "instructions": "Which handler should take the request in `request`?",
        "criteria": {
            "command": "A direct dashboard or system command that needs no thinking: open or show a view or a named note, search for a term, capture a note, run a named skill or job",
            "answer": "A question answerable by looking things up in personal notes and server configuration: what, when, where, why, status, summaries, explanations",
            "agent": "Real work that needs an agent with tools: write or change files, research on the web, build, fix, deploy, or produce a report or document",
        },
    },
    "command": {
        "type": "choice",
        "instructions": "If the request in `request` is a direct command, which one is it?",
        "criteria": {
            "open_view": "Open, show or switch to a dashboard view: neural graph, memory, skills, systems, capture",
            "open_note": "Open or bring up one specific note, report, digest or journal entry",
            "search": "Search or filter the notes for a word or phrase",
            "capture": "Save, capture, jot down or remember a new note or thought",
            "run_skill": "Run, start or trigger a named skill, job or automation",
            "none": "Not a direct command",
        },
    },
    "skill": {
        "type": "choice",
        "instructions": "If the request in `request` asks to run a skill, which one?",
        "criteria": {
            "inbox-sweep": "File or sweep the inbox notes",
            "daily-digest": "Write the daily digest or summary of the day",
            "gardener": "Tidy, clean up or check the health of the notes",
            "dead-links": "Fix broken or dead links between notes",
            "graph-vault": "Rebuild the notes knowledge graph",
            "graph-repo": "Rebuild the config or code knowledge graph",
            "brain-build": "Refresh the brain dashboard data",
            "none": "No skill is being asked for",
        },
    },
}


def post_json(url, body, timeout, key=KEY):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


# ── tier 0: Jev sits in front of everything ────────────────────────────────
def route_jev(text):
    if not KEY:
        return None
    t0 = time.time()
    try:
        r = post_json(JEV_URL, {"model": JEV_MODEL, "state": {"request": text}, "questions": JEV_QUESTIONS}, 2.5)
    except Exception as e:
        return {"error": str(e)[:160]}
    a = r.get("answers") or {}
    tier = a.get("tier") or {}
    if tier.get("choice") not in ("command", "answer", "agent"):
        return {"error": "no tier in the Jev reply"}
    return {"via": "jev", "model": r.get("model", JEV_MODEL), "ms": int((time.time() - t0) * 1000),
            "tier": tier["choice"], "probabilities": tier.get("probabilities") or {tier["choice"]: 1.0},
            "confidence": tier.get("confidence"),
            "command": (a.get("command") or {}).get("choice"), "skill": (a.get("skill") or {}).get("choice")}


CMD_OPEN = re.compile(r"^(open|show|go to|switch to|bring up|pull up|display)\b", re.I)
CMD_SEARCH = re.compile(r"^(search( for)?|find|look for|filter)\b", re.I)
CMD_CAPTURE = re.compile(r"^(capture|note( that)?|remember( that)?|jot( down)?|save a note)\b[:,]?", re.I)
CMD_RUN = re.compile(r"^(run|start|trigger|kick off)\b", re.I)
AGENT_HINT = re.compile(r"\b(write|create|build|make|generate|draft|fix|deploy|install|refactor|research|report on|set up)\b", re.I)


def route_rules(text):
    t = text.strip()
    if CMD_CAPTURE.match(t):
        tier, cmd = "command", "capture"
    elif CMD_RUN.match(t):
        tier, cmd = "command", "run_skill"
    elif CMD_SEARCH.match(t):
        tier, cmd = "command", "search"
    elif CMD_OPEN.match(t):
        tier, cmd = "command", "open_view" if any(v in t.lower() for v in VIEWS) else "open_note"
    elif AGENT_HINT.search(t) and not t.endswith("?"):
        tier, cmd = "agent", "none"
    else:
        tier, cmd = "answer", "none"
    return {"via": "rules", "ms": 0, "tier": tier, "probabilities": {tier: 1.0}, "confidence": None,
            "command": cmd, "skill": None}


# ── tier 1: commands, no AI ────────────────────────────────────────────────
def find_note(text):
    words = [w for w in re.findall(r"[\w-]{3,}", text.lower()) if w not in STOP]
    if not words or not os.path.exists(DB):
        return None
    try:
        c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
        q = " OR ".join(f'title:"{w}"' for w in words[:8])
        r = c.execute("SELECT path FROM notes_fts WHERE notes_fts MATCH ? ORDER BY bm25(notes_fts) LIMIT 1", (q,)).fetchone()
        c.close()
        return os.path.basename(r[0])[:-3] if r else None
    except sqlite3.Error:
        return None


def command(text, route):
    t = text.strip()
    cmd = route.get("command") or "none"
    low = t.lower()
    if cmd == "run_skill":
        sid = route.get("skill")
        if sid not in RUNNABLE:
            sid = next((s for s in RUNNABLE if s in low or s.replace("-", " ") in low), None)
        if sid:
            ok, msg = run_skill(sid)
            return {"action": {"type": "run", "skill": sid, "ok": ok}, "answer": msg}
        return {"action": {"type": "view", "view": "skills"}, "answer": "I couldn't tell which skill you meant, so here they are."}
    if cmd == "capture":
        body = CMD_CAPTURE.sub("", t).strip() or t
        return {"action": {"type": "capture", "text": body}, "answer": "Captured to the inbox."}
    if cmd == "search":
        term = CMD_SEARCH.sub("", t).strip(" :") or t
        return {"action": {"type": "search", "q": term}, "answer": f"Searching the vault for {term}."}
    if cmd == "open_view":
        view = next((v for k, v in VIEWS.items() if k in low), None)
        if view:
            return {"action": {"type": "view", "view": view}, "answer": ""}
    note = find_note(CMD_OPEN.sub("", t))
    if note:
        return {"action": {"type": "open", "note": note}, "answer": f"Opening {note}."}
    view = next((v for k, v in VIEWS.items() if k in low), None)
    if view:
        return {"action": {"type": "view", "view": view}, "answer": ""}
    return None


def run_skill(sid):
    unit = RUNNABLE.get(sid)
    if not unit:
        return False, "That skill has no automation to start."
    try:
        p = subprocess.run([SUDO, "-n", "systemctl", "start", "--no-block", unit + ".service"],
                           capture_output=True, text=True, timeout=10)
        return (p.returncode == 0, f"Started {sid}." if p.returncode == 0 else f"Could not start {sid}: {p.stderr.strip()[:120]}")
    except Exception as e:
        return False, f"Could not start {sid}: {e}"


def unit_state(unit):
    def show(name, props):
        try:
            out = subprocess.run(["systemctl", "show", "--timestamp=unix", "-p", props, "--", name],
                                 capture_output=True, text=True, timeout=5).stdout
            return dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
        except Exception:
            return {}
    ep = lambda v: int(v[1:]) if v and v.startswith("@") and v[1:].isdigit() else 0
    s = show(unit + ".service", "Result,ActiveState,ExecMainExitTimestamp")
    t = show(unit + ".timer", "LastTriggerUSec,NextElapseUSecRealtime")
    return {"result": s.get("Result", "unknown"), "active": s.get("ActiveState") in ("active", "activating"),
            "last": ep(t.get("LastTriggerUSec", "")) or ep(s.get("ExecMainExitTimestamp", "")),
            "next": ep(t.get("NextElapseUSecRealtime", ""))}


# ── tier 2: quick answers from memory ──────────────────────────────────────
STOP = set("the and for that this with what when where which who why how are was were did does have has had "
           "you your about from into they them then than there here just can could would should will not but "
           "open show bring pull display note notes tell give please muninn".split())


def retrieve(q):
    words = [w for w in re.findall(r"[\w-]{3,}", q.lower()) if w not in STOP][:12]
    notes = []
    if words and os.path.exists(DB):
        try:
            c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
            fts = " OR ".join(f'"{w}"' for w in words)
            for path, title, body in c.execute(
                    "SELECT n.path, n.title, n.body FROM notes_fts JOIN notes n ON n.path = notes_fts.path "
                    "WHERE notes_fts MATCH ? ORDER BY bm25(notes_fts, 0, 4.0, 1.0) LIMIT 6", (fts,)):
                notes.append({"id": os.path.basename(path)[:-3], "path": path, "title": title or os.path.basename(path)[:-3],
                              "body": (body or "").strip()[:1800]})
            c.close()
        except sqlite3.Error:
            pass
    code, code_nodes = "", []
    if os.path.exists(GRAPHIFY) and os.path.exists(CODE_GRAPH):
        try:
            code = subprocess.run([GRAPHIFY, "query", q, "--graph", CODE_GRAPH], capture_output=True, text=True, timeout=8,
                                  env={**os.environ, "HOME": "/var/lib/huginn"}).stdout[:6000]
            code_nodes = [m.strip() for m in re.findall(r"^NODE (.+?) \[src=", code, re.M)][:12]
        except Exception:
            pass
    return notes, code, code_nodes


SYSTEM = ("You are muninn, the voice of Christina's personal homelab and note system. Answer using ONLY the "
          "provided context: notes from her Obsidian vault and a knowledge graph of her NixOS config (hosts: "
          "mjolnir desktop, heimdall services VM, odyn TrueNAS, mimir AI box, hermod agent VM). Your answer is "
          "read aloud, so keep it to two to four plain sentences with no markdown, lists or file paths unless "
          "she asks for detail. Name the note you used. If the context lacks the answer, say so plainly.")


def answer(q):
    notes, code, code_nodes = retrieve(q)
    sources = [{"id": n["id"], "path": n["path"], "title": n["title"]} for n in notes]
    if not KEY:
        if notes:
            text = "I can't reach the language model right now. The closest notes are: " + "; ".join(n["title"] for n in notes[:4]) + "."
        else:
            text = "I can't reach the language model right now, and no note matched."
        return {"answer": text, "sources": sources, "code_nodes": code_nodes, "model": None}
    ctx = "\n\n".join(f"### [[{n['title']}]] ({n['path']})\n{n['body']}" for n in notes) or "(no matching notes)"
    try:
        r = post_json(BASE + "/chat/completions", {"model": MODEL, "temperature": 0.2, "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": f"Question: {q}\n\n--- notes ---\n{ctx}\n\n--- config graph ---\n{code or '(none)'}"}]}, 60)
        text = (r.get("choices") or [{}])[0].get("message", {}).get("content") or r.get("error", {}).get("message") or "No reply from the model."
    except Exception as e:
        text = f"The language model did not answer ({str(e)[:120]})."
    return {"answer": text.strip(), "sources": sources, "code_nodes": code_nodes, "model": MODEL}


# ── tier 3: real work, Codex headless on this host ─────────────────────────
def codex_ready():
    return bool(shutil.which(CODEX)) and os.path.exists(os.path.join(CODEX_HOME, "auth.json"))


def run_codex(job):
    fd, out = tempfile.mkstemp(prefix="muninn-agent-", suffix=".txt")
    os.close(fd)
    try:
        p = subprocess.run([CODEX, "exec", "--skip-git-repo-check", "-s", "workspace-write", "-C", VAULT, "-o", out,
                            AGENT_BRIEF + job["text"]], capture_output=True, text=True, timeout=1500, stdin=subprocess.DEVNULL)
        with open(out, encoding="utf-8", errors="ignore") as fh:
            msg = fh.read().strip()
        ok = p.returncode == 0 and bool(msg)
        job.update(status="done" if ok else "failed", answer=msg or p.stderr.strip()[-400:] or "Codex returned nothing.")
    except subprocess.TimeoutExpired:
        job.update(status="failed", answer="Codex ran out of time (25 minutes).")
    except Exception as e:
        job.update(status="failed", answer=f"Codex could not run: {e}")
    finally:
        try:
            os.remove(out)
        except OSError:
            pass


def run_hermes(job):
    # hermes on hermod, through its API server; one named conversation keeps context between turns
    try:
        r = post_json(HERMES_URL + "/v1/responses", {"model": "hermes-agent", "input": job["text"], "conversation": "muninn-brain"},
                      1500, key=HERMES_KEY)
        msg = " ".join(c.get("text", "") for item in r.get("output") or [] if item.get("type") == "message"
                       for c in item.get("content") or [] if c.get("type") == "output_text").strip()
        job.update(status="done" if msg else "failed", answer=msg or "Hermes returned nothing.")
    except Exception as e:
        job.update(status="failed", answer=f"Hermes did not answer ({str(e)[:160]}).")


def run_agent(job):
    try:
        (run_hermes if job["agent"] == "hermes" else run_codex)(job)
    finally:
        job["ended"] = int(time.time())
        log_talk(job["text"], {"answer": job["answer"], "sources": [], "route": {"tier": "agent", "via": job["agent"]}})


def pick_agent(target):
    have = {"hermes": bool(HERMES_KEY), "codex": codex_ready()}
    if target in have:
        return target if have[target] else None
    return next((a for a in ("hermes", "codex") if have[a]), None)


def start_agent(text, agent):
    job = {"id": uuid.uuid4().hex[:10], "agent": agent, "text": text, "status": "running",
           "started": int(time.time()), "answer": ""}
    with LOCK:
        JOBS[job["id"]] = job
        for old in sorted(JOBS.values(), key=lambda j: j["started"])[:-30]:
            JOBS.pop(old["id"], None)
    threading.Thread(target=run_agent, args=(job,), daemon=True).start()
    return job


# ── usage: the 5-hour and weekly windows of both subscriptions ─────────────
def _window(w):
    w = w or {}
    used = w.get("used_percent", w.get("used_percentage"))
    return {"used_percent": float(used), "resets_at": int(w.get("resets_at") or 0)} if isinstance(used, (int, float)) else None


def codex_usage():
    # Codex writes a rate-limit snapshot into its session log after every turn.
    files = sorted(glob.glob(os.path.join(CODEX_HOME, "sessions", "*", "*", "*", "*.jsonl")), key=os.path.getmtime, reverse=True)[:8]
    for f in files:
        try:
            with open(f, "rb") as fh:
                fh.seek(max(0, os.path.getsize(f) - 600000))
                data = fh.read().decode("utf-8", "ignore")
            i = data.rfind('"rate_limits":')
            if i < 0:
                continue
            rl, _ = json.JSONDecoder().raw_decode(data[i + len('"rate_limits":'):])
            snap = {"host": socket.gethostname(), "as_of": int(os.path.getmtime(f)),
                    "five_hour": _window(rl.get("primary")), "seven_day": _window(rl.get("secondary"))}
            if snap["five_hour"] or snap["seven_day"]:
                return snap
        except (OSError, ValueError, AttributeError):
            continue
    return None


def load_usage():
    try:
        with open(USAGE_FILE, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def usage():
    u = load_usage()
    local = codex_usage()
    if local and local["as_of"] >= (u.get("openai") or {}).get("as_of", 0):
        u["openai"] = local
    return {"anthropic": u.get("anthropic"), "openai": u.get("openai"), "codex_ready": codex_ready()}


def push_usage(b):
    prov = b.get("provider")
    if prov not in ("anthropic", "openai"):
        return False
    # a reporter may say when the numbers were measured; never later than now
    now = int(time.time())
    try:
        seen = min(int(b.get("as_of") or now), now)
    except (TypeError, ValueError):
        seen = now
    snap = {"host": re.sub(r"[^\w.-]", "", str(b.get("host", "")))[:40], "as_of": seen,
            "five_hour": _window(b.get("five_hour")), "seven_day": _window(b.get("seven_day"))}
    if not (snap["five_hour"] or snap["seven_day"]):
        return False
    with LOCK:
        u = load_usage()
        if seen < (u.get(prov) or {}).get("as_of", 0):
            return True   # an older measurement never replaces a newer one
        u[prov] = snap
        tmp = USAGE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(u, fh)
        os.replace(tmp, USAGE_FILE)
    return True


# ── vault log: everything said goes back into memory ───────────────────────
def log_talk(q, res):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        day = datetime.date.today().isoformat()
        path = os.path.join(LOG_DIR, f"Talk {day}.md")
        new = not os.path.exists(path)
        r = res.get("route", {})
        p = (r.get("probabilities") or {}).get(r.get("tier"))
        head = f"### {datetime.datetime.now().strftime('%H:%M')} · {r.get('tier', '?')}" + (f" ({p:.2f} via {r.get('via')})" if isinstance(p, (int, float)) else "")
        src = " ".join(f"[[{s['id']}]]" for s in res.get("sources", [])[:5])
        with open(path, "a", encoding="utf-8") as fh:
            if new:
                fh.write(f"---\ntype: journal\nstatus: active\ntags: [talk, muninn]\ncreated: {day}\nagent: muninn-bridge\n---\n\n"
                         f"# Talk {day}\n\nEverything said to muninn on {day}, logged by the bridge.\n\nUp: [[Agents MOC]]\n")
            fh.write(f"\n{head}\n- **you:** {q.strip()}\n- **muninn:** {(res.get('answer') or '—').strip()}\n" + (f"- sources: {src}\n" if src else ""))
        if new:
            os.chmod(path, 0o664)
    except OSError:
        pass


def talk(text, target="auto"):
    jev_error = None
    if target in ("hermes", "codex"):
        # addressed to an agent by name: nothing to sort
        route = {"via": "direct", "ms": 0, "tier": "agent", "probabilities": {"agent": 1.0}, "confidence": None,
                 "command": "none", "skill": None}
    else:
        route = route_jev(text)
        if not route or route.get("error"):
            jev_error = (route or {}).get("error", "no key")
            route = route_rules(text)
    res = None
    if route["tier"] == "command":
        res = command(text, route)
        if res is None:
            route = {**route, "tier": "answer", "fellthrough": True}
    if route["tier"] == "agent":
        agent = pick_agent(target)
        if agent:
            job = start_agent(text, agent)
            res = {"answer": f"On it. {agent.capitalize()} is working on that now.", "sources": [], "job": job["id"],
                   "agent": agent, "route": route}
            if jev_error:
                res["jev_error"] = jev_error
            return res   # the job logs itself when it finishes
        res = {"answer": "That is real work for an agent, but no agent is connected yet: hermes needs its API key "
                         "on heimdall, and Codex needs codex login on heimdall.", "sources": []}
    if res is None:
        res = answer(text)
    res["route"] = route
    if jev_error:
        res["jev_error"] = jev_error
    # opening a view or a note is not worth remembering; everything else is
    if (res.get("action") or {}).get("type") not in ("view", "open", "search"):
        log_talk(text, res)
    return res


# ── voice: ears (Whisper) and mouth (Kokoro) on mimir ──────────────────────
def stt(audio, ctype):
    ext = "webm" if "webm" in ctype else "ogg" if "ogg" in ctype else "mp4" if "mp4" in ctype else "wav"
    b = uuid.uuid4().hex
    body = (f"--{b}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n{STT_MODEL}\r\n"
            f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.{ext}\"\r\n"
            f"Content-Type: {ctype or 'application/octet-stream'}\r\n\r\n").encode() + audio + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request(VOICE + "/v1/audio/transcriptions", data=body, method="POST",
                                 headers={"Content-Type": f"multipart/form-data; boundary={b}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return (json.loads(r.read().decode("utf-8", "replace")).get("text") or "").strip()


def tts(text):
    req = urllib.request.Request(VOICE + "/v1/audio/speech", method="POST", headers={"Content-Type": "application/json"},
                                 data=json.dumps({"input": text[:1500], "model": TTS_MODEL, "voice": TTS_VOICE,
                                                  "response_format": "mp3", "speed": 1.0}).encode())
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def voice_up():
    try:
        with urllib.request.urlopen(VOICE + "/health", timeout=1.5) as r:
            return r.status == 200
    except Exception:
        return False


class H(BaseHTTPRequestHandler):
    def log_message(self, f, *a):
        pass

    def _j(self, status, payload):
        b = json.dumps(payload, default=str).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def _body(self, limit):
        n = int(self.headers.get("content-length", 0) or 0)
        if n > limit:
            return None
        return self.rfile.read(n)

    def do_GET(self):
        p = self.path.split("?")[0].rstrip("/")
        if p == "/bridge/health":
            return self._j(200, {"ok": True, "jev": bool(KEY), "jev_model": JEV_MODEL, "llm": MODEL if KEY else None,
                                 "voice": voice_up(), "index": os.path.exists(DB), "codex": codex_ready(),
                                 "hermes": bool(HERMES_KEY)})
        if p == "/bridge/skills":
            return self._j(200, {"skills": [{**s, **(unit_state(s["unit"]) if s["unit"] else {})} for s in SKILLS]})
        if p == "/bridge/usage":
            return self._j(200, usage())
        if p.startswith("/bridge/jobs/"):
            job = JOBS.get(p.rsplit("/", 1)[1])
            return self._j(200, job) if job else self._j(404, {"error": "no such job"})
        self._j(404, {"error": f"unknown: {p}"})

    def do_POST(self):
        p = self.path.split("?")[0].rstrip("/")
        try:
            if p == "/bridge/stt":
                audio = self._body(25 * 1024 * 1024)
                if not audio:
                    return self._j(400, {"error": "no audio"})
                return self._j(200, {"text": stt(audio, self.headers.get("content-type", ""))})
            raw = self._body(262144)
            if raw is None:
                return self._j(413, {"error": "body too large"})
            try:
                b = json.loads(raw.decode() or "{}")
            except ValueError:
                return self._j(400, {"error": "invalid JSON"})
            if p == "/bridge/talk":
                text = (b.get("text") or "").strip()
                if not text:
                    return self._j(400, {"error": "missing text"})
                return self._j(200, talk(text[:4000], b.get("target") or "auto"))
            if p == "/bridge/run":
                ok, msg = run_skill(b.get("skill"))
                return self._j(200 if ok else 400, {"ok": ok, "message": msg})
            if p == "/bridge/usage":
                ok = push_usage(b)
                return self._j(200 if ok else 400, {"ok": ok})
            if p == "/bridge/tts":
                text = (b.get("text") or "").strip()
                if not text:
                    return self._j(400, {"error": "missing text"})
                audio = tts(text)
                self.send_response(200)
                self.send_header("Content-Type", "audio/mpeg")
                self.send_header("Content-Length", str(len(audio)))
                self.end_headers()
                return self.wfile.write(audio)
            self._j(404, {"error": f"unknown POST: {p}"})
        except urllib.error.URLError as e:
            self._j(502, {"error": f"upstream unreachable: {e.reason}"})
        except Exception as e:
            self._j(500, {"error": str(e)[:300]})


if __name__ == "__main__":
    print(f"muninn-bridge: 127.0.0.1:{PORT} jev={'on' if KEY else 'off (rules)'} llm={MODEL} voice={VOICE}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()

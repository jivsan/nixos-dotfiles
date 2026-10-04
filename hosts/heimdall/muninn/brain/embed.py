#!/usr/bin/env python3
"""Meaning-based search over the vault, on top of the embedding model on mimir.

`python3 embed.py` is the embedder: it keeps one vector per note in a small
SQLite file, re-embedding a note when it changes. The bridge imports this module
to embed a question and rank the notes by similarity. Nothing here is required:
when mimir is unreachable the embedder waits and every lookup returns nothing,
so callers fall back to keyword search.
"""
import array
import json
import math
import operator
import os
import sqlite3
import sys
import threading
import time
import urllib.request

# Two instances of the same model on mimir: notes go to one, questions to the
# other. In a single instance a question waits for whatever note is being
# embedded (17-30 s instead of half a second).
URL = os.environ.get("MUNINN_EMBED_URL", "http://10.0.20.18:8081").rstrip("/")
QUERY_URL = os.environ.get("MUNINN_EMBED_QUERY_URL", "http://10.0.20.18:8082").rstrip("/")
MODEL = os.environ.get("MUNINN_EMBED_MODEL", "Qwen3-Embedding-4B-Q8_0")
DB = os.environ.get("MUNINN_EMBED_DB", "/var/lib/muninn-brain/embeddings.db")
INDEX = os.environ.get("MUNINN_DB", "/var/lib/muninn-brain/index.db")
# Qwen3 vectors keep their meaning when cut short, so 1024 of the 2560 numbers
# are kept: a third of the storage and fast enough to compare in plain Python.
DIM = 1024
# A longer note is embedded by its beginning, which is where a note says what it
# is about. On mimir's CPU the 4B model needs about 25 s for 4,000 characters and
# the cost grows faster than the length (175 s for 14,700), so the cut is what
# keeps the first full index to about an hour. Raise it once mimir has its GPU.
MAX_CHARS = int(os.environ.get("MUNINN_EMBED_MAX_CHARS", "8000"))
# Qwen3 is instruction-aware: a query says what it is looking for, a note is embedded as it is.
INSTRUCT = ("Instruct: Given a question or a piece of writing, retrieve the notes from a personal "
            "knowledge base that are about the same subject\nQuery:")
# Logs of what was said or filed are searchable by keyword; as neighbours they are noise.
SKIP = ("Resources/Talk logs/", "Resources/Reports/inbox-", "Resources/Reports/alert-", "_inbox/")
_LOCK = threading.Lock()
_QUERIES = {}                    # recent query text -> vector: retrieval and placement ask the same thing
_LOADED = {"stamp": None, "rows": []}


def shorten(vector):
    """The first DIM numbers of a vector, rescaled to length one."""
    head = [float(x) for x in vector[:DIM]]
    norm = math.sqrt(sum(x * x for x in head))
    if not norm:
        raise ValueError("embedding server returned an empty vector")
    return array.array("f", (x / norm for x in head))


def embed(text, timeout=120, url=None):
    """One vector for a text, from the embedding server (the notes instance by default)."""
    request = urllib.request.Request(
        (url or URL) + "/v1/embeddings",
        data=json.dumps({"model": MODEL, "input": text[:MAX_CHARS]}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return shorten(json.load(response)["data"][0]["embedding"])


def embed_query(text, timeout=10):
    """The vector to search with. Cached, and one call at a time, so the answer
    path and the placement path share a single request to mimir."""
    text = text.strip()[:2000]
    with _LOCK:
        if text not in _QUERIES:
            if len(_QUERIES) > 64:
                _QUERIES.clear()
            _QUERIES[text] = embed(INSTRUCT + text, timeout, QUERY_URL)
        return _QUERIES[text]


def connect(path=None):
    path = path or DB
    os.makedirs(os.path.dirname(path), exist_ok=True)
    db = sqlite3.connect(path, timeout=30)
    db.execute("CREATE TABLE IF NOT EXISTS vectors "
               "(path TEXT PRIMARY KEY, mtime INTEGER, model TEXT, vec BLOB)")
    return db


def wanted(path):
    return not path.startswith(SKIP)


def sync(embedder=embed, index=None, store=None, log=print):
    """Bring the vectors in line with the note index. Returns (embedded, removed).

    One note is committed at a time, so a restart or an unreachable server loses
    nothing that was already done."""
    notes = sqlite3.connect(f"file:{index or INDEX}?mode=ro", uri=True)
    try:
        current = {path: (mtime, title, body) for path, mtime, title, body
                   in notes.execute("SELECT path, mtime, title, body FROM notes") if wanted(path)}
    finally:
        notes.close()
    db = connect(store)
    try:
        have = {path: (mtime, model) for path, mtime, model in db.execute("SELECT path, mtime, model FROM vectors")}
        gone = [path for path in have if path not in current]
        for path in gone:
            db.execute("DELETE FROM vectors WHERE path = ?", (path,))
        db.commit()
        done = 0
        for path, (mtime, title, body) in sorted(current.items()):
            if have.get(path) == (mtime, MODEL):
                continue
            started = time.time()
            name = title or os.path.basename(path)[:-3]
            vector = embedder(f"{name}\n\n{(body or '').strip()}")
            db.execute("INSERT OR REPLACE INTO vectors VALUES (?, ?, ?, ?)", (path, mtime, MODEL, vector.tobytes()))
            db.commit()
            done += 1
            log(f"embedded {path} ({time.time() - started:.1f}s)")
        return done, len(gone)
    finally:
        db.close()


def vectors(store=None):
    """Every stored vector, reloaded only when the file has changed."""
    path = store or DB
    try:
        stamp = (path, os.stat(path).st_mtime_ns)
    except OSError:
        return []
    if _LOADED["stamp"] != stamp:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            rows = [(note, array.array("f", blob)) for note, blob
                    in db.execute("SELECT path, vec FROM vectors WHERE model = ?", (MODEL,))]
        finally:
            db.close()
        _LOADED.update(stamp=stamp, rows=rows)
    return _LOADED["rows"]


def nearest(vector, k=6, store=None):
    """The k notes closest to a vector, as (path, similarity), best first."""
    scored = [(sum(map(operator.mul, vector, other)), path)
              for path, other in vectors(store) if len(other) == len(vector)]
    return [(path, score) for score, path in sorted(scored, reverse=True)[:k]]


def similar(text, k=6, timeout=10, store=None):
    """The notes closest in meaning to a text. Empty when the model cannot be asked."""
    try:
        if not text.strip() or not vectors(store):
            return []
        return nearest(embed_query(text, timeout), k, store)
    except Exception:
        return []


def main():
    pause = int(os.environ.get("MUNINN_EMBED_INTERVAL", "60"))
    print(f"muninn-embedder: notes={URL} questions={QUERY_URL} model={MODEL} dim={DIM} store={DB}", flush=True)
    while True:
        try:
            done, gone = sync(log=lambda line: print(line, flush=True))
            if done or gone:
                print(f"muninn-embedder: {done} embedded, {gone} removed", flush=True)
        except Exception as exc:   # mimir down, index not built yet: try again next round
            print(f"muninn-embedder: waiting ({str(exc)[:160]})", flush=True)
        time.sleep(pause)


if __name__ == "__main__":
    sys.exit(main())

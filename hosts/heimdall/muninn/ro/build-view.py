#!/usr/bin/env python3
# muninn-ro-build: copies every note of my vault into the read-only view that muninn-ro serves.
# it skips .obsidian, .trash, _templates (and .git), anything that isn't markdown, and the globs in
# my exclude file. safety filters on every note:
#   dropped whole: a secret-shaped line, a word from my deny file, hidden characters (zero-width,
#   bidi controls), or lines aimed at agents ("ignore previous instructions", tool-call markup)
#   masked in place: email addresses -> "(email)", public ip addresses -> "(public ip)"
#   links to notes that aren't in the view -> "(private note)"
# graphs: huginn's vault graph cut down to the notes in the view (it fails closed), and a copy of the
# dotfiles graph. nothing here runs graphify.
# it prints counts only: never note text, matched strings or paths. drops.log (0600, next to the
# view) has path + reason for me on heimdall: sudo cat /var/lib/muninn-ro/drops.log
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import ipaddress
import json
import math
import os
import posixpath
import re
import shutil
import stat
import sys
import time
import unicodedata
from collections import Counter
from urllib.parse import parse_qs, unquote, urlsplit

PRUNE_TOP = {".git", ".obsidian"}        # not walked at all
SKIP_TOP = {".trash", "_templates"}      # walked only so links to them count as private
MAX_BYTES = 2 * 1024 * 1024
PRIVATE_LINK = "(private note)"
PRIVATE_LABEL = "(private)"
NODE_KEYS = {"id", "label", "file", "community", "community_name", "kind"}
EDGE_KEYS = {"source", "target", "relation"}

# ---------------------------------------------------------------- hidden characters
# zero-width, bidi controls, invisible fillers, tag characters (ascii smuggling), variation selectors 17+
HIDDEN = re.compile(
    "[\u061c\u115f\u1160\u17b4\u17b5\u180b-\u180f\u200b\u200c\u200e\u200f\u202a-\u202e"
    "\u2060-\u2064\u2066-\u206f\u3164\ufeff\uffa0\ufff9-\ufffb"
    "\U000e0000-\U000e007f\U000e0100-\U000e01ef]")


def _emoji(ch: str) -> bool:
    o = ord(ch)
    return o >= 0x1F000 or 0x2600 <= o <= 0x27BF or o in (0xFE0F, 0x20E3)


def has_hidden(text: str) -> bool:
    if text.startswith("\ufeff"):        # a byte order mark at the very start is harmless
        text = text[1:]
    if HIDDEN.search(text):
        return True
    i = text.find("\u200d")              # zero-width joiner: fine inside an emoji, nowhere else
    while i != -1:
        if i == 0 or i + 1 >= len(text) or not (_emoji(text[i - 1]) and _emoji(text[i + 1])):
            return True
        i = text.find("\u200d", i + 1)
    return False


def clean(text: str) -> str:
    # what goes into the view: no leading byte order mark, no soft hyphens (invisible anyway)
    if text.startswith("\ufeff"):
        text = text[1:]
    return text.replace("\u00ad", "")


def for_checks(text: str) -> str:
    # the agent and deny checks look at this: fullwidth letters folded, soft hyphens gone, lowercase
    t = unicodedata.normalize("NFKC", text.replace("\u00ad", ""))
    return re.sub(r"[ \t]+", " ", t).lower()


# ---------------------------------------------------------------- lines aimed at agents
_AI = (r"(?:ai|llms?|large language models?|language models?|ai assistants?|ai agents?|ai models?|"
       r"assistants?|agents?|bots?|chatbots?|grok|claude|chatgpt|gpt|gemini|copilot|hermes)")
AGENT_RULES = [(name, re.compile(rx, re.M)) for name, rx in [
    ("ignore-instructions",
     r"\b(?:ignore|disregard|forget|override|bypass)\b[^.\n]{0,40}?\b(?:previous|prior|above|earlier|preceding|"
     r"all|any|your|the|these|those|system)\b[^.\n]{0,25}?\b(?:instructions?|prompts?|rules|directions|"
     r"guidelines|guardrails)\b"),
    ("new-instructions", r"\b(?:new|updated|real|actual|hidden|secret|override) (?:system )?instructions?[ \t]*[:\-]"),
    ("system-prompt", r"\b(?:system|developer) (?:prompt|message|instructions?)[ \t]*:"),
    ("you-are-now", r"\byou are now (?:an? )?(?:unrestricted|jailbroken|dan\b|free from|in (?:developer|god|admin|"
                    r"debug|jailbreak) mode|no longer bound)"),
    ("if-you-are-ai", r"\bif you(?:'re| are) an? " + _AI + r"\b"),
    ("note-to-ai", r"\b(?:note|message|instructions?|attention|hey|hello|hi|dear|psa)[ \t]+(?:to|for)?[ \t]*(?:all[ \t]+)?"
                   + _AI + r"[ \t]*[:,!]"),
    ("ai-reading-this", r"\b(?:ai|llm|language model|gpt)s? ?(?:agents?|assistants?|models?|systems?|crawlers?|"
                        r"scrapers?)? (?:reading|processing|parsing|summari[sz]ing|scraping|that reads?) (?:this|these)\b"),
    ("tell-the-bots", r"\btell (?:all|other|every|the other) (?:the )?(?:bots?|agents?|ais?|assistants?|models?)\b"),
    ("hide-from-user", r"\bdo(?:n't| not) (?:tell|inform|alert|mention (?:this|it) to|reveal (?:this|it) to) "
                       r"the (?:user|human|owner|operator)\b"),
    ("tool-markup", r"</?[ \t]*(?:system-reminder|system_prompt|system-prompt|tool_call|tool_calls|tool_use|"
                    r"tool_result|tool_response|function_calls?|function_results?|invoke|antml:[a-z_]+|im_start|"
                    r"im_end|assistant_response|user_query)\b"),
    ("chat-tokens", r"<\|(?:im_start|im_end|system|user|assistant|endoftext|eot_id|start_header_id|"
                    r"end_header_id|begin_of_text|tool_call)\|>"),
    ("inst-tags", r"\[/?inst\]|<</?sys>>"),
    ("tool-json", r"\"(?:tool_calls|function_call|tool_use)\"[ \t]*:"),
    ("function-tag", r"<function=[a-z_]"),
]]


def agent_rule(norm: str) -> str | None:
    for name, rx in AGENT_RULES:
        if rx.search(norm):
            return name
    return None


# ---------------------------------------------------------------- secret-shaped lines
PLACEHOLDER = re.compile(
    r"^(?:<.*|\$.*|\{.*|%.*|\(.*|\[.*|\*+.*|x{3,}.*|\.{3}.*|\u2026.*|changeme|change-me|password|passwd|"
    r"secret|token|example|redacted|hidden|none|null|nil|true|false|yes|no|required|optional|string|value|"
    r"todo|tbd|placeholder|your[-_].*|my[-_].*)$", re.I)


def _valueish(v: str) -> bool:
    # a value after password: / token= ... that looks like a real secret, not a path or a placeholder
    v = v.strip("\"'`,;.)]}")
    if len(v) < 6 or PLACEHOLDER.match(v):
        return False
    if v.lower().startswith(("/", "~", "./", "../", "http://", "https://", "file:", "env:", "config.",
                             "pkgs.", "lib.", "builtins.", "cfg.", "self.", "inputs.")):
        return False
    d = any(c.isdigit() for c in v)
    a = any(c.isalpha() for c in v)
    up = any(c.isupper() for c in v)
    lo = any(c.islower() for c in v)
    if d and a and len(v) >= 8:
        return True
    if len(v) >= 20 and up and lo:
        return True
    return len(v) >= 8 and a and any(c in "!@#%^&*+=?" for c in v)


def _randomish(m: re.Match) -> bool:
    piece = m.group(0).split()[-1]
    if "ssh-" in piece:
        return False
    d = any(c.isdigit() for c in piece)
    up = any(c.isupper() for c in piece)
    lo = any(c.islower() for c in piece)
    return d and (up or lo) or (up and lo and len(piece) >= 20)


def _url_password(m: re.Match) -> bool:
    pw = m.group(2)
    return len(pw) >= 3 and not PLACEHOLDER.match(pw) and pw.lower() not in {"pass", "pw", "x", "pwd"}


KV = re.compile(
    r"(?i)(?<![a-z])(?:pass(?:word|wd|phrase)?|pwd|secret|token|api[-_ ]?key|apikey|access[-_]?key|"
    r"secret[-_]?key|private[-_]?key|client[-_]?secret|auth[-_]?(?:key|token)|psk|pre[-_]?shared[-_]?key|"
    r"(?:totp|otp|mfa|2fa)[-_ ]?(?:seed|secret|key))[a-z0-9_-]{0,24}[\"']?\s*[:=]+\s*[\"']?([^\s\"'`<>,;]{6,})")


def _totp_seed(m: re.Match) -> bool:
    # a base32 seed has a digit 2-7 almost always; a long run with none must at least look random
    s = m.group(1).replace(" ", "")
    if len(s) < 16:
        return False
    if any(c in "234567" for c in s):
        return True
    return " " not in m.group(1) and s.isupper() and _entropy(s) >= 3.5


def _password_value(m: re.Match) -> bool:
    return _valueish(m.group(1))


# a token with no ':' or '=' in front: "forgejo token 3f9a…", "token `k2x9…`". a long lowercase, hex or
# mixed run up to 30 characters after a word like token, key, secret, api, auth
TOKEN_WORD = re.compile(r"(?i)(?<![a-z])[a-z]{0,12}?(?:token|key|secret|passord|password|passwd|api|bearer|auth)s?"
                        r"(?![a-z])")
TOKEN_RUN = re.compile(r"(?<![A-Za-z0-9/.+-])(?:[0-9a-f]{32,}|[A-Za-z0-9]{24,})(?![A-Za-z0-9])")
NOT_SECRET = re.compile(r"(?i)public|pubkey|(?<![a-z])(?:hash|sha\d*|md5|digest|commit|rev|revision|checksum|"
                        r"fingerprint|fpr|id|uuid|guid)(?![a-z])")
HEX_RUN = re.compile(r"[0-9a-f]{32,}")
NIX32 = set("0123456789abcdfghijklmnpqrsvwxyz")      # nix's base32: store hashes are 32 long, sha256 52


def _token_after_word(m: re.Match) -> bool:
    line, start, run = m.string, m.start(), m.group(0)
    before = line[max(0, start - 60):start]
    words = [w for w in TOKEN_WORD.finditer(before) if len(before) - w.end() <= 30]
    if not words:
        return False
    if NOT_SECRET.search(before[max(0, words[-1].start() - 12):]):
        return False                             # a hash, a commit, an id or a public key
    if run.startswith(ID_PREFIX) or any(line[:start].endswith(p) for p in ID_PREFIX if p[-1] in "_-"):
        return False                             # req_…, msg_…, toolu_…
    if SKIP_BEFORE.search(line[max(0, start - 45):start]):
        return False
    if len(run) <= 44 and NIX_KEY_NAME.search(line[max(0, start - 64):start]):
        return False
    if len(run) in (32, 52) and set(run) <= NIX32:
        return False
    digits = sum(c.isdigit() for c in run)
    letters = len(run) - digits
    if HEX_RUN.fullmatch(run):
        return digits >= 2 and letters >= 2
    return digits >= 4 and letters >= 4 and _entropy(run) >= 3.6


SECRET_RULES = [
    ("private-key", re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"), None),
    ("putty-key", re.compile(r"PuTTY-User-Key-File-\d"), None),
    ("sk-token", re.compile(r"\bsk-(?:ant-|or-|proj-|svcacct-|live-)?[A-Za-z0-9_-]{20,}"), _randomish),
    ("github", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})"), None),
    ("gitlab", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}"), None),
    ("slack", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}"), None),
    ("aws", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), None),
    ("google", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), None),
    ("huggingface", re.compile(r"\bhf_[A-Za-z0-9]{30,}\b"), None),
    ("tailscale", re.compile(r"\btskey-[a-z]+-[A-Za-z0-9-]{10,}"), None),
    ("npm", re.compile(r"\bnpm_[A-Za-z0-9]{36}\b"), None),
    ("stripe", re.compile(r"\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}"), None),
    ("muninn-ro", re.compile(r"\bmro_[0-9a-f]{64}\b"), None),
    ("ntfy", re.compile(r"\btk_[a-z0-9]{29}\b"), None),
    ("telegram", re.compile(r"\b\d{8,10}:AA[A-Za-z0-9_-]{33}\b"), None),
    ("discord-webhook", re.compile(r"discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]{30,}"), None),
    ("age-key", re.compile(r"\bAGE-SECRET-KEY-1[0-9A-Z]{50,}"), None),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"), None),
    ("auth-header", re.compile(r"(?i)\b(?:proxy-)?authorization\s*:\s*(?:bearer|basic|token|bot|digest)\s+"
                               r"[A-Za-z0-9._~+/=-]{12,}"), _randomish),
    ("bearer", re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{24,}=*"), _randomish),
    ("api-key-header", re.compile(r"(?i)\bx-(?:api|auth)-(?:key|token)\s*:\s*[A-Za-z0-9._~+/=-]{12,}"), _randomish),
    ("totp-uri", re.compile(r"(?i)\botpauth(?:-migration)?://"), None),
    ("url-password", re.compile(r"(?i)\b[a-z][a-z0-9+.-]{1,20}://([^\s:/@<>'\"]{1,64}):([^\s@/<>'\"]{1,128})@[\w\[]"),
     _url_password),
    ("wireguard-key", re.compile(r"(?i)\b(?:private|preshared)\s*key\s*=\s*[A-Za-z0-9+/]{42,43}="), None),
    # "totp: JBSW…", "OTP secret JBSW Y3DP …" (no ':' or '=' needed)
    ("totp-seed", re.compile(r"(?i)(?<![a-z0-9])(?:totp|otp|2fa|mfa)(?![a-z0-9])[^\n]{0,20}?(?<![a-z0-9])"
                             r"((?:[a-z2-7]{4} ){3,}[a-z2-7]{4}|[a-z2-7]{16,})(?![a-z0-9])"), _totp_seed),
    # "password is Hunter2!xq", "pw: …", "passordet er …"
    ("password-is", re.compile(r"(?i)(?<![a-z])(?:password|passord(?:et)?|passwd|passphrase|pw|pwd)(?![a-z])[ \t]*"
                               r"(?:(?:is|was|er|var)(?![a-z])|:|=)[ \t]*[\"'`]?([^\s\"'`<>,;]+)"), _password_value),
    ("token-after-word", TOKEN_RUN, _token_after_word),
]

RUN = re.compile(r"[A-Za-z0-9+/_=-]{32,}")
SKIP_BEFORE = re.compile(
    r"(?:sha(?:1|224|256|384|512)[-:]|md5[-:]|base64,|ssh-(?:ed25519|rsa|dss) |ecdsa-sha2-nistp\d+ |"
    r"sk-(?:ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com |nodekey:|discokey:|machinekey:|/nix/store/|"
    r"public[-_ ]?key[\"']?[ \t]*[:=][ \t]*[\"']?|pubkey[\"']?[ \t]*[:=][ \t]*[\"']?)$", re.I)
NIX_KEY_NAME = re.compile(r"[A-Za-z0-9.-]+-\d+:$")     # cache.nixos.org-1:<public key>
SEGMENTS = re.compile(r"[-_/.+=]+")
ID_PREFIX = ("req_", "msg_", "toolu_", "chatcmpl-", "call_", "resp_", "run_", "wf_", "file_", "batch_",
             "asst_", "thread_", "AAAA")
HASH_PREFIX = re.compile(r"(?i)(?:sha(?:1|224|256|384|512)|md5|blake2b|blake3)[-_]")
URL = re.compile(r"(?i)\b(?:[a-z][a-z0-9+.-]{1,20}://|www\.)[^\s<>\"'`)\]]+")
URL_SECRET_KEY = re.compile(r"(?i)^(?:token|key|secret|sig|signature|password|passwd|pass|auth|access_token|"
                            r"refresh_token|id_token|api_key|apikey|session|sessionid|client_secret|x-amz-signature)$")
WORDISH = re.compile(r"[a-z][a-z0-9]*(?:[-_.][a-z0-9]+)*|[A-Z][a-z]+(?:[-_][A-Za-z0-9]+)*")


def _entropy(s: str) -> float:
    n = len(s)
    return -sum(v / n * math.log2(v / n) for v in Counter(s).values())


def _url_token(line: str) -> bool:
    # a url with ?token=<random> or &sig=<random> in it
    for m in URL.finditer(line):
        try:
            query = urlsplit(m.group(0)).query
        except ValueError:
            continue
        for k, vals in parse_qs(query).items():
            if URL_SECRET_KEY.match(k):
                for v in vals:
                    if len(v) >= 16 and any(c.isdigit() for c in v) and any(c.isalpha() for c in v):
                        return True
    return False


def _high_entropy(line: str) -> bool:
    # a long random-looking run (mixed case + digits, high entropy) that isn't a hash, an id, a url or a path
    urls = [m.span() for m in URL.finditer(line)]
    for m in RUN.finditer(line):
        start = m.start()
        if any(a <= start < b for a, b in urls):  # urls are checked by _url_token
            continue
        if SKIP_BEFORE.search(line[max(0, start - 45):start]):
            continue
        core = m.group(0).strip("=_-/")
        if core.startswith(ID_PREFIX) or HASH_PREFIX.match(core):
            continue
        if "/" in core and sum(1 for p in core.split("/") if p and WORDISH.fullmatch(p)) >= 2:
            continue                             # a path
        if len(core) < 32:
            continue
        if len(core) <= 44 and NIX_KEY_NAME.search(line[max(0, start - 64):start]):
            continue                             # a nix signing key's public half (the secret half is 88 long)
        if not (any(c.isupper() for c in core) and any(c.islower() for c in core)
                and any(c.isdigit() for c in core)):
            continue
        # names like Qwen3-30B-A3B-Instruct-Q4_K_M are short word pieces; a secret has a long random piece
        longest = max(SEGMENTS.split(core), key=len)
        if len(longest) < 16 or sum((any(c.isupper() for c in longest), any(c.islower() for c in longest),
                                     any(c.isdigit() for c in longest))) < 2:
            continue
        if _entropy(core) >= 4.2:
            return True
    return False


def secret_rule(line: str) -> str | None:
    for name, rx, ok in SECRET_RULES:
        for m in rx.finditer(line):
            if ok is None or ok(m):
                return name
    for m in KV.finditer(line):
        if _valueish(m.group(1)):
            return "key-value"
    if _url_token(line):
        return "url-token"
    if _high_entropy(line):
        return "high-entropy"
    return None


# ---------------------------------------------------------------- masks
EMAIL = re.compile(r"(?<![\w.+%-])([A-Za-z0-9][A-Za-z0-9._%+-]*)@([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?"
                   r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,24})(?![\w-])")
IPV4 = re.compile(r"(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(?!\w|\.\d)")
IPV6 = re.compile(r"(?<![\w:.])((?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4})(?![\w:])")


def _public(addr: str) -> bool:
    try:
        return ipaddress.ip_address(addr).is_global
    except ValueError:
        return False


def mask(text: str) -> tuple[str, int, int]:
    counts = [0, 0]

    def email(m):
        if m.group(1).lower() == "git":     # git@github.com:... is an ssh user, not a mailbox
            return m.group(0)
        counts[0] += 1
        return "(email)"

    def ip(m):
        if _public(m.group(1)):
            counts[1] += 1
            return "(public ip)"
        return m.group(0)

    text = EMAIL.sub(email, text)
    text = IPV4.sub(ip, text)
    text = IPV6.sub(ip, text)
    return text, counts[0], counts[1]


# ---------------------------------------------------------------- deny words and exclude globs
def read_list(path: str | None) -> list[str]:
    if not path:
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return []
    return [ln.strip() for ln in lines if ln.strip() and not ln.strip().startswith("#")]


def make_deny(words: list[str]) -> re.Pattern | None:
    parts = [r"\s+".join(re.escape(w) for w in for_checks(word).split()) for word in words]
    parts = [p for p in parts if p]
    if not parts:
        return None
    return re.compile(r"(?<!\w)(?:" + "|".join(sorted(parts, key=len, reverse=True)) + r")(?!\w)")


def excluded(rel: str, globs: list[str]) -> bool:
    # "journal/*" or "journal/" leave out a folder, "Areas/x.md" one note, "*private*" any path with it
    for g in globs:
        if g.endswith("/") and rel.startswith(g):
            return True
        if fnmatch.fnmatchcase(rel, g):
            return True
    return False


# ---------------------------------------------------------------- links to notes outside the view
WIKI = re.compile(r"!?\[\[([^\[\]\n]+?)\]\]")
MDLINK = re.compile(r"!?\[([^\]\n]*)\]\(\s*(<[^>\n]+>|[^)\s]+)((?:\s+\"[^\"\n]*\")?)\s*\)")
OBSURL = re.compile(r"obsidian://[^\s)\]>\"']+", re.I)
SCHEME = re.compile(r"^[a-z][a-z0-9+.-]*:", re.I)


class LinkIndex:
    def __init__(self, private: set[str]):
        self.paths = {p[:-3].lower() for p in private}
        self.stems = {posixpath.basename(p)[:-3].lower() for p in private}

    def is_private(self, target: str, base_dir: str = "") -> bool:
        t = unquote(target).strip().replace("\\", "/")
        t = t.split("|", 1)[0].split("#", 1)[0].strip()
        if t.lower().endswith(".md"):
            t = t[:-3]
        if not t:
            return False
        cands = {t.lstrip("/").lower()}
        if base_dir and not t.startswith("/"):
            cands.add(posixpath.normpath(posixpath.join(base_dir, t)).lower())
        for c in cands:
            while c.startswith("./"):
                c = c[2:]
            if c in self.paths:
                return True
            if "/" not in c and c in self.stems:
                return True
            if "/" in c and any(p.endswith("/" + c) for p in self.paths):
                return True
        return False

    def obsidian_private(self, url: str) -> bool:
        q = parse_qs(urlsplit(url).query)
        f = (q.get("file") or q.get("path") or [""])[0]
        return bool(f) and self.is_private(f)


def rewrite_links(text: str, base_dir: str, idx: LinkIndex) -> tuple[str, int]:
    n = [0]

    def hide():
        n[0] += 1
        return PRIVATE_LINK

    def wiki(m):
        return hide() if idx.is_private(m.group(1), base_dir) else m.group(0)

    def md(m):
        target = m.group(2).strip("<>")
        if target.lower().startswith("obsidian://"):
            return hide() if idx.obsidian_private(target) else m.group(0)
        if SCHEME.match(target):
            return m.group(0)                # http:, mailto: ...
        return hide() if idx.is_private(target, base_dir) else m.group(0)

    def obs(m):
        return hide() if idx.obsidian_private(m.group(0)) else m.group(0)

    text = WIKI.sub(wiki, text)
    text = MDLINK.sub(md, text)
    text = OBSURL.sub(obs, text)
    return text, n[0]


# ---------------------------------------------------------------- one note
def classify(rel: str, text: str, deny: re.Pattern | None) -> tuple[str, str] | None:
    """(reason, rule) when the note has to stay out of the view, None when it can go in"""
    if has_hidden(rel) or has_hidden(text):
        return ("hidden-chars", "unicode")
    norm, norm_rel = for_checks(text), for_checks(rel)
    rule = agent_rule(norm) or agent_rule(norm_rel)
    if rule:
        return ("agent-text", rule)
    for line in text.replace("\u00ad", "").splitlines():
        rule = secret_rule(line)
        if rule:
            return ("secret", rule)
    if deny and (deny.search(norm) or deny.search(norm_rel)):
        return ("deny-word", "list")
    if EMAIL.search(rel) or any(_public(m.group(1)) for m in IPV4.finditer(rel)):
        return ("path", "email-or-ip")
    return None


def tags(text: str) -> list[str]:
    if not text.startswith("---\n"):
        return []
    end = text.find("\n---", 4)
    if end == -1:
        return []
    lines = text[4:end].split("\n")
    out: list[str] = []
    for i, ln in enumerate(lines):
        m = re.match(r"^tags\s*:\s*(.*)$", ln)
        if not m:
            continue
        v = m.group(1).strip()
        if v:
            out = [t.strip().strip("'\"#") for t in v.strip("[]").split(",")]
        else:
            for nxt in lines[i + 1:]:
                mm = re.match(r"^\s*-\s*(.+)$", nxt)
                if not mm:
                    break
                out.append(mm.group(1).strip().strip("'\"#"))
        break
    return [t[:60] for t in out if t][:30]


# ---------------------------------------------------------------- graphs
class LabelCleaner:
    def __init__(self, idx: LinkIndex, deny: re.Pattern | None):
        self.idx, self.deny = idx, deny

    def __call__(self, s: str, private: str = PRIVATE_LABEL) -> str:
        s, _ = rewrite_links(str(s)[:400], "", self.idx)
        if has_hidden(s):
            return private
        norm = for_checks(s)
        if agent_rule(norm) or secret_rule(s) or (self.deny and self.deny.search(norm)):
            return private
        s, _, _ = mask(s)
        return clean(s)


def norm_graph(obj) -> tuple[list[dict], list[dict]]:
    """huginn's node-link graph.json, or a graph this script wrote before -> plain nodes and edges"""
    if not isinstance(obj, dict):
        raise ValueError("graph is not an object")
    raw_nodes, raw_edges = obj.get("nodes"), obj.get("edges", obj.get("links"))
    if not isinstance(raw_nodes, list) or not isinstance(raw_edges, list):
        raise ValueError("graph has no node or edge list")
    nodes, edges = [], []
    for n in raw_nodes:
        if not isinstance(n, dict) or "id" not in n:
            raise ValueError("bad node")
        c = n.get("community")
        nodes.append({"id": str(n["id"]), "label": str(n.get("label") or n["id"]),
                      "file": str(n.get("source_file", n.get("file")) or ""),
                      "community": c if isinstance(c, int) and not isinstance(c, bool) else None,
                      "community_name": str(n.get("community_name") or ""),
                      "kind": str(n.get("node_kind") or n.get("kind") or n.get("file_type") or "")})
    for e in raw_edges:
        if not isinstance(e, dict) or "source" not in e or "target" not in e:
            raise ValueError("bad edge")
        f = e.get("source_file")
        edges.append({"source": str(e["source"]), "target": str(e["target"]),
                      "relation": str(e.get("relation") or ""), "file": None if f is None else str(f)})
    return nodes, edges


def prune_notes_graph(nodes: list[dict], edges: list[dict], paths: set[str], label: LabelCleaner) -> dict:
    keep = {n["id"] for n in nodes if n["file"] and n["file"] in paths}
    # a community with any note that isn't in the view loses its name: minimax wrote it from all members
    tainted = {n["community"] for n in nodes if n["id"] not in keep and n["community"] is not None}
    new_id: dict[str, str] = {}
    out_nodes = []
    for n in nodes:
        if n["id"] not in keep or n["id"] in new_id:
            continue
        new_id[n["id"]] = f"n{len(out_nodes)}"      # new ids: the old ones are made from headings
        name = "" if n["community"] in tainted else label(n["community_name"], private="")
        out_nodes.append({"id": new_id[n["id"]], "label": label(n["label"]), "file": n["file"],
                          "community": n["community"], "community_name": name, "kind": n["kind"][:20]})
    out_edges = [{"source": new_id[e["source"]], "target": new_id[e["target"]], "relation": e["relation"][:40]}
                 for e in edges
                 if e["source"] in new_id and e["target"] in new_id and (e["file"] is None or e["file"] in paths)]
    return {"nodes": out_nodes, "edges": out_edges}


def verify_notes_graph(g: dict, paths: set[str]) -> Counter:
    problems: Counter = Counter()
    ids: set[str] = set()
    for n in g.get("nodes", []):
        if set(n) - NODE_KEYS:
            problems["node with extra fields"] += 1
        f = n.get("file")
        if not f:
            problems["node without a source file"] += 1
        elif f not in paths:
            problems["node source not in the manifest"] += 1
        if n.get("id") in ids:
            problems["duplicate node id"] += 1
        ids.add(n.get("id"))
    for e in g.get("edges", []):
        if set(e) - EDGE_KEYS:
            problems["edge with extra fields"] += 1
        if e.get("source") not in ids or e.get("target") not in ids:
            problems["edge to a missing node"] += 1
    return problems


def _load(path: str | None):
    if not path:
        raise FileNotFoundError("no path")
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def notes_graph(candidates, paths: set[str], label: LabelCleaner, log) -> tuple[dict, str]:
    """first candidate that prunes clean wins: the fresh huginn graph, then the previous good copy
    (pruned again to today's manifest), else an empty graph. fails closed."""
    for how, path in candidates:
        try:
            nodes, edges = norm_graph(_load(path))
            g = prune_notes_graph(nodes, edges, paths, label)
        except (OSError, ValueError) as e:
            log(f"graph notes: {how} copy unusable ({type(e).__name__})")
            continue
        problems = verify_notes_graph(g, paths)
        if problems:
            log(f"graph notes: {how} copy failed the check ({sum(problems.values())} problems: "
                + ", ".join(sorted(problems)) + "), not used")
            continue
        if how != "fresh":
            log(f"graph notes: serving the {how} copy")
        return g, how
    log("graph notes: no good copy, serving an empty graph")
    return {"nodes": [], "edges": []}, "empty"


def dotfiles_graph(candidates, log) -> tuple[dict, str]:
    # my public repo: copied, only the fields the server uses, odd labels hidden
    def lab(s, private="(hidden)"):
        s = str(s)[:400]
        return private if has_hidden(s) or agent_rule(for_checks(s)) else s
    for how, path in candidates:
        try:
            nodes, edges = norm_graph(_load(path))
        except (OSError, ValueError) as e:
            log(f"graph dotfiles: {how} copy unusable ({type(e).__name__})")
            continue
        ids = {n["id"] for n in nodes}
        g = {"nodes": [{"id": n["id"], "label": lab(n["label"]), "file": n["file"], "community": n["community"],
                        "community_name": lab(n["community_name"], ""), "kind": n["kind"][:20]} for n in nodes],
             "edges": [{"source": e["source"], "target": e["target"], "relation": e["relation"][:40]}
                       for e in edges if e["source"] in ids and e["target"] in ids]}
        if how != "fresh":
            log(f"graph dotfiles: serving the {how} copy")
        return g, how
    log("graph dotfiles: no good copy, serving an empty graph")
    return {"nodes": [], "edges": []}, "empty"


# ---------------------------------------------------------------- the build
def _walk_error(e: OSError):
    # a folder i can't list (an nfs hiccup) fails the build, so the last good view stays and i get told
    raise e


def scan(vault: str):
    notes, skipped = [], Counter()
    for root, dirs, files in os.walk(vault, followlinks=False, onerror=_walk_error):
        rel_root = os.path.relpath(root, vault)
        rel_root = "" if rel_root == "." else rel_root.replace(os.sep, "/")
        if not rel_root:
            dirs[:] = [d for d in dirs if d not in PRUNE_TOP]
        dirs.sort()
        top = rel_root.split("/", 1)[0]
        for f in sorted(files):
            rel = f"{rel_root}/{f}" if rel_root else f
            try:
                st = os.lstat(os.path.join(root, f))
            except OSError:
                skipped["unreadable"] += 1
                continue
            if not stat.S_ISREG(st.st_mode):
                skipped["not-a-file"] += 1
            elif not f.lower().endswith(".md"):
                skipped["not-markdown"] += 1
            else:
                notes.append((rel, os.path.join(root, f), st, top in SKIP_TOP))
    return notes, skipped


def read_note(full: str) -> bytes:
    fd = os.open(full, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("not a regular file")
        chunks, size = [], 0
        while True:
            b = os.read(fd, 1 << 16)
            if not b:
                break
            size += len(b)
            if size > MAX_BYTES:
                raise OSError("too big")
            chunks.append(b)
        return b"".join(chunks)
    finally:
        os.close(fd)


def _safe_rel(rel: str) -> bool:
    parts = rel.split("/")
    return not rel.startswith("/") and "\x00" not in rel and "\\" not in rel and all(p not in ("", ".", "..") for p in parts)


def _write_atomic(path: str, data: bytes, mode: int) -> None:
    tmp = f"{path}.tmp-{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    try:
        os.write(fd, data)
        os.fchmod(fd, mode)
    finally:
        os.close(fd)
    os.replace(tmp, path)


def build(vault: str, out: str, vault_graph: str | None = None, dotfiles_graph_path: str | None = None,
          exclude: list[str] = (), deny: list[str] = (), now: float | None = None, log=print) -> dict:
    now = time.time() if now is None else now
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now))
    notes, skipped = scan(vault)
    if not notes:
        raise RuntimeError("no notes found: is the vault mounted?")
    deny_re = make_deny(list(deny))
    dropped, rules, drops = Counter(), Counter(), []
    kept: dict[str, tuple[str, os.stat_result]] = {}
    every = set()
    for rel, full, st, in_skipped in notes:
        every.add(rel)
        if in_skipped:
            skipped["skipped-folder"] += 1
            continue
        reason = None
        if not _safe_rel(rel):
            reason = ("path", "unsafe")
        elif excluded(rel, list(exclude)):
            reason = ("excluded", "glob")
        elif st.st_size > MAX_BYTES:
            reason = ("too-big", "size")
        else:
            try:
                text = read_note(full).decode("utf-8")
            except UnicodeDecodeError:
                reason = ("not-utf8", "decode")
            except OSError:
                reason = ("unreadable", "io")
            else:
                reason = classify(rel, text, deny_re)
        if reason:
            dropped[reason[0]] += 1
            rules[f"{reason[0]}:{reason[1]}"] += 1
            drops.append((rel, reason[0]))
        else:
            kept[rel] = (text, st)

    idx = LinkIndex(every - set(kept))
    view_root = os.path.join(out, "view")
    os.makedirs(view_root, exist_ok=True)
    name, i = f"v-{stamp}-{os.getpid()}", 0
    while os.path.lexists(os.path.join(view_root, name)):
        i += 1
        name = f"v-{stamp}-{os.getpid()}-{i}"
    tmp, final = os.path.join(view_root, f".tmp-{name}"), os.path.join(view_root, name)
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(os.path.join(tmp, "notes"))
    os.makedirs(os.path.join(tmp, "graphs"))
    manifest, masked = {}, Counter()
    for rel, (text, st) in sorted(kept.items()):
        body, n_links = rewrite_links(text, posixpath.dirname(rel), idx)
        body, n_email, n_ip = mask(body)
        data = clean(body).encode("utf-8")
        dst = os.path.join(tmp, "notes", *rel.split("/"))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "xb") as fh:
            fh.write(data)
        manifest[rel] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data), "mtime": int(st.st_mtime),
                         "title": posixpath.basename(rel)[:-3], "tags": tags(body)}
        masked["links"] += n_links
        masked["emails"] += n_email
        masked["ips"] += n_ip
        masked["notes"] += 1 if (n_email or n_ip) else 0

    current = os.path.join(view_root, "current")
    prev = os.path.realpath(current) if os.path.islink(current) else None
    paths = set(manifest)
    g_notes, how_notes = notes_graph(
        [("fresh", vault_graph), ("previous", prev and os.path.join(prev, "graphs", "notes.json"))],
        paths, LabelCleaner(idx, deny_re), log)
    g_dot, how_dot = dotfiles_graph(
        [("fresh", dotfiles_graph_path), ("previous", prev and os.path.join(prev, "graphs", "dotfiles.json"))], log)
    built = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    graphs_info = {}
    for gname, g, how in (("notes", g_notes, how_notes), ("dotfiles", g_dot, how_dot)):
        g = {"kind": gname, "built": built, "from": how, **g}
        with open(os.path.join(tmp, "graphs", f"{gname}.json"), "x", encoding="utf-8") as fh:
            json.dump(g, fh, ensure_ascii=False)
        graphs_info[gname] = {"nodes": len(g["nodes"]), "edges": len(g["edges"]), "from": how}
    with open(os.path.join(tmp, "manifest.json"), "x", encoding="utf-8") as fh:
        json.dump({"built": built, "notes": manifest, "graphs": graphs_info}, fh, ensure_ascii=False)

    os.rename(tmp, final)
    link_tmp = os.path.join(view_root, f".current-{os.getpid()}")
    if os.path.lexists(link_tmp):
        os.unlink(link_tmp)
    os.symlink(name, link_tmp)                   # relative, so it resolves inside the server's bind too
    os.replace(link_tmp, current)
    keep = {name, os.path.basename(prev) if prev else ""}   # the new view and the one before it
    for old in os.listdir(view_root):
        if old.startswith("v-") and old not in keep:
            shutil.rmtree(os.path.join(view_root, old), ignore_errors=True)
    for d in os.listdir(view_root):
        if d.startswith(".tmp-"):
            shutil.rmtree(os.path.join(view_root, d), ignore_errors=True)

    _write_atomic(os.path.join(out, "drops.log"),
                  "".join(f"{p}\t{r}\n" for p, r in sorted(drops)).encode("utf-8"), 0o600)
    summary = {"built": built, "kept": len(manifest), "dropped": dict(dropped), "skipped": dict(skipped),
               "masked": dict(masked), "graphs": graphs_info, "rules": dict(rules)}
    log(f"muninn-ro-build: {len(manifest)} notes in the view, {sum(dropped.values())} left out ("
        + ", ".join(f"{k} {v}" for k, v in sorted(dropped.items())) + "), skipped "
        + ", ".join(f"{k} {v}" for k, v in sorted(skipped.items()))
        + f"; masked {masked['emails']} emails and {masked['ips']} public ips in {masked['notes']} notes,"
        f" {masked['links']} links to private notes; graph notes {graphs_info['notes']['nodes']} nodes /"
        f" {graphs_info['notes']['edges']} edges ({how_notes}), dotfiles {graphs_info['dotfiles']['nodes']}"
        f" nodes ({how_dot})")
    return summary


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="build muninn-ro's read-only view of the vault")
    ap.add_argument("--vault", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--vault-graph")
    ap.add_argument("--dotfiles-graph")
    ap.add_argument("--exclude", help="file with globs, one a line")
    ap.add_argument("--deny", help="file with words, one a line")
    ap.add_argument("--stats", action="store_true", help="also print counts per rule (names only)")
    a = ap.parse_args(argv)
    summary = build(a.vault, a.out, a.vault_graph, a.dotfiles_graph, read_list(a.exclude), read_list(a.deny))
    if a.stats:
        print(json.dumps({k: summary[k] for k in ("dropped", "skipped", "masked", "graphs", "rules")}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

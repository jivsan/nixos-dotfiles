#!/usr/bin/env python3
"""ai-gateway: one OpenAI-style door in front of the model servers.

A request names a model (or a route, which is an ordered list of models). The
gateway picks the target that serves it, forwards the call, and measures what
the model servers do not report themselves: time to first token, time per
output token, tokens in and out, finish reasons, queueing. Prometheus reads
the numbers at /metrics; one JSON line per request goes to the journal, and
to Loki when `loki_url` is set, so a request can be looked up by its id.

It also keeps llama.cpp's model swapping safe. With one model in VRAM at a
time, llama-server force-kills the loaded model when another one is asked for,
and the request that was running on it fails. A target marked `exclusive`
makes requests for another model wait here until the running ones are done.

Config: the JSON file named by AIGW_CONFIG (written by ai-gateway.nix).
Run the tests with: python3 -m unittest discover -s hosts/heimdall/ai-gateway -p 'test_*.py'
"""
import asyncio
import collections
import hmac
import ipaddress
import json
import os
import sys
import time
import uuid

import aiohttp
from aiohttp import web
from prometheus_client import (CONTENT_TYPE_LATEST, CollectorRegistry, Counter, Gauge,
                               Histogram, Summary, generate_latest)

ENDPOINTS = ("chat/completions", "completions", "embeddings")
FINISH_REASONS = {"stop", "length", "tool_calls", "content_filter", "repetition", "abort", "error"}
USUAL_REASONS = ("stop", "length", "tool_calls", "abort", "error")
USUAL_CODES = ("200", "500", "502", "stream_error", "client_closed")
MAX_BODY = 64 * 1024 * 1024   # prompts with images are large

# Seconds. A local model swap can hold the first token back for minutes.
LATENCY_BUCKETS = (0.05, 0.1, 0.25, 0.5, 1, 2, 3, 5, 7.5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 300, 600)
PER_TOKEN_BUCKETS = (0.002, 0.005, 0.0075, 0.01, 0.015, 0.02, 0.03, 0.04, 0.05, 0.075, 0.1, 0.15, 0.25, 0.5, 1)
TOKEN_BUCKETS = (1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000, 500000)


class Metrics:
    """Every series the dashboard reads. One registry per gateway, so tests start from zero."""

    def __init__(self):
        self.registry = r = CollectorRegistry()
        per_call = ("model", "target")
        self.requests = Counter("aigw_requests", "Requests answered, by what the caller got: an HTTP status, "
                                "client_closed (the caller left) or stream_error (the upstream broke mid-stream).",
                                ("endpoint", *per_call, "code"), registry=r)
        self.duration = Histogram("aigw_request_duration_seconds", "Arrival to last byte.",
                                  per_call, buckets=LATENCY_BUCKETS, registry=r)
        self.ttft = Histogram("aigw_time_to_first_token_seconds", "Arrival to first streamed token, queueing included.",
                              per_call, buckets=LATENCY_BUCKETS, registry=r)
        self.per_token = Histogram("aigw_time_per_output_token_seconds", "Mean gap between output tokens of a request.",
                                   per_call, buckets=PER_TOKEN_BUCKETS, registry=r)
        self.prompt_tokens = Counter("aigw_prompt_tokens", "Prompt tokens, cached ones included.", per_call, registry=r)
        self.cached_tokens = Counter("aigw_cached_prompt_tokens", "Prompt tokens served from the prompt cache.",
                                     per_call, registry=r)
        self.completion_tokens = Counter("aigw_completion_tokens", "Generated tokens.", per_call, registry=r)
        self.request_prompt = Histogram("aigw_request_prompt_tokens", "Prompt tokens per request.",
                                        per_call, buckets=TOKEN_BUCKETS, registry=r)
        self.request_completion = Histogram("aigw_request_completion_tokens", "Generated tokens per request.",
                                            per_call, buckets=TOKEN_BUCKETS, registry=r)
        self.queue = Summary("aigw_queue_seconds", "Wait for a free slot on the target.", per_call, registry=r)
        self.prefill = Summary("aigw_prefill_seconds", "Prompt processing time.", per_call, registry=r)
        self.decode = Summary("aigw_decode_seconds", "Generation time.", per_call, registry=r)
        self.finish = Counter("aigw_finish_reason", "Why generation ended.", (*per_call, "reason"), registry=r)
        self.decisions = Counter("aigw_route_decisions", "Which tier served a request and why that model was picked.",
                                 ("route", "tier", "reason"), registry=r)
        self.inflight = Gauge("aigw_inflight_requests", "Requests inside the gateway.", registry=r)
        self.running = Gauge("aigw_target_running", "Requests a target is working on.", ("target",), registry=r)
        self.waiting = Gauge("aigw_target_waiting", "Requests queued here for a target.", ("target",), registry=r)
        self.up = Gauge("aigw_target_up", "1 if the target's health check passed.", ("target",), registry=r)


class Gate:
    """Admission to one target, first come first served.

    At most `slots` requests run at once (0 = no limit). When `exclusive`, they
    must all be for the same model: a request for another one waits until the
    target is idle, and nothing behind it overtakes, so it cannot starve.
    """

    def __init__(self, slots=0, exclusive=False):
        self.slots, self.exclusive = slots, exclusive
        self.model, self.running = None, 0
        self.waiters = collections.deque()   # (model, future)

    def _fits(self, model):
        if self.slots and self.running >= self.slots:
            return False
        return not self.exclusive or self.running == 0 or self.model == model

    def _admit(self):
        while self.waiters:
            model, turn = self.waiters[0]
            if not turn.cancelled():
                if not self._fits(model):
                    return
                self.model, self.running = model, self.running + 1
                turn.set_result(None)
            self.waiters.popleft()

    async def enter(self, model):
        turn = asyncio.get_running_loop().create_future()
        self.waiters.append((model, turn))
        self._admit()
        try:
            await turn
        except asyncio.CancelledError:
            if turn.done() and not turn.cancelled():   # admitted in the same moment the caller left
                self.leave()
            else:
                turn.cancel()
                self._admit()
            raise

    def leave(self):
        self.running -= 1
        self._admit()


class Call:
    """What is known about one request by the time it ends."""

    def __init__(self, request_id, endpoint):
        self.id, self.endpoint = request_id, endpoint
        self.start = time.monotonic()
        self.model, self.target = "unknown", "none"
        self.route = self.tier = self.reason = None
        self.code = "500"
        self.stream = False
        self.queued = 0.0            # seconds waiting at the gate
        self.sent = None             # when the upstream request went out
        self.first = self.last = None   # first and last streamed token
        self.pieces = 0              # streamed deltas that carried output
        self.usage = self.timings = None
        self.finish = None
        self.done = False            # the stream ended with [DONE]

    def see(self, data):
        """Read one upstream JSON object: a whole response or one stream chunk."""
        if not isinstance(data, dict):
            return
        if isinstance(data.get("usage"), dict):
            self.usage = data["usage"]
        if isinstance(data.get("timings"), dict):
            self.timings = data["timings"]   # llama.cpp
        if data.get("error"):
            self.finish = "error"
        for choice in data.get("choices") or ():
            if not isinstance(choice, dict):
                continue
            delta = choice.get("delta")
            if isinstance(delta, dict):   # chat stream
                output = any(delta.get(k) for k in ("content", "reasoning_content", "reasoning", "tool_calls"))
            else:                         # completions stream
                output = self.stream and bool(choice.get("text"))
            if output:
                self.last = time.monotonic()
                self.first = self.first or self.last
                self.pieces += 1
            if choice.get("finish_reason") and self.finish != "error":
                self.finish = choice["finish_reason"]

    def tokens(self):
        """(prompt, cached, completion); None where the upstream gave no count."""
        usage, timings = self.usage or {}, self.timings or {}
        prompt = usage.get("prompt_tokens", usage.get("input_tokens"))
        if prompt is None and "prompt_n" in timings:
            prompt = timings["prompt_n"] + timings.get("cache_n", 0)   # prompt_n leaves the cached ones out
        cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens", timings.get("cache_n"))
        completion = usage.get("completion_tokens", usage.get("output_tokens", timings.get("predicted_n")))
        if completion is None and self.pieces:
            completion = self.pieces   # servers stream about one token per chunk
        return prompt, cached, completion


def log(**fields):
    print(json.dumps(fields), flush=True)


def openai_error(status, message, kind="invalid_request_error"):
    return web.json_response({"error": {"message": message, "type": kind, "code": status}}, status=status)


def load_config(path):
    with open(path, encoding="utf-8") as fh:
        config = json.load(fh)
    config.setdefault("targets", {})
    config.setdefault("models", {})
    config.setdefault("routes", {})
    for name, model in config["models"].items():
        if model.get("target") not in config["targets"]:
            raise ValueError(f"model {name!r} names an unknown target {model.get('target')!r}")
    for name, route in config["routes"].items():
        if name in config["models"]:
            raise ValueError(f"{name!r} is both a model and a route")
        missing = [m for m in route.get("models", []) if m not in config["models"]]
        if missing or not route.get("models"):
            raise ValueError(f"route {name!r} needs a list of known models (unknown: {missing})")
    return config


class Gateway:
    def __init__(self, config, environ=os.environ):
        self.targets, self.models, self.routes = config["targets"], config["models"], config["routes"]
        self.health_interval = config.get("health_interval", 15)
        self.metrics = Metrics()
        self.client_keys = [k.strip() for k in environ.get("AIGW_CLIENT_KEYS", "").split(",") if k.strip()]
        self.keys = {}      # target -> upstream API key
        self.unset = set()  # targets whose key variable is empty: configured but not usable
        for name, target in self.targets.items():
            if target.get("api_key_env"):
                self.keys[name] = environ.get(target["api_key_env"], "")
                if not self.keys[name]:
                    self.unset.add(name)
        self.gates = {name: Gate(target.get("max_concurrent", 0), target.get("exclusive", False))
                      for name, target in self.targets.items()}
        self.up = {name: True for name in self.targets}   # until a health check says otherwise
        self.loki = config.get("loki_url")
        self.shipping = set()   # log lines on their way to Loki
        self.session = None
        self.prober = None
        self.prime()

    def prime(self):
        """Start the series of every configured model at zero.

        Prometheus only sees a rise between two scrapes: a counter that first
        appears at 1 has that first request missing from every rate() and
        increase(). It also gives the dashboard its zero rows.
        """
        m = self.metrics
        for name, model in self.models.items():
            labels = (name, model["target"])
            for metric in (m.duration, m.ttft, m.per_token, m.prompt_tokens, m.cached_tokens, m.completion_tokens,
                           m.request_prompt, m.request_completion, m.queue, m.prefill, m.decode):
                metric.labels(*labels)
            for reason in USUAL_REASONS:
                m.finish.labels(*labels, reason)
            for code in USUAL_CODES:
                m.requests.labels(ENDPOINTS[0], *labels, code)
            m.decisions.labels("direct", model.get("tier", "efficient"), "requested")
            m.running.labels(model["target"])
            m.waiting.labels(model["target"])
        for name, route in self.routes.items():
            for model in route["models"]:
                for reason in ("first", "too_long", "down", "failover"):
                    m.decisions.labels(name, self.models[model].get("tier", "efficient"), reason)

    # ── lifecycle ────────────────────────────────────────────────────────────
    def app(self):
        app = web.Application(client_max_size=MAX_BODY)
        app.router.add_get("/health", self.health)
        app.router.add_get("/metrics", self.metrics_page)
        app.router.add_get("/v1/models", self.list_models)
        for endpoint in ENDPOINTS:
            app.router.add_post(f"/v1/{endpoint}", self.handle)
        app.on_startup.append(self.start)
        app.on_cleanup.append(self.stop)
        return app

    async def start(self, _app):
        # No total timeout: a long generation is not a fault. Reads may stall
        # for as long as a target takes to load a model.
        self.session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None, sock_connect=10, sock_read=900))
        await self.probe_all()
        self.prober = asyncio.create_task(self.probe_forever())

    async def stop(self, _app):
        self.prober.cancel()
        await self.session.close()

    # ── health ───────────────────────────────────────────────────────────────
    async def probe(self, name, url):
        try:
            async with self.session.get(url, timeout=aiohttp.ClientTimeout(total=3)) as response:
                self.up[name] = response.status < 400
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
            self.up[name] = False
        self.metrics.up.labels(name).set(self.up[name])

    async def probe_all(self):
        checks = [self.probe(name, target["health"]) for name, target in self.targets.items() if target.get("health")]
        await asyncio.gather(*checks)

    async def probe_forever(self):
        while True:
            await asyncio.sleep(self.health_interval)
            await self.probe_all()

    async def health(self, _request):
        return web.json_response({"status": "ok", "targets": self.up})

    async def metrics_page(self, _request):
        return web.Response(body=generate_latest(self.metrics.registry), headers={"Content-Type": CONTENT_TYPE_LATEST})

    async def list_models(self, _request):
        names = [*self.routes, *(m for m, model in self.models.items() if model["target"] not in self.unset)]
        return web.json_response({"object": "list", "data": [
            {"id": name, "object": "model", "owned_by": "ai-gateway"} for name in names]})

    # ── who may use what ─────────────────────────────────────────────────────
    def trusted(self, request):
        """A caller on this host, or one with a client key. Only they reach targets that cost money."""
        auth = request.headers.get("Authorization", "")
        if auth.startswith("Bearer ") and any(hmac.compare_digest(auth[7:], key) for key in self.client_keys):
            return True
        if "X-Forwarded-For" in request.headers:   # came through a proxy: its address is not the caller's
            return False
        try:
            return ipaddress.ip_address(request.remote or "").is_loopback
        except ValueError:
            return False

    def plan(self, name, size, trusted):
        """Models to try, in order, for a request of `size` bytes: (route, [(model, reason)]) or an error response."""
        if name in self.models:
            target = self.models[name]["target"]
            if target in self.unset:
                return openai_error(503, f"model {name!r} is not available: no API key is set for {target}", "unavailable_error")
            if target in self.keys and not trusted:
                return openai_error(403, f"model {name!r} needs a client key from this address", "permission_error")
            return "direct", [(name, "requested")]
        if name not in self.routes:
            return openai_error(404, f"model {name!r} not found", "model_not_found")
        eligible = []   # (model, "ok" | "down" | "too_long"), in the route's order
        for model in self.routes[name]["models"]:
            target = self.models[model]["target"]
            limit = self.models[model].get("max_prompt_chars")
            if target in self.unset or (target in self.keys and not trusted):
                continue
            eligible.append((model, "too_long" if limit and size > limit else "ok" if self.up[target] else "down"))
        # A failed health check may be stale, so those models are tried last rather than never.
        order = [m for m, state in eligible if state == "ok"] + [m for m, state in eligible if state == "down"]
        if not order:
            if eligible:
                return openai_error(413, f"route {name!r}: the request is too long for every model", "invalid_request_error")
            return openai_error(503, f"route {name!r}: no model is available to this caller", "unavailable_error")
        before = [m for m, _ in eligible].index(order[0])
        reason = eligible[before - 1][1] if before else "first"   # why the model ahead of it was passed over
        return name, [(order[0], reason), *((m, "failover") for m in order[1:])]

    # ── one request ──────────────────────────────────────────────────────────
    async def handle(self, request):
        call = Call(request.headers.get("X-Request-Id") or uuid.uuid4().hex, request.path.removeprefix("/v1/"))
        self.metrics.inflight.inc()
        try:
            return await self.serve(request, call)
        except asyncio.CancelledError:
            # The caller hung up. Leaving the upstream request closes its
            # connection and frees its slot here. llama-server then stops a
            # streamed generation at once; one that is not streamed runs on
            # until it is done or its model is swapped out.
            call.code, call.finish = "client_closed", "abort"
            raise
        finally:
            self.metrics.inflight.dec()
            self.record(call)

    async def serve(self, request, call):
        raw = await request.read()
        try:
            body = json.loads(raw)
            name = body["model"]
            if not isinstance(name, str):
                raise TypeError
        except (ValueError, KeyError, TypeError):
            call.code = "400"
            return openai_error(400, "the request body must be a JSON object with a \"model\" name")
        plan = self.plan(name, len(raw), self.trusted(request))
        if isinstance(plan, web.Response):
            call.code = str(plan.status)
            return plan
        call.route, candidates = plan
        call.stream = bool(body.get("stream"))
        hide_usage = False
        if call.stream and call.endpoint != "embeddings":
            # Ask for the token counts; a caller that did not ask is not shown the extra chunk.
            options = body.get("stream_options") if isinstance(body.get("stream_options"), dict) else {}
            hide_usage = not options.get("include_usage")
            body["stream_options"] = {**options, "include_usage": True}
        for position, (model, reason) in enumerate(candidates):
            call.model, call.target = model, self.models[model]["target"]
            call.tier, call.reason = self.models[model].get("tier", "efficient"), reason
            last = position == len(candidates) - 1
            response = await self.attempt(request, call, body, hide_usage, may_retry=not last)
            if response is not None:
                return response
            log(event="failover", id=call.id, **{"from": model, "to": candidates[position + 1][0]})

    async def attempt(self, request, call, body, hide_usage, may_retry):
        """Send the request to call.model. None means: failed before the caller saw anything, try the next model."""
        model, target = self.models[call.model], self.targets[call.target]
        upstream_model = model.get("upstream_model", call.model)
        headers = {"Content-Type": "application/json", "Accept": request.headers.get("Accept", "*/*")}
        if call.target in self.keys:
            headers["Authorization"] = f"Bearer {self.keys[call.target]}"
        url = f"{target['base_url'].rstrip('/')}/{call.endpoint}"
        gate, metrics = self.gates[call.target], self.metrics
        waited = time.monotonic()
        metrics.waiting.labels(call.target).inc()
        try:
            await gate.enter(upstream_model)
        finally:
            metrics.waiting.labels(call.target).dec()
        call.queued += time.monotonic() - waited
        call.sent = time.monotonic()
        metrics.running.labels(call.target).inc()
        try:
            try:
                upstream = await self.session.post(url, data=json.dumps({**body, "model": upstream_model}), headers=headers)
            except (aiohttp.ClientError, asyncio.TimeoutError, OSError) as error:
                if may_retry:
                    return None
                call.code, call.finish = "502", "error"
                return openai_error(502, f"{call.target} did not answer: {error.__class__.__name__}: {error}", "upstream_error")
            async with upstream:
                if "text/event-stream" in upstream.headers.get("Content-Type", "") and upstream.status == 200:
                    return await self.relay_stream(request, call, upstream, hide_usage)
                try:
                    payload = await upstream.read()
                except (aiohttp.ClientError, asyncio.TimeoutError) as error:
                    if may_retry:
                        return None
                    call.code, call.finish = "502", "error"
                    return openai_error(502, f"{call.target} broke off: {error.__class__.__name__}", "upstream_error")
                try:
                    data = json.loads(payload)
                except ValueError:
                    data = None
                if upstream.status >= 400:
                    error = data.get("error") if isinstance(data, dict) else None
                    kind = error.get("type") if isinstance(error, dict) else None
                    # the next model may be up, or have the room this one lacks
                    if may_retry and (upstream.status >= 500 or kind == "exceed_context_size_error"):
                        return None
                    call.finish = "error"
                else:
                    call.see(data)
                call.code = str(upstream.status)
                return web.Response(body=payload, status=upstream.status, headers=self.answer_headers(call, upstream))
        finally:
            metrics.running.labels(call.target).dec()
            gate.leave()

    def answer_headers(self, call, upstream):
        return {"Content-Type": upstream.headers.get("Content-Type", "application/json"),
                "X-Request-Id": call.id, "X-AIGW-Model": call.model, "X-AIGW-Target": call.target}

    async def relay_stream(self, request, call, upstream, hide_usage):
        response = web.StreamResponse(headers={**self.answer_headers(call, upstream),
                                               "Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
        await response.prepare(request)
        call.code = "200"
        buffer = b""
        try:
            async for chunk in upstream.content.iter_any():
                buffer += chunk.replace(b"\r\n", b"\n")
                *events, buffer = buffer.split(b"\n\n")
                for event in events:
                    if self.read_event(call, event, hide_usage):
                        await response.write(event + b"\n\n")
            if buffer.strip() and self.read_event(call, buffer, hide_usage):
                await response.write(buffer + b"\n\n")
            if not call.done and not call.finish:
                raise aiohttp.ClientPayloadError("the stream stopped without finishing")
            await response.write_eof()
        except ConnectionResetError:   # the caller's side went away between two writes
            call.code, call.finish = "client_closed", "abort"
        except (aiohttp.ClientError, asyncio.TimeoutError):
            call.code, call.finish = "stream_error", "error"
        return response

    @staticmethod
    def read_event(call, event, hide_usage):
        """Take the numbers out of one SSE event. False if the caller should not get it."""
        for line in event.split(b"\n"):
            if not line.startswith(b"data:"):
                continue
            try:
                data = json.loads(line[5:])
            except ValueError:
                call.done = call.done or line[5:].strip() == b"[DONE]"
                continue
            call.see(data)
            if hide_usage and isinstance(data, dict) and data.get("choices") == [] and "usage" in data:
                return False
        return True

    # ── numbers ──────────────────────────────────────────────────────────────
    def record(self, call):
        m, labels = self.metrics, (call.model, call.target)
        now = time.monotonic()
        elapsed = now - call.start
        ok = call.code == "200"
        finish = call.finish
        if finish is None and call.sent is not None and not ok:
            finish = "error"   # an upstream was asked and the caller got no answer
        if finish and finish not in FINISH_REASONS:
            finish = "other"
        m.requests.labels(call.endpoint, *labels, call.code).inc()
        m.duration.labels(*labels).observe(elapsed)
        if call.route:
            m.decisions.labels(call.route, call.tier, call.reason).inc()
        if call.sent is not None:
            m.queue.labels(*labels).observe(call.queued)
        if finish:
            m.finish.labels(*labels, finish).inc()
        prompt, cached, completion = call.tokens()
        if prompt is not None:
            m.prompt_tokens.labels(*labels).inc(prompt)
            m.request_prompt.labels(*labels).observe(prompt)
        if cached:
            m.cached_tokens.labels(*labels).inc(cached)
        if completion is not None and call.endpoint != "embeddings":
            m.completion_tokens.labels(*labels).inc(completion)
            m.request_completion.labels(*labels).observe(completion)
        ttft = per_token = None
        timings = call.timings or {}
        if call.first is not None:
            ttft = call.first - call.start
            m.ttft.labels(*labels).observe(ttft)
            if completion and completion > 1:
                per_token = (call.last - call.first) / (completion - 1)
        elif ok and timings.get("predicted_n") and timings.get("predicted_ms") is not None:
            per_token = timings["predicted_ms"] / 1000 / timings["predicted_n"]
        if per_token is not None:
            m.per_token.labels(*labels).observe(per_token)
        # The server's own timings where it gives them (llama.cpp), else what was seen on the wire.
        if "prompt_ms" in timings and "predicted_ms" in timings:
            m.prefill.labels(*labels).observe(timings["prompt_ms"] / 1000)
            m.decode.labels(*labels).observe(timings["predicted_ms"] / 1000)
        elif call.first is not None:
            m.prefill.labels(*labels).observe(call.first - call.sent)
            m.decode.labels(*labels).observe(call.last - call.first)
        fields = dict(event="request", id=call.id, endpoint=call.endpoint, model=call.model, target=call.target,
                      route=call.route, tier=call.tier, reason=call.reason, code=call.code, stream=call.stream,
                      finish=finish, prompt_tokens=prompt, cached_tokens=cached, completion_tokens=completion,
                      queued_s=round(call.queued, 3), ttft_s=None if ttft is None else round(ttft, 3),
                      duration_s=round(elapsed, 3))
        log(**fields)
        if self.loki and self.session and not self.session.closed:
            task = asyncio.create_task(self.ship(json.dumps(fields)))   # nobody waits for it
            self.shipping.add(task)
            task.add_done_callback(self.shipping.discard)

    async def ship(self, line):
        entry = {"streams": [{"stream": {"job": "ai-gateway"}, "values": [[str(time.time_ns()), line]]}]}
        try:
            async with self.session.post(self.loki, json=entry, timeout=aiohttp.ClientTimeout(total=3)):
                pass
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
            pass   # the journal still has the line


def main():
    config = load_config(os.environ.get("AIGW_CONFIG", "config.json"))
    gateway = Gateway(config)
    listen = config.get("listen", {})
    host, port = listen.get("host", "127.0.0.1"), listen.get("port", 4000)
    for name in sorted(gateway.unset):
        print(f"ai-gateway: target {name} is off: ${config['targets'][name]['api_key_env']} is not set", file=sys.stderr, flush=True)
    print(f"ai-gateway: {host}:{port}, models: {', '.join([*gateway.routes, *gateway.models])}", file=sys.stderr, flush=True)
    # handler_cancellation: a caller that disconnects cancels its request instead of holding a slot to the end
    web.run_app(gateway.app(), host=host, port=port, print=None, handler_cancellation=True, access_log=None)


if __name__ == "__main__":
    main()

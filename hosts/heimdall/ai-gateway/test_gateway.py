"""Gateway tests; the model servers are a local stand-in, nothing leaves this machine.

The stand-in's replies are llama.cpp's own (llama-server b9190, router mode),
captured from a real run and shortened.

Run with: python3 -m unittest discover -s hosts/heimdall/ai-gateway -p 'test_*.py'
"""
import asyncio
import json
import tempfile
import unittest
from unittest import mock

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

import gateway
from gateway import Gate, Gateway

TIMINGS = {"cache_n": 45, "prompt_n": 1, "prompt_ms": 250.0, "predicted_n": 3, "predicted_ms": 500.0}
USAGE = {"completion_tokens": 3, "prompt_tokens": 46, "total_tokens": 49, "prompt_tokens_details": {"cached_tokens": 45}}
CHAT = {"choices": [{"finish_reason": "stop", "index": 0, "message": {"role": "assistant", "content": "Hi there"}}],
        "model": "small", "object": "chat.completion", "usage": USAGE, "timings": TIMINGS}


def chunk(delta=None, finish=None, **extra):
    return {"choices": [{"finish_reason": finish, "index": 0, "delta": delta or {}}],
            "model": "small", "object": "chat.completion.chunk", **extra}


# What llama-server streams when asked for usage: the last content chunk carries
# the finish reason, then one chunk with no choices carries usage and timings.
STREAM = [chunk({"role": "assistant", "content": None}), chunk({"content": "Hi"}), chunk({"content": " there"}),
          chunk({"content": "!"}), chunk(finish="stop"),
          {"choices": [], "object": "chat.completion.chunk", "usage": USAGE, "timings": TIMINGS}]


def json_reply(payload, status=200):
    async def reply(_request, _body):
        return web.json_response(payload, status=status)
    return reply


def sse_reply(events, done=True, pause=0):
    async def reply(request, _body):
        response = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
        await response.prepare(request)
        for event in events:
            await response.write(b"data: " + json.dumps(event).encode() + b"\n\n")
            await asyncio.sleep(pause)
        if done:
            await response.write(b"data: [DONE]\n\n")
        return response
    return reply


class Upstream:
    """Stands in for every target; `seen` is what reached it, `replies` what it answers per model."""

    def __init__(self):
        self.seen = []       # (path, headers, body)
        self.replies = {}    # model -> reply, "*" for the rest
        self.healthy = True
        self.pushed = []     # what was sent to the stand-in Loki

    def app(self):
        app = web.Application()
        app.router.add_get("/health", self.health)
        app.router.add_post("/loki/api/v1/push", self.push)
        app.router.add_post("/{path:.*}", self.handle)
        return app

    async def health(self, _request):
        return web.json_response({"status": "ok"}, status=200 if self.healthy else 503)

    async def push(self, request):
        self.pushed.append(await request.json())
        return web.Response(status=204)

    async def handle(self, request):
        body = await request.json()
        self.seen.append((request.path, request.headers, body))
        reply = self.replies.get(body["model"]) or self.replies.get("*") or json_reply(CHAT)
        return await reply(request, body)


class GatewayCase(unittest.IsolatedAsyncioTestCase):
    environ = {"CLOUD_KEY": "upstream-key-for-tests", "AIGW_CLIENT_KEYS": "client-key-for-tests"}

    def config(self, url):
        return {
            "targets": {
                "gpu": {"base_url": f"{url}/v1", "health": f"{url}/health", "max_concurrent": 2, "exclusive": True},
                "cloud": {"base_url": f"{url}/cloud/v1", "api_key_env": "CLOUD_KEY"},
            },
            "models": {
                "small": {"target": "gpu", "tier": "efficient", "max_prompt_chars": 2000},
                "big": {"target": "gpu", "tier": "capable", "upstream_model": "big-q4"},
                "cloud/large": {"target": "cloud", "tier": "capable"},
            },
            "routes": {"auto": {"models": ["small", "cloud/large"]}},
        }

    async def asyncSetUp(self):
        patch = mock.patch.object(gateway, "log")
        self.log = patch.start()
        self.addCleanup(patch.stop)
        self.upstream = Upstream()
        upstream_server = TestServer(self.upstream.app())
        await upstream_server.start_server()
        self.addAsyncCleanup(upstream_server.close)
        self.gw = Gateway(self.config(str(upstream_server.make_url("")).rstrip("/")), environ=self.environ)
        server = TestServer(self.gw.app())
        await server.start_server()   # the test server cancels a handler when its caller leaves, as main() does
        self.client = TestClient(server)
        await self.client.start_server()
        self.addAsyncCleanup(self.client.close)

    def value(self, name, **labels):
        return self.gw.metrics.registry.get_sample_value(name, labels) or 0

    async def chat(self, model="small", headers=None, **body):
        return await self.client.post("/v1/chat/completions", headers=headers, json={
            "model": model, "messages": [{"role": "user", "content": "hi"}], **body})

    def logged(self, event="request"):
        return [call.kwargs for call in self.log.call_args_list if call.kwargs.get("event") == event]

    async def settled(self, check):
        """Wait for something that happens just after the caller is gone."""
        for _ in range(200):
            if check():
                return
            await asyncio.sleep(0.01)
        self.fail("timed out")


class PlainRequests(GatewayCase):
    async def test_answer_passes_through_and_is_counted(self):
        response = await self.chat()
        self.assertEqual(response.status, 200)
        self.assertEqual(await response.json(), CHAT)
        self.assertEqual(response.headers["X-AIGW-Target"], "gpu")
        labels = {"model": "small", "target": "gpu"}
        self.assertEqual(self.value("aigw_requests_total", endpoint="chat/completions", code="200", **labels), 1)
        self.assertEqual(self.value("aigw_prompt_tokens_total", **labels), 46)
        self.assertEqual(self.value("aigw_cached_prompt_tokens_total", **labels), 45)
        self.assertEqual(self.value("aigw_completion_tokens_total", **labels), 3)
        self.assertEqual(self.value("aigw_finish_reason_total", reason="stop", **labels), 1)
        self.assertEqual(self.value("aigw_route_decisions_total", route="direct", tier="efficient", reason="requested"), 1)
        self.assertEqual(self.value("aigw_request_duration_seconds_count", **labels), 1)
        self.assertEqual(self.value("aigw_inflight_requests"), 0)

    async def test_server_timings_fill_the_stage_breakdown(self):
        await self.chat()
        labels = {"model": "small", "target": "gpu"}
        self.assertAlmostEqual(self.value("aigw_prefill_seconds_sum", **labels), 0.25)
        self.assertAlmostEqual(self.value("aigw_decode_seconds_sum", **labels), 0.5)
        # not streamed, so the per-token time is the server's: 500 ms over 3 tokens
        self.assertAlmostEqual(self.value("aigw_time_per_output_token_seconds_sum", **labels), 0.5 / 3)
        self.assertEqual(self.value("aigw_time_to_first_token_seconds_count", **labels), 0)

    async def test_upstream_gets_its_own_model_name(self):
        await self.chat("big")
        path, _, body = self.upstream.seen[0]
        self.assertEqual((path, body["model"]), ("/v1/chat/completions", "big-q4"))
        self.assertEqual(self.value("aigw_route_decisions_total", route="direct", tier="capable", reason="requested"), 1)

    async def test_callers_key_is_never_forwarded(self):
        await self.chat(headers={"Authorization": "Bearer client-key-for-tests"})
        await self.chat("cloud/large", headers={"Authorization": "Bearer client-key-for-tests"})
        local, cloud = (headers.get("Authorization") for _, headers, _ in self.upstream.seen)
        self.assertIsNone(local)
        self.assertEqual(cloud, "Bearer upstream-key-for-tests")

    async def test_embeddings_count_prompt_tokens_only(self):
        self.upstream.replies["*"] = json_reply({"data": [{"embedding": [0.1]}], "usage": {"prompt_tokens": 7, "total_tokens": 7}})
        response = await self.client.post("/v1/embeddings", json={"model": "small", "input": "hi"})
        self.assertEqual(response.status, 200)
        self.assertEqual(self.value("aigw_prompt_tokens_total", model="small", target="gpu"), 7)
        self.assertEqual(self.value("aigw_request_completion_tokens_count", model="small", target="gpu"), 0)
        self.assertEqual(self.value("aigw_finish_reason_total", model="small", target="gpu", reason="error"), 0)

    async def test_unknown_model_and_bad_body(self):
        self.assertEqual((await self.chat("nope")).status, 404)
        bad = await self.client.post("/v1/chat/completions", data=b"not json")
        self.assertEqual(bad.status, 400)
        self.assertEqual((await bad.json())["error"]["type"], "invalid_request_error")
        # callers' model names never become label values, and a turned-away request is not a latency sample
        self.assertEqual(self.value("aigw_requests_total", endpoint="chat/completions", model="unknown", target="none", code="404"), 1)
        self.assertEqual(self.value("aigw_request_duration_seconds_count", model="unknown", target="none"), 0)
        self.assertEqual(self.upstream.seen, [])

    async def test_upstream_error_is_passed_on(self):
        error = {"error": {"code": 400, "message": "bad sampler", "type": "invalid_request_error"}}
        self.upstream.replies["*"] = json_reply(error, status=400)
        response = await self.chat()
        self.assertEqual((response.status, await response.json()), (400, error))
        self.assertEqual(self.value("aigw_finish_reason_total", model="small", target="gpu", reason="error"), 1)

    async def test_models_list_and_request_id(self):
        listed = [m["id"] for m in (await (await self.client.get("/v1/models")).json())["data"]]
        self.assertEqual(listed, ["auto", "small", "big", "cloud/large"])
        response = await self.chat(headers={"X-Request-Id": "abc123"})
        self.assertEqual(response.headers["X-Request-Id"], "abc123")
        self.assertEqual(self.logged()[-1]["id"], "abc123")
        self.assertEqual(self.logged()[-1]["completion_tokens"], 3)


class FreshStart(GatewayCase):
    async def test_series_exist_at_zero_before_the_first_request(self):
        # a counter that first appears at 1 is invisible to rate() and increase()
        sample = self.gw.metrics.registry.get_sample_value
        labels = {"model": "big", "target": "gpu"}
        self.assertEqual(sample("aigw_finish_reason_total", {**labels, "reason": "abort"}), 0)
        self.assertEqual(sample("aigw_completion_tokens_total", labels), 0)
        self.assertEqual(sample("aigw_requests_total", {**labels, "endpoint": "chat/completions", "code": "502"}), 0)
        self.assertEqual(sample("aigw_time_to_first_token_seconds_count", labels), 0)
        self.assertEqual(sample("aigw_route_decisions_total", {"route": "auto", "tier": "capable", "reason": "failover"}), 0)
        self.assertEqual(sample("aigw_route_decisions_total", {"route": "direct", "tier": "efficient", "reason": "requested"}), 0)
        self.assertEqual(sample("aigw_target_waiting", {"target": "gpu"}), 0)
        text = await (await self.client.get("/metrics")).text()
        self.assertIn('aigw_target_up{target="gpu"} 1.0', text)


class RequestLog(GatewayCase):
    def config(self, url):
        return {**super().config(url), "loki_url": f"{url}/loki/api/v1/push"}

    async def test_request_line_goes_to_loki(self):
        await self.chat(headers={"X-Request-Id": "abc123"})
        await self.settled(lambda: self.upstream.pushed)
        stream, = self.upstream.pushed[0]["streams"]
        self.assertEqual(stream["stream"], {"job": "ai-gateway"})
        (stamp, line), = stream["values"]
        self.assertEqual(len(stamp), 19)   # nanoseconds, as a string
        self.assertEqual({k: json.loads(line)[k] for k in ("id", "model", "prompt_tokens", "code")},
                         {"id": "abc123", "model": "small", "prompt_tokens": 46, "code": "200"})


class LokiDown(GatewayCase):
    def config(self, url):
        return {**super().config(url), "loki_url": "http://127.0.0.1:9/loki/api/v1/push"}

    async def test_requests_do_not_depend_on_it(self):
        self.assertEqual((await self.chat()).status, 200)
        await self.settled(lambda: not self.gw.shipping)


class Streaming(GatewayCase):
    async def events(self, response):
        text = (await response.read()).decode()
        return [json.loads(e[6:]) if e != "data: [DONE]" else "[DONE]" for e in text.strip().split("\n\n")]

    async def test_stream_is_relayed_and_usage_chunk_hidden(self):
        self.upstream.replies["*"] = sse_reply(STREAM, pause=0.01)
        response = await self.chat(stream=True)
        self.assertEqual(response.headers["Content-Type"], "text/event-stream")
        # the caller did not ask for usage: it gets everything but the chunk the gateway asked for
        self.assertEqual(await self.events(response), [*STREAM[:-1], "[DONE]"])
        self.assertEqual(self.upstream.seen[0][2]["stream_options"], {"include_usage": True})
        labels = {"model": "small", "target": "gpu"}
        self.assertEqual(self.value("aigw_completion_tokens_total", **labels), 3)
        self.assertEqual(self.value("aigw_prompt_tokens_total", **labels), 46)
        self.assertEqual(self.value("aigw_time_to_first_token_seconds_count", **labels), 1)
        self.assertEqual(self.value("aigw_time_per_output_token_seconds_count", **labels), 1)
        self.assertEqual(self.value("aigw_finish_reason_total", reason="stop", **labels), 1)
        # three pieces 10 ms apart, so about 10 ms a token; never the whole request time
        self.assertLess(self.value("aigw_time_per_output_token_seconds_sum", **labels), 0.05)
        self.assertGreater(self.value("aigw_time_per_output_token_seconds_sum", **labels), 0.005)

    async def test_caller_who_asked_for_usage_gets_it(self):
        self.upstream.replies["*"] = sse_reply(STREAM)
        response = await self.chat(stream=True, stream_options={"include_usage": True})
        self.assertEqual(await self.events(response), [*STREAM, "[DONE]"])

    async def test_tokens_from_timings_when_there_is_no_usage(self):
        # llama-server without include_usage: timings ride on the last chunk
        self.upstream.replies["*"] = sse_reply([*STREAM[:4], chunk(finish="length", timings=TIMINGS)])
        await (await self.chat(stream=True)).read()
        labels = {"model": "small", "target": "gpu"}
        self.assertEqual(self.value("aigw_prompt_tokens_total", **labels), 46)   # 1 processed + 45 cached
        self.assertEqual(self.value("aigw_completion_tokens_total", **labels), 3)
        self.assertEqual(self.value("aigw_finish_reason_total", reason="length", **labels), 1)

    async def test_pieces_are_counted_when_the_server_reports_nothing(self):
        self.upstream.replies["*"] = sse_reply(STREAM[:5])
        await (await self.chat(stream=True)).read()
        self.assertEqual(self.value("aigw_completion_tokens_total", model="small", target="gpu"), 3)
        self.assertEqual(self.value("aigw_request_prompt_tokens_count", model="small", target="gpu"), 0)

    async def test_completions_stream(self):
        events = [{"choices": [{"text": t, "index": 0, "finish_reason": None}]} for t in (",", " there")]
        events.append({"choices": [{"text": "", "index": 0, "finish_reason": "length"}], "usage": USAGE, "timings": TIMINGS})
        self.upstream.replies["*"] = sse_reply(events)
        response = await self.client.post("/v1/completions", json={"model": "small", "prompt": "Once", "stream": True})
        self.assertEqual(await self.events(response), [*events, "[DONE]"])
        self.assertEqual(self.value("aigw_time_to_first_token_seconds_count", model="small", target="gpu"), 1)

    async def test_reasoning_counts_as_first_token(self):
        self.upstream.replies["*"] = sse_reply([chunk({"reasoning_content": "hm"}), chunk({"content": "4"}), chunk(finish="stop")])
        await (await self.chat(stream=True)).read()
        self.assertEqual(self.logged()[-1]["completion_tokens"], 2)

    async def test_stream_that_stops_short_is_an_error(self):
        self.upstream.replies["*"] = sse_reply(STREAM[:3], done=False)
        response = await self.chat(stream=True)
        await response.read()
        labels = {"model": "small", "target": "gpu"}
        self.assertEqual(self.value("aigw_requests_total", endpoint="chat/completions", code="stream_error", **labels), 1)
        self.assertEqual(self.value("aigw_finish_reason_total", reason="error", **labels), 1)

    async def test_error_inside_a_stream(self):
        self.upstream.replies["*"] = sse_reply([chunk({"content": "Hi"}), {"error": {"message": "overloaded"}, "choices": [
            {"finish_reason": "error", "index": 0, "delta": {}}]}])
        await (await self.chat(stream=True)).read()
        self.assertEqual(self.value("aigw_finish_reason_total", model="small", target="gpu", reason="error"), 1)


class CallerLeaves(GatewayCase):
    def hold(self, streamed):
        """An upstream that never finishes; `gone` is set when its connection is dropped."""
        self.started, self.gone = asyncio.Event(), asyncio.Event()

        async def reply(request, _body):
            response = web.StreamResponse(headers={"Content-Type": "text/event-stream" if streamed else "application/json"})
            try:
                if streamed:
                    await response.prepare(request)
                    await response.write(b"data: " + json.dumps(chunk({"content": "Hi"})).encode() + b"\n\n")
                self.started.set()
                await asyncio.sleep(30)
            finally:
                self.gone.set()
            return response
        self.upstream.replies["*"] = reply

    async def leave(self, streamed):
        self.hold(streamed)
        request = asyncio.create_task(self.chat(stream=streamed))
        await asyncio.wait_for(self.started.wait(), 5)
        if streamed:
            response = await request
            await response.content.readany()
            response.close()
        else:
            request.cancel()
        # the model server sees the connection drop: that is what stops the generation
        await asyncio.wait_for(self.gone.wait(), 5)
        labels = {"model": "small", "target": "gpu"}
        await self.settled(lambda: self.value("aigw_finish_reason_total", reason="abort", **labels) == 1)
        self.assertEqual(self.value("aigw_requests_total", endpoint="chat/completions", code="client_closed", **labels), 1)
        self.assertEqual(self.value("aigw_target_running", target="gpu"), 0)
        self.assertEqual(self.value("aigw_inflight_requests"), 0)

    async def test_mid_stream(self):
        await self.leave(streamed=True)
        self.assertEqual(self.logged()[-1]["completion_tokens"], 1)   # what was generated before the caller left

    async def test_while_waiting_for_a_whole_answer(self):
        await self.leave(streamed=False)


class Trust(GatewayCase):
    remote = {"X-Forwarded-For": "10.0.20.50"}   # the test client is on loopback; a proxied call is not

    async def test_local_model_is_open_to_everyone(self):
        self.assertEqual((await self.chat(headers=self.remote)).status, 200)

    async def test_paid_model_needs_a_key_from_elsewhere(self):
        refused = await self.chat("cloud/large", headers=self.remote)
        self.assertEqual(refused.status, 403)
        self.assertEqual(self.upstream.seen, [])
        wrong = await self.chat("cloud/large", headers={**self.remote, "Authorization": "Bearer nope"})
        self.assertEqual(wrong.status, 403)
        keyed = await self.chat("cloud/large", headers={**self.remote, "Authorization": "Bearer client-key-for-tests"})
        self.assertEqual(keyed.status, 200)

    async def test_this_host_needs_no_key(self):
        self.assertEqual((await self.chat("cloud/large")).status, 200)

    async def test_route_keeps_a_stranger_on_the_local_models(self):
        self.upstream.replies["small"] = json_reply({"error": {"message": "boom"}}, status=500)
        response = await self.chat("auto", headers=self.remote)
        self.assertEqual(response.status, 500)   # no failover to the paid model
        self.assertEqual(len(self.upstream.seen), 1)


class NoUpstreamKey(GatewayCase):
    environ = {}

    async def test_target_without_its_key_is_off(self):
        self.assertEqual((await self.chat("cloud/large")).status, 503)
        listed = [m["id"] for m in (await (await self.client.get("/v1/models")).json())["data"]]
        self.assertNotIn("cloud/large", listed)
        self.upstream.replies["small"] = json_reply({"error": {"message": "boom"}}, status=500)
        self.assertEqual((await self.chat("auto")).status, 500)   # the route has only the local model left
        self.assertEqual([path for path, _, _ in self.upstream.seen], ["/v1/chat/completions"])


class Routes(GatewayCase):
    def decided(self, tier, reason):
        return self.value("aigw_route_decisions_total", route="auto", tier=tier, reason=reason)

    async def test_first_model_takes_it(self):
        response = await self.chat("auto")
        self.assertEqual(response.headers["X-AIGW-Model"], "small")
        self.assertEqual(self.decided("efficient", "first"), 1)

    async def test_long_request_skips_the_small_model(self):
        response = await self.chat("auto", messages=[{"role": "user", "content": "x" * 3000}])
        self.assertEqual(response.headers["X-AIGW-Model"], "cloud/large")
        self.assertEqual([path for path, _, _ in self.upstream.seen], ["/cloud/v1/chat/completions"])
        self.assertEqual(self.decided("capable", "too_long"), 1)

    async def test_too_long_for_every_model(self):
        self.gw.models["cloud/large"]["max_prompt_chars"] = 2500
        response = await self.chat("auto", messages=[{"role": "user", "content": "x" * 3000}])
        self.assertEqual(response.status, 413)

    async def test_unhealthy_target_is_tried_last(self):
        self.upstream.healthy = False
        await self.gw.probe_all()
        self.assertEqual(self.value("aigw_target_up", target="gpu"), 0)
        self.assertEqual((await (await self.client.get("/health")).json())["targets"], {"gpu": False, "cloud": True})
        response = await self.chat("auto")
        self.assertEqual(response.headers["X-AIGW-Model"], "cloud/large")
        self.assertEqual(self.decided("capable", "down"), 1)
        # asked for by name, it is still tried: the health check may be stale
        self.assertEqual((await self.chat("small")).status, 200)

    async def test_failover_when_the_first_model_fails(self):
        self.upstream.replies["small"] = json_reply({"error": {"message": "proxy error: Failed to read connection"}}, status=500)
        response = await self.chat("auto")
        self.assertEqual((response.status, response.headers["X-AIGW-Model"]), (200, "cloud/large"))
        self.assertEqual(self.decided("capable", "failover"), 1)
        self.assertEqual(self.decided("efficient", "first"), 0)   # one decision per request: the one that answered
        self.assertEqual(self.logged("failover")[0]["to"], "cloud/large")
        self.assertEqual(self.value("aigw_requests_total", endpoint="chat/completions", model="cloud/large", target="cloud", code="200"), 1)

    async def test_failover_when_the_context_is_too_small(self):
        self.upstream.replies["small"] = json_reply({"error": {
            "code": 400, "message": "request (9000 tokens) exceeds the available context size (8192 tokens)",
            "type": "exceed_context_size_error"}}, status=400)
        self.assertEqual((await self.chat("auto")).headers["X-AIGW-Model"], "cloud/large")

    async def test_callers_mistake_is_not_retried(self):
        self.upstream.replies["small"] = json_reply({"error": {"code": 400, "type": "invalid_request_error"}}, status=400)
        self.assertEqual((await self.chat("auto")).status, 400)
        self.assertEqual(len(self.upstream.seen), 1)

    async def test_last_model_failing_is_the_answer(self):
        self.upstream.replies["*"] = json_reply({"error": {"message": "boom"}}, status=500)
        response = await self.chat("auto")
        self.assertEqual((response.status, len(self.upstream.seen)), (500, 2))
        self.assertEqual(self.value("aigw_requests_total", endpoint="chat/completions", model="cloud/large", target="cloud", code="500"), 1)


class Unreachable(GatewayCase):
    def config(self, url):
        config = super().config(url)
        config["targets"]["gpu"]["base_url"] = "http://127.0.0.1:9/v1"   # nothing listens on the discard port
        return config

    async def test_route_moves_on(self):
        response = await self.chat("auto")
        self.assertEqual((response.status, response.headers["X-AIGW-Model"]), (200, "cloud/large"))

    async def test_named_model_is_a_502(self):
        response = await self.chat("small")
        self.assertEqual(response.status, 502)
        self.assertEqual((await response.json())["error"]["type"], "upstream_error")
        self.assertEqual(self.value("aigw_finish_reason_total", model="small", target="gpu", reason="error"), 1)


class Queueing(GatewayCase):
    """One model in VRAM at a time: llama-server kills the running model to load another."""

    def slow(self):
        self.release, self.order = asyncio.Event(), []

        async def reply(_request, body):
            self.order.append(("start", body["model"]))
            if body["model"] == "small":
                await self.release.wait()
            self.order.append(("end", body["model"]))
            return web.json_response(CHAT)
        self.upstream.replies["*"] = reply

    async def test_other_model_waits_for_the_running_one(self):
        self.slow()
        first = asyncio.create_task(self.chat("small"))
        await self.settled(lambda: self.order == [("start", "small")])
        second = asyncio.create_task(self.chat("big"))
        await self.settled(lambda: self.value("aigw_target_waiting", target="gpu") == 1)
        self.assertEqual(self.value("aigw_target_running", target="gpu"), 1)
        self.assertEqual(self.order, [("start", "small")])   # big has not reached the server
        self.release.set()
        self.assertEqual([(await r).status for r in (first, second)], [200, 200])
        self.assertEqual(self.order, [("start", "small"), ("end", "small"), ("start", "big-q4"), ("end", "big-q4")])
        self.assertEqual(self.value("aigw_target_waiting", target="gpu"), 0)
        self.assertGreater(self.value("aigw_queue_seconds_sum", model="big", target="gpu"), 0)

    async def test_same_model_shares_the_slots(self):
        self.slow()
        calls = [asyncio.create_task(self.chat("small")) for _ in range(3)]
        await self.settled(lambda: self.value("aigw_target_waiting", target="gpu") == 1)
        self.assertEqual(self.value("aigw_target_running", target="gpu"), 2)   # max_concurrent
        self.release.set()
        self.assertEqual([(await r).status for r in calls], [200, 200, 200])

    async def test_cloud_target_is_not_queued(self):
        self.slow()
        first = asyncio.create_task(self.chat("small"))
        await self.settled(lambda: self.order == [("start", "small")])
        self.assertEqual((await self.chat("cloud/large")).status, 200)
        self.release.set()
        await first


class GateRules(unittest.IsolatedAsyncioTestCase):
    async def entered(self, gate, model):
        task = asyncio.create_task(gate.enter(model))
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        return task

    async def test_no_overtaking_past_a_waiting_model(self):
        gate = Gate(slots=4, exclusive=True)
        a1 = await self.entered(gate, "a")
        b = await self.entered(gate, "b")
        a2 = await self.entered(gate, "a")   # would fit beside a1, but b was first
        self.assertEqual((a1.done(), b.done(), a2.done()), (True, False, False))
        gate.leave()
        await asyncio.sleep(0)
        self.assertEqual((b.done(), a2.done(), gate.model), (True, False, "b"))
        gate.leave()
        await asyncio.sleep(0)
        self.assertTrue(a2.done())

    async def test_waiter_that_gives_up_frees_the_queue(self):
        gate = Gate(slots=1)
        await self.entered(gate, "a")
        quitter = await self.entered(gate, "a")
        patient = await self.entered(gate, "a")
        quitter.cancel()
        await asyncio.sleep(0)
        self.assertEqual(gate.running, 1)
        gate.leave()
        await asyncio.sleep(0)
        self.assertTrue(patient.done())
        self.assertEqual((gate.running, len(gate.waiters)), (1, 0))

    async def test_no_limits_means_no_waiting(self):
        gate = Gate()
        tasks = [await self.entered(gate, m) for m in "abc"]
        self.assertTrue(all(t.done() for t in tasks))


class Config(unittest.TestCase):
    def load(self, config):
        with tempfile.NamedTemporaryFile("w", suffix=".json") as fh:
            json.dump(config, fh)
            fh.flush()
            return gateway.load_config(fh.name)

    def test_model_must_name_a_target(self):
        with self.assertRaisesRegex(ValueError, "unknown target"):
            self.load({"targets": {}, "models": {"m": {"target": "gone"}}})

    def test_route_must_name_models(self):
        targets = {"t": {"base_url": "http://x/v1"}}
        with self.assertRaisesRegex(ValueError, "known models"):
            self.load({"targets": targets, "models": {"m": {"target": "t"}}, "routes": {"auto": {"models": ["m", "typo"]}}})
        with self.assertRaisesRegex(ValueError, "both a model and a route"):
            self.load({"targets": targets, "models": {"m": {"target": "t"}}, "routes": {"m": {"models": ["m"]}}})


if __name__ == "__main__":
    unittest.main()

# AI gateway — one endpoint for the models, with metrics

One OpenAI-style endpoint on heimdall in front of the chat models on mimir and
OpenRouter. It measures every request, Prometheus scrapes it, and Grafana shows it on
the **AI gateway** dashboard (`https://grafana.oryxserver.org/d/ai-gateway`).

```
client ──▶ http://10.0.20.17:4000/v1   ai-gateway (heimdall)
                │                          ├─ /metrics ◀── Prometheus (heimdall)
                │                          └─ request log ──▶ Loki (heimdall)
                ├─▶ http://10.0.20.18:8080/v1   llama-server on mimir (RTX 5070 Ti)
                └─▶ https://openrouter.ai/api/v1   MiniMax

mimir ── :9835 nvidia-smi exporter, :9100 node exporter ◀── Prometheus (heimdall)
```

| piece | where |
|---|---|
| gateway code and tests | `hosts/heimdall/ai-gateway/` |
| gateway service, targets, models, routes | `hosts/heimdall/modules/system/ai-gateway.nix` |
| dashboard | `hosts/heimdall/modules/system/ai-gateway-dashboard.json` |
| scrape jobs (`ai-gateway`, `nvidia-gpu`, mimir in `node`) | `hosts/heimdall/modules/system/prometheus.nix` |
| host exporter | `hosts/mimir/modules/system/exporters.nix` |
| GPU exporter (import commented out until the card is in) | `hosts/mimir/modules/system/gpu-exporter.nix` |
| chat model server (import commented out until the card is in) | `hosts/mimir/modules/system/llm.nix` |

muninn's MiniMax calls go through the gateway: huginn's skills (graphify's labeling
included) and the bridge's MiniMax floor. Jev, Codex, Claude and hermes do not.

## Using it

```sh
curl http://10.0.20.17:4000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "auto", "stream": true,
  "messages": [{"role": "user", "content": "hello"}]}'
```

`/v1/chat/completions`, `/v1/completions`, `/v1/embeddings` and `/v1/models` are served.
Every answer carries `X-Request-Id`, `X-AIGW-Model` and `X-AIGW-Target`.

A caller can name itself by using `http://10.0.20.17:4000/client/<name>/v1` as its base
URL. Its requests, tokens and cost are then counted under that name; without a name
they are counted as `other`. The names are the `clients` list in `ai-gateway.nix`
(`huginn`, `bridge`, `hermes`, `mjolnir`); any other name is a 404, so a typo shows.
The name is a label for the dashboard, not a login.

| model | served by | tier |
|---|---|---|
| `qwen3.5-9b` | mimir | efficient |
| `qwen3.8-27b` | mimir | capable |
| `minimax/minimax-m3` | OpenRouter | capable |
| `auto` | a route: `qwen3.5-9b` first, then `minimax/minimax-m3` | |

A **route** tries its models in order. A model is skipped when the request is longer
than its `max_prompt_chars`; a model whose target failed its health check is tried
last. If a model fails before anything was sent back (connection refused, a 5xx, or
llama.cpp's "exceeds the available context size"), the next one gets the request.

Until `llm.nix` is deployed on mimir, `auto` from heimdall goes to MiniMax, and from
anywhere else it fails (see the next section).

## Who may use what

- Models on mimir are open to the LAN, like mimir's other ports.
- A target with an API key (OpenRouter) costs money. It answers only callers on heimdall
  itself, or callers that send a client key as `Authorization: Bearer <key>`. Client
  keys are optional: put `AIGW_CLIENT_KEYS=key1,key2` in `/var/lib/secrets/ai-gateway.env`
  on heimdall and restart `ai-gateway`.
- A request that arrives through a reverse proxy (it has `X-Forwarded-For`) is never
  treated as local.
- The OpenRouter key is read from `/var/lib/secrets/graphify-openrouter.env`
  (`OPENAI_API_KEY`). No key is in this repo. Without that file the OpenRouter target is
  off and its models are not listed.
- The port is open on `ens18` only.

## One model in VRAM at a time

llama-server runs in router mode with `--models-max 1`: it loads a model when it is
first asked for and unloads the other one. Measured with llama.cpp b9190 on 2026-10-06:

- A request for the model that is **not** loaded makes llama-server stop the loaded one,
  wait 10 s, then kill it. A request still running on it fails with HTTP 500.
- `GET /metrics?model=<name>` on llama-server loads that model. A Prometheus scrape of
  it would swap models every 15 s.

So the gateway marks the mimir target `exclusive`: a request for the other model waits
in the gateway until the running ones are done (dashboard: **Waiting Requests**), and
Prometheus scrapes the gateway, never llama-server.

**Do not call `10.0.20.18:8080` directly**, and do not open llama-server's web UI while
agents are using the gateway: both bypass the queue and the dashboard.

A caller that hangs up frees its slot at once. llama-server stops a streamed generation
when that happens; one that is not streamed runs on until it ends or its model is
swapped out.

## Deploy

heimdall and mimir, in either order. Before the card is in, mimir only gets the host
exporter; the dashboard's GPU row is empty and the `mimir:8080` and `mimir:9835` health
rows are red.

**Do not enable the GPU exporter before the card is in.** It runs `nvidia-smi` on every
scrape. With the GTX 1070 and the open kernel module, each run made the kernel load the
driver, fail and unload it, five times every 15 s, and the card's fans ramped up and
down until the service was stopped (2026-10-06).

When the RTX 5070 Ti is installed:

1. In `hosts/mimir/default.nix`, uncomment `./modules/system/gpu-exporter.nix` and
   `./modules/system/llm.nix`. The first rebuild compiles llama.cpp with CUDA.
2. Download the two models on mimir (20 GiB; the files are world-readable, which the
   service needs):

   ```sh
   cd /var/lib/llama-chat/models
   sudo curl -L -C - -O https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q6_K.gguf
   sudo curl -L -C - -O https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-IQ4_XS.gguf
   ```

3. `curl http://10.0.20.17:4000/health` on heimdall should show `"mimir-chat": true`.
   The first request to a model loads it, so its time to first token is long.

Neither model is measured on the card yet. If the 27B does not fit, the fallback from
the vault note is `Qwen3.8-27B-UD-Q3_K_XL.gguf`; change the file name in `llm.nix`.

### Adding or renaming a model

A local model is a section in the preset in `llm.nix` and an entry in `models` in
`ai-gateway.nix`; the two names must be the same. `max_concurrent` on the target should
equal the largest `parallel` in the preset. `ctx-size` is shared by a model's slots.

### muninn's MiniMax calls

huginn and the bridge read `OPENAI_BASE_URL` from `/var/lib/secrets/graphify-openrouter.env`.
That file is not changed. Each unit reads a second, non-secret file after it, which
sets the gateway as the base URL:

| who | where | base URL |
|---|---|---|
| huginn's skills | `viaGateway` in `huginn.nix` | `http://127.0.0.1:4000/client/huginn/v1` |
| the bridge | `EnvironmentFile` of `muninn-bridge` in `brain.nix` | `http://127.0.0.1:4000/client/bridge/v1` |

To go back to calling OpenRouter directly, delete that entry from the unit's
`EnvironmentFile` list and rebuild heimdall. Jev has its own `JEV_URL`, and `ask`'s SSH
fallback loads only the secrets file; both still call OpenRouter directly.

If the gateway is down, these calls fail until it is back (it restarts itself after
5 s). `OPENAI_MODEL` is still `minimax/minimax-m3`; making it `auto` would try the local
model first once it runs.

## The dashboard

The first two rows copy the reference dashboard panel for panel. Below them: token
totals, **Cost and Callers**, mimir's GPU, and **Request Lookup**.

- **Spend** is what OpenRouter charged, which it reports with every answer. Local
  models add nothing to it.
- **Tokens / Requests / Spend by Caller** split by the name in the caller's URL.

- **Efficient / Capable Routed Decisions** count requests by the tier of the model that
  answered, whether a route picked it or the caller named it.
- **Running / Waiting Requests** are the gateway's own counts per target.
- **Inference Stage Breakdown** uses llama.cpp's own prefill and decode timings; for
  OpenRouter it uses what was seen on the wire.
- **Request ID**: paste the `X-Request-Id` of a response to see that request's record
  (model, tokens, timings). Clear the box to list every request. The same lines are in
  `journalctl -u ai-gateway`. Prompts and answers are never logged.
- Tokens are counted when a request ends, so throughput arrives in steps.

## Metrics

All at `http://10.0.20.17:4000/metrics`, labelled `model` and `target` unless noted.
The request, token and cost counters also carry `client`.

| metric | what |
|---|---|
| `aigw_requests_total{endpoint,code}` | requests; `code` is the HTTP status, `client_closed` or `stream_error` |
| `aigw_cost_usd_total` | US dollars the upstream charged (OpenRouter's `usage.cost`) |
| `aigw_request_duration_seconds` | arrival to last byte (histogram) |
| `aigw_time_to_first_token_seconds` | streamed requests, queueing included (histogram) |
| `aigw_time_per_output_token_seconds` | mean gap between output tokens (histogram) |
| `aigw_prompt_tokens_total`, `aigw_cached_prompt_tokens_total`, `aigw_completion_tokens_total` | token counters |
| `aigw_request_prompt_tokens`, `aigw_request_completion_tokens` | tokens per request (histograms) |
| `aigw_queue_seconds`, `aigw_prefill_seconds`, `aigw_decode_seconds` | time per stage (sum and count) |
| `aigw_finish_reason_total{reason}` | stop, length, tool_calls, abort, error |
| `aigw_route_decisions_total{route,tier,reason}` | reason: requested, first, too_long, down, failover |
| `aigw_inflight_requests` | requests inside the gateway |
| `aigw_target_running{target}`, `aigw_target_waiting{target}` | per target |
| `aigw_target_up{target}` | the gateway's health check, every 15 s |

GPU numbers are `nvidia_smi_*` from mimir, labelled `host="mimir"`.

## Tests

```sh
nix shell --impure --expr 'with (builtins.getFlake (toString ./.)).nixosConfigurations.heimdall.pkgs; python3.withPackages (ps: [ ps.aiohttp ps.prometheus-client ])' \
  --command python3 -m unittest discover -s hosts/heimdall/ai-gateway -p 'test_*.py'
```

The model servers are a local stand-in; nothing leaves the machine.

## History

- 2026-10-06: built. Verified on mjolnir against a real llama-server (CPU build, small
  test models), a local Prometheus, Grafana and Loki. Deployed to heimdall and mimir
  the same day; two real MiniMax calls through it worked. Not yet run against the
  RTX 5070 Ti.
- 2026-10-06: cost and per-caller counting added, and muninn's MiniMax calls pointed at
  the gateway. The GPU exporter was taken out of mimir's imports after it made the
  GTX 1070's fans cycle.

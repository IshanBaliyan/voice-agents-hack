# Cactus Model Server + Relay

Self-contained Python backend for the auditory-navigation iOS app. Two
FastAPI processes:

| Process      | File         | Port | Role                                             |
|--------------|--------------|------|--------------------------------------------------|
| Model server | `server.py`  | 8001 | Loads Gemma 4 via the Cactus FFI, runs inference |
| Relay        | `relay.py`   | 8000 | Accepts iOS WebSocket clients, proxies to model  |

The relay is what the iPhone connects to (`ws://<host>:8000/ws`). It opens
an internal WebSocket to the model server for each client session.

The `vendor/` directory ships the Cactus Python bindings and the macOS
`libcactus.dylib`, so no external Cactus checkout is needed.

---

## Prerequisites

- macOS (Apple Silicon) — the bundled `libcactus.dylib` is arm64 only.
- [`uv`](https://docs.astral.sh/uv/) for Python dep management.
- `make`, `unzip`, and enough disk for the Gemma 4 weights (~4 GB extracted).

---

## One-time setup

From this directory (`cactus_server/`):

```bash
make sync             # install runtime deps into .venv via uv
make download-model   # fetch Cactus-Compute/gemma-4-E4B-it + extract weights
```

`make download-model` downloads the HF repo into `./models/.hf_cache/`,
extracts the Apple Silicon int4 bundle into `./models/gemma-4-E4B-it/`,
and copies `config.json` alongside the weights. It skips if the target
directory is already populated.

By default the Makefile exports
`GEMMA4_MODEL_PATH=<cactus_server>/models/gemma-4-E4B-it` so no further
config is needed. Override by copying `.env.example` → `.env` and editing
the value.

---

## Running

In **two** terminals (both from `cactus_server/`):

```bash
# Terminal 1 — model server (loads Gemma 4 on startup; takes ~30–60 s)
make model

# Terminal 2 — relay (accepts iOS clients)
make relay
```

Verify:

```bash
curl http://localhost:8001/health   # {"status":"ready","model_loaded":true}
curl http://localhost:8000/health   # {"status":"ok","active_clients":0}
```

Stop with `make stop` (or `make stop-model` / `make stop-relay`).

The iOS app should connect to `ws://<your-mac-ip>:8000/ws?audio_format=pcm16_base64`.

---

## Environment variables

| Var                        | Default                                          | Purpose                                   |
|----------------------------|--------------------------------------------------|-------------------------------------------|
| `GEMMA4_MODEL_PATH`        | `<cactus_server>/models/gemma-4-E4B-it`          | Absolute path to extracted Gemma 4 weights |
| `CACTUS_PYTHON_PATH`       | `<cactus_server>/vendor/python`                  | Cactus Python bindings dir                |
| `CACTUS_MODEL_SERVER_URL`  | `ws://localhost:8001/ws/cactus`                  | Relay → model server WebSocket URL        |

Put overrides in `cactus_server/.env` (auto-loaded by both the Makefile
and `server.py`).

---

## Troubleshooting

**`/health` returns `model_loaded: false`** — look at the model server's
stdout. Either `GEMMA4_MODEL_PATH` is unset, points at the `.zip` instead
of the extracted directory, or `cactus_init` failed (dylib arch mismatch,
corrupt weights, etc.).

**Relay returns 403 on WebSocket connect** — the path doesn't match. The
iOS app must hit `/ws` on port 8000, not `/ws/relay` or anything else.

**Large TTS replies disconnect mid-stream** — the relay's inbound WS
client already uses `max_size=None`. If you're sending >16 MiB audio
payloads to the iOS app, also raise `--ws-max-size` on the relay.

**Rebuilding `libcactus.dylib`** — if you rebuild upstream, copy the new
`libcactus.dylib` into `vendor/cactus/build/`.

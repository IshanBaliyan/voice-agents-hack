# Cactus Server + Relay
#
# The model server (server.py) and the client-facing relay (relay.py) both
# live in this package and are imported as `cactus_server.<module>`. All
# uvicorn commands therefore run from the parent directory.
#
# This Makefile uses `uv` for environment + dependency management. Install it
# from https://docs.astral.sh/uv/ if you don't have it.

MODEL_PORT    ?= 8001
RELAY_PORT    ?= 8000
HOST          ?= 0.0.0.0
PARENT_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
UV            ?= uv
UV_RUN        := $(UV) run --project "$(CURDIR)"

# Auto-load cactus_server/.env if present so GEMMA4_MODEL_PATH (and anything
# else) is exported to the subprocesses spawned by `make model` / `make relay`.
-include .env
export

# Default model dir populated by `make download-model`. If .env sets
# GEMMA4_MODEL_PATH, that wins (the ?= below is a no-op in that case).
export GEMMA4_MODEL_PATH ?= $(CURDIR)/models/gemma-4-E4B-it

# Re-export settings that the model server consults at startup.
# CACTUS_PYTHON_PATH defaults to cactus_server/vendor/python (shipped in-tree);
# set it explicitly only if you want to point at a different cactus checkout.
export CACTUS_MODEL_SERVER_URL ?= ws://localhost:$(MODEL_PORT)/ws/cactus

.PHONY: help check-uv sync sync-dev download-model build-index model relay stop-model stop-relay stop clean

help:
	@echo "Targets:"
	@echo "  sync            Install runtime dependencies with uv"
	@echo "  sync-dev        Install runtime + dev dependencies"
	@echo "  download-model  Download Gemma 4 E4B weights into ./models/"
	@echo "  build-index     Parse ./docs/*.pdf with docling and build the Qdrant RAG index"
	@echo "  model           Run the Cactus model server (port $(MODEL_PORT))"
	@echo "  relay           Run the client-facing relay (port $(RELAY_PORT))"
	@echo "  stop-model      Kill whatever is listening on :$(MODEL_PORT)"
	@echo "  stop-relay      Kill whatever is listening on :$(RELAY_PORT)"
	@echo "  stop            Kill both"
	@echo "  clean           Remove __pycache__ directories"
	@echo ""
	@echo "GEMMA4_MODEL_PATH = $(GEMMA4_MODEL_PATH)"
	@echo "(Override in cactus_server/.env if you want a different path.)"

check-uv:
	@command -v $(UV) >/dev/null 2>&1 || { \
		echo "uv is not installed. See https://docs.astral.sh/uv/"; exit 1; }

sync: check-uv
	$(UV) sync --project "$(CURDIR)"

sync-dev: check-uv
	$(UV) sync --project "$(CURDIR)" --group dev

download-model: check-uv
	$(UV) run --project "$(CURDIR)" --with huggingface_hub \
		python "$(CURDIR)/scripts/download_model.py"

# One-shot offline ingestion: docling-parse every PDF in ./docs/ and write
# an embedded Qdrant database to ./qdrant_data/. Safe to re-run — unchanged
# PDFs are skipped via a sidecar manifest. Use `make build-index ARGS=--force`
# to re-ingest everything from scratch.
build-index: check-uv
	cd "$(PARENT_DIR)" && $(UV_RUN) python -m cactus_server.scripts.build_rag_index $(ARGS)

model: check-uv
	cd "$(PARENT_DIR)" && $(UV_RUN) uvicorn cactus_server.server:app \
		--host $(HOST) --port $(MODEL_PORT) --reload

relay: check-uv
	cd "$(PARENT_DIR)" && $(UV_RUN) uvicorn cactus_server.relay:app \
		--host $(HOST) --port $(RELAY_PORT) --reload

stop-model:
	@-lsof -ti tcp:$(MODEL_PORT) | xargs kill 2>/dev/null || true
	@echo "Stopped model server on :$(MODEL_PORT)."

stop-relay:
	@-lsof -ti tcp:$(RELAY_PORT) | xargs kill 2>/dev/null || true
	@echo "Stopped relay on :$(RELAY_PORT)."

stop: stop-model stop-relay

clean:
	find . -type d -name __pycache__ -prune -exec rm -rf {} +

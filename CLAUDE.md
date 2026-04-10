# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure-as-code for NVIDIA DGX Spark serving LLMs and STT. Two deployment modes:

1. **2-Node Cluster**: Gemma 4 26B-A4B MoE (FP8) across 2 nodes with nginx load balancer
2. **Single Node**: Gemma-4-31B-IT-NVFP4 (NVFP4/modelopt, multimodal) on 1 node with nginx reverse proxy

Target platform is Ubuntu 24.04 aarch64 with CUDA 13.0 and 128GB unified LPDDR5X per node.

## Architecture

```
nginx (Node A:80) — least_conn load balancer
├── /v1/*    → llm_backend  (Node A:8000, Node B:8000) — vLLM OpenAI-compatible API
├── /stt/*   → stt_backend  (Node A:9000, Node B:9000) — faster-whisper (strips /stt prefix)
├── /health  → proxied to llm_backend
└── /status  → static JSON
```

- **Node A** runs 3 containers: `gemma4-vllm`, `gemma4-whisper`, `gemma4-nginx`
- **Node B** runs 2 containers: `gemma4-vllm`, `gemma4-whisper`
- Docker Compose uses a split-file pattern: `docker-compose.node.yml` (base, both nodes) + `docker-compose.lb.yml` (nginx override, Node A only)
- vLLM and whisper share the single GPU device on each node. vLLM claims 70% of GPU memory (`gpu_memory_utilization=0.70`); whisper uses ~3-4GB from the remainder.

## vLLM Serving Configuration

vLLM runs with these notable flags (defined in `docker-compose.node.yml` command + `config/vllm-env.sh`):
- **FP8 online quantization** (`--quantization fp8 --kv-cache-dtype fp8`) for throughput
- **Tool calling** enabled (`--enable-auto-tool-choice --tool-call-parser gemma4 --reasoning-parser gemma4`)
- **256K context** (`--max-model-len 262144`) with prefix caching and chunked prefill
- **Concurrency**: `--max-num-seqs 4 --max-num-batched-tokens 8192`

Override extra args via `VLLM_EXTRA_ARGS` env var in `config/vllm-env.sh`.

## Single-Node vLLM Configuration

Single-node mode serves `nvidia/Gemma-4-31B-IT-NVFP4` (defined in `docker-compose.single.yml`):
- **NVFP4 quantization** (`--quantization modelopt`) — pre-quantized via NVIDIA Model Optimizer
- **Multimodal** — text + image + video input natively supported
- **Tool calling** enabled (same `gemma4` parser)
- **256K context** (`--max-model-len 262144`)
- **85% GPU memory** (`--gpu-memory-utilization 0.85`) — NVFP4 weights are ~16-20GB, more room for KV cache
- **nginx**: Uses Docker service names (`vllm:8000`, `whisper:9000`) instead of host IPs
- Container names use `gemma4-31b-*` prefix to avoid collision with 2-node `gemma4-*` containers

## Key Commands

```bash
# ── 2-Node Cluster ──
./setup.sh                          # Full cluster deploy (both nodes, parallel)
./verify.sh                         # Verify cluster health

# Per-node setup (used internally by setup.sh)
bash scripts/setup-node.sh --role nodeA --skip-lb
bash scripts/setup-node.sh --role nodeB

# ── Single Node (Gemma-4-31B-IT-NVFP4) ──
./setup-single.sh                   # Deploy on single DGX Spark
./verify-remote.sh <DGX_IP>         # Verify from remote Linux/macOS
verify-remote.bat <DGX_IP>          # Verify from remote Windows

# ── Common ──
bash scripts/health-check.sh localhost
bash tests/generate-test-audio.sh

# View logs (2-node)
docker compose -f docker/docker-compose.node.yml -f docker/docker-compose.lb.yml logs -f

# View logs (single-node)
cd docker && docker compose -f docker-compose.single.yml logs -f

# Stop (2-node, Node A)
cd docker && docker compose -f docker-compose.node.yml -f docker-compose.lb.yml down

# Stop (single-node)
cd docker && docker compose -f docker-compose.single.yml down
```

## Configuration Flow

1. `.env` (copied from `.env.example`) holds node IPs, SSH user, and optional HF token
2. `config/vllm-env.sh` and `config/whisper-env.sh` define model/image/port defaults with `${VAR:-default}` pattern
3. `setup.sh` sources `.env` then both config scripts, validates, rsyncs repo to Node B, runs parallel node setup, generates nginx config, starts LB
4. `.env.token` is generated at runtime (contains `HUGGING_FACE_HUB_TOKEN=...`) and used as Docker `env_file` — never committed

## Deployment Details

- **Repo sync**: `setup.sh` uses `rsync --delete` to sync to Node B at `/home/$SSH_USER/dgx-spark-ai-cluster/`, excluding `.omc`, `.git`, `__pycache__`, `.env`, `.env.token`, and `config/nginx.conf`. The `.env` is copied separately with `chmod 600`.
- **Parallel setup**: Node B runs via SSH in background; Node A runs in foreground. Both wait up to 3600s for health checks.
- **Setup logs**: Written to `/tmp/dgx-spark-setup/nodeA.log` and `/tmp/dgx-spark-setup/nodeB.log`.

## Important Constraints

- **Platform**: All containers target aarch64 (ARM). The vLLM image is `vllm/vllm-openai:gemma4-cu130`. The whisper Dockerfile builds from `nvidia/cuda:12.8.0-cudnn-runtime-ubuntu24.04`.
- **No HF token required**: Gemma 4 is Apache 2.0. `HF_TOKEN` is optional and only needed for gated models.
- **Idempotent deploys**: `setup.sh` uses `docker compose up -d --no-recreate` so re-running doesn't kill healthy containers.
- **vLLM health start_period is 3600s** (1 hour) to allow time for first-run model download (~49GB).
- **nginx config is generated, not committed**: `config/nginx.conf` is in `.gitignore`; only `config/nginx.conf.template` is tracked.
- **Secrets**: `.env` and `.env.token` are gitignored. Never commit these files.

## Whisper Server (docker/whisper/server.py)

Custom FastAPI server wrapping `faster-whisper` (`large-v3-turbo` model by default). OpenAI-compatible endpoint at `POST /v1/audio/transcriptions`. Accepts multipart file upload (max 25MB). Allowed audio extensions: wav, mp3, flac, ogg, m4a, webm, mp4. Thread-safe model loading with GPU-first, CPU fallback.

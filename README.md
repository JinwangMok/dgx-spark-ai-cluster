# DGX Spark Gemma 4 Cluster

2x DGX Spark 클러스터에서 **Gemma 4 26B-A4B MoE** LLM과 **faster-whisper** STT를 서빙하는 단일 명령어 배포 스크립트.

```
                    ┌─────────────────────────────┐
                    │     nginx (Node A:80)        │
                    │   LLM LB  ←→  STT LB        │
                    └──────┬──────────┬────────────┘
                           │          │
              ┌────────────┴──┐  ┌────┴────────────┐
              │   Node A      │  │   Node B         │
              │ vLLM :8000    │  │ vLLM :8000       │
              │ Whisper :9000 │  │ Whisper :9000    │
              └───────────────┘  └───────────────────┘
                    ◄── 100G link ──►
```

## Prerequisites

- **Hardware**: 2x NVIDIA DGX Spark (128GB unified memory each), 100G inter-node link
- **OS**: Ubuntu 24.04 aarch64 with CUDA 13.0
- **Software**:
  - Docker with NVIDIA Container Toolkit (`nvidia-container-toolkit`)
  - Docker Compose plugin (`docker compose`)
  - SSH passwordless authentication between nodes
  - `rsync` (for repo sync to Node B)
  - `curl`, `envsubst` (usually pre-installed)
- **Accounts**: HuggingFace token with [Gemma 4 model access](https://huggingface.co/google/gemma-4-26B-A4B-it)
- **Disk**: Minimum 80GB free on `/data` per node

## Quick Start

```bash
# 1. Clone the repository on Node A
git clone https://github.com/<your-org>/dgx-spark-ai-cluster.git
cd dgx-spark-ai-cluster

# 2. Configure environment
cp .env.example .env
nano .env   # Fill in NODE_A_IP, NODE_B_IP, HF_TOKEN

# 3. Generate test audio (optional, for STT verification)
bash tests/generate-test-audio.sh

# 4. Run setup (deploys to BOTH nodes)
chmod +x setup.sh verify.sh scripts/*.sh
./setup.sh
```

First run takes **15-60 minutes** (model download: ~49GB per node, parallel).

## Configuration

### Required Variables (`.env`)

| Variable | Description | Example |
|----------|-------------|---------|
| `NODE_A_IP` | IP address of Node A (this node) | `192.168.1.10` |
| `NODE_B_IP` | IP address of Node B (remote) | `192.168.1.11` |
| `HF_TOKEN` | HuggingFace access token | `hf_abc123...` |
| `SSH_USER` | SSH username for Node B | `ubuntu` (default: current user) |

### Optional Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `MODEL_ID` | `google/gemma-4-26B-A4B-it` | HuggingFace model ID |
| `VLLM_GPU_MEMORY_UTILIZATION` | `0.80` | Fraction of GPU memory for vLLM (0.0-1.0) |
| `WHISPER_MODEL` | `large-v3` | Whisper model size |
| `MODEL_CACHE_DIR` | `/data/models` | Host path for LLM model cache |
| `WHISPER_CACHE_DIR` | `/data/models/whisper` | Host path for whisper model cache |
| `VLLM_PORT` | `8000` | vLLM container port |
| `WHISPER_PORT` | `9000` | Whisper container port |

### Memory Budget (per node, 128GB unified)

| Component | Memory | Notes |
|-----------|--------|-------|
| Gemma 4 26B-A4B MoE (BF16) | ~49GB | Model weights |
| vLLM KV cache + overhead | ~53GB | At `gpu_memory_utilization=0.80` |
| faster-whisper (large-v3) | ~3-4GB | CTranslate2 GPU |
| nginx + OS | ~5-10GB | Only on Node A |
| **Headroom** | **~12-21GB** | Safety margin |

## API Endpoints

All endpoints are accessed through the nginx load balancer on Node A (port 80).

### LLM — OpenAI-compatible API

```bash
# Chat completion
curl http://<NODE_A_IP>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "google/gemma-4-26B-A4B-it",
    "messages": [{"role": "user", "content": "Explain quantum computing in simple terms."}],
    "max_tokens": 256,
    "temperature": 0.7
  }'

# Streaming
curl http://<NODE_A_IP>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "google/gemma-4-26B-A4B-it",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'

# List models
curl http://<NODE_A_IP>/v1/models
```

### STT — OpenAI Whisper-compatible API

```bash
# Transcribe audio
curl http://<NODE_A_IP>/stt/v1/audio/transcriptions \
  -F file=@audio.wav \
  -F model=whisper-1

# Specify language
curl http://<NODE_A_IP>/stt/v1/audio/transcriptions \
  -F file=@audio.wav \
  -F model=whisper-1 \
  -F language=ko
```

**Supported audio formats**: WAV, MP3, FLAC, OGG, M4A (via ffmpeg)

### Health & Status

```bash
curl http://<NODE_A_IP>/health        # {"status":"ok"}
curl http://<NODE_A_IP>/status        # Cluster info
```

## Verification

```bash
./verify.sh
```

Checks:
1. Container status on both nodes (3 on Node A, 2 on Node B)
2. LLM API response (chat completion)
3. STT API response (audio transcription)
4. Load balancer distribution (requests spread across nodes)
5. Response time (LLM <30s, STT <10s)
6. GPU memory usage on both nodes

## Management

```bash
# View logs
docker compose -f docker/docker-compose.node.yml -f docker/docker-compose.lb.yml logs -f
docker compose -f docker/docker-compose.node.yml -f docker/docker-compose.lb.yml logs vllm
docker compose -f docker/docker-compose.node.yml -f docker/docker-compose.lb.yml logs whisper

# Stop all services on Node A
cd docker && docker compose -f docker-compose.node.yml -f docker-compose.lb.yml down

# Stop all services on Node B
ssh <SSH_USER>@<NODE_B_IP> "cd ~/dgx-spark-ai-cluster/docker && docker compose -f docker-compose.node.yml down"

# Restart (idempotent — safe to re-run)
./setup.sh

# Health check single node
./scripts/health-check.sh localhost
./scripts/health-check.sh <NODE_B_IP>
```

## Troubleshooting

### Model download fails

```
ERROR: Failed to download LLM model
```
- Verify HF token: `huggingface-cli whoami --token $HF_TOKEN`
- Accept Gemma 4 license on HuggingFace: https://huggingface.co/google/gemma-4-26B-A4B-it
- Check disk space: `df -h /data`

### GPU OOM (Out of Memory)

```
CUDA out of memory
```
- Lower `VLLM_GPU_MEMORY_UTILIZATION` in `.env` (try `0.70`)
- Check GPU usage: `nvidia-smi` on both nodes
- Ensure no other GPU processes are running

### SSH timeout to Node B

```
ERROR: Cannot SSH to user@node-b-ip
```
- Test manually: `ssh <SSH_USER>@<NODE_B_IP>`
- Set up passwordless SSH: `ssh-copy-id <SSH_USER>@<NODE_B_IP>`
- Check firewall: ports 22, 8000, 9000 must be open between nodes

### Container won't start

```
docker compose up fails
```
- Check NVIDIA runtime: `docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi`
- Check image exists: `docker images | grep vllm`
- Check logs: `docker logs gemma4-vllm`

### vLLM model loading is slow

vLLM takes 1-3 minutes to load the 49GB model. The health check has a 180s `start_period`.
- Monitor: `docker logs -f gemma4-vllm`
- If still loading after 5 minutes, check GPU memory and model integrity

### Partial failure (one node up, one down)

If Node B fails while Node A succeeds:
- Node A services remain running (no automatic rollback)
- Check Node B logs: `ssh <user>@<NODE_B_IP> "docker compose -f ~/dgx-spark-ai-cluster/docker/docker-compose.node.yml logs"`
- Fix the issue on Node B and re-run `./setup.sh` (idempotent)

## Alternative Deployment: Git Clone on Both Nodes

If you prefer independent Git checkouts instead of rsync:

```bash
# On Node A
git clone https://github.com/<your-org>/dgx-spark-ai-cluster.git
cd dgx-spark-ai-cluster
cp .env.example .env && nano .env
bash scripts/setup-node.sh --role nodeA

# On Node B (separately)
git clone https://github.com/<your-org>/dgx-spark-ai-cluster.git
cd dgx-spark-ai-cluster
cp .env.example .env && nano .env  # Same values
bash scripts/setup-node.sh --role nodeB

# On Node A: generate nginx config and start LB
envsubst '${NODE_A_IP} ${NODE_B_IP}' < config/nginx.conf.template > config/nginx.conf
cd docker && docker compose -f docker-compose.node.yml -f docker-compose.lb.yml up -d nginx
```

---

## Single-Node Setup

단일 DGX Spark 1대에서 LLM + **faster-whisper** STT를 서빙하는 독립 스크립트.

```
┌───────────────────────────────┐
│     nginx (:80)               │
│   /v1/* → vLLM   /stt/* → STT│
├───────────────────────────────┤
│   Single DGX Spark            │
│   vLLM :8000 (31B NVFP4)     │
│   Whisper :9000               │
└───────────────────────────────┘
```

### Model Options

| | Default (`setup-single.sh`) | 31B mode (`setup-single.sh --31b`) |
|---|---|---|
| Model | Gemma 4 26B-A4B MoE | Gemma-4-31B-IT-NVFP4 |
| Quantization | FP8 (online) | NVFP4 (modelopt) |
| GPU Memory | 70% for vLLM | 85% for vLLM |
| TPS | ~38 t/s | ~7 t/s |
| Multimodal | Text only | Text + Image + Video |

### Differences from 2-Node Cluster

| | 2-Node Cluster | Single Node |
|---|---|---|
| Nodes | 2x DGX Spark | 1x DGX Spark |
| nginx | Load balancer (2 upstreams) | Reverse proxy (1 upstream) |
| Setup script | `setup.sh` (SSH + rsync) | `setup-single.sh` (local only) |
| Default model | Same (Gemma 4 26B-A4B) | Same (Gemma 4 26B-A4B) |

### Quick Start (Single Node)

```bash
# 1. Clone on the DGX Spark
git clone https://github.com/<your-org>/dgx-spark-ai-cluster.git
cd dgx-spark-ai-cluster

# 2. (Optional) Configure .env for HF_TOKEN or cache dir overrides
cp .env.example .env
nano .env   # HF_TOKEN is optional for public models

# 3. Run setup (default: 26B model, same as cluster)
chmod +x setup-single.sh
./setup-single.sh

# Or use 31B multimodal model (slower, ~7 t/s)
./setup-single.sh --31b
```

First run takes **15-60 minutes** (model download: ~49GB for 26B, ~20GB for 31B).

### Model Details

**Default — Gemma 4 26B-A4B MoE (same as 2-node cluster):**
- **Model**: `google/gemma-4-26B-A4B-it` — MoE, 4B active parameters
- **Quantization**: FP8 online (`--quantization fp8 --kv-cache-dtype fp8`)
- **Context**: 256K tokens, Tool Calling enabled
- **TPS**: ~38 t/s

**`--31b` — Gemma-4-31B-IT-NVFP4:**
- **Model**: [`nvidia/Gemma-4-31B-IT-NVFP4`](https://huggingface.co/nvidia/Gemma-4-31B-IT-NVFP4) — 30.7B dense
- **Quantization**: `--quantization modelopt` (NVFP4)
- **Multimodal**: Text + Image + Video (up to 60s, 1fps)
- **TPS**: ~7 t/s

### API Endpoints (Single Node)

Same URL structure as the cluster, accessed via nginx on port 80. Use `/v1/models` to check the served model name:

```bash
# Check served model
curl http://<DGX_IP>/v1/models

# Text chat (model name from /v1/models)
curl http://<DGX_IP>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "google/gemma-4-26B-A4B-it",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 256
  }'

# STT transcription
curl http://<DGX_IP>/stt/v1/audio/transcriptions \
  -F file=@audio.wav -F model=whisper-1

# Health & status
curl http://<DGX_IP>/health
curl http://<DGX_IP>/status
```

### Remote Verification

검증 스크립트를 원격 머신 (Windows/Linux/macOS)에서 실행:

```bash
# Linux / macOS
./verify-remote.sh <DGX_SPARK_IP>

# Windows (cmd)
verify-remote.bat <DGX_SPARK_IP>
```

Tests: health check, text chat, multimodal (image), tool calling, STT transcription, response time.

### Single-Node Management

```bash
# View logs
cd docker && docker compose -f docker-compose.single.yml logs -f
docker compose -f docker-compose.single.yml logs vllm

# Stop all services
cd docker && docker compose -f docker-compose.single.yml down

# Restart (idempotent)
./setup-single.sh
```

> **Note**: The single-node setup and 2-node cluster cannot run simultaneously on the same machine (port conflict on 8000, 9000, 80).

### Single-Node Memory Budget (128GB unified)

**Default (26B, same as 2-node cluster):**

| Component | Memory | Notes |
|-----------|--------|-------|
| Gemma 4 26B-A4B MoE (FP8) | ~49GB | Model weights |
| vLLM KV cache + overhead | ~41GB | At `gpu_memory_utilization=0.70` |
| faster-whisper (large-v3-turbo) | ~3-4GB | CTranslate2 GPU |
| nginx + OS | ~5-10GB | |
| **Headroom** | **~16-30GB** | Safety margin |

**31B mode (`--31b`):**

| Component | Memory | Notes |
|-----------|--------|-------|
| Gemma-4-31B-IT-NVFP4 (NVFP4) | ~16-20GB | Pre-quantized weights |
| vLLM KV cache + overhead | ~89GB | At `gpu_memory_utilization=0.85` |
| faster-whisper (large-v3-turbo) | ~3-4GB | CTranslate2 GPU |
| nginx + OS | ~5-10GB | |
| **Headroom** | **~5-14GB** | Safety margin |

---

## Project Structure

```
dgx-spark-ai-cluster/
├── .env.example                    # Environment template (copy to .env)
├── setup.sh                        # 2-node cluster deploy
├── setup-single.sh                 # Single-node deploy (Gemma-4-31B-IT-NVFP4)
├── verify.sh                       # 2-node cluster validation
├── verify-remote.sh                # Remote verification (Linux/macOS)
├── verify-remote.bat               # Remote verification (Windows)
├── README.md
├── config/
│   ├── nginx.conf.template         # nginx LB config (2-node, envsubst template)
│   ├── nginx-single.conf           # nginx config (single-node, static)
│   ├── vllm-env.sh                 # vLLM configuration (2-node)
│   └── whisper-env.sh              # Whisper configuration
├── docker/
│   ├── docker-compose.node.yml     # 2-node: vLLM + whisper (both nodes)
│   ├── docker-compose.lb.yml       # 2-node: adds nginx (Node A only)
│   ├── docker-compose.single.yml   # Single-node: vLLM + whisper + nginx
│   └── whisper/
│       ├── Dockerfile              # Custom faster-whisper for aarch64
│       └── server.py               # Whisper API server
├── scripts/
│   ├── setup-node.sh               # Per-node setup (2-node cluster)
│   └── health-check.sh             # Health check utility
└── tests/
    └── generate-test-audio.sh      # Generate test WAV for STT verification
```

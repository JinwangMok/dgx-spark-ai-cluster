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

## Project Structure

```
dgx-spark-ai-cluster/
├── .env.example                    # Environment template (copy to .env)
├── setup.sh                        # Main entry point — deploys everything
├── verify.sh                       # Validation script
├── README.md
├── config/
│   ├── nginx.conf.template         # nginx LB config (envsubst template)
│   ├── vllm-env.sh                 # vLLM configuration
│   └── whisper-env.sh              # Whisper configuration
├── docker/
│   ├── docker-compose.node.yml     # Base: vLLM + whisper (both nodes)
│   ├── docker-compose.lb.yml       # Override: adds nginx (Node A only)
│   └── whisper/
│       ├── Dockerfile              # Custom faster-whisper for aarch64
│       └── server.py               # Whisper API server
├── scripts/
│   ├── setup-node.sh               # Per-node setup (prereqs, download, start)
│   └── health-check.sh             # Health check utility
└── tests/
    └── generate-test-audio.sh      # Generate test WAV for STT verification
```

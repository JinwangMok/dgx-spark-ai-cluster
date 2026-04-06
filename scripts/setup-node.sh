#!/usr/bin/env bash
# Per-node setup script for DGX Spark Gemma 4 Cluster
# Usage: ./scripts/setup-node.sh --role nodeA|nodeB [--skip-lb]
#
# This script:
# 1. Validates prerequisites (Docker, NVIDIA, disk space, HF token)
# 2. Downloads the LLM and whisper models
# 3. Pulls Docker images
# 4. Starts containers via Docker Compose
# 5. Waits for health checks to pass

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse arguments
ROLE=""
SKIP_LB=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --skip-lb) SKIP_LB=true; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$ROLE" ]] || [[ "$ROLE" != "nodeA" && "$ROLE" != "nodeB" ]]; then
    echo "ERROR: --role must be 'nodeA' or 'nodeB'"
    exit 1
fi

# Source configuration
source "$REPO_DIR/config/vllm-env.sh"
source "$REPO_DIR/config/whisper-env.sh"
if [[ -f "$REPO_DIR/.env" ]]; then
    set -a
    source "$REPO_DIR/.env"
    set +a
fi

echo "=========================================="
echo "DGX Spark Gemma 4 Cluster - Node Setup"
echo "Role: $ROLE"
echo "=========================================="

# ─── Pre-flight Checks ───

echo ""
echo "[1/6] Pre-flight checks..."

# Check Docker
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed"
    exit 1
fi
echo "  Docker: $(docker --version | head -1)"

# Check Docker Compose plugin
if ! docker compose version &> /dev/null; then
    echo "ERROR: Docker Compose plugin is not installed"
    echo "  Install: sudo apt-get install docker-compose-plugin"
    exit 1
fi
echo "  Compose: $(docker compose version | head -1)"

# Check NVIDIA Container Toolkit
if ! command -v nvidia-smi &> /dev/null; then
    echo "ERROR: nvidia-smi not found. NVIDIA drivers may not be installed."
    exit 1
fi
echo "  GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
echo "  Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
echo "  CUDA: $(nvidia-smi --query-gpu=cuda_version --format=csv,noheader 2>/dev/null || echo 'N/A')"

# Check NVIDIA Docker runtime
if ! docker info 2>/dev/null | grep -q "nvidia"; then
    echo "WARNING: NVIDIA runtime not detected in Docker. GPU passthrough may not work."
    echo "  Install: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
fi

# Check disk space
DATA_DIR="${MODEL_CACHE_DIR:-/data/models}"
if [[ ! -d "$DATA_DIR" ]]; then
    mkdir -p "$DATA_DIR" 2>/dev/null || sudo mkdir -p "$DATA_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$DATA_DIR" 2>/dev/null || true
fi
AVAILABLE_GB=$(df -BG "$DATA_DIR" | tail -1 | awk '{print $4}' | tr -d 'G')
if [[ "$AVAILABLE_GB" -lt 80 ]]; then
    echo "ERROR: Insufficient disk space on $DATA_DIR"
    echo "  Available: ${AVAILABLE_GB}GB, Required: 80GB minimum"
    exit 1
fi
echo "  Disk ($DATA_DIR): ${AVAILABLE_GB}GB available"

# Check HuggingFace token (optional — Gemma 4 is Apache 2.0)
if [[ -n "${HF_TOKEN:-}" ]]; then
    echo "  HF Token: set"
else
    echo "  HF Token: not set (OK for public models like Gemma 4)"
fi

# ─── GPU Memory Probe ───

echo ""
echo "[2/6] GPU memory probe..."
GPU_MEM_BYTES=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
echo "  GPU reports: ${GPU_MEM_BYTES} MiB"
echo "  vLLM gpu_memory_utilization: ${VLLM_GPU_MEMORY_UTILIZATION}"
USABLE_MB=$(awk "BEGIN {printf \"%.0f\", $GPU_MEM_BYTES * $VLLM_GPU_MEMORY_UTILIZATION}" 2>/dev/null || echo "N/A")
echo "  vLLM will use: ~${USABLE_MB} MiB"

# ─── Download Models ───

echo ""
echo "[3/6] Downloading models..."

# Download LLM model
echo "  Downloading LLM: $MODEL_ID"
if [[ -d "$DATA_DIR/models--$(echo "$MODEL_ID" | tr '/' '--')" ]]; then
    echo "  LLM model already cached, skipping download"
else
    if command -v huggingface-cli &> /dev/null; then
        HF_CLI_ARGS="--cache-dir $DATA_DIR --local-dir-use-symlinks True"
        [[ -n "${HF_TOKEN:-}" ]] && HF_CLI_ARGS="--token $HF_TOKEN $HF_CLI_ARGS"
        huggingface-cli download "$MODEL_ID" $HF_CLI_ARGS \
            || { echo "ERROR: Failed to download LLM model"; exit 1; }
    else
        echo "  huggingface-cli not found, model will be downloaded by vLLM on first start"
        echo "  (This may take 15-60 minutes for the 49GB model)"
    fi
fi

# Download Whisper model
WHISPER_CACHE="${WHISPER_CACHE_DIR:-/data/models/whisper}"
if [[ ! -d "$WHISPER_CACHE" ]]; then
    mkdir -p "$WHISPER_CACHE" 2>/dev/null || sudo mkdir -p "$WHISPER_CACHE"
    sudo chown -R "$(id -u):$(id -g)" "$WHISPER_CACHE" 2>/dev/null || true
fi
echo "  Downloading Whisper: $WHISPER_MODEL"
echo "  Whisper model will be downloaded on first container start if not cached"

# ─── Pull Docker Images ───

echo ""
echo "[4/6] Pulling Docker images..."
cd "$REPO_DIR/docker"

# Pull vLLM image (whisper is built locally)
docker pull "$VLLM_IMAGE" || { echo "ERROR: Failed to pull vLLM image: $VLLM_IMAGE"; exit 1; }
echo "  vLLM image: $VLLM_IMAGE pulled"

# Build whisper image
echo "  Building whisper image..."
docker compose -f docker-compose.node.yml build whisper \
    || { echo "ERROR: Failed to build whisper image"; exit 1; }
echo "  Whisper image: built"

# ─── Start Containers ───

echo ""
echo "[5/6] Starting containers..."

# Stop existing containers (idempotent)
if [[ "$ROLE" == "nodeA" ]] && [[ "$SKIP_LB" == "false" ]]; then
    docker compose -f docker-compose.node.yml -f docker-compose.lb.yml down --remove-orphans 2>/dev/null || true
    docker compose -f docker-compose.node.yml -f docker-compose.lb.yml up -d
else
    docker compose -f docker-compose.node.yml down --remove-orphans 2>/dev/null || true
    docker compose -f docker-compose.node.yml up -d
fi

# ─── Wait for Health Checks ───

echo ""
echo "[6/6] Waiting for services to become healthy..."

MAX_WAIT=3600  # 60 minutes max (first run: 49GB download + model load)
INTERVAL=10
ELAPSED=0

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    HEALTHY=true

    # Check vLLM
    if ! curl -sf --max-time 5 "http://localhost:${VLLM_PORT:-8000}/health" > /dev/null 2>&1; then
        HEALTHY=false
    fi

    # Check whisper
    if ! curl -sf --max-time 5 "http://localhost:${WHISPER_PORT:-9000}/health" > /dev/null 2>&1; then
        HEALTHY=false
    fi

    if $HEALTHY; then
        echo "  All services healthy! (took ${ELAPSED}s)"
        break
    fi

    echo "  Waiting... (${ELAPSED}s / ${MAX_WAIT}s)"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    echo "WARNING: Health check timeout after ${MAX_WAIT}s"
    echo "  Services may still be loading (vLLM takes 1-3 min for model load)"
    echo "  Run 'docker compose logs' to check status"
    echo "  Run './scripts/health-check.sh localhost' to re-check"
    exit 1
fi

echo ""
echo "=========================================="
echo "Node setup complete: $ROLE"
echo "=========================================="

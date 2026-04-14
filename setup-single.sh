#!/usr/bin/env bash
# Single DGX Spark Setup — LLM + faster-whisper + nginx
#
# Usage: ./setup-single.sh [--31b]
#
# Default: Gemma 4 26B-A4B MoE (FP8, same as 2-node cluster)
#   --31b: Gemma-4-31B-IT-NVFP4 (NVFP4/modelopt, multimodal, slower ~7 t/s)
#
# Deploys on a single DGX Spark node:
#   - vLLM serving the selected model
#   - faster-whisper STT (large-v3-turbo)
#   - nginx reverse proxy (port 80)
#
# Prerequisites:
#   - NVIDIA DGX Spark (Grace Blackwell GB10, 128GB, aarch64)
#   - Docker + Docker Compose plugin
#   - NVIDIA Container Toolkit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Parse arguments ───

USE_31B=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --31b) USE_31B=true; shift ;;
        *) echo "Unknown argument: $1"; echo "Usage: $0 [--31b]"; exit 1 ;;
    esac
done

# ─── Model configuration ───

if $USE_31B; then
    # Gemma-4-31B-IT-NVFP4 (NVFP4 pre-quantized, multimodal, ~7 t/s)
    export MODEL_ID="nvidia/Gemma-4-31B-IT-NVFP4"
    export VLLM_QUANTIZATION="modelopt"
    export VLLM_QUANT_EXTRA_ARGS=" "
    export VLLM_GPU_MEMORY_UTILIZATION="${VLLM_GPU_MEMORY_UTILIZATION:-0.85}"
    export VLLM_CONTAINER_NAME="gemma4-31b-vllm"
    MODEL_LABEL="Gemma-4-31B-IT-NVFP4 (NVFP4, multimodal)"
    MIN_DISK_GB=50
else
    # Gemma 4 26B-A4B MoE (FP8, same as 2-node cluster, ~38 t/s)
    export MODEL_ID="google/gemma-4-26B-A4B-it"
    export VLLM_QUANTIZATION="fp8"
    export VLLM_QUANT_EXTRA_ARGS="--kv-cache-dtype fp8 --load-format safetensors"
    export VLLM_GPU_MEMORY_UTILIZATION="${VLLM_GPU_MEMORY_UTILIZATION:-0.70}"
    export VLLM_CONTAINER_NAME="dgx-vllm"
    MODEL_LABEL="Gemma 4 26B-A4B MoE (FP8)"
    MIN_DISK_GB=80
fi

# Source whisper config
source "$SCRIPT_DIR/config/whisper-env.sh"

# Source .env if it exists (for optional overrides like HF_TOKEN, MODEL_CACHE_DIR)
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:gemma4-cu130}"
VOXCPM_IMAGE="${VOXCPM_IMAGE:-jinwangmok/voxcpm-api-server:latest}"
MODEL_CACHE_DIR="${MODEL_CACHE_DIR:-/data/models}"
WHISPER_CACHE_DIR="${WHISPER_CACHE_DIR:-/data/models/whisper}"
VOXCPM_CACHE_DIR="${VOXCPM_CACHE_DIR:-/data/models/voxcpm}"
export VOXCPM_IMAGE VOXCPM_CACHE_DIR

echo "=========================================="
echo "DGX Spark — Single Node Setup"
echo "Model: ${MODEL_LABEL}"
echo "=========================================="

# ─── 1. Pre-flight Checks ───

echo ""
echo "[1/7] Pre-flight checks..."

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

# Check NVIDIA runtime
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
fi

# Check disk space
if [[ ! -d "$MODEL_CACHE_DIR" ]]; then
    mkdir -p "$MODEL_CACHE_DIR" 2>/dev/null || sudo mkdir -p "$MODEL_CACHE_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$MODEL_CACHE_DIR" 2>/dev/null || true
fi
AVAILABLE_GB=$(df -BG "$MODEL_CACHE_DIR" | tail -1 | awk '{print $4}' | tr -d 'G')
if [[ "$AVAILABLE_GB" -lt "$MIN_DISK_GB" ]]; then
    echo "ERROR: Insufficient disk space on $MODEL_CACHE_DIR"
    echo "  Available: ${AVAILABLE_GB}GB, Required: ${MIN_DISK_GB}GB minimum"
    exit 1
fi
echo "  Disk ($MODEL_CACHE_DIR): ${AVAILABLE_GB}GB available"

# Check HuggingFace token (optional)
if [[ -n "${HF_TOKEN:-}" ]]; then
    echo "  HF Token: set"
else
    echo "  HF Token: not set (OK for public models)"
fi

# ─── 2. GPU Memory Probe ───

echo ""
echo "[2/7] GPU memory probe..."
GPU_MEM_MIB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
echo "  GPU reports: ${GPU_MEM_MIB} MiB"
echo "  vLLM gpu_memory_utilization: ${VLLM_GPU_MEMORY_UTILIZATION}"
USABLE_MB=$(awk "BEGIN {printf \"%.0f\", $GPU_MEM_MIB * $VLLM_GPU_MEMORY_UTILIZATION}" 2>/dev/null || echo "N/A")
echo "  vLLM will use: ~${USABLE_MB} MiB"

# ─── 3. Create Model Cache Directories ───

echo ""
echo "[3/7] Preparing model cache directories..."
for DIR in "$MODEL_CACHE_DIR" "$WHISPER_CACHE_DIR" "$VOXCPM_CACHE_DIR"; do
    if [[ ! -d "$DIR" ]]; then
        mkdir -p "$DIR" 2>/dev/null || sudo mkdir -p "$DIR"
        sudo chown -R "$(id -u):$(id -g)" "$DIR" 2>/dev/null || true
    fi
    echo "  $DIR: OK"
done

# ─── 4. Generate .env.token ───

echo ""
echo "[4/7] Generating .env.token..."
echo "HUGGING_FACE_HUB_TOKEN=${HF_TOKEN:-}" > "$SCRIPT_DIR/.env.token"
chmod 600 "$SCRIPT_DIR/.env.token"
echo "  .env.token: generated"

# ─── 5. Pull vLLM Image & Check quantization support ───

echo ""
echo "[5/7] Pulling Docker images..."
docker pull "$VLLM_IMAGE" || { echo "ERROR: Failed to pull vLLM image: $VLLM_IMAGE"; exit 1; }
echo "  vLLM image: $VLLM_IMAGE pulled"
docker pull "$VOXCPM_IMAGE" || { echo "ERROR: Failed to pull VoxCPM image: $VOXCPM_IMAGE"; exit 1; }
echo "  VoxCPM image: $VOXCPM_IMAGE pulled"

# Verify quantization backend (only for modelopt/31B)
if $USE_31B; then
    echo "  Checking modelopt quantization support..."
    if docker run --rm "$VLLM_IMAGE" python -c "import modelopt" 2>/dev/null; then
        echo "  modelopt: available"
    else
        echo "WARNING: modelopt library not found in $VLLM_IMAGE"
        echo "  The --quantization modelopt flag may not work."
        echo "  Continuing anyway (vLLM may handle NVFP4 natively)..."
    fi
fi

# Build whisper image
echo "  Building whisper image..."
cd "$SCRIPT_DIR/docker"
docker compose -f docker-compose.single.yml build whisper \
    || { echo "ERROR: Failed to build whisper image"; exit 1; }
echo "  Whisper image: built"

# ─── 6. Start Containers ───

echo ""
echo "[6/7] Starting containers..."
echo "  Model: ${MODEL_ID}"
echo "  Quantization: ${VLLM_QUANTIZATION}"
echo "  GPU Memory: ${VLLM_GPU_MEMORY_UTILIZATION}"
cd "$SCRIPT_DIR/docker"
docker compose -f docker-compose.single.yml up -d --no-recreate

# ─── 7. Wait for Health Checks ───

echo ""
echo "[7/7] Waiting for services to become healthy..."

MAX_WAIT=3600
INTERVAL=10
ELAPSED=0

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    HEALTHY=true

    # Check vLLM
    if ! curl -sf --max-time 5 "http://localhost:8000/health" > /dev/null 2>&1; then
        HEALTHY=false
    fi

    # Check whisper
    if ! curl -sf --max-time 5 "http://localhost:9000/health" > /dev/null 2>&1; then
        HEALTHY=false
    fi

    # Check voxcpm
    if ! curl -sf --max-time 5 "http://localhost:9100/health" > /dev/null 2>&1; then
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
    echo "  Services may still be loading"
    echo "  Run 'docker compose -f docker/docker-compose.single.yml logs -f' to check"
    exit 1
fi

# ─── Summary ───

NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

echo ""
echo "=========================================="
echo "  Single Node Setup Complete!"
echo "=========================================="
echo ""
echo "  Model: ${MODEL_LABEL}"
echo ""
echo "  Endpoints:"
echo "    LLM API:   http://${NODE_IP}/v1/chat/completions"
echo "    STT API:   http://${NODE_IP}/stt/v1/audio/transcriptions"
echo "    TTS API:   http://${NODE_IP}/tts/v1/audio/speech"
echo "    Health:    http://${NODE_IP}/health"
echo "    Status:    http://${NODE_IP}/status"
echo "    Models:    http://${NODE_IP}/v1/models"
echo ""
echo "  Direct ports (without nginx):"
echo "    vLLM:      http://${NODE_IP}:8000"
echo "    Whisper:   http://${NODE_IP}:9000"
echo "    VoxCPM:    http://${NODE_IP}:9100"
echo ""
echo "  Verify from remote machine:"
echo "    ./verify-remote.sh ${NODE_IP}"
echo "    verify-remote.bat ${NODE_IP}"
echo ""
echo "  Teardown:"
echo "    cd docker && docker compose -f docker-compose.single.yml down"
echo ""

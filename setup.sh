#!/usr/bin/env bash
# DGX Spark Gemma 4 Cluster - Main Setup Script
#
# Usage: ./setup.sh
#
# Prerequisites:
#   - .env file configured (copy from .env.example)
#   - SSH passwordless auth to Node B
#   - Docker + NVIDIA Container Toolkit on both nodes
#   - HuggingFace token with Gemma 4 access
#
# This script:
#   1. Validates configuration and SSH connectivity
#   2. Syncs repo to Node B via rsync
#   3. Starts services on BOTH nodes in parallel
#   4. Generates nginx config and starts load balancer
#   5. Runs verification

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ╔══════════════════════════════════════════╗
# ║  DGX Spark Gemma 4 Cluster Setup        ║
# ╚══════════════════════════════════════════╝

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  DGX Spark Gemma 4 Cluster Setup        ║"
echo "║  2x Gemma 4 26B-A4B MoE + STT + nginx  ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ─── Load Configuration ───

if [[ ! -f .env ]]; then
    echo "ERROR: .env file not found"
    echo "  Copy .env.example to .env and fill in the values:"
    echo "    cp .env.example .env"
    echo "    nano .env"
    exit 1
fi

set -a
source .env
set +a

# Validate required variables
MISSING=()
[[ -z "${NODE_A_IP:-}" ]] && MISSING+=("NODE_A_IP")
[[ -z "${NODE_B_IP:-}" ]] && MISSING+=("NODE_B_IP")
[[ -z "${HF_TOKEN:-}" ]] && MISSING+=("HF_TOKEN")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "ERROR: Required variables not set in .env:"
    for var in "${MISSING[@]}"; do
        echo "  - $var"
    done
    exit 1
fi

SSH_USER="${SSH_USER:-$(whoami)}"
SSH_TARGET="${SSH_USER}@${NODE_B_IP}"

# Source config files
source config/vllm-env.sh
source config/whisper-env.sh

echo "Configuration:"
echo "  Node A: ${NODE_A_IP} (this node + nginx LB)"
echo "  Node B: ${NODE_B_IP} (remote node)"
echo "  SSH:    ${SSH_TARGET}"
echo "  Model:  ${MODEL_ID}"
echo "  vLLM:   ${VLLM_IMAGE}"
echo "  GPU Mem: ${VLLM_GPU_MEMORY_UTILIZATION}"
echo ""

# ─── Step 1: SSH Connectivity ───

echo "[Step 1/5] Testing SSH connectivity to Node B..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_TARGET" "echo ok" > /dev/null 2>&1; then
    echo "ERROR: Cannot SSH to ${SSH_TARGET}"
    echo "  Ensure passwordless SSH is configured:"
    echo "    ssh-copy-id ${SSH_TARGET}"
    exit 1
fi
echo "  SSH to Node B: OK"
echo ""

# ─── Step 2: Sync Repo to Node B ───

echo "[Step 2/5] Syncing repository to Node B..."
REMOTE_DIR="/home/${SSH_USER}/dgx-spark-ai-cluster"

rsync -az --delete \
    --exclude '.omc' \
    --exclude '.git' \
    --exclude '__pycache__' \
    --exclude '.env' \
    --exclude '.env.token' \
    --exclude 'config/nginx.conf' \
    "$SCRIPT_DIR/" "${SSH_TARGET}:${REMOTE_DIR}/"

# Copy .env to Node B with restrictive permissions
scp "$SCRIPT_DIR/.env" "${SSH_TARGET}:${REMOTE_DIR}/.env"
ssh "$SSH_TARGET" "chmod 600 ${REMOTE_DIR}/.env"

# Create token-only file for Docker env_file (avoids exposing full .env)
echo "HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}" > "$SCRIPT_DIR/.env.token"
chmod 600 "$SCRIPT_DIR/.env.token"
scp "$SCRIPT_DIR/.env.token" "${SSH_TARGET}:${REMOTE_DIR}/.env.token"
ssh "$SSH_TARGET" "chmod 600 ${REMOTE_DIR}/.env.token"

echo "  Synced to ${SSH_TARGET}:${REMOTE_DIR}"
echo ""

# ─── Step 3: Parallel Node Setup ───

# Ensure local .env.token exists for Docker env_file
echo "HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}" > "$SCRIPT_DIR/.env.token"
chmod 600 "$SCRIPT_DIR/.env.token"

echo "[Step 3/5] Setting up services on both nodes (parallel)..."
echo "  This may take 15-60 minutes on first run (model download: ~49GB)"
echo ""

# Create log directory
mkdir -p /tmp/dgx-spark-setup

# Start Node B setup in background via SSH
echo "  Starting Node B setup (background)..."
ssh "$SSH_TARGET" \
    "cd ${REMOTE_DIR} && bash scripts/setup-node.sh --role nodeB" \
    > /tmp/dgx-spark-setup/nodeB.log 2>&1 &
NODE_B_PID=$!

# Run Node A setup in foreground (without nginx LB — started separately after)
echo "  Starting Node A setup (foreground)..."
bash scripts/setup-node.sh --role nodeA --skip-lb 2>&1 | tee /tmp/dgx-spark-setup/nodeA.log
NODE_A_STATUS=${PIPESTATUS[0]}

# Wait for Node B
echo ""
echo "  Waiting for Node B to complete..."
wait $NODE_B_PID
NODE_B_STATUS=$?

# Report results
echo ""
if [[ $NODE_A_STATUS -ne 0 ]]; then
    echo "ERROR: Node A setup failed (exit code: $NODE_A_STATUS)"
    echo "  Log: /tmp/dgx-spark-setup/nodeA.log"
fi
if [[ $NODE_B_STATUS -ne 0 ]]; then
    echo "ERROR: Node B setup failed (exit code: $NODE_B_STATUS)"
    echo "  Log: /tmp/dgx-spark-setup/nodeB.log"
    echo "  Remote log: ssh ${SSH_TARGET} 'cat /tmp/dgx-spark-setup/nodeB.log'"
fi
if [[ $NODE_A_STATUS -ne 0 ]] || [[ $NODE_B_STATUS -ne 0 ]]; then
    echo ""
    echo "Setup failed. Fix the errors above and re-run ./setup.sh"
    exit 1
fi

echo "  Node A: OK"
echo "  Node B: OK"
echo ""

# ─── Step 4: Start nginx Load Balancer ───

echo "[Step 4/5] Starting nginx load balancer on Node A..."

# Generate nginx.conf from template
envsubst '${NODE_A_IP} ${NODE_B_IP}' \
    < config/nginx.conf.template \
    > config/nginx.conf

echo "  Generated config/nginx.conf"

# Start nginx via Compose override
cd docker
docker compose -f docker-compose.node.yml -f docker-compose.lb.yml up -d nginx
cd "$SCRIPT_DIR"

# Wait for nginx health
echo "  Waiting for nginx..."
for i in $(seq 1 30); do
    if curl -sf --max-time 5 "http://localhost:80/health" > /dev/null 2>&1; then
        echo "  nginx: healthy"
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "WARNING: nginx health check timeout"
        echo "  Check: docker logs gemma4-nginx"
    fi
    sleep 2
done
echo ""

# ─── Step 5: Verification ───

echo "[Step 5/5] Running verification..."
echo ""

bash verify.sh
VERIFY_STATUS=$?

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Setup Complete                          ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Endpoints:"
echo "  LLM API:  http://${NODE_A_IP}/v1/chat/completions"
echo "  STT API:  http://${NODE_A_IP}/stt/v1/audio/transcriptions"
echo "  Health:   http://${NODE_A_IP}/health"
echo "  Status:   http://${NODE_A_IP}/status"
echo ""
echo "Quick test:"
echo "  # LLM"
echo "  curl http://${NODE_A_IP}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}'"
echo ""
echo "  # STT"
echo "  curl http://${NODE_A_IP}/stt/v1/audio/transcriptions \\"
echo "    -F file=@audio.wav -F model=whisper-1"
echo ""
echo "Management:"
echo "  Logs:     docker compose -f docker/docker-compose.node.yml logs -f"
echo "  Stop:     docker compose -f docker/docker-compose.node.yml -f docker/docker-compose.lb.yml down"
echo "  Verify:   ./verify.sh"
echo ""

exit $VERIFY_STATUS

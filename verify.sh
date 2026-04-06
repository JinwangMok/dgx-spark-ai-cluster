#!/usr/bin/env bash
# DGX Spark Gemma 4 Cluster - Verification Script
#
# Usage: ./verify.sh
#
# Validates all acceptance criteria:
#   1. Container status on both nodes
#   2. LLM API (OpenAI-compatible) response
#   3. STT API (Whisper-compatible) response
#   4. Load balancer distribution
#   5. Response time measurement
#   6. GPU memory usage

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load configuration
if [[ -f .env ]]; then
    set -a; source .env; set +a
fi
source config/vllm-env.sh 2>/dev/null || true
source config/whisper-env.sh 2>/dev/null || true

SSH_USER="${SSH_USER:-$(whoami)}"
SSH_TARGET="${SSH_USER}@${NODE_B_IP}"
LB_URL="http://${NODE_A_IP}"

PASS=0
FAIL=0
WARN=0
TOTAL=0

# ─── Helpers ───

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "  [FAIL] $1"; }
warn() { WARN=$((WARN + 1)); echo "  [WARN] $1"; }

section() { echo ""; echo "━━━ $1 ━━━"; }

# ╔══════════════════════════════════════════╗
# ║  DGX Spark Gemma 4 Cluster Verification ║
# ╚══════════════════════════════════════════╝

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  DGX Spark Gemma 4 Cluster Verification ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Node A: ${NODE_A_IP} | Node B: ${NODE_B_IP}"

# ━━━ 1. Container Status ━━━

section "1. Container Status"

# Node A containers (vllm + whisper + nginx = 3)
NODE_A_CONTAINERS=$(docker ps --format '{{.Names}}' | grep -c 'gemma4' 2>/dev/null || echo "0")
if [[ "$NODE_A_CONTAINERS" -ge 3 ]]; then
    pass "Node A: ${NODE_A_CONTAINERS} containers running (vllm + whisper + nginx)"
else
    fail "Node A: only ${NODE_A_CONTAINERS}/3 containers running"
    echo "       Expected: gemma4-vllm, gemma4-whisper, gemma4-nginx"
    docker ps --format 'table {{.Names}}\t{{.Status}}' | grep gemma4 || true
fi

# Node B containers (vllm + whisper = 2)
NODE_B_CONTAINERS=$(ssh -o ConnectTimeout=10 "$SSH_TARGET" \
    "docker ps --format '{{.Names}}' | grep -c 'gemma4'" 2>/dev/null || echo "0")
if [[ "$NODE_B_CONTAINERS" -ge 2 ]]; then
    pass "Node B: ${NODE_B_CONTAINERS} containers running (vllm + whisper)"
else
    fail "Node B: only ${NODE_B_CONTAINERS}/2 containers running"
fi

# ━━━ 2. LLM API Test ━━━

section "2. LLM API (OpenAI-compatible)"

# Direct test to Node A
LLM_RESPONSE=$(curl -sf --max-time 60 "${LB_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_ID:-google/gemma-4-26B-A4B-it}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in exactly 3 words.\"}],
        \"max_tokens\": 20,
        \"temperature\": 0.1
    }" 2>/dev/null) || true

if echo "$LLM_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['choices'][0]['message']['content']" 2>/dev/null; then
    LLM_TEXT=$(echo "$LLM_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'][:80])")
    pass "LLM response: \"${LLM_TEXT}\""
else
    fail "LLM API did not return valid response"
    [[ -n "$LLM_RESPONSE" ]] && echo "       Response: ${LLM_RESPONSE:0:200}"
fi

# ━━━ 3. STT API Test ━━━

section "3. STT API (Whisper-compatible)"

TEST_AUDIO="$SCRIPT_DIR/tests/test.wav"

if [[ -f "$TEST_AUDIO" ]]; then
    STT_RESPONSE=$(curl -sf --max-time 30 "${LB_URL}/stt/v1/audio/transcriptions" \
        -F "file=@${TEST_AUDIO}" \
        -F "model=whisper-1" 2>/dev/null) || true

    if echo "$STT_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('text','')" 2>/dev/null; then
        STT_TEXT=$(echo "$STT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['text'][:80])")
        pass "STT transcription: \"${STT_TEXT}\""
    else
        fail "STT API did not return valid transcription"
        [[ -n "$STT_RESPONSE" ]] && echo "       Response: ${STT_RESPONSE:0:200}"
    fi
else
    warn "Test audio not found: $TEST_AUDIO (generate with: ./tests/generate-test-audio.sh)"
    # Try health check instead
    if curl -sf --max-time 10 "${LB_URL}/stt/health" > /dev/null 2>&1; then
        pass "STT health endpoint reachable (no audio test)"
    else
        fail "STT health endpoint not reachable"
    fi
fi

# ━━━ 4. Load Balancer Distribution ━━━

section "4. Load Balancer Distribution"

# Send 10 LLM requests and check X-Backend-Server header
echo "  Sending 10 LLM requests to check distribution..."
declare -A BACKEND_COUNT
LB_TEST_OK=true

for i in $(seq 1 10); do
    BACKEND=$(curl -sI --max-time 10 "${LB_URL}/v1/models" 2>/dev/null \
        | grep -i 'X-Backend-Server' | awk '{print $2}' | tr -d '\r\n') || true

    if [[ -n "$BACKEND" ]]; then
        BACKEND_COUNT[$BACKEND]=$(( ${BACKEND_COUNT[$BACKEND]:-0} + 1 ))
    fi
    sleep 0.2
done

if [[ ${#BACKEND_COUNT[@]} -ge 2 ]]; then
    pass "LLM LB: requests distributed across ${#BACKEND_COUNT[@]} backends"
    for backend in "${!BACKEND_COUNT[@]}"; do
        echo "       $backend: ${BACKEND_COUNT[$backend]} requests"
    done
elif [[ ${#BACKEND_COUNT[@]} -eq 1 ]]; then
    warn "LLM LB: all requests went to single backend (may be correct if other node is slower)"
    for backend in "${!BACKEND_COUNT[@]}"; do
        echo "       $backend: ${BACKEND_COUNT[$backend]} requests"
    done
else
    fail "LLM LB: could not determine backend distribution (X-Backend-Server header missing?)"
fi

# STT LB check
echo "  Checking STT load balancer..."
STT_BACKENDS=()
for i in 1 2 3; do
    STT_BACK=$(curl -sI --max-time 10 "${LB_URL}/stt/health" 2>/dev/null \
        | grep -i 'X-Backend-Server' | awk '{print $2}' | tr -d '\r\n') || true
    [[ -n "$STT_BACK" ]] && STT_BACKENDS+=("$STT_BACK")
done

UNIQUE_STT=$(printf '%s\n' "${STT_BACKENDS[@]}" 2>/dev/null | sort -u | wc -l)
if [[ "$UNIQUE_STT" -ge 2 ]]; then
    pass "STT LB: distributed across backends"
elif [[ "${#STT_BACKENDS[@]}" -gt 0 ]]; then
    warn "STT LB: only 1 unique backend seen in 3 requests"
else
    fail "STT LB: could not determine distribution"
fi

# ━━━ 5. Response Time ━━━

section "5. Response Time"

# LLM response time
LLM_TIME=$(curl -o /dev/null -sf --max-time 120 -w '%{time_total}' \
    "${LB_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_ID:-google/gemma-4-26B-A4B-it}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}],
        \"max_tokens\": 5
    }" 2>/dev/null) || LLM_TIME="timeout"

if [[ "$LLM_TIME" != "timeout" ]]; then
    LLM_TIME_INT=$(echo "$LLM_TIME" | cut -d. -f1)
    if [[ "$LLM_TIME_INT" -lt 30 ]]; then
        pass "LLM response time: ${LLM_TIME}s"
    else
        warn "LLM response time: ${LLM_TIME}s (>30s, may indicate slow inference)"
    fi
else
    fail "LLM response timed out (>120s)"
fi

# STT response time (if test audio exists)
if [[ -f "$TEST_AUDIO" ]]; then
    STT_TIME=$(curl -o /dev/null -sf --max-time 30 -w '%{time_total}' \
        "${LB_URL}/stt/v1/audio/transcriptions" \
        -F "file=@${TEST_AUDIO}" \
        -F "model=whisper-1" 2>/dev/null) || STT_TIME="timeout"

    if [[ "$STT_TIME" != "timeout" ]]; then
        STT_TIME_INT=$(echo "$STT_TIME" | cut -d. -f1)
        if [[ "$STT_TIME_INT" -lt 10 ]]; then
            pass "STT response time: ${STT_TIME}s"
        else
            warn "STT response time: ${STT_TIME}s (>10s)"
        fi
    else
        fail "STT response timed out (>30s)"
    fi
fi

# ━━━ 6. GPU Memory ━━━

section "6. GPU Memory"

# Node A
GPU_A_USED=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1) || true
GPU_A_TOTAL=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1) || true

if [[ -n "$GPU_A_TOTAL" ]] && [[ "$GPU_A_TOTAL" -gt 0 ]] 2>/dev/null; then
    GPU_A_PCT=$(( GPU_A_USED * 100 / GPU_A_TOTAL ))
    if [[ $GPU_A_PCT -lt 95 ]]; then
        pass "Node A GPU: ${GPU_A_USED}/${GPU_A_TOTAL} MiB (${GPU_A_PCT}%)"
    else
        warn "Node A GPU: ${GPU_A_USED}/${GPU_A_TOTAL} MiB (${GPU_A_PCT}% - near limit)"
    fi
else
    warn "Node A GPU: could not query memory"
fi

# Node B
GPU_B_INFO=$(ssh -o ConnectTimeout=10 "$SSH_TARGET" \
    "nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits" 2>/dev/null) || true

if [[ -n "$GPU_B_INFO" ]]; then
    GPU_B_USED=$(echo "$GPU_B_INFO" | cut -d',' -f1 | tr -d ' ')
    GPU_B_TOTAL=$(echo "$GPU_B_INFO" | cut -d',' -f2 | tr -d ' ')

    if [[ -n "$GPU_B_TOTAL" ]] && [[ "$GPU_B_TOTAL" -gt 0 ]] 2>/dev/null; then
        GPU_B_PCT=$(( GPU_B_USED * 100 / GPU_B_TOTAL ))
        if [[ $GPU_B_PCT -lt 95 ]]; then
            pass "Node B GPU: ${GPU_B_USED}/${GPU_B_TOTAL} MiB (${GPU_B_PCT}%)"
        else
            warn "Node B GPU: ${GPU_B_USED}/${GPU_B_TOTAL} MiB (${GPU_B_PCT}% - near limit)"
        fi
    else
        warn "Node B GPU: could not parse memory values"
    fi
else
    warn "Node B GPU: could not query (SSH timeout?)"
fi

# ━━━ Summary ━━━

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Verification Summary                    ║"
echo "╠══════════════════════════════════════════╣"
printf "║  PASS: %-3d  FAIL: %-3d  WARN: %-3d        ║\n" "$PASS" "$FAIL" "$WARN"
echo "╚══════════════════════════════════════════╝"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo "All checks passed! Cluster is operational."
    exit 0
else
    echo "Some checks failed. Review the output above."
    exit 1
fi

#!/usr/bin/env bash
# TPS (Tokens Per Second) Benchmark for DGX Spark
#
# Usage: ./benchmark-tps.sh <DGX_SPARK_IP>
# Example: ./benchmark-tps.sh 10.40.40.40
#
# Measures output TPS from a single request path (token count and timing
# from the same response). Uses temperature=0 for deterministic output.
# Validates the served model before benchmarking.

set -uo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <DGX_SPARK_IP>"
    exit 1
fi

TARGET_IP="$1"
BASE_URL="http://${TARGET_IP}"

echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║  DGX Spark — TPS Benchmark                    ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""
echo "Target: ${BASE_URL}"

# ─── Validate served model ───

echo ""
echo "━━━ Model Verification ━━━"

MODELS_RESPONSE=$(curl -sf --max-time 10 "${BASE_URL}/v1/models" 2>/dev/null) || {
    echo "  [ERROR] Cannot reach ${BASE_URL}/v1/models"
    exit 1
}

MODEL=$(echo "$MODELS_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
models = d.get('data', [])
if not models:
    print('ERROR: no models served')
    sys.exit(1)
m = models[0]
print(m['id'])
" 2>/dev/null) || { echo "  [ERROR] Cannot parse model list"; exit 1; }

echo "  Served model: ${MODEL}"
echo "  Owned by:     vllm"

# Detect quantization from model name
if echo "$MODEL" | grep -qi "NVFP4"; then
    echo "  Quantization: NVFP4 (inferred from model ID)"
elif echo "$MODEL" | grep -qi "fp8"; then
    echo "  Quantization: FP8 (inferred from model ID)"
else
    echo "  Quantization: unknown (check container logs for --quantization flag)"
fi

# ─── Benchmark function ───
# Single request path: token counts AND timing from the same response.
# Uses temperature=0 for deterministic decoding.

run_benchmark() {
    local label="$1"
    local prompt="$2"
    local max_tokens="$3"

    echo ""
    echo "━━━ ${label} (max_tokens=${max_tokens}) ━━━"

    # Single request: measure wall time with curl -w, extract tokens from response
    local tmpfile
    tmpfile=$(mktemp)

    local wall_time
    wall_time=$(curl -s --max-time 300 -w '%{time_total}' -o "$tmpfile" \
        "${BASE_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${MODEL}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}],
            \"max_tokens\": ${max_tokens},
            \"temperature\": 0
        }" 2>/dev/null) || { echo "  [ERROR] Request failed"; rm -f "$tmpfile"; return; }

    # Extract metrics from the same response that was timed
    python3 -c "
import json, sys

try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except:
    print('  [ERROR] Invalid JSON response')
    sys.exit(1)

if 'error' in d:
    print(f'  [ERROR] {d[\"error\"].get(\"message\", d[\"error\"])}')
    sys.exit(1)

u = d['usage']
wall = float(sys.argv[2])
prompt_tok = u['prompt_tokens']
comp_tok = u['completion_tokens']

# Overall TPS = completion_tokens / total_wall_time
overall_tps = comp_tok / wall if wall > 0 else 0

print(f'  Prompt tokens:     {prompt_tok}')
print(f'  Completion tokens: {comp_tok}')
print(f'  Wall time:         {wall:.2f} s')
print(f'  Output TPS:        {overall_tps:.1f} tok/s')
" "$tmpfile" "$wall_time"

    rm -f "$tmpfile"
}

# ─── Warmup ───

echo ""
echo "Warmup..."
curl -s --max-time 60 "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":5,\"temperature\":0}" > /dev/null 2>&1
echo "Done."

# ─── Run Benchmarks ───

run_benchmark "1. Short prompt, short output" \
    "What is 2+2? Answer with just the number." \
    16

run_benchmark "2. Short prompt, medium output" \
    "Explain quantum computing in simple terms." \
    256

run_benchmark "3. Short prompt, long output" \
    "Write a detailed essay about the history of artificial intelligence, covering key milestones from the 1950s to 2025." \
    1024

run_benchmark "4. Medium prompt, medium output" \
    "You are an expert software engineer. Review the following approach: We are building a REST API using Python FastAPI with PostgreSQL. We need to handle 1000 concurrent users, implement JWT authentication, rate limiting, and caching. The API serves machine learning model predictions. Each prediction takes about 200ms. We want to minimize latency and maximize throughput. What architecture would you recommend? Include specific libraries, patterns, and deployment strategies." \
    512

# ─── Summary ───

echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║  Benchmark Complete                            ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""
echo "Note: These are single-request latency measurements."
echo "      TPS under concurrent load will differ."
echo "      Run multiple times for stable results."

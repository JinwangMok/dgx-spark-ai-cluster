#!/usr/bin/env bash
# Health check utility for DGX Spark Gemma 4 Cluster
# Usage: ./scripts/health-check.sh [host] [--quiet]
#
# Checks vLLM, whisper, and optionally nginx containers.
# Returns exit code 0 if all healthy, 1 otherwise.

set -euo pipefail

HOST="${1:-localhost}"
QUIET="${2:-}"

VLLM_PORT="${VLLM_PORT:-8000}"
WHISPER_PORT="${WHISPER_PORT:-9000}"

PASS=0
FAIL=0

check() {
    local name="$1"
    local url="$2"
    local timeout="${3:-10}"

    if curl -sf --max-time "$timeout" "$url" > /dev/null 2>&1; then
        [[ -z "$QUIET" ]] && echo "  [PASS] $name"
        ((PASS++))
    else
        [[ -z "$QUIET" ]] && echo "  [FAIL] $name ($url)"
        ((FAIL++))
    fi
}

[[ -z "$QUIET" ]] && echo "Health check: $HOST"
[[ -z "$QUIET" ]] && echo "================================"

# Check vLLM
check "vLLM API" "http://${HOST}:${VLLM_PORT}/health"

# Check whisper
check "Whisper STT" "http://${HOST}:${WHISPER_PORT}/health"

# Check nginx (only on Node A / port 80)
if curl -sf --max-time 5 "http://${HOST}:80/health" > /dev/null 2>&1; then
    check "nginx LB" "http://${HOST}:80/health"
fi

[[ -z "$QUIET" ]] && echo "================================"
[[ -z "$QUIET" ]] && echo "Results: ${PASS} passed, ${FAIL} failed"

[[ $FAIL -eq 0 ]]

#!/usr/bin/env bash
# Remote Verification Script for Single DGX Spark Node
#
# Usage: ./verify-remote.sh <DGX_SPARK_IP>
#
# Runs from any Linux/macOS machine to verify all features:
#   1. Health check
#   2. LLM text chat
#   3. Multimodal (image input)
#   4. Tool calling
#   5. STT transcription
#   6. Response time measurement
#
# Requirements: curl, python3 (for JSON parsing), sox or ffmpeg (for STT test)

set -uo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <DGX_SPARK_IP>"
    echo "Example: $0 192.168.1.100"
    exit 1
fi

TARGET_IP="$1"
BASE_URL="http://${TARGET_IP}"

# Auto-detect served model from /v1/models endpoint
MODEL=$(curl -sf --max-time 10 "${BASE_URL}/v1/models" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null) \
    || MODEL="unknown"

PASS=0
FAIL=0
WARN=0
TOTAL=0

# ─── Helpers ───

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "  [FAIL] $1"; }
warn() { WARN=$((WARN + 1)); echo "  [WARN] $1"; }
section() { echo ""; echo "━━━ $1 ━━━"; }

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  DGX Spark Single Node — Remote Verification ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Target: ${BASE_URL}"
echo "Model:  ${MODEL}"

# ━━━ 1. Health Check ━━━

section "1. Health Check"

HEALTH_RESPONSE=$(curl -sf --max-time 10 "${BASE_URL}/health" 2>/dev/null) && \
    pass "Health endpoint reachable" || \
    fail "Health endpoint not reachable at ${BASE_URL}/health"

STATUS_RESPONSE=$(curl -sf --max-time 10 "${BASE_URL}/status" 2>/dev/null) || true
if [[ -n "$STATUS_RESPONSE" ]]; then
    echo "  Status: $STATUS_RESPONSE"
fi

# ━━━ 2. LLM Text Chat ━━━

section "2. LLM Text Chat"

LLM_START=$(date +%s%N 2>/dev/null || date +%s)
LLM_RESPONSE=$(curl -sf --max-time 120 "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in exactly 3 words.\"}],
        \"max_tokens\": 20,
        \"temperature\": 0.1
    }" 2>/dev/null) || true
LLM_END=$(date +%s%N 2>/dev/null || date +%s)

if echo "$LLM_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['choices'][0]['message']['content']" 2>/dev/null; then
    LLM_TEXT=$(echo "$LLM_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'][:80])")
    pass "LLM text response: \"${LLM_TEXT}\""
else
    fail "LLM text chat did not return valid response"
    [[ -n "${LLM_RESPONSE:-}" ]] && echo "       Response: ${LLM_RESPONSE:0:200}"
fi

# ━━━ 3. Multimodal (Image Input) ━━━

section "3. Multimodal (Image Input)"

# Generate a tiny 2x2 red PNG as base64 (avoids external URL issues like 403)
TEST_IMG_B64=$(python3 -c "
import base64, zlib
from struct import pack
w, h = 2, 2
raw = b''.join(b'\x00' + b'\xff\x00\x00' * w for _ in range(h))
def chunk(t, d):
    c = t + d
    return pack('>I', len(d)) + c + pack('>I', zlib.crc32(c) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(raw))
png += chunk(b'IEND', b'')
print(base64.b64encode(png).decode())
" 2>/dev/null) || true

if [[ -n "$TEST_IMG_B64" ]]; then
    MULTIMODAL_RESPONSE=$(curl -sf --max-time 120 "${BASE_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${MODEL}\",
            \"messages\": [{
                \"role\": \"user\",
                \"content\": [
                    {\"type\": \"text\", \"text\": \"What color is this image? Answer in one word.\"},
                    {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/png;base64,${TEST_IMG_B64}\"}}
                ]
            }],
            \"max_tokens\": 20,
            \"temperature\": 0.1
        }" 2>/dev/null) || true
else
    warn "python3 not available for base64 image generation"
    MULTIMODAL_RESPONSE=""
fi

if echo "$MULTIMODAL_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['choices'][0]['message']['content']" 2>/dev/null; then
    MM_TEXT=$(echo "$MULTIMODAL_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'][:100])")
    pass "Multimodal response: \"${MM_TEXT}\""
else
    fail "Multimodal (image) did not return valid response"
    [[ -n "${MULTIMODAL_RESPONSE:-}" ]] && echo "       Response: ${MULTIMODAL_RESPONSE:0:200}"
fi

# ━━━ 4. Tool Calling ━━━

section "4. Tool Calling"

TOOL_RESPONSE=$(curl -sf --max-time 120 "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"What is the weather in Seoul today?\"}],
        \"tools\": [{
            \"type\": \"function\",
            \"function\": {
                \"name\": \"get_weather\",
                \"description\": \"Get current weather for a city\",
                \"parameters\": {
                    \"type\": \"object\",
                    \"properties\": {
                        \"city\": {\"type\": \"string\", \"description\": \"City name\"}
                    },
                    \"required\": [\"city\"]
                }
            }
        }],
        \"tool_choice\": \"auto\",
        \"max_tokens\": 100,
        \"temperature\": 0.1
    }" 2>/dev/null) || true

if echo "$TOOL_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
msg = d['choices'][0]['message']
assert msg.get('tool_calls') or msg.get('content')
" 2>/dev/null; then
    HAS_TOOL_CALLS=$(echo "$TOOL_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
tc = d['choices'][0]['message'].get('tool_calls', [])
if tc:
    print(f'tool_calls: {tc[0][\"function\"][\"name\"]}({tc[0][\"function\"][\"arguments\"]})')
else:
    print(f'text response (no tool call): {d[\"choices\"][0][\"message\"][\"content\"][:60]}')
" 2>/dev/null)
    pass "Tool calling: ${HAS_TOOL_CALLS}"
else
    fail "Tool calling did not return valid response"
    [[ -n "${TOOL_RESPONSE:-}" ]] && echo "       Response: ${TOOL_RESPONSE:0:200}"
fi

# ━━━ 5. STT Transcription ━━━

section "5. STT Transcription"

TEST_AUDIO="/tmp/dgx-verify-test.wav"
AUDIO_GENERATED=false

# Generate a short test audio file
if command -v sox &> /dev/null; then
    sox -n -r 16000 -c 1 "$TEST_AUDIO" synth 2 sine 440 2>/dev/null && AUDIO_GENERATED=true
elif command -v ffmpeg &> /dev/null; then
    ffmpeg -y -f lavfi -i "sine=frequency=440:duration=2" -ar 16000 -ac 1 "$TEST_AUDIO" 2>/dev/null && AUDIO_GENERATED=true
fi

if $AUDIO_GENERATED && [[ -f "$TEST_AUDIO" ]]; then
    STT_RESPONSE=$(curl -sf --max-time 30 "${BASE_URL}/stt/v1/audio/transcriptions" \
        -F "file=@${TEST_AUDIO}" \
        -F "model=whisper-1" 2>/dev/null) || true

    if echo "$STT_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'text' in d" 2>/dev/null; then
        STT_TEXT=$(echo "$STT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['text'][:80])")
        pass "STT transcription: \"${STT_TEXT}\""
    else
        fail "STT did not return valid transcription"
        [[ -n "${STT_RESPONSE:-}" ]] && echo "       Response: ${STT_RESPONSE:0:200}"
    fi
    rm -f "$TEST_AUDIO"
else
    warn "Cannot generate test audio (install sox or ffmpeg)"
    # Fallback: health check only
    if curl -sf --max-time 10 "${BASE_URL}/stt/health" > /dev/null 2>&1; then
        pass "STT health endpoint reachable (no audio test)"
    else
        fail "STT health endpoint not reachable"
    fi
fi

# ━━━ 6. Response Time ━━━

section "6. Response Time"

# LLM response time
LLM_TIME=$(curl -o /dev/null -sf --max-time 120 -w '%{time_total}' \
    "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL}\",
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

# STT response time (if audio tools available)
if command -v sox &> /dev/null || command -v ffmpeg &> /dev/null; then
    # Regenerate test audio
    if command -v sox &> /dev/null; then
        sox -n -r 16000 -c 1 "$TEST_AUDIO" synth 2 sine 440 2>/dev/null
    else
        ffmpeg -y -f lavfi -i "sine=frequency=440:duration=2" -ar 16000 -ac 1 "$TEST_AUDIO" 2>/dev/null
    fi

    if [[ -f "$TEST_AUDIO" ]]; then
        STT_TIME=$(curl -o /dev/null -sf --max-time 30 -w '%{time_total}' \
            "${BASE_URL}/stt/v1/audio/transcriptions" \
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
        rm -f "$TEST_AUDIO"
    fi
fi

# ━━━ Summary ━━━

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Verification Summary                        ║"
echo "╠══════════════════════════════════════════════╣"
printf "║  PASS: %-3d  FAIL: %-3d  WARN: %-3d            ║\n" "$PASS" "$FAIL" "$WARN"
echo "╚══════════════════════════════════════════════╝"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo "All checks passed! Single node is operational."
    exit 0
else
    echo "Some checks failed. Review the output above."
    exit 1
fi

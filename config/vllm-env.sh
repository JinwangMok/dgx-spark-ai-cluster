#!/usr/bin/env bash
# vLLM Configuration for Gemma 4 26B-A4B MoE on DGX Spark

# Model
MODEL_ID="${MODEL_ID:-google/gemma-4-26B-A4B-it}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:gemma4-cu130}"
VLLM_PORT="${VLLM_PORT:-8000}"

# GPU Memory: 0.70 is safe for 128GB unified LPDDR5X
# Leaves ~38GB for OS + whisper + system overhead (benchmark-validated)
VLLM_GPU_MEMORY_UTILIZATION="${VLLM_GPU_MEMORY_UTILIZATION:-0.70}"

# vLLM serving flags
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:---enable-auto-tool-choice --tool-call-parser gemma4 --reasoning-parser gemma4 --load-format safetensors --enable-prefix-caching --enable-chunked-prefill --max-num-seqs 4 --max-num-batched-tokens 8192 --max-model-len 262144}"

# Model cache directory on host
MODEL_CACHE_DIR="${MODEL_CACHE_DIR:-/data/models}"

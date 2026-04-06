#!/usr/bin/env bash
# faster-whisper STT Configuration for DGX Spark

# Whisper model size
WHISPER_MODEL="${WHISPER_MODEL:-large-v3-turbo}"
WHISPER_PORT="${WHISPER_PORT:-9000}"

# Cache directory for whisper models on host
WHISPER_CACHE_DIR="${WHISPER_CACHE_DIR:-/data/models/whisper}"

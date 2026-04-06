#!/usr/bin/env bash
# Generate a small test WAV file for STT verification
#
# Requires: sox (apt install sox) or ffmpeg
#
# Generates a 2-second audio file with a sine wave tone.
# Not speech — used to verify the STT pipeline works (will return empty/noise transcription).
# For a real speech test, replace tests/test.wav with an actual speech recording.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$SCRIPT_DIR/test.wav"

if [[ -f "$OUTPUT" ]]; then
    echo "Test audio already exists: $OUTPUT"
    exit 0
fi

if command -v sox &> /dev/null; then
    echo "Generating test audio with sox..."
    sox -n -r 16000 -c 1 -b 16 "$OUTPUT" synth 2 sine 440 vol 0.5
    echo "Created: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
elif command -v ffmpeg &> /dev/null; then
    echo "Generating test audio with ffmpeg..."
    ffmpeg -f lavfi -i "sine=frequency=440:duration=2" -ar 16000 -ac 1 -y "$OUTPUT" 2>/dev/null
    echo "Created: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
else
    echo "ERROR: Neither sox nor ffmpeg found"
    echo "  Install: sudo apt install sox"
    echo "  Or:      sudo apt install ffmpeg"
    exit 1
fi

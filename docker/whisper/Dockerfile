FROM nvidia/cuda:12.8.0-cudnn-runtime-ubuntu24.04

LABEL maintainer="DGX Spark Gemma 4 Cluster"
LABEL description="faster-whisper STT server for aarch64 DGX Spark"

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Install Python and system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 \
    python3.12-venv \
    python3-pip \
    curl \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Create virtual environment
RUN python3.12 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install pinned dependencies for reproducible builds
RUN pip install --no-cache-dir \
    faster-whisper==1.1.1 \
    fastapi==0.115.0 \
    uvicorn[standard]==0.34.0 \
    python-multipart==0.0.20 \
    numpy==2.1.0

# Copy the server application
COPY server.py /app/server.py

WORKDIR /app

ENV WHISPER_MODEL=large-v3
ENV WHISPER_PORT=9000

EXPOSE 9000

CMD ["python3", "server.py"]

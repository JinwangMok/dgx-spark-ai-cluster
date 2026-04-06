"""
faster-whisper STT Server — OpenAI Whisper API compatible.
Serves on WHISPER_PORT (default 9000) with GPU acceleration.
"""

import os
import time
import tempfile
import logging
import threading
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, File, UploadFile, Form, HTTPException
from fastapi.responses import JSONResponse
import uvicorn

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("whisper-server")

ALLOWED_EXTENSIONS = {".wav", ".mp3", ".flac", ".ogg", ".m4a", ".webm", ".mp4"}
MAX_FILE_SIZE = 25 * 1024 * 1024  # 25MB

# Global model reference with thread-safe loading
model = None
_model_lock = threading.Lock()


def get_model():
    global model
    if model is None:
        with _model_lock:
            if model is None:
                from faster_whisper import WhisperModel

                model_size = os.environ.get("WHISPER_MODEL", "large-v3")
                cache_dir = os.environ.get("WHISPER_CACHE_DIR", "/data/models/whisper")
                device = "cuda"
                compute_type = "float16"

                logger.info(f"Loading whisper model: {model_size} (device={device}, compute={compute_type})")
                model = WhisperModel(
                    model_size,
                    device=device,
                    compute_type=compute_type,
                    download_root=cache_dir,
                )
                logger.info("Whisper model loaded successfully")
    return model


@asynccontextmanager
async def lifespan(app):
    """Pre-load the model on startup."""
    try:
        get_model()
    except Exception as e:
        logger.error(f"Failed to load whisper model: {e}")
        raise
    yield


app = FastAPI(title="faster-whisper STT Server", lifespan=lifespan)


@app.get("/health")
async def health():
    """Health check endpoint."""
    if model is not None:
        return {"status": "ok", "model": os.environ.get("WHISPER_MODEL", "large-v3")}
    return JSONResponse(status_code=503, content={"status": "loading"})


@app.post("/v1/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model_name: str = Form(default="whisper-1", alias="model"),
    language: str = Form(default=None),
    response_format: str = Form(default="json"),
    temperature: float = Form(default=0.0),
):
    """
    OpenAI-compatible transcription endpoint.
    Accepts audio file and returns transcription.
    """
    whisper = get_model()

    # Sanitize file extension to allowed audio types
    raw_suffix = Path(file.filename).suffix.lower() if file.filename else ".wav"
    suffix = raw_suffix if raw_suffix in ALLOWED_EXTENSIONS else ".wav"

    # Read and validate file size
    content = await file.read()
    if len(content) > MAX_FILE_SIZE:
        raise HTTPException(status_code=413, detail="File too large. Maximum 25MB.")

    # Save to temp file
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(content)
        tmp_path = tmp.name

    try:
        start_time = time.time()

        kwargs = {"beam_size": 5, "temperature": temperature}
        if language:
            kwargs["language"] = language

        segments, info = whisper.transcribe(tmp_path, **kwargs)
        text = " ".join(segment.text for segment in segments).strip()

        duration = time.time() - start_time
        logger.info(f"Transcription completed in {duration:.2f}s (lang={info.language}, prob={info.language_probability:.2f})")

        if response_format == "text":
            return text

        return {
            "text": text,
            "language": info.language,
            "duration": info.duration,
            "processing_time": round(duration, 2),
        }
    except Exception as e:
        logger.error(f"Transcription failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail="Transcription failed. Check server logs.")
    finally:
        os.unlink(tmp_path)


if __name__ == "__main__":
    port = int(os.environ.get("WHISPER_PORT", 9000))
    logger.info(f"Starting whisper server on port {port}")
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")

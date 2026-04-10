@echo off
setlocal enabledelayedexpansion

REM TPS (Tokens Per Second) Benchmark for DGX Spark (Windows)
REM
REM Usage: benchmark-tps.bat <DGX_SPARK_IP>
REM Example: benchmark-tps.bat 10.40.40.40
REM
REM Single request path: token counts and timing from the same response.
REM Validates the served model before benchmarking.

if "%~1"=="" (
    echo Usage: %~nx0 ^<DGX_SPARK_IP^>
    exit /b 1
)

set "TARGET_IP=%~1"
set "BASE_URL=http://%TARGET_IP%"

echo.
echo =========================================================
echo   DGX Spark - TPS Benchmark (Windows)
echo =========================================================
echo.
echo Target: %BASE_URL%

REM ─── Validate served model ───
echo.
echo --- Model Verification ---

curl.exe -sf --max-time 10 "%BASE_URL%/v1/models" > "%TEMP%\dgx_models.json" 2>nul
if !errorlevel! neq 0 (
    echo   [ERROR] Cannot reach %BASE_URL%/v1/models
    exit /b 1
)

for /f "delims=" %%M in ('python -c "import json;d=json.load(open(r'%TEMP%\dgx_models.json'));print(d['data'][0]['id'])" 2^>nul') do set "MODEL=%%M"
echo   Served model: !MODEL!

REM ─── Warmup ───
echo.
echo Warmup...
curl.exe -s --max-time 60 "%BASE_URL%/v1/chat/completions" -H "Content-Type: application/json" -d "{\"model\":\"!MODEL!\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":5,\"temperature\":0}" > nul 2>&1
echo Done.

REM ─── Benchmarks ───
echo.
echo --- 1. Short prompt, short output (max_tokens=16) ---
call :run_benchmark "What is 2+2? Answer with just the number." 16

echo.
echo --- 2. Short prompt, medium output (max_tokens=256) ---
call :run_benchmark "Explain quantum computing in simple terms." 256

echo.
echo --- 3. Short prompt, long output (max_tokens=1024) ---
call :run_benchmark "Write a detailed essay about the history of artificial intelligence, covering key milestones from the 1950s to 2025." 1024

echo.
echo --- 4. Medium prompt, medium output (max_tokens=512) ---
call :run_benchmark "You are an expert software engineer. Review the following approach: We are building a REST API using Python FastAPI with PostgreSQL. We need to handle 1000 concurrent users, implement JWT authentication, rate limiting, and caching. The API serves machine learning model predictions. Each prediction takes about 200ms. We want to minimize latency and maximize throughput. What architecture would you recommend?" 512

echo.
echo =========================================================
echo   Benchmark Complete
echo =========================================================
echo.
echo Note: These are single-request latency measurements.
echo       TPS under concurrent load will differ.

del "%TEMP%\dgx_models.json" 2>nul
goto :eof

REM ─── Benchmark Function (single request path) ───
:run_benchmark
set "PROMPT=%~1"
set "MAX_TOKENS=%~2"

REM Single request: curl -w for timing, response for token counts
curl.exe -s --max-time 300 -w "%%{time_total}" -o "%TEMP%\dgx_bench.json" "%BASE_URL%/v1/chat/completions" -H "Content-Type: application/json" -d "{\"model\":\"!MODEL!\",\"messages\":[{\"role\":\"user\",\"content\":\"%PROMPT%\"}],\"max_tokens\":%MAX_TOKENS%,\"temperature\":0}" > "%TEMP%\dgx_time.txt" 2>nul

if !errorlevel! neq 0 (
    echo   [ERROR] Request failed
    goto :eof
)

set /p WALL_TIME=<"%TEMP%\dgx_time.txt"

python -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    if 'error' in d:
        print(f'  [ERROR] {d[\"error\"].get(\"message\", d[\"error\"])}')
        sys.exit(1)
    u = d['usage']
    wall = float(sys.argv[2])
    comp = u['completion_tokens']
    tps = comp / wall if wall > 0 else 0
    print(f'  Prompt tokens:     {u[\"prompt_tokens\"]}')
    print(f'  Completion tokens: {comp}')
    print(f'  Wall time:         {wall:.2f} s')
    print(f'  Output TPS:        {tps:.1f} tok/s')
except Exception as e:
    print(f'  [ERROR] {e}')
" "%TEMP%\dgx_bench.json" "!WALL_TIME!"

del "%TEMP%\dgx_bench.json" 2>nul
del "%TEMP%\dgx_time.txt" 2>nul
goto :eof

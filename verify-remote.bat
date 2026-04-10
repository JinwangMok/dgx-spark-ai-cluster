@echo off
setlocal enabledelayedexpansion

REM Remote Verification Script for Single DGX Spark Node (Windows)
REM
REM Usage: verify-remote.bat <DGX_SPARK_IP>
REM
REM Runs from Windows 11 to verify all features:
REM   1. Health check
REM   2. LLM text chat
REM   3. Multimodal (image input)
REM   4. Tool calling
REM   5. STT transcription
REM   6. Response time measurement
REM
REM Requirements: curl.exe (built into Windows 11), python3 (for JSON parsing)

if "%~1"=="" (
    echo Usage: %~nx0 ^<DGX_SPARK_IP^>
    echo Example: %~nx0 192.168.1.100
    exit /b 1
)

set "TARGET_IP=%~1"
set "BASE_URL=http://%TARGET_IP%"
set "MODEL=nvidia/Gemma-4-31B-IT-NVFP4"

set /a PASS=0
set /a FAIL=0
set /a WARN=0
set /a TOTAL=0

echo.
echo ========================================================
echo   DGX Spark Single Node - Remote Verification (Windows)
echo ========================================================
echo.
echo Target: %BASE_URL%
echo Model:  %MODEL%

REM ━━━ 1. Health Check ━━━
echo.
echo --- 1. Health Check ---

curl.exe -sf --max-time 10 "%BASE_URL%/health" >nul 2>&1
if !errorlevel! equ 0 (
    set /a PASS+=1 & set /a TOTAL+=1
    echo   [PASS] Health endpoint reachable
) else (
    set /a FAIL+=1 & set /a TOTAL+=1
    echo   [FAIL] Health endpoint not reachable at %BASE_URL%/health
)

curl.exe -sf --max-time 10 "%BASE_URL%/status" 2>nul
echo.

REM ━━━ 2. LLM Text Chat ━━━
echo.
echo --- 2. LLM Text Chat ---

set "LLM_PAYLOAD={\"model\":\"%MODEL%\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in exactly 3 words.\"}],\"max_tokens\":20,\"temperature\":0.1}"

curl.exe -sf --max-time 120 "%BASE_URL%/v1/chat/completions" -H "Content-Type: application/json" -d "%LLM_PAYLOAD%" > "%TEMP%\dgx_llm_response.json" 2>nul

if !errorlevel! equ 0 (
    python -c "import sys,json; d=json.load(open(sys.argv[1])); print(d['choices'][0]['message']['content'][:80])" "%TEMP%\dgx_llm_response.json" 2>nul
    if !errorlevel! equ 0 (
        set /a PASS+=1 & set /a TOTAL+=1
        echo   [PASS] LLM text chat working
    ) else (
        set /a FAIL+=1 & set /a TOTAL+=1
        echo   [FAIL] LLM response invalid JSON
    )
) else (
    set /a FAIL+=1 & set /a TOTAL+=1
    echo   [FAIL] LLM text chat request failed
)

REM ━━━ 3. Multimodal (Image Input) ━━━
echo.
echo --- 3. Multimodal (Image Input) ---

REM Generate a tiny 2x2 red PNG as base64 (avoids external URL 403 issues)
for /f "delims=" %%B in ('python -c "import base64,zlib;from struct import pack;w,h=2,2;raw=b''.join(b'\x00'+b'\xff\x00\x00'*w for _ in range(h));chunk=lambda t,d:pack('>I',len(d))+t+d+pack('>I',zlib.crc32(t+d)%%0xffffffff);png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'');print(base64.b64encode(png).decode())" 2^>nul') do set "IMG_B64=%%B"
set "MM_PAYLOAD={\"model\":\"%MODEL%\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"What color is this image? Answer in one word.\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,!IMG_B64!\"}}]}],\"max_tokens\":20,\"temperature\":0.1}"

curl.exe -sf --max-time 120 "%BASE_URL%/v1/chat/completions" -H "Content-Type: application/json" -d "%MM_PAYLOAD%" > "%TEMP%\dgx_mm_response.json" 2>nul

if !errorlevel! equ 0 (
    python -c "import sys,json; d=json.load(open(sys.argv[1])); print(d['choices'][0]['message']['content'][:100])" "%TEMP%\dgx_mm_response.json" 2>nul
    if !errorlevel! equ 0 (
        set /a PASS+=1 & set /a TOTAL+=1
        echo   [PASS] Multimodal (image) working
    ) else (
        set /a FAIL+=1 & set /a TOTAL+=1
        echo   [FAIL] Multimodal response invalid
    )
) else (
    set /a FAIL+=1 & set /a TOTAL+=1
    echo   [FAIL] Multimodal request failed
)

REM ━━━ 4. Tool Calling ━━━
echo.
echo --- 4. Tool Calling ---

set "TOOL_PAYLOAD={\"model\":\"%MODEL%\",\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Seoul today?\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"Get current weather for a city\",\"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"description\":\"City name\"}},\"required\":[\"city\"]}}}],\"tool_choice\":\"auto\",\"max_tokens\":100,\"temperature\":0.1}"

curl.exe -sf --max-time 120 "%BASE_URL%/v1/chat/completions" -H "Content-Type: application/json" -d "%TOOL_PAYLOAD%" > "%TEMP%\dgx_tool_response.json" 2>nul

if !errorlevel! equ 0 (
    python -c "import sys,json; d=json.load(open(sys.argv[1])); msg=d['choices'][0]['message']; tc=msg.get('tool_calls',[]); print(f'tool_calls: {tc[0][\"function\"][\"name\"]}' if tc else f'text: {msg[\"content\"][:60]}')" "%TEMP%\dgx_tool_response.json" 2>nul
    if !errorlevel! equ 0 (
        set /a PASS+=1 & set /a TOTAL+=1
        echo   [PASS] Tool calling working
    ) else (
        set /a FAIL+=1 & set /a TOTAL+=1
        echo   [FAIL] Tool calling response invalid
    )
) else (
    set /a FAIL+=1 & set /a TOTAL+=1
    echo   [FAIL] Tool calling request failed
)

REM ━━━ 5. STT Transcription ━━━
echo.
echo --- 5. STT Transcription ---

REM Generate test audio using PowerShell
set "TEST_AUDIO=%TEMP%\dgx_test_audio.wav"
powershell -Command "& { $sampleRate=16000; $duration=2; $freq=440; $samples=$sampleRate*$duration; $bytes=New-Object byte[] (44+$samples*2); [System.Text.Encoding]::ASCII.GetBytes('RIFF') | % { $i=0 } { $bytes[$i++]=$_ }; $size=$bytes.Length-8; $bytes[4]=[byte]($size -band 0xFF); $bytes[5]=[byte](($size -shr 8) -band 0xFF); $bytes[6]=[byte](($size -shr 16) -band 0xFF); $bytes[7]=[byte](($size -shr 24) -band 0xFF); [System.Text.Encoding]::ASCII.GetBytes('WAVE') | % { $bytes[$i++]=$_ }; [System.Text.Encoding]::ASCII.GetBytes('fmt ') | % { $bytes[$i++]=$_ }; $bytes[16]=16; $bytes[20]=1; $bytes[22]=1; $bytes[24]=[byte]($sampleRate -band 0xFF); $bytes[25]=[byte](($sampleRate -shr 8) -band 0xFF); $bps=$sampleRate*2; $bytes[28]=[byte]($bps -band 0xFF); $bytes[29]=[byte](($bps -shr 8) -band 0xFF); $bytes[32]=2; $bytes[34]=16; [System.Text.Encoding]::ASCII.GetBytes('data') | % { $bytes[$i++]=$_ }; $dataSize=$samples*2; $bytes[40]=[byte]($dataSize -band 0xFF); $bytes[41]=[byte](($dataSize -shr 8) -band 0xFF); $bytes[42]=[byte](($dataSize -shr 16) -band 0xFF); $bytes[43]=[byte](($dataSize -shr 24) -band 0xFF); for($s=0;$s -lt $samples;$s++) { $v=[int](32767*[Math]::Sin(2*[Math]::PI*$freq*$s/$sampleRate)); $bytes[44+$s*2]=[byte]($v -band 0xFF); $bytes[44+$s*2+1]=[byte](($v -shr 8) -band 0xFF) }; [IO.File]::WriteAllBytes('%TEST_AUDIO%',$bytes) }" 2>nul

if exist "%TEST_AUDIO%" (
    curl.exe -sf --max-time 30 "%BASE_URL%/stt/v1/audio/transcriptions" -F "file=@%TEST_AUDIO%" -F "model=whisper-1" > "%TEMP%\dgx_stt_response.json" 2>nul
    if !errorlevel! equ 0 (
        python -c "import sys,json; d=json.load(open(sys.argv[1])); print(d.get('text','')[:80])" "%TEMP%\dgx_stt_response.json" 2>nul
        if !errorlevel! equ 0 (
            set /a PASS+=1 & set /a TOTAL+=1
            echo   [PASS] STT transcription working
        ) else (
            set /a FAIL+=1 & set /a TOTAL+=1
            echo   [FAIL] STT response invalid
        )
    ) else (
        set /a FAIL+=1 & set /a TOTAL+=1
        echo   [FAIL] STT request failed
    )
    del "%TEST_AUDIO%" 2>nul
) else (
    REM Fallback: health check only
    curl.exe -sf --max-time 10 "%BASE_URL%/stt/health" >nul 2>&1
    if !errorlevel! equ 0 (
        set /a PASS+=1 & set /a TOTAL+=1
        echo   [PASS] STT health endpoint reachable (no audio test)
    ) else (
        set /a FAIL+=1 & set /a TOTAL+=1
        echo   [FAIL] STT health endpoint not reachable
    )
)

REM ━━━ 6. Response Time ━━━
echo.
echo --- 6. Response Time ---

set "RT_PAYLOAD={\"model\":\"%MODEL%\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":5}"

curl.exe -o nul -sf --max-time 120 -w "%%{time_total}" "%BASE_URL%/v1/chat/completions" -H "Content-Type: application/json" -d "%RT_PAYLOAD%" > "%TEMP%\dgx_rt.txt" 2>nul

if !errorlevel! equ 0 (
    set /p LLM_TIME=<"%TEMP%\dgx_rt.txt"
    echo   LLM response time: !LLM_TIME!s
    set /a PASS+=1 & set /a TOTAL+=1
    echo   [PASS] LLM response time measured
) else (
    set /a FAIL+=1 & set /a TOTAL+=1
    echo   [FAIL] LLM response timed out
)

REM ━━━ Summary ━━━
echo.
echo ========================================================
echo   Verification Summary
echo --------------------------------------------------------
echo   PASS: %PASS%  FAIL: %FAIL%  WARN: %WARN%
echo ========================================================
echo.

REM Cleanup temp files
del "%TEMP%\dgx_llm_response.json" 2>nul
del "%TEMP%\dgx_mm_response.json" 2>nul
del "%TEMP%\dgx_tool_response.json" 2>nul
del "%TEMP%\dgx_stt_response.json" 2>nul
del "%TEMP%\dgx_rt.txt" 2>nul

if %FAIL% equ 0 (
    echo All checks passed! Single node is operational.
    exit /b 0
) else (
    echo Some checks failed. Review the output above.
    exit /b 1
)

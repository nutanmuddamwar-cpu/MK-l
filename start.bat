@echo off
setlocal EnableDelayedExpansion

title M2X Compute ^& Tool Exchange — Launcher
color 0B

echo.
echo  =====================================================
echo   M2X Compute ^& Tool Exchange  —  Starting up...
echo  =====================================================
echo.

:: ── Locate project root (same directory as this bat file) ──────────────────
set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
set "BACKEND=%ROOT%\backend"
set "VENV=%ROOT%\.venv"
set "ENV_FILE=%ROOT%\.env"

:: ── Copy .env from example if .env does not exist ──────────────────────────
if not exist "%ENV_FILE%" (
    if exist "%ROOT%\.env.example" (
        echo  [INFO] .env not found — copying from .env.example
        copy /Y "%ROOT%\.env.example" "%ENV_FILE%" >nul
    )
)

:: ── Find Python ────────────────────────────────────────────────────────────
set "PYTHON="
set "USE_UV=0"

:: Try uv first (fastest)
where uv >nul 2>&1
if !errorlevel! == 0 (
    set "USE_UV=1"
    echo  [OK]  uv found — using uv for environment management
    goto :env_ready
)

:: Check PATH for python / python3 / py launcher
for %%P in (python3 python py) do (
    where %%P >nul 2>&1
    if !errorlevel! == 0 (
        set "PYTHON=%%P"
        goto :found_python
    )
)

:: Check common install locations
for %%D in (
    "%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
    "%LOCALAPPDATA%\Programs\Python\Python311\python.exe"
    "%LOCALAPPDATA%\Programs\Python\Python310\python.exe"
    "%LOCALAPPDATA%\Programs\Python\Launcher\py.exe"
    "C:\Python312\python.exe"
    "C:\Python311\python.exe"
    "C:\Python310\python.exe"
) do (
    if exist %%D (
        set "PYTHON=%%~D"
        goto :found_python
    )
)

echo  [ERROR] Python 3.10+ not found.
echo.
echo  Please install Python from https://www.python.org/downloads/
echo  Make sure to tick "Add Python to PATH" during installation.
echo.
pause
exit /b 1

:found_python
echo  [OK]  Python launcher found: %PYTHON%

:env_ready

:: ── Create / activate virtual environment ──────────────────────────────────
if "%USE_UV%"=="1" (
    if not exist "%VENV%" (
        echo  [INFO] Creating virtual environment with uv...
        uv venv "%VENV%" --python 3.11 2>nul || uv venv "%VENV%"
    )
    set "PY=%VENV%\Scripts\python.exe"
) else (
    if not exist "%VENV%" (
        echo  [INFO] Creating virtual environment...
        "%PYTHON%" -m venv "%VENV%"
    )
    set "PY=%VENV%\Scripts\python.exe"
)

:: ── Install / upgrade dependencies ─────────────────────────────────────────
echo  [INFO] Checking dependencies...

if "%USE_UV%"=="1" (
    uv pip install --quiet --python "%PY%" -r "%BACKEND%\requirements.txt" 2>nul
) else (
    "%PY%" -m pip install --quiet --upgrade pip >nul 2>&1
    "%PY%" -m pip install --quiet -r "%BACKEND%\requirements.txt" 2>nul
)

if !errorlevel! neq 0 (
    echo  [WARN] Installing core dependencies...
    if "%USE_UV%"=="1" (
        uv pip install --python "%PY%" fastapi uvicorn pydantic pydantic-settings SQLAlchemy PyJWT httpx python-multipart
    ) else (
        "%PY%" -m pip install fastapi uvicorn pydantic pydantic-settings SQLAlchemy PyJWT httpx python-multipart
    )
)

:: Install AlgoKit / Algorand SDK utils
if "%USE_UV%"=="1" (
    uv pip install --quiet --python "%PY%" py-algorand-sdk algokit-utils 2>nul
) else (
    "%PY%" -m pip install --quiet py-algorand-sdk algokit-utils 2>nul
)

echo  [OK]  Dependencies ready.
echo.

:: ── Check if port 8000 is free ─────────────────────────────────────────────
netstat -ano | findstr ":8000 " | findstr "LISTENING" >nul 2>&1
if !errorlevel! == 0 (
    echo  [WARN] Port 8000 is already in use.
    echo         Using existing server instance.
    goto :open_browser
)

:: ── Start the FastAPI server in a new window ───────────────────────────────
echo  [INFO] Starting M2X API server on http://localhost:8000 ...
echo.

start "M2X API Server" /D "%BACKEND%" cmd /k "^
color 0A ^& ^
echo  M2X API Server — running on http://localhost:8000 ^& ^
echo  Press Ctrl+C to stop. ^& ^
echo. ^& ^
\"%PY%\" -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload"

:: ── Wait for server to become ready ────────────────────────────────────────
echo  [INFO] Waiting for server to be ready...
set "READY=0"
set "TRIES=0"

:wait_loop
timeout /t 2 /nobreak >nul
set /a TRIES+=1

curl -s -o nul -w "%%{http_code}" http://localhost:8000/health 2>nul | findstr "200" >nul 2>&1
if !errorlevel! == 0 (
    set "READY=1"
    goto :server_ready
)

powershell -NoProfile -Command "try{$r=(Invoke-WebRequest -Uri 'http://localhost:8000/health' -UseBasicParsing -TimeoutSec 2).StatusCode;if($r -eq 200){exit 0}else{exit 1}}catch{exit 1}" >nul 2>&1
if !errorlevel! == 0 (
    set "READY=1"
    goto :server_ready
)

if !TRIES! lss 15 goto :wait_loop

echo  [WARN] Server health check timed out — opening browser anyway.

:server_ready
if "!READY!"=="1" echo  [OK]  Server is ready^^!

:open_browser
echo.
echo  =====================================================
echo   Opening dashboard: http://localhost:8000/dashboard
echo  =====================================================
echo.

:: Open dashboard in default web browser
start "" "http://localhost:8000/dashboard"

echo  [OK]  Browser launched.
echo.
echo  Dashboard :  http://localhost:8000/dashboard
echo  API Docs  :  http://localhost:8000/docs
echo  ReDoc     :  http://localhost:8000/redoc
echo  Health    :  http://localhost:8000/health
echo  AlgoKit   :  http://localhost:8000/v1/algokit/status
echo  VibeKit   :  http://localhost:8000/v1/vibekit/info
echo.
echo  Keep the "M2X API Server" console window open while using the app.
echo.
pause
endlocal

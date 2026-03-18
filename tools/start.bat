@echo off
chcp 65001 >nul
:: ============================================================
::  Music On 서버 시작 스크립트 (Windows)
::  사용법: tools\start.bat 더블클릭 또는 터미널에서 실행
:: ============================================================

echo.
echo   Music On 서버 시작 스크립트
echo ==============================

:: ── 1. Python 확인 ─────────────────────────────────────
python --version >nul 2>&1
if errorlevel 1 (
    echo [오류] Python이 설치되지 않았습니다.
    echo.
    echo   아래 주소에서 Python 3.x 설치 후 다시 실행하세요:
    echo   https://www.python.org/downloads/
    echo   (설치 시 "Add Python to PATH" 체크 필수)
    echo.
    pause
    exit /b 1
)
for /f "tokens=*" %%v in ('python --version') do echo [OK] %%v

:: ── 2. yt-dlp 설치 / 업데이트 ──────────────────────────
echo [->] yt-dlp 설치 확인 중...
python -m pip install -q --upgrade yt-dlp
if errorlevel 1 (
    echo [오류] yt-dlp 설치 실패. pip 상태를 확인하세요.
    pause
    exit /b 1
)
echo [OK] yt-dlp 준비 완료

:: ── 3. ffmpeg 확인 및 자동 설치 ────────────────────────
ffmpeg -version >nul 2>&1
if errorlevel 1 (
    echo.
    echo [!] ffmpeg가 없습니다. 자동 설치를 시도합니다...

    :: 방법 1: winget 시도
    winget install --id Gyan.FFmpeg -e --silent >nul 2>&1
    if not errorlevel 1 (
        echo [OK] winget으로 ffmpeg 설치 완료
        :: winget 설치 후 PATH 갱신 (PowerShell로 시스템 PATH 읽기)
        for /f "usebackq tokens=*" %%p in (`powershell -noprofile -command "[Environment]::GetEnvironmentVariable('PATH','Machine')"`) do set PATH=%%p;%PATH%
        goto :ffmpeg_done
    )

    :: 방법 2: PowerShell로 직접 다운로드
    echo [->] winget 실패, ffmpeg를 직접 다운로드합니다...
    set FFMPEG_DIR=%LOCALAPPDATA%\music_on\ffmpeg
    powershell -noprofile -command ^
        "$url='https://github.com/GyanD/codexffmpeg/releases/download/7.1/ffmpeg-7.1-essentials_build.zip';" ^
        "$zip='%TEMP%\ffmpeg.zip';" ^
        "Write-Host '[->] 다운로드 중 (약 80MB)...';" ^
        "Invoke-WebRequest $url -OutFile $zip -UseBasicParsing;" ^
        "Expand-Archive $zip -DestinationPath '%LOCALAPPDATA%\music_on' -Force;" ^
        "Rename-Item '%LOCALAPPDATA%\music_on\ffmpeg-7.1-essentials_build' '%LOCALAPPDATA%\music_on\ffmpeg' -ErrorAction SilentlyContinue;" ^
        "Write-Host '[OK] 다운로드 완료'"
    if exist "%FFMPEG_DIR%\bin\ffmpeg.exe" (
        set PATH=%FFMPEG_DIR%\bin;%PATH%
        echo [OK] ffmpeg 설치 완료: %FFMPEG_DIR%\bin
        goto :ffmpeg_done
    )

    :: 두 방법 모두 실패
    echo.
    echo [!] ffmpeg 자동 설치에 실패했습니다.
    echo     수동 설치: https://www.gyan.dev/ffmpeg/builds/
    echo     설치 후 bin 폴더를 PATH에 추가하고 다시 실행하세요.
    echo.
    echo     서버는 실행되지만 음악 다운로드가 동작하지 않을 수 있습니다.
    echo.
    pause
)
:ffmpeg_done
ffmpeg -version >nul 2>&1
if not errorlevel 1 (
    echo [OK] ffmpeg 준비 완료
)

:: ── 4. 서버 시작 ───────────────────────────────────────
echo.
echo ==============================
set MUSIC_ON_NO_BROWSER=1

:: 브라우저 자동 오픈 (1초 후)
start "" /b cmd /c "timeout /t 1 >nul && start http://localhost:8888"

:: 현재 스크립트 위치 기준으로 server.py 실행
set SCRIPT_DIR=%~dp0
python "%SCRIPT_DIR%server.py"

pause

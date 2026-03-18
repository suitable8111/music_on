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

:: ── 3. ffmpeg 확인 ─────────────────────────────────────
ffmpeg -version >nul 2>&1
if errorlevel 1 (
    echo.
    echo [!] ffmpeg가 설치되지 않았습니다.
    echo.
    echo   방법 1 - winget (Windows 11 권장):
    echo     winget install ffmpeg
    echo.
    echo   방법 2 - 수동 설치:
    echo     https://www.gyan.dev/ffmpeg/builds/ 에서 다운로드
    echo     압축 해제 후 bin 폴더를 시스템 PATH에 추가
    echo.
    echo   ffmpeg 설치 후 이 스크립트를 다시 실행하세요.
    echo.
    pause
    exit /b 1
)
echo [OK] ffmpeg 준비 완료

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

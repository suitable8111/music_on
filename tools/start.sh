#!/usr/bin/env bash
# ============================================================
#  Music On 서버 시작 스크립트 (Mac / Linux)
#  사용법: bash tools/start.sh
# ============================================================
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

OS="$(uname -s)"

echo ""
echo "  🎵 Music On 서버 시작 스크립트"
echo "=============================="

# ── 1. Python 확인 ──────────────────────────────────────
if command -v python3 &>/dev/null; then
    PYTHON=python3
elif command -v python &>/dev/null; then
    PYTHON=python
else
    echo -e "${RED}[오류] Python이 설치되지 않았습니다.${NC}"
    echo "  Mac:   brew install python"
    echo "  Linux: sudo apt install python3"
    exit 1
fi
echo -e "${GREEN}[✓] Python: $($PYTHON --version)${NC}"

# ── 2. yt-dlp 설치 / 업데이트 ───────────────────────────
echo -e "${YELLOW}[→] yt-dlp 설치 확인 중...${NC}"

if [ "$OS" = "Darwin" ]; then
    # Mac: Homebrew로 설치 (pip은 externally-managed-environment 오류 발생)
    if ! command -v brew &>/dev/null; then
        echo -e "${RED}[오류] Homebrew가 필요합니다: https://brew.sh${NC}"
        exit 1
    fi
    brew install yt-dlp --quiet 2>/dev/null || brew upgrade yt-dlp --quiet 2>/dev/null || true
else
    # Linux: pip 사용 (시스템 관리 환경이면 --break-system-packages 추가)
    if $PYTHON -m pip install -q --upgrade yt-dlp 2>/dev/null; then
        : # 성공
    else
        $PYTHON -m pip install -q --upgrade --break-system-packages yt-dlp
    fi
fi

if command -v yt-dlp &>/dev/null; then
    echo -e "${GREEN}[✓] yt-dlp: $(yt-dlp --version)${NC}"
else
    echo -e "${RED}[오류] yt-dlp 설치 실패${NC}"
    exit 1
fi

# ── 3. ffmpeg 확인 ──────────────────────────────────────
if ! command -v ffmpeg &>/dev/null; then
    echo -e "${YELLOW}[!] ffmpeg가 없습니다. 설치 중...${NC}"
    if [ "$OS" = "Darwin" ]; then
        brew install ffmpeg
    elif command -v apt-get &>/dev/null; then
        sudo apt-get install -y ffmpeg
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y ffmpeg
    elif command -v yum &>/dev/null; then
        sudo yum install -y ffmpeg
    else
        echo -e "${RED}[오류] ffmpeg를 수동으로 설치하세요: https://ffmpeg.org${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}[✓] ffmpeg: $(ffmpeg -version 2>&1 | head -1 | cut -d' ' -f1-3)${NC}"

# ── 4. 서버 시작 ─────────────────────────────────────────
echo ""
echo "=============================="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MUSIC_ON_NO_BROWSER=1

# 브라우저 자동 오픈 (백그라운드, 1초 후)
(sleep 1 && open "http://localhost:8888" 2>/dev/null || xdg-open "http://localhost:8888" 2>/dev/null || true) &

$PYTHON "$SCRIPT_DIR/server.py"

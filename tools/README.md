# Music On 서버

YouTube 오디오를 mp3로 변환해 Music On 앱에 서빙하는 로컬 서버입니다.

---

## 빠른 시작

### Mac / Linux
```bash
bash tools/start.sh
```

### Windows
`tools\start.bat` 더블클릭 또는 터미널에서:
```bat
tools\start.bat
```

> 스크립트가 `yt-dlp`, `ffmpeg` 등 필요한 도구를 자동으로 설치합니다.

---

## 수동 설치

### 공통 요구사항
- **Python 3.8+** — [python.org](https://www.python.org/downloads/)
- **yt-dlp** — YouTube 다운로더
- **ffmpeg** — mp3 변환 엔진

### Mac
```bash
# Homebrew가 없으면 먼저 설치: https://brew.sh
brew install yt-dlp ffmpeg
python3 tools/server.py
```

### Linux (Ubuntu / Debian)
```bash
sudo apt install ffmpeg python3-pip
pip3 install yt-dlp
python3 tools/server.py
```

### Linux (Fedora / RHEL)
```bash
sudo dnf install ffmpeg python3-pip
pip3 install yt-dlp
python3 tools/server.py
```

### Windows
```bat
# Python PATH 등록 후 PowerShell 관리자 권한에서:
winget install ffmpeg
pip install yt-dlp
python tools\server.py
```

---

## 앱 연결

서버 시작 후 터미널에 출력되는 주소를 앱 설정에 입력하세요.

```
📱 앱 설정에 입력할 주소:
   http://192.168.0.xx:8888
```

- **포트 기본값**: `8888`
- 서버 PC와 휴대폰이 **같은 Wi-Fi**에 있어야 합니다.
- 방화벽에서 8888 포트가 차단되어 있으면 허용 필요

---

## 대시보드

서버 시작 시 브라우저가 자동으로 열립니다.
수동으로 열려면: **[http://localhost:8888](http://localhost:8888)**

대시보드에서 확인할 수 있는 정보:
| 항목 | 설명 |
|------|------|
| 서버 주소 | 앱에 입력할 IP:PORT |
| 캐시된 곡 수 | 로컬에 저장된 mp3 개수 |
| 캐시 용량 | 디스크 사용량 (MB) |
| 업타임 | 서버 실행 시간 |
| 다운로드 기록 | 최근 50건 다운로드 로그 |
| 진행 중 | 현재 다운로드 중인 곡 수 |

---

## API 엔드포인트

| 경로 | 설명 |
|------|------|
| `GET /` | 대시보드 HTML |
| `GET /ping` | 서버 상태 확인 → `pong` |
| `GET /audio?id=VIDEO_ID` | mp3 스트리밍 (없으면 자동 다운로드) |
| `GET /list` | 캐시된 video ID 목록 (JSON) |
| `GET /status` | 서버 상태 JSON (대시보드용) |

---

## 캐시 위치

| OS | 경로 |
|----|------|
| Mac / Linux | `~/.music_on_cache/` |
| Windows | `C:\Users\유저명\.music_on_cache\` |

---

## 문제 해결

**`yt-dlp: command not found`**
→ `pip install yt-dlp` 후 터미널 재시작

**`ffmpeg: command not found`**
→ Mac: `brew install ffmpeg` / Windows: `winget install ffmpeg`

**앱에서 서버 연결 안 됨**
→ 같은 Wi-Fi 확인 → 방화벽 8888 포트 허용 → 서버 터미널의 IP 주소 재확인

**다운로드 실패 (500 오류)**
→ `yt-dlp --update` 로 업데이트 (YouTube 정책 변경 대응)

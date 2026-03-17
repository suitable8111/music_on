#!/usr/bin/env python3
"""
Music On 로컬 서버
yt-dlp로 YouTube 오디오를 mp3로 변환해 앱에 서빙합니다.

사용법:
  pip3 install yt-dlp
  brew install ffmpeg   (mp3 변환에 필요)
  python3 tools/server.py

앱 설정에서 서버 주소: http://<맥IP>:8888
  맥 IP 확인: ifconfig | grep "inet " | grep -v 127.0.0.1
"""

import http.server
import subprocess
import os
import urllib.parse
import threading
from pathlib import Path

PORT = 8888
CACHE_DIR = Path.home() / '.music_on_cache'
CACHE_DIR.mkdir(exist_ok=True)

# 중복 다운로드 방지용 락
_locks: dict = {}
_locks_mutex = threading.Lock()

def get_lock(video_id: str) -> threading.Lock:
    with _locks_mutex:
        if video_id not in _locks:
            _locks[video_id] = threading.Lock()
        return _locks[video_id]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if parsed.path == '/audio' and 'id' in params:
            video_id = params['id'][0]
            self._serve_audio(video_id)
        elif parsed.path == '/ping':
            self._respond(200, b'pong', 'text/plain')
        elif parsed.path == '/list':
            self._serve_list()
        else:
            self._respond(404, b'Not found', 'text/plain')

    def _serve_audio(self, video_id: str):
        mp3_path = CACHE_DIR / f'{video_id}.mp3'

        # 아직 캐시 없으면 다운로드 (같은 곡 동시 요청 방지)
        lock = get_lock(video_id)
        with lock:
            if not mp3_path.exists():
                print(f'[↓] 다운로드 중: {video_id}')
                result = subprocess.run([
                    'yt-dlp',
                    '-x',
                    '--audio-format', 'mp3',
                    '--audio-quality', '0',
                    '--no-playlist',
                    '-o', str(CACHE_DIR / '%(id)s.%(ext)s'),
                    f'https://www.youtube.com/watch?v={video_id}'
                ], capture_output=True, text=True)

                if result.returncode != 0:
                    print(f'[!] yt-dlp 오류: {result.stderr}')
                    self._respond(500, result.stderr.encode(), 'text/plain')
                    return
                print(f'[✓] 완료: {video_id}')

        if not mp3_path.exists():
            self._respond(500, b'Conversion failed', 'text/plain')
            return

        file_size = mp3_path.stat().st_size
        self.send_response(200)
        self.send_header('Content-Type', 'audio/mpeg')
        self.send_header('Content-Length', str(file_size))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        with open(mp3_path, 'rb') as f:
            self.wfile.write(f.read())

    def _serve_list(self):
        import json
        ids = [f.stem for f in CACHE_DIR.glob('*.mp3')]
        body = json.dumps(ids).encode()
        self._respond(200, body, 'application/json')

    def _respond(self, code, body, content_type):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f'[서버] {args[0]} → {args[1]}')


if __name__ == '__main__':
    import socket
    hostname = socket.gethostname()
    local_ip = socket.gethostbyname(hostname)

    print('=' * 50)
    print(f'  Music On 서버 시작 (포트 {PORT})')
    print(f'  캐시 폴더: {CACHE_DIR}')
    print()
    print(f'  앱 설정에 입력할 주소:')
    print(f'  http://{local_ip}:{PORT}')
    print('=' * 50)

    server = http.server.ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n서버 종료')

#!/usr/bin/env python3
"""
Music On 로컬 서버
yt-dlp로 YouTube 오디오를 mp3로 변환해 앱에 서빙합니다.

사용법:
  python3 tools/server.py        (Mac/Linux)
  tools\\start.bat               (Windows)

앱 설정에서 서버 주소: http://<서버IP>:8888
"""

import http.server
import subprocess
import shutil
import os
import sys
import json
import time
import urllib.parse
import threading
from pathlib import Path
from datetime import datetime

PORT = 8888
CACHE_DIR = Path.home() / '.music_on_cache'
CACHE_DIR.mkdir(exist_ok=True)

_start_time = time.time()
_local_ip = '127.0.0.1'

# 중복 다운로드 방지용 락
_locks: dict = {}
_locks_mutex = threading.Lock()

# 최근 다운로드 로그 (최대 50개)
_download_log: list = []
_log_lock = threading.Lock()

# 현재 진행 중인 다운로드 목록
_active_downloads: set = set()
_active_lock = threading.Lock()

# 접속자 IP 기록
_visitors: dict = {}  # {ip: {count, first_seen, last_seen, last_path}}
_visitors_lock = threading.Lock()


def get_lock(video_id: str) -> threading.Lock:
    with _locks_mutex:
        if video_id not in _locks:
            _locks[video_id] = threading.Lock()
        return _locks[video_id]


def add_log(video_id: str, status: str):
    entry = {'id': video_id, 'status': status, 'time': datetime.now().strftime('%H:%M:%S')}
    with _log_lock:
        _download_log.insert(0, entry)
        if len(_download_log) > 50:
            _download_log.pop()


def record_visitor(ip: str, path: str):
    now = datetime.now().strftime('%H:%M:%S')
    with _visitors_lock:
        if ip in _visitors:
            _visitors[ip]['count'] += 1
            _visitors[ip]['last_seen'] = now
            _visitors[ip]['last_path'] = path
        else:
            _visitors[ip] = {'count': 1, 'first_seen': now, 'last_seen': now, 'last_path': path}


def json_response(data: dict) -> bytes:
    return json.dumps(data, ensure_ascii=False).encode()


DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Music On 서버 대시보드</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: #121212; color: #e0e0e0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; padding: 24px; max-width: 960px; margin: 0 auto; }
  h1 { font-size: 22px; font-weight: 700; margin-bottom: 4px; }
  h1 span { color: #BB86FC; }
  .subtitle { color: #888; font-size: 13px; margin-bottom: 28px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 16px; margin-bottom: 28px; }
  .card { background: #1e1e1e; border-radius: 12px; padding: 20px; }
  .card-label { font-size: 12px; color: #888; margin-bottom: 6px; text-transform: uppercase; letter-spacing: 0.5px; }
  .card-value { font-size: 28px; font-weight: 700; color: #BB86FC; }
  .card-unit { font-size: 13px; color: #888; margin-left: 4px; }
  .status-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: #4CAF50; margin-right: 6px; animation: pulse 2s infinite; }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }
  .section-title { font-size: 15px; font-weight: 600; margin-bottom: 12px; color: #ccc; display: flex; align-items: center; gap: 8px; }
  table { width: 100%; border-collapse: collapse; background: #1e1e1e; border-radius: 12px; overflow: hidden; margin-bottom: 28px; }
  th { background: #2a2a2a; padding: 10px 16px; text-align: left; font-size: 12px; color: #888; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; }
  td { padding: 10px 16px; font-size: 13px; border-top: 1px solid #2a2a2a; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; }
  .badge-done { background: #1b5e20; color: #69f0ae; }
  .badge-active { background: #4a148c; color: #ea80fc; }
  .badge-error { background: #b71c1c; color: #ff8a80; }
  .ip-box { background: #1e1e1e; border-radius: 12px; padding: 16px 20px; display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 28px; }
  .ip-addr { font-size: 20px; font-weight: 700; color: #BB86FC; font-family: monospace; }
  .ip-label { font-size: 12px; color: #888; margin-bottom: 4px; }
  .refresh-info { font-size: 11px; color: #555; text-align: right; margin-top: -20px; margin-bottom: 24px; }
  .empty { color: #555; font-size: 13px; text-align: center; padding: 24px; }

  /* 설정 패널 */
  .settings-panel { background: #1e1e1e; border-radius: 12px; padding: 20px; margin-bottom: 28px; display: grid; gap: 16px; }
  .setting-row { display: flex; flex-direction: column; gap: 8px; }
  .setting-label { font-size: 12px; color: #888; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; }
  .setting-control { display: flex; gap: 8px; align-items: center; }
  input[type=text] { flex: 1; background: #2a2a2a; border: none; border-radius: 8px; padding: 10px 14px; color: #e0e0e0; font-size: 13px; font-family: monospace; outline: none; }
  input[type=text]::placeholder { color: #555; }
  input[type=text]:focus { box-shadow: 0 0 0 2px #BB86FC44; }
  button { padding: 9px 18px; border: none; border-radius: 8px; font-size: 13px; font-weight: 600; cursor: pointer; transition: opacity 0.15s; white-space: nowrap; }
  button:hover { opacity: 0.85; }
  button:disabled { opacity: 0.4; cursor: default; }
  .btn-danger { background: #cf6679; color: #fff; }
  .btn-primary { background: #BB86FC; color: #121212; }
  .btn-secondary { background: #3a3a3a; color: #e0e0e0; }
  .toast { position: fixed; bottom: 24px; right: 24px; background: #2a2a2a; border-radius: 10px; padding: 12px 20px; font-size: 13px; box-shadow: 0 4px 20px rgba(0,0,0,0.5); transform: translateY(80px); opacity: 0; transition: all 0.3s; z-index: 999; }
  .toast.show { transform: translateY(0); opacity: 1; }
  .toast.ok { border-left: 3px solid #69f0ae; }
  .toast.err { border-left: 3px solid #ff8a80; }
  .divider { border: none; border-top: 1px solid #2a2a2a; margin: 4px 0; }
</style>
</head>
<body>
<h1><span>Music On</span> 서버 대시보드</h1>
<p class="subtitle"><span class="status-dot"></span>서버 실행 중</p>

<div class="ip-box">
  <div>
    <div class="ip-label">앱에 입력할 서버 주소</div>
    <div class="ip-addr" id="ip-addr">불러오는 중...</div>
  </div>
  <div style="display:flex;gap:8px">
    <button class="btn-secondary" onclick="copyIp()">복사</button>
    <button class="btn-secondary" id="restart-btn" onclick="restartServer()">재시작</button>
    <button class="btn-danger" id="shutdown-btn" onclick="shutdownServer()">종료</button>
  </div>
</div>

<div class="grid">
  <div class="card"><div class="card-label">캐시된 곡</div><div><span class="card-value" id="cache-count">-</span><span class="card-unit">곡</span></div></div>
  <div class="card"><div class="card-label">캐시 용량</div><div><span class="card-value" id="cache-size">-</span><span class="card-unit">MB</span></div></div>
  <div class="card"><div class="card-label">업타임</div><div><span class="card-value" id="uptime">-</span></div></div>
  <div class="card"><div class="card-label">진행 중</div><div><span class="card-value" id="active-count">-</span><span class="card-unit">건</span></div></div>
  <div class="card"><div class="card-label">접속자</div><div><span class="card-value" id="visitor-count">-</span><span class="card-unit">명</span></div></div>
</div>

<p class="refresh-info" id="refresh-info">새로고침 중...</p>

<!-- ── 설정 패널 ──────────────────────────── -->
<div class="section-title">⚙️ 설정</div>
<div class="settings-panel">

  <!-- 1. 캐시 지우기 -->
  <div class="setting-row">
    <div class="setting-label">캐시 지우기</div>
    <div class="setting-control">
      <span style="font-size:13px;color:#888;flex:1">캐시 폴더의 모든 mp3 파일을 삭제합니다.</span>
      <button class="btn-danger" onclick="clearCache()">캐시 지우기</button>
    </div>
  </div>

  <hr class="divider">

  <!-- 2. 백업 -->
  <div class="setting-row">
    <div class="setting-label">캐시 백업</div>
    <div class="setting-control">
      <input type="text" id="backup-path" placeholder="/Users/이름/Desktop/music_backup">
      <button class="btn-primary" onclick="doBackup()">백업</button>
    </div>
  </div>

  <!-- 3. 백업 불러오기 -->
  <div class="setting-row">
    <div class="setting-label">백업 불러오기</div>
    <div class="setting-control">
      <input type="text" id="restore-path" placeholder="/Users/이름/Desktop/music_backup">
      <button class="btn-secondary" onclick="doRestore()">불러오기</button>
    </div>
  </div>

</div>

<!-- ── 접속자 IP 기록 ─────────────────────── -->
<div class="section-title">🌐 접속자 IP 기록</div>
<table>
  <thead><tr><th>IP 주소</th><th>최초 접속</th><th>최근 접속</th><th>최근 경로</th><th>요청 수</th></tr></thead>
  <tbody id="visitors-body"><tr><td colspan="5" class="empty">접속 기록 없음</td></tr></tbody>
</table>

<!-- ── 다운로드 기록 ──────────────────────── -->
<div class="section-title">📥 최근 다운로드 기록</div>
<table>
  <thead><tr><th>시간</th><th>Video ID</th><th>상태</th></tr></thead>
  <tbody id="log-body"><tr><td colspan="3" class="empty">기록 없음</td></tr></tbody>
</table>

<!-- ── 캐시된 곡 목록 ─────────────────────── -->
<div class="section-title">🎵 캐시된 곡 목록</div>
<table>
  <thead><tr><th>#</th><th>Video ID</th><th>크기</th></tr></thead>
  <tbody id="song-body"><tr><td colspan="3" class="empty">로딩 중...</td></tr></tbody>
</table>

<div class="toast" id="toast"></div>

<script>
let _ipAddr = '';

function showToast(msg, ok=true) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'toast show ' + (ok ? 'ok' : 'err');
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.className = 'toast', 3000);
}

function copyIp() {
  navigator.clipboard.writeText(_ipAddr).then(() => showToast('주소가 복사됐습니다'));
}

async function shutdownServer() {
  if (!confirm('서버를 종료할까요?\n종료 후에는 앱에서 새 곡을 받을 수 없습니다.')) return;
  const btn = document.getElementById('shutdown-btn');
  btn.disabled = true;
  btn.textContent = '종료 중...';
  try { await fetch('/shutdown', {method:'POST'}); } catch(_) {}
  document.querySelector('.status-dot').style.background = '#888';
  document.querySelector('.status-dot').style.animation = 'none';
  document.querySelector('.subtitle').innerHTML = '⬛ 서버가 종료됐습니다';
  document.getElementById('refresh-info').textContent = '서버 오프라인';
  showToast('서버가 종료됐습니다', false);
}

async function restartServer() {
  if (!confirm('서버를 재시작할까요?\n잠시 연결이 끊어진 후 자동으로 다시 연결됩니다.')) return;
  const btn = document.getElementById('restart-btn');
  btn.disabled = true;
  btn.textContent = '재시작 중...';
  try {
    await fetch('/restart', {method:'POST'});
  } catch(_) {}

  // 서버가 내려간 동안 ping 폴링으로 재연결 감지
  showToast('재시작 중... 잠시 기다려주세요', true);
  document.getElementById('refresh-info').textContent = '⏳ 서버 재시작 대기 중...';

  let attempts = 0;
  const poll = setInterval(async () => {
    attempts++;
    try {
      const r = await fetch('/ping');
      if (r.ok) {
        clearInterval(poll);
        btn.disabled = false;
        btn.textContent = '재시작';
        showToast('✓ 서버가 재시작됐습니다');
        refresh();
      }
    } catch(_) {
      if (attempts > 30) {
        clearInterval(poll);
        btn.disabled = false;
        btn.textContent = '재시작';
        showToast('서버 응답 없음 — 수동으로 확인하세요', false);
      }
    }
  }, 500);
}

async function clearCache() {
  if (!confirm('캐시된 모든 mp3 파일을 삭제할까요?\n이 작업은 되돌릴 수 없습니다.')) return;
  const r = await fetch('/cache/clear', {method:'POST'});
  const d = await r.json();
  showToast(d.message, r.ok);
  refresh();
}

async function doBackup() {
  const dest = document.getElementById('backup-path').value.trim();
  if (!dest) { showToast('백업 경로를 입력하세요', false); return; }
  const r = await fetch('/backup', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({dest})});
  const d = await r.json();
  showToast(d.message, r.ok);
}

async function doRestore() {
  const src = document.getElementById('restore-path').value.trim();
  if (!src) { showToast('백업 경로를 입력하세요', false); return; }
  if (!confirm(src + '\n\n위 경로에서 mp3 파일을 가져올까요?')) return;
  const r = await fetch('/restore', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({src})});
  const d = await r.json();
  showToast(d.message, r.ok);
  refresh();
}

function fmtUptime(sec) {
  const h = Math.floor(sec/3600), m = Math.floor((sec%3600)/60), s = sec%60;
  if (h > 0) return h + 'h ' + m + 'm';
  if (m > 0) return m + 'm ' + s + 's';
  return s + 's';
}

async function refresh() {
  try {
    const status = await fetch('/status').then(r=>r.json());
    _ipAddr = 'http://' + status.local_ip + ':' + status.port;
    document.getElementById('ip-addr').textContent = _ipAddr;
    document.getElementById('cache-count').textContent = status.cache_count;
    document.getElementById('cache-size').textContent = status.cache_size_mb;
    document.getElementById('uptime').textContent = fmtUptime(status.uptime);
    document.getElementById('active-count').textContent = status.active_downloads;
    document.getElementById('visitor-count').textContent = status.visitors.length;
    document.getElementById('refresh-info').textContent = '마지막 갱신: ' + new Date().toLocaleTimeString();

    // 접속자
    const vb = document.getElementById('visitors-body');
    if (!status.visitors.length) {
      vb.innerHTML = '<tr><td colspan="5" class="empty">접속 기록 없음</td></tr>';
    } else {
      vb.innerHTML = status.visitors.map(v =>
        '<tr><td style="font-family:monospace">' + v.ip +
        '</td><td>' + v.first_seen +
        '</td><td>' + v.last_seen +
        '</td><td style="color:#888;font-family:monospace;font-size:11px">' + v.last_path +
        '</td><td>' + v.count + '</td></tr>'
      ).join('');
    }

    // 다운로드 로그
    const lb = document.getElementById('log-body');
    if (!status.recent_downloads.length) {
      lb.innerHTML = '<tr><td colspan="3" class="empty">기록 없음</td></tr>';
    } else {
      lb.innerHTML = status.recent_downloads.map(d => {
        const cls = d.status === '완료' ? 'badge-done' : d.status.includes('오류') ? 'badge-error' : 'badge-active';
        return '<tr><td>' + d.time + '</td><td style="font-family:monospace">' + d.id +
               '</td><td><span class="badge ' + cls + '">' + d.status + '</span></td></tr>';
      }).join('');
    }

    // 곡 목록
    const sb = document.getElementById('song-body');
    const ids = Object.keys(status.cache_files);
    if (!ids.length) {
      sb.innerHTML = '<tr><td colspan="3" class="empty">캐시된 곡 없음</td></tr>';
    } else {
      sb.innerHTML = ids.map((id, i) =>
        '<tr><td>' + (i+1) + '</td><td style="font-family:monospace">' + id +
        '</td><td>' + status.cache_files[id] + ' MB</td></tr>'
      ).join('');
    }
  } catch(e) {
    document.getElementById('refresh-info').textContent = '⚠ 서버 연결 끊김';
  }
}
refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>
"""


class Handler(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        client_ip = self.client_address[0]
        record_visitor(client_ip, parsed.path)

        if parsed.path == '/audio' and 'id' in params:
            self._serve_audio(params['id'][0])
        elif parsed.path == '/ping':
            self._respond(200, b'pong', 'text/plain')
        elif parsed.path == '/list':
            self._serve_list()
        elif parsed.path == '/status':
            self._serve_status()
        elif parsed.path in ('/', '/dashboard'):
            self._serve_dashboard()
        else:
            self._respond(404, b'Not found', 'text/plain')

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        client_ip = self.client_address[0]
        record_visitor(client_ip, parsed.path)

        length = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(length)) if length else {}

        if parsed.path == '/cache/clear':
            self._handle_cache_clear()
        elif parsed.path == '/backup':
            self._handle_backup(body)
        elif parsed.path == '/restore':
            self._handle_restore(body)
        elif parsed.path == '/restart':
            self._handle_restart()
        elif parsed.path == '/shutdown':
            self._handle_shutdown()
        else:
            self._respond(404, b'Not found', 'text/plain')

    # ── GET 핸들러 ───────────────────────────────────────

    def _serve_audio(self, video_id: str):
        mp3_path = CACHE_DIR / f'{video_id}.mp3'
        lock = get_lock(video_id)
        with lock:
            if not mp3_path.exists():
                with _active_lock:
                    _active_downloads.add(video_id)
                add_log(video_id, '다운로드 중')
                print(f'[↓] 다운로드 중: {video_id}')
                result = subprocess.run([
                    sys.executable, '-m', 'yt_dlp',
                    '-x',
                    '--audio-format', 'mp3',
                    '--audio-quality', '0',
                    '--no-playlist',
                    '-o', str(CACHE_DIR / '%(id)s.%(ext)s'),
                    f'https://www.youtube.com/watch?v={video_id}'
                ], capture_output=True, text=True)
                with _active_lock:
                    _active_downloads.discard(video_id)

                if result.returncode != 0:
                    print(f'[!] yt-dlp 오류: {result.stderr}')
                    add_log(video_id, '오류')
                    self._respond(500, result.stderr.encode(), 'text/plain')
                    return
                add_log(video_id, '완료')
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
        ids = [f.stem for f in CACHE_DIR.glob('*.mp3')]
        self._respond(200, json.dumps(ids).encode(), 'application/json')

    def _serve_status(self):
        cache_files = list(CACHE_DIR.glob('*.mp3'))
        total_size = sum(f.stat().st_size for f in cache_files)
        file_sizes = {f.stem: round(f.stat().st_size / 1024 / 1024, 1) for f in cache_files}
        with _active_lock:
            active_count = len(_active_downloads)
        with _log_lock:
            recent = list(_download_log[:20])
        with _visitors_lock:
            visitors = [
                {'ip': ip, **info}
                for ip, info in sorted(_visitors.items(), key=lambda x: -x[1]['count'])
            ]
        data = {
            'uptime': int(time.time() - _start_time),
            'cache_count': len(cache_files),
            'cache_size_mb': round(total_size / 1024 / 1024, 1),
            'cache_files': file_sizes,
            'local_ip': _local_ip,
            'port': PORT,
            'active_downloads': active_count,
            'recent_downloads': recent,
            'visitors': visitors,
        }
        body = json_response(data)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def _serve_dashboard(self):
        body = DASHBOARD_HTML.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ── POST 핸들러 ──────────────────────────────────────

    def _handle_cache_clear(self):
        files = list(CACHE_DIR.glob('*.mp3'))
        count = 0
        for f in files:
            try:
                f.unlink()
                count += 1
            except Exception:
                pass
        print(f'[캐시] {count}개 파일 삭제')
        self._json(200, {'message': f'캐시 {count}곡 삭제 완료'})

    def _handle_backup(self, body: dict):
        dest_str = body.get('dest', '').strip()
        if not dest_str:
            self._json(400, {'message': '백업 경로를 입력하세요'})
            return
        dest = Path(dest_str).expanduser()
        try:
            dest.mkdir(parents=True, exist_ok=True)
            files = list(CACHE_DIR.glob('*.mp3'))
            count = 0
            for f in files:
                shutil.copy2(f, dest / f.name)
                count += 1
            print(f'[백업] {count}개 → {dest}')
            self._json(200, {'message': f'{count}곡을 백업했습니다 → {dest}'})
        except Exception as e:
            self._json(500, {'message': f'백업 실패: {e}'})

    def _handle_shutdown(self):
        self._json(200, {'message': '서버를 종료합니다.'})
        print('[종료] 서버 종료 중...')
        threading.Thread(target=lambda: (time.sleep(0.5), _server.shutdown()), daemon=True).start()

    def _handle_restart(self):
        self._json(200, {'message': '서버를 재시작합니다...'})
        print('[재시작] 서버 재시작 중...')
        def _do_restart():
            import sys
            time.sleep(0.5)
            os.execv(sys.executable, [sys.executable] + sys.argv)
        threading.Thread(target=_do_restart, daemon=True).start()

    def _handle_restore(self, body: dict):
        src_str = body.get('src', '').strip()
        if not src_str:
            self._json(400, {'message': '백업 경로를 입력하세요'})
            return
        src = Path(src_str).expanduser()
        if not src.exists():
            self._json(404, {'message': f'경로를 찾을 수 없습니다: {src}'})
            return
        try:
            files = list(src.glob('*.mp3'))
            count = 0
            for f in files:
                dest_file = CACHE_DIR / f.name
                if not dest_file.exists():
                    shutil.copy2(f, dest_file)
                    count += 1
            print(f'[복원] {count}개 ← {src}')
            self._json(200, {'message': f'{count}곡 복원 완료 (이미 있는 곡은 건너뜀)'})
        except Exception as e:
            self._json(500, {'message': f'복원 실패: {e}'})

    # ── 공통 응답 ────────────────────────────────────────

    def _json(self, code: int, data: dict):
        body = json_response(data)
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        _local_ip = s.getsockname()[0]
        s.close()
    except Exception:
        _local_ip = socket.gethostbyname(hostname)

    dashboard_url = f'http://localhost:{PORT}'

    print('=' * 52)
    print(f'  🎵 Music On 서버 시작 (포트 {PORT})')
    print(f'  📁 캐시 폴더: {CACHE_DIR}')
    print()
    print(f'  📱 앱 설정에 입력할 주소:')
    print(f'     http://{_local_ip}:{PORT}')
    print()
    print(f'  🖥  대시보드: {dashboard_url}')
    print('=' * 52)

    if os.environ.get('MUSIC_ON_NO_BROWSER') != '1':
        import webbrowser
        threading.Timer(1.0, lambda: webbrowser.open(dashboard_url)).start()

    _server = http.server.ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    try:
        _server.serve_forever()
    except KeyboardInterrupt:
        pass
    print('\n서버 종료')

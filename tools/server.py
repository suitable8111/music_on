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
import secrets
import hashlib
import urllib.parse
import threading
from pathlib import Path
from datetime import datetime

PORT = 8888
CACHE_DIR = Path.home() / '.music_on_cache'
CACHE_DIR.mkdir(exist_ok=True)

USERS_FILE = CACHE_DIR / 'users.json'
SESSIONS_FILE = CACHE_DIR / 'sessions.json'

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

# 인증 관련
_users: dict = {}    # {username: {hash, salt, role, created_at}}
_sessions: dict = {}  # {token: {username, created_at, ip}}
_auth_attempts: dict = {}  # {ip: [timestamps]}
_auth_lock = threading.Lock()


# ── 인증 헬퍼 함수 ──────────────────────────────────────────

def _load_users():
    global _users
    if USERS_FILE.exists():
        try:
            with open(USERS_FILE, 'r', encoding='utf-8') as f:
                _users = json.load(f)
        except Exception:
            _users = {}
    else:
        _users = {}


def _save_users():
    with open(USERS_FILE, 'w', encoding='utf-8') as f:
        json.dump(_users, f, ensure_ascii=False, indent=2)


def _load_sessions():
    global _sessions
    if SESSIONS_FILE.exists():
        try:
            with open(SESSIONS_FILE, 'r', encoding='utf-8') as f:
                _sessions = json.load(f)
        except Exception:
            _sessions = {}
    else:
        _sessions = {}


def _save_sessions():
    with open(SESSIONS_FILE, 'w', encoding='utf-8') as f:
        json.dump(_sessions, f, ensure_ascii=False, indent=2)


def _hash_pw(password: str, salt: str) -> str:
    dk = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt.encode('utf-8'), 100000)
    return dk.hex()


def _check_rate(ip: str) -> bool:
    """False if >5 attempts in last 60s"""
    now = time.time()
    with _auth_lock:
        attempts = _auth_attempts.get(ip, [])
        # 60초 이내 기록만 유지
        attempts = [t for t in attempts if now - t < 60]
        _auth_attempts[ip] = attempts
        return len(attempts) < 5


def _get_token(handler) -> tuple:
    """(token, username) from Authorization: Bearer header"""
    auth_header = handler.headers.get('Authorization', '')
    if not auth_header.startswith('Bearer '):
        return None, None
    token = auth_header[7:].strip()
    with _auth_lock:
        session = _sessions.get(token)
    if session is None:
        return None, None
    return token, session['username']


def _require_auth(handler, require_admin: bool = False):
    """Returns username or sends 401/403 and returns None"""
    token, username = _get_token(handler)
    if username is None:
        body = json_response({'error': '인증이 필요합니다'})
        handler.send_response(401)
        handler.send_header('Content-Type', 'application/json')
        handler.send_header('Content-Length', str(len(body)))
        handler.send_header('Access-Control-Allow-Origin', '*')
        handler.end_headers()
        handler.wfile.write(body)
        return None
    if require_admin:
        user = _users.get(username, {})
        if user.get('role') != 'admin':
            body = json_response({'error': '관리자 권한이 필요합니다'})
            handler.send_response(403)
            handler.send_header('Content-Type', 'application/json')
            handler.send_header('Content-Length', str(len(body)))
            handler.send_header('Access-Control-Allow-Origin', '*')
            handler.end_headers()
            handler.wfile.write(body)
            return None
    return username


# ── 기타 헬퍼 ──────────────────────────────────────────────

def find_ffmpeg() -> str | None:
    """ffmpeg 실행 파일 디렉터리 탐색. yt-dlp --ffmpeg-location 인자로 사용."""
    ff = shutil.which('ffmpeg')
    if ff:
        return str(Path(ff).parent)
    if sys.platform == 'win32':
        candidates = [
            Path(os.environ.get('PROGRAMFILES', 'C:/Program Files')) / 'ffmpeg' / 'bin',
            Path(os.environ.get('PROGRAMFILES', 'C:/Program Files')) / 'ffmpeg-full_build' / 'bin',
            Path.home() / 'ffmpeg' / 'bin',
            Path.home() / 'Downloads' / 'ffmpeg' / 'bin',
        ]
        winget_pkgs = Path(os.environ.get('LOCALAPPDATA', '')) / 'Microsoft' / 'WinGet' / 'Packages'
        if winget_pkgs.exists():
            for pkg in winget_pkgs.glob('Gyan.FFmpeg*'):
                for bin_dir in pkg.rglob('bin'):
                    if (bin_dir / 'ffmpeg.exe').exists():
                        candidates.insert(0, bin_dir)
        for c in candidates:
            if c.exists() and (c / ('ffmpeg.exe' if sys.platform == 'win32' else 'ffmpeg')).exists():
                return str(c)
    return None


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
  input[type=text], input[type=password] { flex: 1; background: #2a2a2a; border: none; border-radius: 8px; padding: 10px 14px; color: #e0e0e0; font-size: 13px; font-family: monospace; outline: none; }
  input[type=text]::placeholder, input[type=password]::placeholder { color: #555; }
  input[type=text]:focus, input[type=password]:focus { box-shadow: 0 0 0 2px #BB86FC44; }
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

  /* 인증 */
  .auth-box { max-width: 400px; margin: 80px auto; background: #1e1e1e; border-radius: 16px; padding: 32px; }
  .auth-title { font-size: 18px; font-weight: 700; color: #BB86FC; margin-bottom: 24px; text-align: center; }
  .form-group { margin-bottom: 16px; }
  .form-label { font-size: 12px; color: #888; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; display: block; margin-bottom: 6px; }
  .btn-full { width: 100%; padding: 12px; font-size: 15px; }
  .error-msg { color: #ff8a80; font-size: 13px; margin-top: 12px; text-align: center; min-height: 20px; }
  .role-badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; }
  .role-admin { background: #4a148c; color: #ea80fc; }
  .role-user { background: #1a237e; color: #82b1ff; }
  select { background: #2a2a2a; border: none; border-radius: 8px; padding: 10px 14px; color: #e0e0e0; font-size: 13px; outline: none; }

  /* 숨기기 */
  .hidden { display: none !important; }
</style>
</head>
<body>

<!-- ── 셋업 화면 ──────────────────────────────────────── -->
<div id="setup-view" class="hidden">
  <div class="auth-box">
    <div class="auth-title">🎵 Music On 초기 설정</div>
    <p style="color:#888;font-size:13px;text-align:center;margin-bottom:24px">관리자 계정을 만들어 시작하세요</p>
    <div class="form-group">
      <label class="form-label">사용자 이름</label>
      <input type="text" id="setup-username" placeholder="admin" style="width:100%;font-family:inherit">
    </div>
    <div class="form-group">
      <label class="form-label">비밀번호 (최소 6자)</label>
      <input type="password" id="setup-password" placeholder="••••••" style="width:100%;font-family:inherit">
    </div>
    <button class="btn-primary btn-full" onclick="doSetup()">관리자 계정 만들기</button>
    <div class="error-msg" id="setup-error"></div>
  </div>
</div>

<!-- ── 로그인 화면 ────────────────────────────────────── -->
<div id="login-view" class="hidden">
  <div class="auth-box">
    <div class="auth-title">🎵 Music On 로그인</div>
    <div class="form-group">
      <label class="form-label">사용자 이름</label>
      <input type="text" id="login-username" placeholder="username" style="width:100%;font-family:inherit">
    </div>
    <div class="form-group">
      <label class="form-label">비밀번호</label>
      <input type="password" id="login-password" placeholder="••••••" style="width:100%;font-family:inherit" onkeydown="if(event.key==='Enter')doLogin()">
    </div>
    <button class="btn-primary btn-full" onclick="doLogin()">로그인</button>
    <div class="error-msg" id="login-error"></div>
  </div>
</div>

<!-- ── 대시보드 ──────────────────────────────────────── -->
<div id="dashboard-view" class="hidden">
<h1><span>Music On</span> 서버 대시보드</h1>
<p class="subtitle"><span class="status-dot"></span>서버 실행 중 &nbsp;|&nbsp; <span id="current-user-label" style="color:#BB86FC"></span></p>

<div class="ip-box">
  <div>
    <div class="ip-label">앱에 입력할 서버 주소</div>
    <div class="ip-addr" id="ip-addr">불러오는 중...</div>
  </div>
  <div style="display:flex;gap:8px;flex-wrap:wrap">
    <button class="btn-secondary" onclick="copyIp()">복사</button>
    <button class="btn-secondary" onclick="doLogout()">로그아웃</button>
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

<!-- ── 설정 패널 ──────────────────────────────────────── -->
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

<!-- ── 사용자 관리 (관리자 전용) ───────────────────────── -->
<div id="user-management" class="hidden">
  <div class="section-title">👤 사용자 관리</div>
  <table id="users-table">
    <thead><tr><th>사용자 이름</th><th>역할</th><th>생성일시</th><th>액션</th></tr></thead>
    <tbody id="users-body"><tr><td colspan="4" class="empty">불러오는 중...</td></tr></tbody>
  </table>

  <!-- 활성 세션 -->
  <div class="section-title" style="margin-top:8px">🔑 활성 세션</div>
  <table>
    <thead><tr><th>사용자</th><th>IP</th><th>로그인 시간</th></tr></thead>
    <tbody id="sessions-body"><tr><td colspan="3" class="empty">세션 없음</td></tr></tbody>
  </table>

  <!-- 사용자 추가 폼 -->
  <div class="settings-panel" style="margin-bottom:28px">
    <div class="setting-label">새 사용자 추가</div>
    <div class="setting-control" style="flex-wrap:wrap;gap:8px">
      <input type="text" id="new-username" placeholder="사용자 이름" style="min-width:140px">
      <input type="password" id="new-password" placeholder="비밀번호" style="min-width:140px">
      <select id="new-role">
        <option value="user">user</option>
        <option value="admin">admin</option>
      </select>
      <button class="btn-primary" onclick="addUser()">추가</button>
    </div>
    <div class="error-msg" id="add-user-error" style="text-align:left;margin-top:0"></div>
  </div>
</div>

<!-- ── 접속자 IP 기록 ──────────────────────────────────── -->
<div class="section-title">🌐 접속자 IP 기록</div>
<table>
  <thead><tr><th>IP 주소</th><th>최초 접속</th><th>최근 접속</th><th>최근 경로</th><th>요청 수</th></tr></thead>
  <tbody id="visitors-body"><tr><td colspan="5" class="empty">접속 기록 없음</td></tr></tbody>
</table>

<!-- ── 다운로드 기록 ───────────────────────────────────── -->
<div class="section-title">📥 최근 다운로드 기록</div>
<table>
  <thead><tr><th>시간</th><th>Video ID</th><th>상태</th></tr></thead>
  <tbody id="log-body"><tr><td colspan="3" class="empty">기록 없음</td></tr></tbody>
</table>

<!-- ── 캐시된 곡 목록 ──────────────────────────────────── -->
<div class="section-title">🎵 캐시된 곡 목록</div>
<table>
  <thead><tr><th>#</th><th>Video ID</th><th>크기</th></tr></thead>
  <tbody id="song-body"><tr><td colspan="3" class="empty">로딩 중...</td></tr></tbody>
</table>
</div><!-- /#dashboard-view -->

<div class="toast" id="toast"></div>

<script>
let _ipAddr = '';
let _token = localStorage.getItem('musicon_token') || '';
let _isAdmin = false;

// ── 화면 전환 ──────────────────────────────────────────

function showView(name) {
  ['setup-view', 'login-view', 'dashboard-view'].forEach(id => {
    document.getElementById(id).classList.add('hidden');
  });
  document.getElementById(name + '-view').classList.remove('hidden');
}

function showToast(msg, ok=true) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'toast show ' + (ok ? 'ok' : 'err');
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.className = 'toast', 3000);
}

// ── 인증된 fetch 래퍼 ─────────────────────────────────

async function authFetch(url, opts = {}) {
  opts.headers = opts.headers || {};
  if (_token) opts.headers['Authorization'] = 'Bearer ' + _token;
  const r = await fetch(url, opts);
  if (r.status === 401) {
    localStorage.removeItem('musicon_token');
    _token = '';
    showView('login');
    throw new Error('401');
  }
  return r;
}

// ── 초기 로드 로직 ─────────────────────────────────────

async function init() {
  try {
    const sr = await fetch('/setup/status');
    const sd = await sr.json();
    if (!sd.has_users) {
      showView('setup');
      return;
    }
  } catch(e) {
    showView('login');
    return;
  }

  if (!_token) {
    showView('login');
    return;
  }

  try {
    const r = await fetch('/status', {
      headers: { 'Authorization': 'Bearer ' + _token }
    });
    if (r.status === 401) {
      localStorage.removeItem('musicon_token');
      _token = '';
      showView('login');
      return;
    }
    const status = await r.json();
    _isAdmin = status.is_admin || false;
    document.getElementById('current-user-label').textContent =
      (status.current_user || '') + (_isAdmin ? ' (관리자)' : '');
    if (_isAdmin) {
      document.getElementById('user-management').classList.remove('hidden');
    }
    showView('dashboard');
    renderStatus(status);
    setInterval(refresh, 5000);
  } catch(e) {
    showView('login');
  }
}

// ── 셋업 ──────────────────────────────────────────────

async function doSetup() {
  const username = document.getElementById('setup-username').value.trim();
  const password = document.getElementById('setup-password').value;
  const errEl = document.getElementById('setup-error');
  errEl.textContent = '';

  if (!username) { errEl.textContent = '사용자 이름을 입력하세요'; return; }
  if (password.length < 6) { errEl.textContent = '비밀번호는 최소 6자입니다'; return; }

  try {
    const r = await fetch('/setup', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({username, password})
    });
    const d = await r.json();
    if (r.ok) {
      showToast('관리자 계정이 생성됐습니다. 로그인하세요.');
      showView('login');
    } else {
      errEl.textContent = d.error || '오류 발생';
    }
  } catch(e) {
    errEl.textContent = '서버 오류: ' + e.message;
  }
}

// ── 로그인 ─────────────────────────────────────────────

async function doLogin() {
  const username = document.getElementById('login-username').value.trim();
  const password = document.getElementById('login-password').value;
  const errEl = document.getElementById('login-error');
  errEl.textContent = '';

  if (!username || !password) { errEl.textContent = '사용자 이름과 비밀번호를 입력하세요'; return; }

  try {
    const r = await fetch('/auth/login', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({username, password})
    });
    const d = await r.json();
    if (r.ok) {
      _token = d.token;
      localStorage.setItem('musicon_token', _token);
      location.reload();
    } else {
      errEl.textContent = d.error || '로그인 실패';
    }
  } catch(e) {
    errEl.textContent = '서버 오류: ' + e.message;
  }
}

// ── 로그아웃 ────────────────────────────────────────────

async function doLogout() {
  try {
    await authFetch('/auth/logout', {method: 'POST'});
  } catch(_) {}
  localStorage.removeItem('musicon_token');
  _token = '';
  location.reload();
}

// ── 사용자 관리 ────────────────────────────────────────

function renderUsers(users, sessions) {
  const ub = document.getElementById('users-body');
  if (!users || !users.length) {
    ub.innerHTML = '<tr><td colspan="4" class="empty">사용자 없음</td></tr>';
  } else {
    ub.innerHTML = users.map(u => {
      const roleClass = u.role === 'admin' ? 'role-admin' : 'role-user';
      const delBtn = u.role === 'admin' && users.filter(x => x.role === 'admin').length === 1
        ? '<button class="btn-secondary" disabled style="font-size:11px;padding:4px 10px">삭제</button>'
        : `<button class="btn-danger" onclick="deleteUser('${u.username}')" style="font-size:11px;padding:4px 10px">삭제</button>`;
      return `<tr>
        <td style="font-family:monospace">${u.username}</td>
        <td><span class="role-badge ${roleClass}">${u.role}</span></td>
        <td style="color:#888;font-size:12px">${u.created_at || ''}</td>
        <td>${delBtn}</td>
      </tr>`;
    }).join('');
  }

  const sb = document.getElementById('sessions-body');
  if (!sessions || !sessions.length) {
    sb.innerHTML = '<tr><td colspan="3" class="empty">세션 없음</td></tr>';
  } else {
    sb.innerHTML = sessions.map(s =>
      `<tr><td style="font-family:monospace">${s.username}</td><td style="font-family:monospace">${s.ip}</td><td>${s.created_at}</td></tr>`
    ).join('');
  }
}

async function addUser() {
  const username = document.getElementById('new-username').value.trim();
  const password = document.getElementById('new-password').value;
  const role = document.getElementById('new-role').value;
  const errEl = document.getElementById('add-user-error');
  errEl.textContent = '';

  if (!username || !password) { errEl.textContent = '사용자 이름과 비밀번호를 입력하세요'; return; }
  if (password.length < 6) { errEl.textContent = '비밀번호는 최소 6자입니다'; return; }

  try {
    const r = await authFetch('/admin/users', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({username, password, role})
    });
    const d = await r.json();
    if (r.ok) {
      showToast('사용자가 추가됐습니다');
      document.getElementById('new-username').value = '';
      document.getElementById('new-password').value = '';
      refresh();
    } else {
      errEl.textContent = d.error || '오류 발생';
    }
  } catch(e) {
    if (e.message !== '401') errEl.textContent = '서버 오류: ' + e.message;
  }
}

async function deleteUser(username) {
  if (!confirm(username + ' 사용자를 삭제할까요?')) return;
  try {
    const r = await authFetch('/admin/users/delete', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({username})
    });
    const d = await r.json();
    if (r.ok) {
      showToast('사용자가 삭제됐습니다');
      refresh();
    } else {
      showToast(d.error || '오류 발생', false);
    }
  } catch(e) {
    if (e.message !== '401') showToast('오류: ' + e.message, false);
  }
}

// ── 대시보드 갱신 ──────────────────────────────────────

function copyIp() {
  navigator.clipboard.writeText(_ipAddr).then(() => showToast('주소가 복사됐습니다'));
}

async function shutdownServer() {
  if (!confirm('서버를 종료할까요?\n종료 후에는 앱에서 새 곡을 받을 수 없습니다.')) return;
  const btn = document.getElementById('shutdown-btn');
  btn.disabled = true;
  btn.textContent = '종료 중...';
  try { await authFetch('/shutdown', {method:'POST'}); } catch(_) {}
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
    await authFetch('/restart', {method:'POST'});
  } catch(_) {}

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
  const r = await authFetch('/cache/clear', {method:'POST'});
  const d = await r.json();
  showToast(d.message, r.ok);
  refresh();
}

async function doBackup() {
  const dest = document.getElementById('backup-path').value.trim();
  if (!dest) { showToast('백업 경로를 입력하세요', false); return; }
  const r = await authFetch('/backup', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({dest})});
  const d = await r.json();
  showToast(d.message, r.ok);
}

async function doRestore() {
  const src = document.getElementById('restore-path').value.trim();
  if (!src) { showToast('백업 경로를 입력하세요', false); return; }
  if (!confirm(src + '\n\n위 경로에서 mp3 파일을 가져올까요?')) return;
  const r = await authFetch('/restore', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({src})});
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

function renderStatus(status) {
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

  // 관리자 전용: 사용자 목록 & 세션 목록
  if (_isAdmin && status.users) {
    renderUsers(status.users, status.active_sessions);
  }
}

async function refresh() {
  try {
    const r = await authFetch('/status');
    if (r.status === 401) return; // authFetch가 이미 처리
    const status = await r.json();
    renderStatus(status);
  } catch(e) {
    if (e.message !== '401') {
      document.getElementById('refresh-info').textContent = '⚠ 서버 연결 끊김';
    }
  }
}

init();
</script>
</body>
</html>
"""


class Handler(http.server.BaseHTTPRequestHandler):

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Authorization, Content-Type')
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        client_ip = self.client_address[0]
        record_visitor(client_ip, parsed.path)

        # 인증 불필요 엔드포인트
        if parsed.path == '/ping':
            self._respond(200, b'pong', 'text/plain')
        elif parsed.path in ('/', '/dashboard'):
            self._serve_dashboard()
        elif parsed.path == '/setup/status':
            self._serve_setup_status()
        # 인증 필요 엔드포인트
        elif parsed.path == '/audio' and 'id' in params:
            username = _require_auth(self)
            if username is None:
                return
            self._serve_audio(params['id'][0])
        elif parsed.path == '/list':
            username = _require_auth(self)
            if username is None:
                return
            self._serve_list()
        elif parsed.path == '/status':
            username = _require_auth(self)
            if username is None:
                return
            self._serve_status(username)
        # 관리자 전용
        elif parsed.path == '/admin/users':
            username = _require_auth(self, require_admin=True)
            if username is None:
                return
            self._serve_admin_users()
        else:
            self._respond(404, b'Not found', 'text/plain')

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        client_ip = self.client_address[0]
        record_visitor(client_ip, parsed.path)

        length = int(self.headers.get('Content-Length', 0))
        body = {}
        if length:
            try:
                body = json.loads(self.rfile.read(length))
            except Exception:
                body = {}

        # 인증 불필요
        if parsed.path == '/setup':
            self._handle_setup(body)
        elif parsed.path == '/auth/login':
            self._handle_login(body, client_ip)
        elif parsed.path == '/auth/logout':
            self._handle_logout()
        # 인증 필요 (일반 사용자)
        elif parsed.path == '/cache/clear':
            username = _require_auth(self, require_admin=True)
            if username is None:
                return
            self._handle_cache_clear()
        elif parsed.path == '/backup':
            username = _require_auth(self, require_admin=True)
            if username is None:
                return
            self._handle_backup(body)
        elif parsed.path == '/restore':
            username = _require_auth(self, require_admin=True)
            if username is None:
                return
            self._handle_restore(body)
        elif parsed.path == '/restart':
            username = _require_auth(self, require_admin=True)
            if username is None:
                return
            self._handle_restart()
        elif parsed.path == '/shutdown':
            username = _require_auth(self, require_admin=True)
            if username is None:
                return
            self._handle_shutdown()
        # 관리자 전용
        elif parsed.path == '/admin/users':
            username = _require_auth(self, require_admin=True)
            if username is None:
                return
            self._handle_create_user(body)
        elif parsed.path == '/admin/users/delete':
            username = _require_auth(self, require_admin=True)
            if username is None:
                return
            self._handle_delete_user(body)
        else:
            self._respond(404, b'Not found', 'text/plain')

    # ── 인증 엔드포인트 ──────────────────────────────────

    def _serve_setup_status(self):
        self._json(200, {'has_users': len(_users) > 0})

    def _handle_setup(self, body: dict):
        if len(_users) > 0:
            self._json(400, {'error': '이미 사용자가 존재합니다'})
            return
        username = body.get('username', '').strip()
        password = body.get('password', '')
        if not username:
            self._json(400, {'error': '사용자 이름을 입력하세요'})
            return
        if len(password) < 6:
            self._json(400, {'error': '비밀번호는 최소 6자입니다'})
            return
        salt = secrets.token_hex(16)
        pw_hash = _hash_pw(password, salt)
        with _auth_lock:
            _users[username] = {
                'hash': pw_hash,
                'salt': salt,
                'role': 'admin',
                'created_at': datetime.now().strftime('%Y-%m-%d %H:%M'),
            }
            _save_users()
        print(f'[인증] 관리자 계정 생성: {username}')
        self._json(200, {'message': '관리자 계정이 생성됐습니다'})

    def _handle_login(self, body: dict, client_ip: str):
        if not _check_rate(client_ip):
            self._json(429, {'error': '너무 많은 로그인 시도입니다. 1분 후 다시 시도하세요'})
            return
        username = body.get('username', '').strip()
        password = body.get('password', '')
        with _auth_lock:
            _auth_attempts.setdefault(client_ip, []).append(time.time())
        user = _users.get(username)
        if user is None:
            self._json(401, {'error': '사용자 이름 또는 비밀번호가 틀렸습니다'})
            return
        expected = _hash_pw(password, user['salt'])
        if expected != user['hash']:
            self._json(401, {'error': '사용자 이름 또는 비밀번호가 틀렸습니다'})
            return
        token = secrets.token_urlsafe(32)
        session = {
            'username': username,
            'created_at': datetime.now().strftime('%Y-%m-%d %H:%M'),
            'ip': client_ip,
        }
        with _auth_lock:
            _sessions[token] = session
            _save_sessions()
        print(f'[인증] 로그인: {username} from {client_ip}')
        self._json(200, {'token': token, 'username': username, 'role': user['role']})

    def _handle_logout(self):
        token, username = _get_token(self)
        if token:
            with _auth_lock:
                _sessions.pop(token, None)
                _save_sessions()
            print(f'[인증] 로그아웃: {username}')
        self._json(200, {'message': '로그아웃됐습니다'})

    def _serve_admin_users(self):
        with _auth_lock:
            users_list = [
                {'username': u, 'role': d['role'], 'created_at': d.get('created_at', '')}
                for u, d in _users.items()
            ]
            sessions_list = [
                {'username': s['username'], 'ip': s['ip'], 'created_at': s['created_at']}
                for s in _sessions.values()
            ]
        self._json(200, {'users': users_list, 'sessions': sessions_list})

    def _handle_create_user(self, body: dict):
        username = body.get('username', '').strip()
        password = body.get('password', '')
        role = body.get('role', 'user')
        if role not in ('user', 'admin'):
            role = 'user'
        if not username:
            self._json(400, {'error': '사용자 이름을 입력하세요'})
            return
        if len(password) < 6:
            self._json(400, {'error': '비밀번호는 최소 6자입니다'})
            return
        with _auth_lock:
            if username in _users:
                self._json(400, {'error': '이미 존재하는 사용자 이름입니다'})
                return
            salt = secrets.token_hex(16)
            pw_hash = _hash_pw(password, salt)
            _users[username] = {
                'hash': pw_hash,
                'salt': salt,
                'role': role,
                'created_at': datetime.now().strftime('%Y-%m-%d %H:%M'),
            }
            _save_users()
        print(f'[인증] 사용자 생성: {username} ({role})')
        self._json(200, {'message': f'사용자 {username}이(가) 생성됐습니다'})

    def _handle_delete_user(self, body: dict):
        target = body.get('username', '').strip()
        if not target:
            self._json(400, {'error': '사용자 이름을 입력하세요'})
            return
        with _auth_lock:
            if target not in _users:
                self._json(404, {'error': '사용자를 찾을 수 없습니다'})
                return
            # 마지막 관리자는 삭제 불가
            if _users[target]['role'] == 'admin':
                admin_count = sum(1 for u in _users.values() if u['role'] == 'admin')
                if admin_count <= 1:
                    self._json(400, {'error': '마지막 관리자는 삭제할 수 없습니다'})
                    return
            del _users[target]
            # 해당 사용자 세션도 삭제
            to_del = [t for t, s in _sessions.items() if s['username'] == target]
            for t in to_del:
                del _sessions[t]
            _save_users()
            _save_sessions()
        print(f'[인증] 사용자 삭제: {target}')
        self._json(200, {'message': f'사용자 {target}이(가) 삭제됐습니다'})

    # ── GET 핸들러 ──────────────────────────────────────

    def _serve_audio(self, video_id: str):
        mp3_path = CACHE_DIR / f'{video_id}.mp3'
        lock = get_lock(video_id)
        with lock:
            if not mp3_path.exists():
                with _active_lock:
                    _active_downloads.add(video_id)
                add_log(video_id, '다운로드 중')
                print(f'[↓] 다운로드 중: {video_id}')
                cmd = [
                    sys.executable, '-m', 'yt_dlp',
                    '-x',
                    '--audio-format', 'mp3',
                    '--audio-quality', '0',
                    '--no-playlist',
                    '-o', str(CACHE_DIR / '%(id)s.%(ext)s'),
                ]
                ffmpeg_dir = find_ffmpeg()
                if ffmpeg_dir:
                    cmd.extend(['--ffmpeg-location', ffmpeg_dir])
                else:
                    print('[!] ffmpeg를 찾을 수 없습니다. start.bat을 실행하거나 ffmpeg를 설치하세요.')
                cmd.append(f'https://www.youtube.com/watch?v={video_id}')
                result = subprocess.run(cmd, capture_output=True, text=True)
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
        body = json.dumps(ids).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def _serve_status(self, current_username: str):
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
        user_info = _users.get(current_username, {})
        is_admin = user_info.get('role') == 'admin'
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
            'current_user': current_username,
            'is_admin': is_admin,
        }
        if is_admin:
            with _auth_lock:
                data['users'] = [
                    {'username': u, 'role': d['role'], 'created_at': d.get('created_at', '')}
                    for u, d in _users.items()
                ]
                data['active_sessions'] = [
                    {'username': s['username'], 'ip': s['ip'], 'created_at': s['created_at']}
                    for s in _sessions.values()
                ]
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

    # ── POST 핸들러 ─────────────────────────────────────

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
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def _respond(self, code, body, content_type):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
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

    _load_users()
    _load_sessions()

    dashboard_url = f'http://localhost:{PORT}'

    print('=' * 52)
    print(f'  🎵 Music On 서버 시작 (포트 {PORT})')
    print(f'  📁 캐시 폴더: {CACHE_DIR}')
    print()
    print(f'  📱 앱 설정에 입력할 주소:')
    print(f'     http://{_local_ip}:{PORT}')
    print()
    print(f'  🖥  대시보드: {dashboard_url}')
    if len(_users) == 0:
        print(f'  ⚠  첫 실행: 브라우저에서 관리자 계정을 만드세요')
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

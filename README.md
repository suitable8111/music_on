# Music On 🎵

링크로 음악을 백그라운드에서 재생할 수 있는 Flutter 앱

---

## 개요

**Music On**은 URL을 입력하면 오디오만 추출해 백그라운드에서 재생하는 음악 플레이어 앱입니다. 즐겨찾기와 커스텀 플레이리스트를 지원하며, 화면이 꺼져 있어도 계속 재생됩니다.

---

## 주요 기능

| 기능 | 설명 |
|------|------|
| url 재생 | URL 입력 후 오디오 백그라운드 재생 |
| 백그라운드 재생 | 화면 잠금 / 앱 전환 시에도 재생 유지 |
| 미디어 알림 | 잠금 화면 / 상단바에 재생 컨트롤 표시 |
| 즐겨찾기 | 곡 즐겨찾기 등록/해제 |
| 플레이리스트 | 커스텀 플레이리스트 생성 · 관리 |
| 재생 큐 | 다음 곡 자동 재생, 순서 변경 |
| 재생 모드 | 반복(1곡/전체), 셔플 |
| 검색 | 즐겨찾기 · 플레이리스트 내 검색 |
| 로컬 저장 | 모든 데이터 기기 로컬 저장 (SharedPreferences / Hive) |

---

## 기술 스택

### Flutter 패키지

```yaml
dependencies:
  # 오디오 추출
  _explode_dart: ^2.2.0      #  메타데이터 & 스트림 URL 추출

  # 오디오 재생
  just_audio: ^0.9.40               # 오디오 재생 엔진
  audio_service: ^0.18.15           # 백그라운드 재생 + 미디어 알림

  # 로컬 저장소
  hive: ^2.2.3                      # 빠른 NoSQL 로컬 DB
  hive_flutter: ^1.1.0

  # 상태 관리
  flutter_riverpod: ^2.5.1

  # UI
  cached_network_image: ^3.3.1      # 썸네일 캐싱
  flutter_slidable: ^3.1.0          # 스와이프 액션
```

---

## 아키텍처

```
lib/
├── main.dart
├── app.dart                        # MaterialApp, 테마 설정
│
├── core/
│   ├── constants/
│   │   └── app_colors.dart
│   └── utils/
│       └── _utils.dart      # URL 파싱, ID 추출
│
├── data/
│   ├── models/
│   │   ├── song.dart               # 곡 모델 (id, title, thumbnail, url)
│   │   ├── playlist.dart           # 플레이리스트 모델
│   │   └── play_queue.dart         # 재생 큐 상태
│   └── repositories/
│       ├── favorites_repository.dart
│       └── playlist_repository.dart
│
├── services/
│   ├── audio_handler.dart          # AudioHandler (백그라운드 재생 핵심)
│   └── _service.dart        # _explode로 스트림 URL 획득
│
├── providers/
│   ├── audio_provider.dart         # 재생 상태 Provider
│   ├── favorites_provider.dart
│   └── playlist_provider.dart
│
└── ui/
    ├── screens/
    │   ├── home_screen.dart         # 메인 (URL 입력 + 탭)
    │   ├── player_screen.dart       # 풀스크린 플레이어
    │   ├── favorites_screen.dart    # 즐겨찾기 목록
    │   └── playlist_screen.dart    # 플레이리스트 목록/상세
    └── widgets/
        ├── mini_player.dart         # 하단 미니 플레이어
        ├── song_tile.dart           # 곡 리스트 아이템
        └── add_url_dialog.dart      # URL 입력 다이얼로그
```

---

## 화면 구성

### 1. Home Screen
- 상단:  URL 입력창 + 재생 버튼
- 탭: `즐겨찾기` | `플레이리스트`
- 하단: 미니 플레이어 (현재 재생 중인 곡)

### 2. Player Screen (풀스크린)
- 썸네일 (대형)
- 곡 제목 / 채널명
- 재생바 (seek)
- 컨트롤: 이전 · 재생/일시정지 · 다음
- 반복 / 셔플 토글
- 즐겨찾기 버튼
- 플레이리스트 추가 버튼

### 3. Favorites Screen
- 즐겨찾기한 곡 목록
- 스와이프 → 삭제 / 플레이리스트 추가
- 탭 → 재생

### 4. Playlist Screen
- 플레이리스트 목록 (생성 / 삭제)
- 플레이리스트 상세: 곡 목록, 순서 드래그, 전체 재생

---

## 데이터 모델

```dart
// Song
class Song {
  String id;           //  video ID
  String title;
  String channelName;
  String thumbnailUrl;
  String Url;
  DateTime addedAt;
}

// Playlist
class Playlist {
  String id;           // UUID
  String name;
  List<Song> songs;
  DateTime createdAt;
}
```

---

## 백그라운드 재생 흐름

```
사용자 URL 입력
    ↓
_explode_dart → 오디오 스트림 URL 추출
    ↓
just_audio → 스트림 URL로 재생
    ↓
audio_service → OS에 AudioHandler 등록
    ↓
잠금화면 / 알림바 미디어 컨트롤 표시
    ↓
앱 전환 / 화면 Off → 재생 유지
```

---

## 지원 플랫폼

| 플랫폼 | 지원 |
|--------|------|
| Android | ✅ |
| iOS | ✅ |

### Android 권한 (`AndroidManifest.xml`)
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
```

### iOS (`Info.plist`)
```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

---

## 구현 순서

1. **Flutter 프로젝트 생성** + 패키지 설정
2. **데이터 모델** (Song, Playlist) + Hive 어댑터
3. **Service** — URL → 오디오 스트림 URL
4. **AudioHandler** — just_audio + audio_service 연동
5. **Repository** — Hive CRUD (즐겨찾기, 플레이리스트)
6. **Providers** — Riverpod 상태 관리
7. **UI** — Home, Player, Favorites, Playlist 화면
8. **미니 플레이어** 위젯
9. **플랫폼 설정** — Android/iOS 권한 및 백그라운드 모드

---

## 예상 디렉토리 구조 (전체)

```
music_on/
├── README.md
├── pubspec.yaml
├── android/
│   └── app/src/main/AndroidManifest.xml
├── ios/
│   └── Runner/Info.plist
└── lib/
    └── (위 아키텍처 참조)
```

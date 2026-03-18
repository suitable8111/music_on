import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../../core/constants/app_colors.dart';
import '../../data/models/song.dart';
import '../../providers/auth_provider.dart';
import '../../providers/downloaded_songs_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/playlist_provider.dart';
import '../../providers/audio_provider.dart' show playerProvider, PlaybackMode;
import '../../providers/server_provider.dart' show serverUrlProvider, normalizeServerUrl, displayServerUrl, playbackModeProvider;
import '../../providers/server_status_provider.dart';
import '../../services/youtube_service.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SyncItem {
  final String videoId;
  String title;
  Song? song; // 메타데이터가 있으면 채워짐
  bool selected;
  bool downloading;
  bool done;
  String? error;

  _SyncItem({
    required this.videoId,
    required this.title,
    this.song,
    this.selected = true,
    this.downloading = false,
    this.done = false,
    this.error,
  });
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late TextEditingController _controller;
  String? _pingResult;
  bool _pinging = false;

  // 동기화 상태
  bool _syncing = false;
  List<_SyncItem>? _syncItems;
  bool _downloading = false;

  // 로그인 폼 상태
  final _loginUsernameCtrl = TextEditingController();
  final _loginPasswordCtrl = TextEditingController();

  final _youtubeService = YoutubeService();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: displayServerUrl(ref.read(serverUrlProvider)));
    // 저장된 토큰이 서버에서 아직 유효한지 백그라운드로 확인
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final serverUrl = ref.read(serverUrlProvider);
      ref.read(authProvider.notifier).verifyToken(serverUrl);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _loginUsernameCtrl.dispose();
    _loginPasswordCtrl.dispose();
    super.dispose();
  }

  Future<void> _ping() async {
    setState(() { _pinging = true; _pingResult = null; });
    final input = _controller.text.trim();
    if (input.isEmpty) {
      setState(() { _pingResult = '주소를 입력하세요'; _pinging = false; });
      return;
    }
    final url = normalizeServerUrl(input);
    try {
      final base = url.endsWith('/') ? url : '$url/';
      final token = YoutubeService.authToken;
      final headers = token != null ? {'Authorization': 'Bearer $token'} : <String, String>{};
      final res = await http.get(Uri.parse('${base}ping'), headers: headers)
          .timeout(const Duration(seconds: 5));
      setState(() {
        if (res.statusCode == 200) {
          _pingResult = '✓ 서버 연결 성공!';
        } else if (res.statusCode == 401) {
          _pingResult = '✗ 인증 실패: 로그인 후 다시 시도하세요';
        } else {
          _pingResult = '✗ 서버 오류: ${res.statusCode}';
        }
        _pinging = false;
      });
    } catch (e) {
      setState(() { _pingResult = '✗ 연결 실패: 서버가 실행 중인지 확인하세요'; _pinging = false; });
    }
  }

  void _save() {
    ref.read(serverUrlProvider.notifier).set(_controller.text);
    ref.read(serverStatusProvider.notifier).refresh();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('저장됐습니다'), backgroundColor: AppColors.primary),
    );
  }

  // 모든 곡 메타데이터를 videoId → Song 맵으로 수집
  Map<String, Song> _buildSongMap() {
    final map = <String, Song>{};

    // 다운로드된 곡
    for (final s in ref.read(downloadedSongsProvider)) {
      map[s.id] = s;
    }
    // 즐겨찾기
    for (final s in ref.read(favoritesProvider)) {
      map[s.id] = s;
    }
    // 플레이리스트 내 곡
    for (final pl in ref.read(playlistProvider)) {
      for (final s in pl.songs) {
        map[s.id] = s;
      }
    }

    return map;
  }

  Future<void> _fetchSyncData() async {
    final serverUrl = ref.read(serverUrlProvider);
    if (serverUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('서버 주소를 먼저 저장하세요'), backgroundColor: AppColors.primary),
      );
      return;
    }

    setState(() { _syncing = true; _syncItems = null; });

    try {
      final results = await Future.wait([
        _youtubeService.fetchServerIds(serverUrl),
        _youtubeService.getLocalCachedIds(),
      ]);

      final serverIds = results[0].toSet();
      final localIds = results[1].toSet();
      final missingIds = serverIds.difference(localIds);

      final songMap = _buildSongMap();

      final items = missingIds.map((id) {
        final song = songMap[id];
        return _SyncItem(
          videoId: id,
          title: song?.title ?? id,
          song: song,
        );
      }).toList()
        ..sort((a, b) => a.title.compareTo(b.title));

      setState(() { _syncItems = items; });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('오류: $e'), backgroundColor: AppColors.primary),
        );
      }
    } finally {
      if (mounted) setState(() { _syncing = false; });
    }
  }

  Future<void> _downloadSelected() async {
    final items = _syncItems;
    if (items == null) return;
    final selected = items.where((i) => i.selected && !i.done).toList();
    if (selected.isEmpty) return;

    final serverUrl = ref.read(serverUrlProvider);
    setState(() { _downloading = true; });

    for (final item in selected) {
      if (!mounted) break;
      setState(() { item.downloading = true; item.error = null; });
      try {
        // 1. YouTube에서 메타데이터 조회 (없는 경우)
        Song song;
        if (item.song != null) {
          song = item.song!;
        } else {
          song = await _youtubeService.fetchSongInfoById(item.videoId);
          if (mounted) {
            setState(() {
              item.song = song;
              item.title = song.title;
            });
          }
        }

        // 2. 서버에서 오디오 다운로드
        await _youtubeService.getAudioFilePath(item.videoId, serverUrl)
            .timeout(const Duration(minutes: 5));

        // 3. 다운로드된 곡 목록에 저장 → 앱에서 바로 보임
        await ref.read(downloadedSongsProvider.notifier).saveSong(song);

        if (mounted) setState(() { item.downloading = false; item.done = true; });
      } catch (e) {
        if (mounted) setState(() { item.downloading = false; item.error = e.toString(); });
      }
    }

    if (mounted) setState(() { _downloading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final serverUrl = ref.watch(serverUrlProvider);

    // 토큰이 바뀔 때마다 YoutubeService에 반영
    ref.listen<AuthState>(authProvider, (prev, next) {
      YoutubeService.authToken = next.token;
    });
    // 초기에도 설정
    YoutubeService.authToken = auth.token;

    final syncItems = _syncItems;
    final selectedCount = syncItems?.where((i) => i.selected).length ?? 0;
    final allSelected = syncItems != null && syncItems.isNotEmpty && selectedCount == syncItems.length;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('설정', style: TextStyle(color: AppColors.textPrimary)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [

          // ── 계정 로그인 ──────────────────────────────────
          const Text(
            '계정 로그인',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),

          if (auth.isLoggedIn) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.green.withValues(alpha: 0.4), width: 1),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '로그인됨: ${auth.username} (${auth.role ?? 'user'})',
                      style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      ref.read(authProvider.notifier).logout(serverUrl);
                      YoutubeService.authToken = null;
                    },
                    child: const Text('로그아웃', style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                  ),
                ],
              ),
            ),
          ] else ...[
            TextField(
              controller: _loginUsernameCtrl,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: '사용자 이름',
                hintStyle: const TextStyle(color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _loginPasswordCtrl,
              obscureText: true,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: '비밀번호',
                hintStyle: const TextStyle(color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            if (auth.error != null) ...[
              const SizedBox(height: 8),
              Text(
                auth.error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: auth.isLoading
                    ? null
                    : () {
                        ref.read(authProvider.notifier).login(
                          serverUrl,
                          _loginUsernameCtrl.text.trim(),
                          _loginPasswordCtrl.text,
                        );
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: auth.isLoading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('로그인', style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ),
          ],

          // ── 서버 주소 설정 ──────────────────────────────
          const SizedBox(height: 32),
          Row(
            children: [
              const Text(
                '서버 주소 확인',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.info_outline, color: AppColors.textSecondary, size: 20),
                tooltip: '서버 설정 안내',
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: AppColors.card,
                    title: const Text('서버 설정 안내', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Mac에서 server.py를 실행한 후\n표시된 IP 주소를 입력하세요.\n포트 미입력 시 기본값 8888이 사용됩니다.',
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.6),
                        ),
                        const SizedBox(height: 16),
                        const Text('서버 실행 방법', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            '# 1. 의존성 설치 (최초 1회)\nbrew install yt-dlp ffmpeg\n\n# 2. 서버 실행\npython3 tools/server.py',
                            style: TextStyle(color: AppColors.textSecondary, fontSize: 12, fontFamily: 'monospace', height: 1.6),
                          ),
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('확인', style: TextStyle(color: AppColors.primary)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            style: const TextStyle(color: AppColors.textPrimary),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              hintText: '192.168.0.x',
              prefixText: 'http://',
              prefixStyle: const TextStyle(color: AppColors.textSecondary),
              hintStyle: const TextStyle(color: AppColors.textSecondary),
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('저장', style: TextStyle(color: Colors.white, fontSize: 16)),
                ),
              ),
              const SizedBox(width: 12),
              Tooltip(
                message: auth.isLoggedIn ? '' : '로그인 후 연결 테스트 가능',
                child: ElevatedButton(
                  onPressed: (_pinging || !auth.isLoggedIn) ? null : _ping,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.surface,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                  ),
                  child: _pinging
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('연결 테스트', style: TextStyle(color: AppColors.textPrimary)),
                ),
              ),
            ],
          ),
          if (_pingResult != null) ...[
            const SizedBox(height: 12),
            Text(
              _pingResult!,
              style: TextStyle(
                color: _pingResult!.startsWith('✓') ? Colors.green : AppColors.primary,
                fontSize: 14,
              ),
            ),
          ],

          // ── 음악 재생 설정 ────────────────────────────────
          const SizedBox(height: 32),
          const Text(
            '음악 재생 설정',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: DropdownButton<PlaybackMode>(
              value: ref.watch(playbackModeProvider),
              isExpanded: true,
              underline: const SizedBox.shrink(),
              dropdownColor: AppColors.card,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
              icon: const Icon(Icons.expand_more, color: AppColors.textSecondary),
              items: const [
                DropdownMenuItem(value: PlaybackMode.single, child: Text('한곡만 듣기')),
                DropdownMenuItem(value: PlaybackMode.repeatAll, child: Text('전체 반복 듣기')),
                DropdownMenuItem(value: PlaybackMode.repeatOne, child: Text('한곡만 반복 듣기')),
              ],
              onChanged: (v) {
                if (v == null) return;
                ref.read(playbackModeProvider.notifier).set(v);
                ref.read(playerProvider.notifier).setPlaybackMode(v);
              },
            ),
          ),

          // ── 서버 동기화 ──────────────────────────────────
          const SizedBox(height: 32),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '서버 동기화',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              ElevatedButton.icon(
                onPressed: (_syncing || _downloading) ? null : _fetchSyncData,
                icon: _syncing
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.compare_arrows, size: 16),
                label: Text(_syncing ? '비교 중...' : '비교하기'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '서버에 있지만 기기에 없는 곡을 선택해서 다운로드할 수 있습니다.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),

          if (syncItems != null) ...[
            const SizedBox(height: 16),
            if (syncItems.isEmpty)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 20),
                    SizedBox(width: 8),
                    Text('기기와 서버의 곡이 모두 동일합니다', style: TextStyle(color: AppColors.textSecondary)),
                  ],
                ),
              )
            else ...[
              // 헤더: 전체 선택 + 다운로드 버튼
              Row(
                children: [
                  Checkbox(
                    value: allSelected,
                    onChanged: _downloading ? null : (v) {
                      setState(() {
                        for (final item in syncItems) {
                          if (!item.done) item.selected = v ?? false;
                        }
                      });
                    },
                    activeColor: AppColors.primary,
                  ),
                  Text(
                    '전체 선택 ($selectedCount/${syncItems.length}곡)',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: (selectedCount == 0 || _downloading) ? null : _downloadSelected,
                    icon: _downloading
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.download, size: 16),
                    label: Text(_downloading ? '다운로드 중...' : '다운로드'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: AppColors.surface,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              // 곡 목록
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: syncItems.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.background),
                  itemBuilder: (_, i) {
                    final item = syncItems[i];
                    return CheckboxListTile(
                      value: item.selected,
                      onChanged: (item.done || _downloading) ? null : (v) {
                        setState(() => item.selected = v ?? false);
                      },
                      activeColor: AppColors.primary,
                      title: Text(
                        item.title,
                        style: TextStyle(
                          color: item.done ? AppColors.textSecondary : AppColors.textPrimary,
                          fontSize: 14,
                          decoration: item.done ? TextDecoration.lineThrough : null,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: item.error != null
                          ? Text(item.error!, style: const TextStyle(color: Colors.redAccent, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis)
                          : Text(item.videoId, style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                      secondary: item.downloading
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary))
                          : item.done
                              ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
                              : item.song != null
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: CachedNetworkImage(
                                        imageUrl: item.song!.thumbnailUrl,
                                        width: 36, height: 36, fit: BoxFit.cover,
                                        errorWidget: (_, __, ___) => const Icon(Icons.music_note, color: AppColors.textSecondary, size: 20),
                                      ),
                                    )
                                  : const Icon(Icons.music_note, color: AppColors.textSecondary, size: 20),
                    );
                  },
                ),
              ),
            ],
          ],

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

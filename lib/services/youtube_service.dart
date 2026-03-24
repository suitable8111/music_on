import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../data/models/song.dart';
import '../core/utils/youtube_utils.dart';

class YoutubeService {
  final _yt = YoutubeExplode();

  /// 서버 API 호출 시 사용할 인증 토큰 (앱 로그인 후 설정됨)
  static String? authToken;

  static Map<String, String> get _authHeaders =>
      authToken != null ? {'Authorization': 'Bearer $authToken'} : {};

  Future<Song> fetchSongInfo(String url) async {
    final videoId = YoutubeUtils.extractVideoId(url);
    if (videoId == null) throw Exception('유효하지 않은 YouTube URL입니다.');
    return fetchSongInfoById(videoId, youtubeUrl: url);
  }

  /// videoId로 직접 YouTube 메타데이터(제목·아티스트·썸네일·가사) 조회
  Future<Song> fetchSongInfoById(String videoId, {String? youtubeUrl}) async {
    final video = await _yt.videos.get(videoId);
    final lyrics = await _fetchLyrics(videoId);
    return Song(
      id: videoId,
      title: video.title,
      channelName: video.author,
      thumbnailUrl: YoutubeUtils.thumbnailUrl(videoId),
      youtubeUrl: youtubeUrl ?? 'https://www.youtube.com/watch?v=$videoId',
      addedAt: DateTime.now(),
      lyrics: lyrics,
    );
  }

  /// 자막(closed captions)에서 가사 추출 — 없으면 null 반환
  Future<String?> _fetchLyrics(String videoId) async {
    try {
      final manifest = await _yt.videos.closedCaptions.getManifest(videoId);
      if (manifest.tracks.isEmpty) return null;

      // 한국어 → 영어 → 첫 번째 트랙 순으로 시도
      final track = manifest.tracks.firstWhere(
        (t) => t.language.code == 'ko',
        orElse: () => manifest.tracks.firstWhere(
          (t) => t.language.code == 'en',
          orElse: () => manifest.tracks.first,
        ),
      );

      final captions = await _yt.videos.closedCaptions.get(track);
      if (captions.captions.isEmpty) return null;

      return captions.captions.map((c) => c.text.trim()).join('\n');
    } catch (_) {
      return null;
    }
  }

  /// 로컬 캐시 파일 경로 (Documents/music_on_cache/)
  Future<File> _cacheFile(String videoId) async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/music_on_cache');
    await cacheDir.create(recursive: true);
    return File('${cacheDir.path}/$videoId.mp3');
  }

  /// 로컬 캐시에서만 파일 경로 반환. 없으면 예외 발생.
  Future<String> getLocalAudioFilePath(String videoId) async {
    final file = await _cacheFile(videoId);
    if (await file.exists()) return file.path;
    throw Exception('로컬 파일 없음: $videoId\n먼저 서버에서 다운로드하세요.');
  }

  /// 캐시가 있으면 즉시 반환, 없으면 서버에서 다운로드 후 저장.
  Future<String> getAudioFilePath(
    String videoId,
    String serverUrl, {
    void Function(int received, int total)? onProgress,
  }) async {
    final file = await _cacheFile(videoId);

    // 캐시 히트 → 서버 불필요
    if (await file.exists()) return file.path;

    if (serverUrl.isEmpty) {
      throw Exception('서버 주소가 설정되지 않았습니다.\n설정에서 Mac 서버 주소를 입력하세요.');
    }

    // 서버에서 스트리밍 다운로드 → 로컬 저장
    final base = serverUrl.endsWith('/') ? serverUrl : '$serverUrl/';
    final uri = Uri.parse('${base}audio?id=$videoId');

    final client = http.Client();
    try {
      final request = http.Request('GET', uri)..headers.addAll(_authHeaders);
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw Exception('서버 오류 ${response.statusCode}');
      }

      final total = response.contentLength ?? 0;
      int received = 0;
      final tmpFile = File('${file.path}.tmp');
      final sink = tmpFile.openWrite();

      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
        await sink.close();
        await tmpFile.rename(file.path);
      } catch (e) {
        await sink.close();
        if (await tmpFile.exists()) await tmpFile.delete();
        rethrow;
      }
    } finally {
      client.close();
    }

    return file.path;
  }

  /// 로컬 캐시에 저장된 videoId 목록 반환
  Future<List<String>> getLocalCachedIds() async {
    final file = await _cacheFile('_dummy_');
    final cacheDir = file.parent;
    if (!await cacheDir.exists()) return [];
    final entities = await cacheDir.list().toList();
    return entities
        .whereType<File>()
        .where((f) => f.path.endsWith('.mp3'))
        .map((f) => f.uri.pathSegments.last.replaceAll('.mp3', ''))
        .toList();
  }

  /// 서버에 캐시된 곡 목록 반환 [{id, title}]
  Future<List<Map<String, String>>> fetchServerSongs(String serverUrl) async {
    final base = serverUrl.endsWith('/') ? serverUrl : '$serverUrl/';
    final res = await http
        .get(Uri.parse('${base}list'), headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('서버 오류: ${res.statusCode}');
    final list = jsonDecode(res.body) as List;
    return list.map((e) {
      if (e is Map) {
        return {'id': e['id'] as String, 'title': (e['title'] as String?) ?? e['id'] as String};
      }
      final id = e.toString();
      return {'id': id, 'title': id};
    }).toList();
  }

  /// 서버에 캐시된 videoId 목록만 반환 (하위 호환)
  Future<List<String>> fetchServerIds(String serverUrl) async {
    final songs = await fetchServerSongs(serverUrl);
    return songs.map((s) => s['id']!).toList();
  }

  /// YouTube 검색 첫 페이지 반환 (약 20개)
  Future<VideoSearchList> searchVideos(String query) async {
    return _yt.search.search(query);
  }

  /// 다음 페이지 로드 — 없으면 null 반환
  Future<VideoSearchList?> searchNextPage(VideoSearchList current) async {
    return current.nextPage();
  }

  /// 특정 곡 캐시 삭제
  Future<void> clearCache(String videoId) async {
    final file = await _cacheFile(videoId);
    if (await file.exists()) await file.delete();
  }

  void dispose() => _yt.close();
}

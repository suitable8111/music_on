import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/audio_handler.dart' show PlaybackMode;

const _boxName = 'settings';
const _serverKey = 'server_url';

/// IP(또는 IP:PORT) 입력을 완전한 URL로 정규화
/// 예: "192.168.0.10" → "http://192.168.0.10:8888"
///     "192.168.0.10:9000" → "http://192.168.0.10:9000"
String normalizeServerUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return '';
  // http(s):// 제거
  if (s.startsWith('https://')) s = s.substring(8);
  if (s.startsWith('http://')) s = s.substring(7);
  // 포트가 없으면 기본 8888 추가
  if (!s.contains(':')) s = '$s:8888';
  return 'http://$s';
}

/// 저장된 전체 URL에서 표시용 IP(:PORT) 추출
String displayServerUrl(String stored) {
  var s = stored;
  if (s.startsWith('https://')) s = s.substring(8);
  if (s.startsWith('http://')) s = s.substring(7);
  // 기본 포트면 포트 숨기기
  if (s.endsWith(':8888')) s = s.substring(0, s.length - 5);
  return s;
}

final serverUrlProvider = StateNotifierProvider<ServerUrlNotifier, String>((ref) {
  final box = Hive.box(_boxName);
  final saved = box.get(_serverKey, defaultValue: '') as String;
  return ServerUrlNotifier(box, saved);
});

class ServerUrlNotifier extends StateNotifier<String> {
  final Box _box;
  ServerUrlNotifier(this._box, String initial) : super(initial);

  void set(String input) {
    final url = normalizeServerUrl(input);
    state = url;
    _box.put(_serverKey, url);
  }
}

const _playbackModeKey = 'playback_mode';

final playbackModeProvider = StateNotifierProvider<PlaybackModeNotifier, PlaybackMode>((ref) {
  final box = Hive.box(_boxName);
  final saved = box.get(_playbackModeKey, defaultValue: 'repeatAll') as String;
  final mode = PlaybackMode.values.firstWhere((e) => e.name == saved, orElse: () => PlaybackMode.repeatAll);
  return PlaybackModeNotifier(box, mode);
});

class PlaybackModeNotifier extends StateNotifier<PlaybackMode> {
  final Box _box;
  PlaybackModeNotifier(this._box, PlaybackMode initial) : super(initial);

  void set(PlaybackMode mode) {
    state = mode;
    _box.put(_playbackModeKey, mode.name);
  }
}

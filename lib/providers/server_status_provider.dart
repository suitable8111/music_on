import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'server_provider.dart';
import '../services/youtube_service.dart';

enum ServerStatus { checking, connected, disconnected }

final serverStatusProvider =
    StateNotifierProvider<ServerStatusNotifier, ServerStatus>((ref) {
  return ServerStatusNotifier(ref);
});

class ServerStatusNotifier extends StateNotifier<ServerStatus> {
  final Ref _ref;

  ServerStatusNotifier(this._ref) : super(ServerStatus.checking) {
    _check();
    // URL이 바뀔 때만 재확인 (주기적 타이머 제거 - 백그라운드 서버 호출 방지)
    _ref.listen(serverUrlProvider, (_, __) => _check());
  }

  Future<void> refresh() => _check();

  Future<void> _check() async {
    final serverUrl = _ref.read(serverUrlProvider);
    if (serverUrl.isEmpty) {
      state = ServerStatus.disconnected;
      return;
    }
    state = ServerStatus.checking;
    try {
      final base = serverUrl.endsWith('/') ? serverUrl : '$serverUrl/';
      final token = YoutubeService.authToken;
      final headers = token != null ? {'Authorization': 'Bearer $token'} : <String, String>{};
      final res = await http
          .get(Uri.parse('${base}ping'), headers: headers)
          .timeout(const Duration(seconds: 4));
      state = res.statusCode == 200
          ? ServerStatus.connected
          : ServerStatus.disconnected;
    } catch (_) {
      state = ServerStatus.disconnected;
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../../core/constants/app_colors.dart';
import '../../core/utils/youtube_utils.dart';
import '../../providers/audio_provider.dart';
import '../../providers/downloaded_songs_provider.dart';
import '../../providers/playlist_provider.dart';
import '../../providers/server_provider.dart';
import '../../services/youtube_service.dart';
import 'player_screen.dart';

class SearchScreen extends ConsumerStatefulWidget {
  /// null 이면 일반 다운로드, 값이 있으면 해당 플레이리스트에 추가
  final String? targetPlaylistId;

  const SearchScreen({super.key, this.targetPlaylistId});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _youtubeService = YoutubeService();
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();

  List<Video>? _results;
  bool _searching = false;
  final Map<String, _DownloadState> _downloadStates = {};
  final Map<String, Timer> _progressTimers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    for (final t in _progressTimers.values) { t.cancel(); }
    _youtubeService.dispose();
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    _focusNode.unfocus();
    setState(() { _searching = true; _results = null; });
    try {
      final results = await _youtubeService.searchVideos(query);
      if (mounted) setState(() => _results = results);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('검색 오류: $e'), backgroundColor: AppColors.primary),
        );
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _startProgressPolling(String videoId, String serverUrl) {
    _progressTimers[videoId]?.cancel();
    _progressTimers[videoId] = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final base = serverUrl.endsWith('/') ? serverUrl : '$serverUrl/';
        final token = YoutubeService.authToken;
        final headers = token != null ? {'Authorization': 'Bearer $token'} : <String, String>{};
        final res = await http.get(
          Uri.parse('${base}progress?id=$videoId'),
          headers: headers,
        ).timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final percent = (data['percent'] as num?)?.toInt() ?? 0;
          if (mounted) {
            setState(() => _downloadStates[videoId] = _DownloadState.progress(percent));
          }
        }
      } catch (_) {}
    });
  }

  Future<void> _downloadAndPlay(Video video) async {
    final id = video.id.value;
    if (_downloadStates[id]?.isLoading == true) return;

    setState(() => _downloadStates[id] = _DownloadState.progress(0));

    final serverUrl = ref.read(serverUrlProvider);
    _startProgressPolling(id, serverUrl);

    try {
      final song = await _youtubeService.fetchSongInfoById(id);
      await _youtubeService.getAudioFilePath(id, serverUrl).timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw Exception('다운로드 시간 초과'),
      );
      _progressTimers[id]?.cancel();
      _progressTimers.remove(id);

      await ref.read(downloadedSongsProvider.notifier).saveSong(song);

      // 플레이리스트 추가 모드
      if (widget.targetPlaylistId != null) {
        if (mounted) setState(() => _downloadStates[id] = _DownloadState.adding());
        await ref.read(playlistProvider.notifier).addSong(widget.targetPlaylistId!, song);
        if (mounted) {
          setState(() => _downloadStates[id] = _DownloadState.done());
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('"${song.title}" 플레이리스트에 추가됐습니다'), backgroundColor: AppColors.primary),
          );
        }
      } else {
        await ref.read(playerProvider.notifier).playSong(song);
        if (mounted) {
          setState(() => _downloadStates[id] = _DownloadState.done());
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PlayerScreen()),
          );
        }
      }
    } catch (e) {
      _progressTimers[id]?.cancel();
      _progressTimers.remove(id);
      if (mounted) {
        setState(() => _downloadStates[id] = _DownloadState.error(e.toString()));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('오류: $e'), backgroundColor: AppColors.primary),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPlaylistMode = widget.targetPlaylistId != null;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: TextField(
          controller: _searchController,
          focusNode: _focusNode,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 16),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: isPlaylistMode ? '플레이리스트에 추가할 곡 검색' : '곡 제목, 아티스트 검색',
            hintStyle: const TextStyle(color: AppColors.textSecondary),
            border: InputBorder.none,
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, color: AppColors.textSecondary, size: 18),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _results = null);
                      _focusNode.requestFocus();
                    },
                  )
                : null,
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _search(),
        ),
        actions: [
          TextButton(
            onPressed: _searching ? null : _search,
            child: _searching
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary))
                : const Text('검색', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    }

    final results = _results;
    if (results == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 72, color: AppColors.textSecondary.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            const Text('검색어를 입력하세요', style: TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      );
    }

    if (results.isEmpty) {
      return const Center(
        child: Text('검색 결과가 없습니다', style: TextStyle(color: AppColors.textSecondary)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: results.length,
      itemBuilder: (_, i) {
        final video = results[i];
        final id = video.id.value;
        final state = _downloadStates[id];
        final thumbnailUrl = YoutubeUtils.thumbnailUrl(id);
        final duration = video.duration;
        final durationText = duration != null
            ? '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}'
            : '';

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: CachedNetworkImage(
              imageUrl: thumbnailUrl,
              width: 64,
              height: 48,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Container(
                width: 64, height: 48,
                color: AppColors.surface,
                child: const Icon(Icons.music_note, color: AppColors.textSecondary),
              ),
            ),
          ),
          title: Text(
            video.title,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${video.author}${durationText.isNotEmpty ? ' · $durationText' : ''}',
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: _buildTrailing(state, video),
          onTap: () => _downloadAndPlay(video),
        );
      },
    );
  }

  Widget _buildTrailing(_DownloadState? state, Video video) {
    if (state?.isDone == true) {
      return const Icon(Icons.check_circle, color: Colors.green, size: 24);
    }
    if (state?.isAdding == true) {
      return const SizedBox(
        width: 64,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.green)),
            SizedBox(height: 3),
            Text('추가 중', style: TextStyle(color: Colors.green, fontSize: 10)),
          ],
        ),
      );
    }
    if (state?.isLoading == true) {
      final pct = state!.percent;
      return SizedBox(
        width: 40,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 24, height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
                value: pct > 0 ? pct / 100.0 : null,
              ),
            ),
            if (pct > 0) ...[
              const SizedBox(height: 2),
              Text('$pct%', style: const TextStyle(color: AppColors.textSecondary, fontSize: 10)),
            ],
          ],
        ),
      );
    }
    if (state?.error != null) {
      return const Icon(Icons.error_outline, color: Colors.redAccent, size: 24);
    }
    return Icon(
      widget.targetPlaylistId != null ? Icons.playlist_add : Icons.download_outlined,
      color: AppColors.textSecondary,
      size: 24,
    );
  }
}

class _DownloadState {
  final bool isLoading;
  final bool isDone;
  final bool isAdding;
  final int percent;
  final String? error;

  const _DownloadState._({this.isLoading = false, this.isDone = false, this.isAdding = false, this.percent = 0, this.error});
  factory _DownloadState.progress(int pct) => _DownloadState._(isLoading: true, percent: pct);
  factory _DownloadState.adding() => const _DownloadState._(isAdding: true);
  factory _DownloadState.done() => const _DownloadState._(isDone: true);
  factory _DownloadState.error(String msg) => _DownloadState._(error: msg);
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../core/constants/app_colors.dart';
import '../../providers/audio_provider.dart';
import '../../providers/downloaded_songs_provider.dart';
import '../../providers/favorites_provider.dart';
import '../widgets/song_tile.dart';
import 'player_screen.dart';

class DownloadedSongsScreen extends ConsumerStatefulWidget {
  const DownloadedSongsScreen({super.key});

  @override
  ConsumerState<DownloadedSongsScreen> createState() => _DownloadedSongsScreenState();
}

class _DownloadedSongsScreenState extends ConsumerState<DownloadedSongsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final songs = ref.watch(downloadedSongsProvider);
    final playerState = ref.watch(playerProvider);
    final favorites = ref.watch(favoritesProvider);

    final filtered = _query.isEmpty
        ? songs
        : songs.where((s) =>
            s.title.toLowerCase().contains(_query.toLowerCase()) ||
            s.channelName.toLowerCase().contains(_query.toLowerCase())).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: '다운로드된 곡 검색',
              hintStyle: const TextStyle(color: AppColors.textSecondary),
              prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
              filled: true,
              fillColor: AppColors.card,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        if (songs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.download_done, size: 14, color: AppColors.textSecondary),
                const SizedBox(width: 6),
                Text('${songs.length}곡 저장됨', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.play_arrow, color: AppColors.primary, size: 18),
                  label: const Text('전체 재생', style: TextStyle(color: AppColors.primary, fontSize: 12)),
                  onPressed: () {
                    if (songs.isNotEmpty) {
                      ref.read(playerProvider.notifier).playSong(
                        songs.first,
                        queue: songs,
                        index: 0,
                      );
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const PlayerScreen()),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.download_outlined, size: 64, color: AppColors.textSecondary.withValues(alpha: 0.4)),
                      const SizedBox(height: 16),
                      Text(
                        _query.isEmpty ? '다운로드된 곡이 없습니다' : '검색 결과가 없습니다',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      if (_query.isEmpty) ...[
                        const SizedBox(height: 8),
                        const Text(
                          '곡을 재생하면 자동으로 저장됩니다',
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: filtered.length,
                  itemBuilder: (ctx, i) {
                    final song = filtered[i];
                    final isPlaying = playerState.currentSong?.id == song.id;
                    final isFav = favorites.any((s) => s.id == song.id);
                    return Slidable(
                      key: ValueKey(song.id),
                      endActionPane: ActionPane(
                        motion: const DrawerMotion(),
                        children: [
                          SlidableAction(
                            onPressed: (_) => ref.read(favoritesProvider.notifier).toggle(song),
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.white,
                            icon: isFav ? Icons.favorite : Icons.favorite_border,
                            label: isFav ? '즐찾 해제' : '즐겨찾기',
                          ),
                          SlidableAction(
                            onPressed: (_) async {
                              await ref.read(downloadedSongsProvider.notifier).removeSong(song.id);
                            },
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            icon: Icons.delete_outline,
                            label: '삭제',
                          ),
                        ],
                      ),
                      child: SongTile(
                        song: song,
                        isPlaying: isPlaying,
                        isFavorite: isFav,
                        onTap: () {
                          ref.read(playerProvider.notifier).playSong(
                            song,
                            queue: filtered,
                            index: i,
                          );
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const PlayerScreen()),
                          );
                        },
                        onFavoriteToggle: () => ref.read(favoritesProvider.notifier).toggle(song),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

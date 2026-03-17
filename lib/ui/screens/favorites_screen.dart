import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../core/constants/app_colors.dart';
import '../../providers/audio_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/playlist_provider.dart';
import '../widgets/song_tile.dart';
import 'player_screen.dart';

class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final favorites = ref.watch(favoritesProvider);
    final playerState = ref.watch(playerProvider);

    final filtered = _query.isEmpty
        ? favorites
        : favorites.where((s) =>
            s.title.toLowerCase().contains(_query.toLowerCase()) ||
            s.channelName.toLowerCase().contains(_query.toLowerCase())).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: '즐겨찾기 검색',
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
        if (favorites.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Text('${favorites.length}곡', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.play_arrow, color: AppColors.primary, size: 18),
                  label: const Text('전체 재생', style: TextStyle(color: AppColors.primary, fontSize: 12)),
                  onPressed: () {
                    if (favorites.isNotEmpty) {
                      ref.read(playerProvider.notifier).playSong(
                        favorites.first,
                        queue: favorites,
                        index: 0,
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
                      Icon(Icons.favorite_border, size: 64, color: AppColors.textSecondary.withValues(alpha: 0.4)),
                      const SizedBox(height: 16),
                      Text(
                        _query.isEmpty ? '즐겨찾기가 비어있습니다' : '검색 결과가 없습니다',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: filtered.length,
                  itemBuilder: (ctx, i) {
                    final song = filtered[i];
                    final isPlaying = playerState.currentSong?.id == song.id;
                    return Slidable(
                      key: ValueKey(song.id),
                      endActionPane: ActionPane(
                        motion: const DrawerMotion(),
                        children: [
                          SlidableAction(
                            onPressed: (_) => _showAddToPlaylist(song),
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.white,
                            icon: Icons.playlist_add,
                            label: '플레이리스트',
                          ),
                          SlidableAction(
                            onPressed: (_) => ref.read(favoritesProvider.notifier).toggle(song),
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
                        isFavorite: true,
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

  void _showAddToPlaylist(song) {
    final playlists = ref.read(playlistProvider);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('플레이리스트에 추가', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          if (playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('플레이리스트가 없습니다', style: TextStyle(color: AppColors.textSecondary)),
            )
          else
            ...playlists.map((pl) => ListTile(
              leading: const Icon(Icons.queue_music, color: AppColors.primary),
              title: Text(pl.name, style: const TextStyle(color: AppColors.textPrimary)),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                await ref.read(playlistProvider.notifier).addSong(pl.id, song);
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                messenger.showSnackBar(
                  SnackBar(content: Text('"${pl.name}"에 추가됐습니다'), backgroundColor: AppColors.primary),
                );
              },
            )),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

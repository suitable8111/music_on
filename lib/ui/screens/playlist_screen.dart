import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../core/constants/app_colors.dart';
import '../../data/models/playlist.dart';
import '../../providers/audio_provider.dart';
import '../../providers/downloaded_songs_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/playlist_provider.dart';
import '../../providers/server_provider.dart';
import '../../services/youtube_service.dart';
import '../widgets/add_url_dialog.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_tile.dart';
import 'player_screen.dart';
import 'search_screen.dart';

class PlaylistScreen extends ConsumerWidget {
  const PlaylistScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistProvider);

    return Column(
      children: [
        Expanded(
          child: playlists.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.queue_music, size: 64, color: AppColors.textSecondary.withValues(alpha: 0.4)),
                      const SizedBox(height: 16),
                      const Text('플레이리스트가 없습니다', style: TextStyle(color: AppColors.textSecondary)),
                      const SizedBox(height: 8),
                      const Text('+ 버튼을 눌러 만들어보세요', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    ],
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                  itemCount: playlists.length,
                  onReorder: (oldIndex, newIndex) {
                    if (newIndex > oldIndex) newIndex--;
                    ref.read(playlistProvider.notifier).reorderPlaylists(oldIndex, newIndex);
                  },
                  proxyDecorator: (child, index, animation) => Material(
                    color: Colors.transparent,
                    child: ScaleTransition(
                      scale: animation.drive(Tween(begin: 1.0, end: 1.03)
                          .chain(CurveTween(curve: Curves.easeOut))),
                      child: child,
                    ),
                  ),
                  itemBuilder: (ctx, i) {
                    final pl = playlists[i];
                    return _PlaylistCard(
                      key: ValueKey(pl.id),
                      playlist: pl,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlist: pl)),
                      ),
                      onMenuTap: () => _showCardMenu(context, ref, pl),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // 롱프레스 메뉴 대신 카드 자체에서 처리
  // (ReorderableListView가 롱프레스를 drag로 사용하므로 별도 메뉴 버튼 사용)
  void _showCardMenu(BuildContext context, WidgetRef ref, Playlist pl) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(pl.name, style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          ListTile(
            leading: const Icon(Icons.edit, color: AppColors.accent),
            title: const Text('이름 변경', style: TextStyle(color: AppColors.textPrimary)),
            onTap: () { Navigator.pop(ctx); _showRenameDialog(context, ref, pl); },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: AppColors.primary),
            title: const Text('삭제', style: TextStyle(color: AppColors.primary)),
            onTap: () { Navigator.pop(ctx); _confirmDelete(context, ref, pl); },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  void _showRenameDialog(BuildContext context, WidgetRef ref, Playlist pl) {
    final ctrl = TextEditingController(text: pl.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('이름 변경', style: TextStyle(color: AppColors.textPrimary)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소', style: TextStyle(color: AppColors.textSecondary))),
          ElevatedButton(
            onPressed: () async {
              if (ctrl.text.trim().isNotEmpty) {
                await ref.read(playlistProvider.notifier).rename(pl.id, ctrl.text.trim());
              }
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('저장', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, Playlist pl) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text('"${pl.name}" 삭제', style: const TextStyle(color: AppColors.textPrimary)),
        content: const Text('플레이리스트를 삭제할까요?', style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소', style: TextStyle(color: AppColors.textSecondary))),
          ElevatedButton(
            onPressed: () async {
              await ref.read(playlistProvider.notifier).delete(pl.id);
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('삭제', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

// 드래그 가능한 플레이리스트 카드
class _PlaylistCard extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback onTap;
  final VoidCallback onMenuTap;

  const _PlaylistCard({
    super.key,
    required this.playlist,
    required this.onTap,
    required this.onMenuTap,
  });

  @override
  Widget build(BuildContext context) {
    final pl = playlist;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 88,
            child: Row(
              children: [
                // 썸네일 미리보기
                SizedBox(
                  width: 88,
                  height: 88,
                  child: pl.songs.isEmpty
                      ? Container(
                          color: AppColors.surface,
                          child: const Icon(Icons.queue_music, color: AppColors.primary, size: 36),
                        )
                      : GridView.count(
                          crossAxisCount: 2,
                          physics: const NeverScrollableScrollPhysics(),
                          children: pl.songs.take(4).map((s) =>
                            Image.network(
                              s.thumbnailUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: AppColors.surface,
                                child: const Icon(Icons.music_note, color: AppColors.primary, size: 16),
                              ),
                            ),
                          ).toList(),
                        ),
                ),
                const SizedBox(width: 14),
                // 제목 + 곡 수
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pl.name,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${pl.songs.length}곡',
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                // 메뉴 버튼
                IconButton(
                  icon: const Icon(Icons.more_vert, color: AppColors.textSecondary, size: 20),
                  onPressed: onMenuTap,
                ),
                // 드래그 핸들
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: Icon(Icons.drag_handle, color: AppColors.textSecondary, size: 22),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  final Playlist playlist;
  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  ConsumerState<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  final _youtubeService = YoutubeService();
  bool _isAdding = false;

  @override
  void dispose() {
    _youtubeService.dispose();
    super.dispose();
  }

  Future<void> _addFromUrl(Playlist current) async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const AddUrlDialog(),
    );
    if (url == null) return;

    setState(() => _isAdding = true);
    try {
      final song = await _youtubeService.fetchSongInfo(url);
      // 서버에서 먼저 다운로드 (이후 재생은 로컬에서만)
      final serverUrl = ref.read(serverUrlProvider);
      await _youtubeService.getAudioFilePath(song.id, serverUrl).timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw Exception('다운로드 시간 초과 (5분)\n서버 실행 여부 및 네트워크를 확인하세요.'),
      );
      await ref.read(downloadedSongsProvider.notifier).saveSong(song);
      await ref.read(playlistProvider.notifier).addSong(current.id, song);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('"${song.title}" 추가됐습니다'),
            backgroundColor: AppColors.primary,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('오류: ${e.toString()}'), backgroundColor: AppColors.primary),
        );
      }
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistProvider);
    final current = playlists.firstWhere((p) => p.id == widget.playlist.id, orElse: () => widget.playlist);
    final playerState = ref.watch(playerProvider);
    final favorites = ref.watch(favoritesProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: Text(current.name, style: const TextStyle(color: AppColors.textPrimary)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (current.songs.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.play_arrow, color: AppColors.primary),
              label: const Text('전체 재생', style: TextStyle(color: AppColors.primary, fontSize: 12)),
              onPressed: () => ref.read(playerProvider.notifier).playSong(
                current.songs.first,
                queue: current.songs,
                index: 0,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.search, color: AppColors.primary),
            tooltip: '검색해서 추가',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SearchScreen(targetPlaylistId: current.id),
              ),
            ),
          ),
          _isAdding
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.add_link, color: AppColors.primary),
                  onPressed: () => _addFromUrl(current),
                  tooltip: 'YouTube 링크 추가',
                ),
        ],
      ),
      body: Stack(
        children: [
          current.songs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.music_off, size: 64, color: AppColors.textSecondary.withValues(alpha: 0.4)),
                      const SizedBox(height: 16),
                      const Text('곡이 없습니다', style: TextStyle(color: AppColors.textSecondary)),
                    ],
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 100),
                  itemCount: current.songs.length,
                  onReorder: (oldIndex, newIndex) {
                    if (newIndex > oldIndex) newIndex--;
                    ref.read(playlistProvider.notifier).reorder(current.id, oldIndex, newIndex);
                  },
                  itemBuilder: (ctx, i) {
                    final song = current.songs[i];
                    final isPlaying = playerState.currentSong?.id == song.id;
                    final isFav = favorites.any((s) => s.id == song.id);
                    return Slidable(
                      key: ValueKey('${current.id}_${song.id}'),
                      endActionPane: ActionPane(
                        motion: const DrawerMotion(),
                        children: [
                          SlidableAction(
                            onPressed: (_) => ref.read(playlistProvider.notifier).removeSong(current.id, song.id),
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            icon: Icons.remove_circle_outline,
                            label: '제거',
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
                            queue: current.songs,
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
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [MiniPlayer(), SizedBox(height: 4)],
            ),
          ),
        ],
      ),
    );
  }
}

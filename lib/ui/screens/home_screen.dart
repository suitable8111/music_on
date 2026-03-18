import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../providers/audio_provider.dart';
import '../../providers/playlist_provider.dart';
import '../../providers/server_provider.dart';
import '../../providers/server_status_provider.dart';
import '../../services/youtube_service.dart';
import '../widgets/add_url_dialog.dart';
import '../widgets/mini_player.dart';
import 'downloaded_songs_screen.dart';
import 'favorites_screen.dart';
import 'player_screen.dart';
import 'playlist_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _youtubeService = YoutubeService();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _youtubeService.dispose();
    super.dispose();
  }

  Future<void> _addAndPlayUrl() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const AddUrlDialog(),
    );
    if (url == null) return;

    setState(() => _isLoading = true);
    try {
      final song = await _youtubeService.fetchSongInfo(url);
      // 서버에서 먼저 다운로드 (이후 재생은 로컬에서만)
      final serverUrl = ref.read(serverUrlProvider);
      await _youtubeService.getAudioFilePath(song.id, serverUrl).timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw Exception('다운로드 시간 초과 (5분)\n서버 실행 여부 및 네트워크를 확인하세요.'),
      );
      await ref.read(playerProvider.notifier).playSong(song);
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PlayerScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('오류: ${e.toString()}'), backgroundColor: AppColors.primary),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _createPlaylist() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('새 플레이리스트', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: '플레이리스트 이름',
            hintStyle: const TextStyle(color: AppColors.textSecondary),
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소', style: TextStyle(color: AppColors.textSecondary))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('만들기', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await ref.read(playlistProvider.notifier).create(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'M',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'Music On',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 22,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search, color: AppColors.primary),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen())),
            tooltip: 'YouTube 검색',
          ),
          if (_tabController.index == 0)
            IconButton(
              icon: const Icon(Icons.add, color: AppColors.primary),
              onPressed: _createPlaylist,
              tooltip: '플레이리스트 만들기',
            ),
          _isLoading
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.add_link, color: AppColors.primary),
                  onPressed: _addAndPlayUrl,
                  tooltip: 'YouTube 링크 가져오기',
                ),
          IconButton(
            icon: const Icon(Icons.settings, color: AppColors.textSecondary),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
            tooltip: '설정',
          ),
        ],
        bottom: _TabBarBottom(
          tabController: _tabController,
          onTabTap: (_) => setState(() {}),
        ),
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tabController,
            children: const [
              PlaylistScreen(),
              FavoritesScreen(),
              DownloadedSongsScreen(),
            ],
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ServerStatusBar(),
                MiniPlayer(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabBarBottom extends StatelessWidget implements PreferredSizeWidget {
  final TabController tabController;
  final void Function(int) onTabTap;

  const _TabBarBottom({required this.tabController, required this.onTabTap});

  @override
  Size get preferredSize => const Size.fromHeight(kTextTabBarHeight);

  @override
  Widget build(BuildContext context) {
    return TabBar(
      controller: tabController,
      indicatorColor: AppColors.primary,
      indicatorWeight: 3,
      labelColor: AppColors.primary,
      unselectedLabelColor: AppColors.textSecondary,
      labelStyle: const TextStyle(fontWeight: FontWeight.bold),
      onTap: onTabTap,
      tabs: const [
        Tab(icon: Icon(Icons.queue_music, size: 18), text: '플레이리스트'),
        Tab(icon: Icon(Icons.favorite, size: 18), text: '즐겨찾기'),
        Tab(icon: Icon(Icons.download_done, size: 18), text: '받은 곡'),
      ],
    );
  }
}

class _ServerStatusBar extends ConsumerWidget {
  const _ServerStatusBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(serverStatusProvider);

    final (color, icon, label) = switch (status) {
      ServerStatus.connected => (
          const Color(0xFF4CAF50),
          Icons.cloud_done_outlined,
          '서버 연결됨 · 다운로드 가능',
        ),
      ServerStatus.disconnected => (
          AppColors.primary,
          Icons.cloud_off_outlined,
          '서버 미연결 · 캐시된 곡만 재생',
        ),
      ServerStatus.checking => (
          AppColors.textSecondary,
          Icons.cloud_sync_outlined,
          '서버 확인 중...',
        ),
    };

    return GestureDetector(
      onTap: () => ref.read(serverStatusProvider.notifier).refresh(),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        color: color.withValues(alpha: 0.12),
        child: Row(
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            if (status == ServerStatus.checking)
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(color: color, strokeWidth: 1.5),
              )
            else
              Icon(Icons.refresh, size: 12, color: color.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}

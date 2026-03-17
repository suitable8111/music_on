import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:just_audio/just_audio.dart';
import 'package:palette_generator/palette_generator.dart';
import '../../core/constants/app_colors.dart';
import '../../data/models/song.dart';
import '../../providers/audio_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/playlist_provider.dart';

// 곡별 palette 색상 캐시 provider
final _paletteProvider = StateProvider.family<Color?, String>((ref, videoId) => null);

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with TickerProviderStateMixin {
  late AnimationController _bgAnimController;
  late Animation<Color?> _bgColorAnim;
  Color _currentBg = const Color(0xFF0D0D1A);
  Color _targetBg = const Color(0xFF0D0D1A);
  Color _accentColor = AppColors.primary;
  String? _lastSongId;
  bool _showQueue = false;
  bool _showLyrics = false;

  @override
  void initState() {
    super.initState();
    _bgAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _bgColorAnim = ColorTween(begin: _currentBg, end: _targetBg)
        .animate(CurvedAnimation(parent: _bgAnimController, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _bgAnimController.dispose();
    super.dispose();
  }

  void _updateColors(Song song) async {
    if (_lastSongId == song.id) return;
    _lastSongId = song.id;

    // 캐시된 색상이 있으면 바로 사용
    final cached = ref.read(_paletteProvider(song.id));
    if (cached != null) {
      _animateTo(cached);
      return;
    }

    try {
      final palette = await PaletteGenerator.fromImageProvider(
        NetworkImage(song.thumbnailUrl),
        maximumColorCount: 20,
      );
      final dominant = palette.darkVibrantColor?.color ??
          palette.darkMutedColor?.color ??
          palette.dominantColor?.color ??
          const Color(0xFF0D0D1A);
      final accent = palette.vibrantColor?.color ??
          palette.lightVibrantColor?.color ??
          AppColors.primary;

      // 너무 밝은 색은 어둡게
      final bg = HSLColor.fromColor(dominant)
          .withLightness((HSLColor.fromColor(dominant).lightness * 0.4).clamp(0.0, 0.25))
          .toColor();

      ref.read(_paletteProvider(song.id).notifier).state = bg;
      if (mounted) {
        setState(() => _accentColor = accent);
        _animateTo(bg);
      }
    } catch (_) {}
  }

  void _animateTo(Color target) {
    _currentBg = _bgColorAnim.value ?? _currentBg;
    _targetBg = target;
    _bgColorAnim = ColorTween(begin: _currentBg, end: _targetBg)
        .animate(CurvedAnimation(parent: _bgAnimController, curve: Curves.easeInOut));
    _bgAnimController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final playerState = ref.watch(playerProvider);
    final song = playerState.currentSong;

    if (song != null) {
      _updateColors(song);
      // 가사 없는 곡으로 바뀌면 가사 뷰 닫기
      if (song.lyrics == null && _showLyrics) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _showLyrics = false);
        });
      }
    }

    if (song == null) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(child: Text('재생 중인 곡이 없습니다', style: TextStyle(color: AppColors.textSecondary))),
      );
    }

    return AnimatedBuilder(
      animation: _bgColorAnim,
      builder: (context, _) {
        final bg = _bgColorAnim.value ?? _currentBg;
        return Scaffold(
          backgroundColor: bg,
          body: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [bg, Colors.black.withValues(alpha: 0.95)],
                stops: const [0.0, 0.7],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  _buildAppBar(context, ref, song),
                  Expanded(
                    child: _showQueue
                        ? _buildQueuePanel(context, ref, playerState, song)
                        : _buildPlayerPanel(context, ref, playerState, song),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAppBar(BuildContext context, WidgetRef ref, Song song) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 32, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Column(
              children: [
                const Text('재생 중', style: TextStyle(color: Colors.white54, fontSize: 12, letterSpacing: 1)),
                const SizedBox(height: 2),
                Text(
                  song.title,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          if (song.lyrics != null)
            IconButton(
              icon: Icon(
                Icons.lyrics_outlined,
                color: _showLyrics ? Colors.white : Colors.white38,
              ),
              tooltip: '가사',
              onPressed: () => setState(() => _showLyrics = !_showLyrics),
            ),
          IconButton(
            icon: const Icon(Icons.playlist_add, color: Colors.white),
            onPressed: () => _showAddToPlaylistSheet(context, ref, song),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerPanel(
      BuildContext context, WidgetRef ref, MusicPlayerState playerState, Song song) {
    final favorites = ref.watch(favoritesProvider);
    final isFav = favorites.any((s) => s.id == song.id);

    return Column(
      children: [
        const SizedBox(height: 12),

        // 앨범아트 or 가사
        Expanded(
          flex: 5,
          child: _showLyrics && song.lyrics != null
              ? _buildLyricsView(song.lyrics!)
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.9, end: playerState.isPlaying ? 1.0 : 0.88),
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutBack,
                    builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: _accentColor.withValues(alpha: 0.4),
                            blurRadius: 40,
                            spreadRadius: 5,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: CachedNetworkImage(
                          imageUrl: song.thumbnailUrl,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(color: AppColors.surface),
                          errorWidget: (_, __, ___) => Container(
                            color: AppColors.surface,
                            child: const Icon(Icons.music_note, size: 80, color: AppColors.primary),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
        ),

        const SizedBox(height: 24),

        // 곡 정보
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      song.channelName,
                      style: const TextStyle(color: Colors.white60, fontSize: 14),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  isFav ? Icons.favorite : Icons.favorite_border,
                  color: isFav ? _accentColor : Colors.white60,
                  size: 28,
                ),
                onPressed: () => ref.read(favoritesProvider.notifier).toggle(song),
              ),
            ],
          ),
        ),

        // 에러 메시지
        if (playerState.errorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(playerState.errorMessage!,
                        style: const TextStyle(color: Colors.red, fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),

        const SizedBox(height: 16),

        // 프로그레스바
        _buildProgressBar(playerState, ref),

        const SizedBox(height: 8),

        // 컨트롤
        _buildControls(playerState, ref),

        const SizedBox(height: 12),

        // 대기열 버튼
        GestureDetector(
          onTap: () => setState(() => _showQueue = true),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.queue_music, color: Colors.white38, size: 18),
                const SizedBox(width: 6),
                const Text('다음 재생 목록', style: TextStyle(color: Colors.white38, fontSize: 13)),
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_up, color: Colors.white38, size: 18),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLyricsView(String lyrics) {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
        stops: [0.0, 0.08, 0.92, 1.0],
      ).createShader(bounds),
      blendMode: BlendMode.dstIn,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Text(
          lyrics,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            height: 2.0,
            letterSpacing: 0.2,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildProgressBar(MusicPlayerState playerState, WidgetRef ref) {
    String fmt(Duration d) {
      final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '$m:$s';
    }

    final max = playerState.duration.inMilliseconds.toDouble();
    final value = playerState.position.inMilliseconds
        .toDouble()
        .clamp(0, max > 0 ? max : 1)
        .toDouble();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              overlayColor: Colors.white24,
            ),
            child: Slider(
              value: value,
              max: max > 0 ? max : 1,
              onChanged: (v) => ref.read(playerProvider.notifier).seek(
                    Duration(milliseconds: v.toInt()),
                  ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(fmt(playerState.position),
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
                Text(fmt(playerState.duration),
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(MusicPlayerState playerState, WidgetRef ref) {
    final notifier = ref.read(playerProvider.notifier);

    final (loopIcon, loopColor) = switch (playerState.loopMode) {
      LoopMode.one => (Icons.repeat_one, Colors.white),
      LoopMode.all => (Icons.repeat, Colors.white),
      _ => (Icons.repeat, Colors.white38),
    };

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          icon: Icon(Icons.shuffle,
              color: playerState.isShuffle ? Colors.white : Colors.white38),
          onPressed: notifier.toggleShuffle,
          iconSize: 24,
        ),
        IconButton(
          icon: const Icon(Icons.skip_previous_rounded, color: Colors.white),
          onPressed: notifier.skipToPrevious,
          iconSize: 42,
        ),
        GestureDetector(
          onTap: notifier.togglePlayPause,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: playerState.isLoading
                ? Center(
                    child: CircularProgressIndicator(
                      color: _currentBg,
                      strokeWidth: 2.5,
                    ),
                  )
                : Icon(
                    playerState.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.black87,
                    size: 42,
                  ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
          onPressed: notifier.skipToNext,
          iconSize: 42,
        ),
        IconButton(
          icon: Icon(loopIcon, color: loopColor),
          onPressed: notifier.toggleLoop,
          iconSize: 24,
        ),
      ],
    );
  }

  Widget _buildQueuePanel(
      BuildContext context, WidgetRef ref, MusicPlayerState playerState, Song song) {
    final handler = ref.read(audioHandlerProvider);
    final queue = handler.currentQueue;
    final currentIndex = handler.currentIndex;

    return Column(
      children: [
        // 패널 헤더
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
          child: Row(
            children: [
              const Text('다음 재생 목록',
                  style: TextStyle(
                      color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white70, size: 28),
                onPressed: () => setState(() => _showQueue = false),
              ),
            ],
          ),
        ),

        // 대기열 리스트
        Expanded(
          child: queue.isEmpty
              ? const Center(
                  child: Text('대기열이 비어있습니다', style: TextStyle(color: Colors.white38)))
              : ListView.builder(
                  itemCount: queue.length,
                  padding: const EdgeInsets.only(bottom: 16),
                  itemBuilder: (ctx, i) {
                    final qSong = queue[i];
                    final isCurrent = i == currentIndex;
                    return ListTile(
                      onTap: () {
                        ref.read(playerProvider.notifier).playSong(
                          qSong,
                          queue: queue,
                          index: i,
                        );
                        setState(() => _showQueue = false);
                      },
                      leading: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: CachedNetworkImage(
                              imageUrl: qSong.thumbnailUrl,
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => Container(
                                width: 48,
                                height: 48,
                                color: AppColors.surface,
                                child: const Icon(Icons.music_note, color: AppColors.primary, size: 20),
                              ),
                            ),
                          ),
                          if (isCurrent)
                            Positioned.fill(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.graphic_eq, color: Colors.white, size: 20),
                              ),
                            ),
                        ],
                      ),
                      title: Text(
                        qSong.title,
                        style: TextStyle(
                          color: isCurrent ? Colors.white : Colors.white70,
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        qSong.channelName,
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: isCurrent
                          ? Icon(Icons.volume_up, color: _accentColor, size: 18)
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showAddToPlaylistSheet(BuildContext context, WidgetRef ref, Song song) {
    final playlists = ref.read(playlistProvider);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('플레이리스트에 추가',
                style: TextStyle(
                    color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          if (playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('플레이리스트가 없습니다',
                  style: TextStyle(color: AppColors.textSecondary), textAlign: TextAlign.center),
            )
          else
            ...playlists.map((pl) => ListTile(
                  leading: const Icon(Icons.queue_music, color: AppColors.primary),
                  title: Text(pl.name, style: const TextStyle(color: AppColors.textPrimary)),
                  subtitle: Text('${pl.songs.length}곡',
                      style: const TextStyle(color: AppColors.textSecondary)),
                  onTap: () async {
                    await ref.read(playlistProvider.notifier).addSong(pl.id, song);
                    if (!ctx.mounted) return;
                    Navigator.of(ctx).pop();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text('"${pl.name}"에 추가됐습니다'),
                          backgroundColor: AppColors.primary),
                    );
                  },
                )),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

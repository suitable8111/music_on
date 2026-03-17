import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import '../data/models/song.dart';
import '../data/repositories/downloaded_songs_repository.dart';
import 'youtube_service.dart';

enum PlaybackMode { single, repeatAll, repeatOne }

class MusicAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = AudioPlayer();
  final _youtubeService = YoutubeService();
  // ConcatenatingAudioSource: 현재곡 + 다음곡을 미리 담아 자동 전환 시 completed 상태 없이 이어짐
  final _playlist = ConcatenatingAudioSource(children: []);

  List<Song> _queue = [];
  int _currentIndex = 0;
  bool _shuffle = false;
  PlaybackMode _playbackMode = PlaybackMode.repeatAll;

  String? _loadingId;
  DownloadedSongsRepository? downloadedSongsRepo;

  // 미리 로드해둔 다음 곡의 큐 인덱스 (null이면 미리 로드 없음)
  int? _preloadedNextIndex;

  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  MusicAudioHandler() {
    _initAudioSession();
    _player.playbackEventStream.listen(_broadcastState);
    _player.playingStream.listen((playing) {
      if (playing) {
        AudioSession.instance.then((s) => s.setActive(true));
      }
    });
    // 플레이어가 ConcatenatingAudioSource 내에서 다음 아이템으로 자동 이동할 때 감지
    _player.currentIndexStream.listen(_onPlayerIndexChanged);
  }

  Future<void> _initAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
      avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
      avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        flags: AndroidAudioFlags.none,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      androidWillPauseWhenDucked: true,
    ));
    session.interruptionEventStream.listen((event) {
      if (event.begin) {
        _player.pause();
      } else {
        if (event.type == AudioInterruptionType.pause ||
            event.type == AudioInterruptionType.duck) {
          _player.play();
        }
      }
    });
  }

  // ConcatenatingAudioSource의 currentIndex가 변경될 때 호출
  // index > 0 이면 자동으로 다음 아이템으로 이동한 것
  Future<void> _onPlayerIndexChanged(int? index) async {
    if (index == null || index == 0 || _preloadedNextIndex == null) return;

    _currentIndex = _preloadedNextIndex!;
    _preloadedNextIndex = null;

    final song = _queue[_currentIndex];
    mediaItem.add(MediaItem(
      id: song.id,
      title: song.title,
      artist: song.channelName,
      artUri: Uri.parse(song.thumbnailUrl),
    ));
    await downloadedSongsRepo?.saveSong(song);

    // 재생이 끝난 이전 아이템(index 0) 제거 → 현재 재생 아이템이 index 0으로 이동
    if (_playlist.length > 1) await _playlist.removeAt(0);

    // 그 다음 곡 미리 로드
    _preloadNext();
  }

  // 다음 곡 파일을 미리 playlist에 추가
  Future<void> _preloadNext() async {
    if (_preloadedNextIndex != null) return; // 이미 미리 로드 중

    final int nextIndex;
    switch (_playbackMode) {
      case PlaybackMode.single:
        return; // 한곡만 → 다음 곡 미리 로드 안 함, 현재 곡 끝나면 정지
      case PlaybackMode.repeatOne:
        nextIndex = _currentIndex;
      case PlaybackMode.repeatAll:
        if (_queue.length <= 1) return;
        if (_shuffle) {
          int n;
          do { n = DateTime.now().millisecondsSinceEpoch % _queue.length; }
          while (_queue.length > 1 && n == _currentIndex);
          nextIndex = n;
        } else {
          nextIndex = (_currentIndex + 1) % _queue.length;
        }
    }

    _preloadedNextIndex = nextIndex;
    final nextSong = _queue[nextIndex];

    try {
      final nextFilePath = await _youtubeService.getLocalAudioFilePath(nextSong.id);
      if (_playlist.length == 1) {
        await _playlist.add(AudioSource.file(nextFilePath));
      }
    } catch (_) {
      // 다음 곡 로컬 파일 없음 → 미리 로드 포기 (자동 전환 불가)
      _preloadedNextIndex = null;
    }
  }

  Future<void> playSong(Song song, {List<Song>? queue, int index = 0}) async {
    _loadingId = null;
    _queue = queue ?? [song];
    _currentIndex = index;
    await _loadAndPlay(_queue[_currentIndex]);
  }

  Future<void> _loadAndPlay(Song song) async {
    if (_loadingId == song.id) return;
    final myLoadId = song.id;
    _loadingId = myLoadId;
    _preloadedNextIndex = null;

    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.loading,
    ));

    try {
      // 로컬 캐시에서만 파일 경로 조회 — 서버 요청 없음
      final filePath = await _youtubeService.getLocalAudioFilePath(song.id);

      if (_loadingId != myLoadId) return;

      mediaItem.add(MediaItem(
        id: song.id,
        title: song.title,
        artist: song.channelName,
        artUri: Uri.parse(song.thumbnailUrl),
      ));
      await downloadedSongsRepo?.saveSong(song);

      // ⚠️ stop() 절대 호출 금지 — idle 전환 시 iOS audio session 비활성화됨
      // ConcatenatingAudioSource를 새로 구성하고 setAudioSource 호출
      await _playlist.clear();
      await _playlist.add(AudioSource.file(filePath));
      await _player.setAudioSource(_playlist, initialIndex: 0, initialPosition: Duration.zero);

      if (_loadingId != myLoadId) return;
      final session = await AudioSession.instance;
      await session.setActive(true);
      await _player.play();

      // 다음 곡 미리 로드 (캐시된 파일이므로 즉시 완료)
      _preloadNext();
    } catch (e) {
      if (_loadingId != myLoadId) return;
      _loadingId = null;
      _errorController.add(e.toString());
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
      ));
    } finally {
      if (_loadingId == myLoadId) _loadingId = null;
    }
  }

  bool get mounted => !_errorController.isClosed;

  @override Future<void> play() => _player.play();
  @override Future<void> pause() => _player.pause();
  @override Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() async {
    _loadingId = null;
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    if (_queue.isEmpty) return;
    _loadingId = null;
    if (_shuffle) {
      int next;
      do { next = DateTime.now().millisecondsSinceEpoch % _queue.length; }
      while (_queue.length > 1 && next == _currentIndex);
      _currentIndex = next;
    } else {
      _currentIndex = (_currentIndex + 1) % _queue.length;
    }
    await _loadAndPlay(_queue[_currentIndex]);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_queue.isEmpty) return;
    _loadingId = null;
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
      return;
    }
    _currentIndex = (_currentIndex - 1 + _queue.length) % _queue.length;
    await _loadAndPlay(_queue[_currentIndex]);
  }

  void _invalidatePreload() {
    _preloadedNextIndex = null;
    if (_playlist.length > 1) {
      _playlist.removeAt(1).then((_) => _preloadNext());
    } else {
      _preloadNext();
    }
    _broadcastState(_player.playbackEvent);
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    _invalidatePreload();
  }

  void toggleLoopMode() {
    _playbackMode = switch (_playbackMode) {
      PlaybackMode.single => PlaybackMode.repeatAll,
      PlaybackMode.repeatAll => PlaybackMode.repeatOne,
      PlaybackMode.repeatOne => PlaybackMode.single,
    };
    _invalidatePreload();
  }

  void setPlaybackMode(PlaybackMode mode) {
    _playbackMode = mode;
    _invalidatePreload();
  }

  bool get isShuffle => _shuffle;
  PlaybackMode get playbackMode => _playbackMode;
  LoopMode get loopMode => switch (_playbackMode) {
    PlaybackMode.single => LoopMode.off,
    PlaybackMode.repeatAll => LoopMode.all,
    PlaybackMode.repeatOne => LoopMode.one,
  };
  List<Song> get currentQueue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;
  Song? get currentSong => _queue.isNotEmpty ? _queue[_currentIndex] : null;
  AudioPlayer get player => _player;

  void _broadcastState(PlaybackEvent event) {
    final playing = _player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek, MediaAction.skipToNext, MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      shuffleMode: _shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      repeatMode: switch (_playbackMode) {
        PlaybackMode.single => AudioServiceRepeatMode.none,
        PlaybackMode.repeatAll => AudioServiceRepeatMode.all,
        PlaybackMode.repeatOne => AudioServiceRepeatMode.one,
      },
    ));
  }

  @override
  Future<void> onTaskRemoved() async {
    await stop();
    super.onTaskRemoved();
  }
}

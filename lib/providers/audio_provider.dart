import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import '../data/models/song.dart';
import '../services/audio_handler.dart';
export '../services/audio_handler.dart' show PlaybackMode;

final audioHandlerProvider = Provider<MusicAudioHandler>((ref) {
  throw UnimplementedError('AudioHandler must be initialized in main');
});

class MusicPlayerState {
  final Song? currentSong;
  final bool isPlaying;
  final bool isLoading;
  final String? errorMessage;
  final Duration position;
  final Duration duration;
  final bool isShuffle;
  final LoopMode loopMode;

  const MusicPlayerState({
    this.currentSong,
    this.isPlaying = false,
    this.isLoading = false,
    this.errorMessage,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.isShuffle = false,
    this.loopMode = LoopMode.off,
  });

  MusicPlayerState copyWith({
    Song? currentSong,
    bool? isPlaying,
    bool? isLoading,
    String? errorMessage,
    Duration? position,
    Duration? duration,
    bool? isShuffle,
    LoopMode? loopMode,
    bool clearSong = false,
    bool clearError = false,
  }) {
    return MusicPlayerState(
      currentSong: clearSong ? null : (currentSong ?? this.currentSong),
      isPlaying: isPlaying ?? this.isPlaying,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      position: position ?? this.position,
      duration: duration ?? this.duration,
      isShuffle: isShuffle ?? this.isShuffle,
      loopMode: loopMode ?? this.loopMode,
    );
  }
}

class PlayerNotifier extends StateNotifier<MusicPlayerState> {
  final MusicAudioHandler _handler;

  PlayerNotifier(this._handler) : super(const MusicPlayerState()) {
    // 재생 상태
    _handler.player.playingStream.listen((playing) {
      state = state.copyWith(isPlaying: playing);
    });
    // 재생 위치
    _handler.player.positionStream.listen((position) {
      state = state.copyWith(position: position);
    });
    // 재생 길이
    _handler.player.durationStream.listen((duration) {
      state = state.copyWith(duration: duration ?? Duration.zero);
    });
    // just_audio 처리 상태
    _handler.player.processingStateStream.listen((ps) {
      state = state.copyWith(
        isLoading: ps == ProcessingState.loading || ps == ProcessingState.buffering,
      );
    });
    // audio_service 로딩/완료 상태
    _handler.playbackState.listen((ps) {
      if (ps.processingState == AudioProcessingState.loading) {
        state = state.copyWith(isLoading: true, clearError: true);
      } else if (ps.processingState == AudioProcessingState.ready) {
        state = state.copyWith(isLoading: false, clearError: true);
      }
    });
    // 현재 곡 변경
    _handler.mediaItem.listen((item) {
      if (item != null) {
        state = state.copyWith(currentSong: _handler.currentSong, clearError: true);
      }
    });
    // 에러 스트림
    _handler.errorStream.listen((error) {
      state = state.copyWith(isLoading: false, errorMessage: error);
    });
  }

  Future<void> playSong(Song song, {List<Song>? queue, int index = 0}) async {
    // 이미 재생 중인 같은 곡은 무시 (단, 다른 queue로 바꾸는 경우는 허용)
    if (_handler.currentSong?.id == song.id &&
        _handler.player.processingState != ProcessingState.idle &&
        _handler.player.processingState != ProcessingState.completed) {
      return;
    }
    state = state.copyWith(isLoading: true, clearError: true, currentSong: song);
    await _handler.playSong(song, queue: queue, index: index);
  }

  Future<void> togglePlayPause() async {
    if (state.isPlaying) {
      await _handler.pause();
    } else {
      await _handler.play();
    }
  }

  Future<void> seek(Duration position) => _handler.seek(position);
  Future<void> skipToNext() => _handler.skipToNext();
  Future<void> skipToPrevious() => _handler.skipToPrevious();

  void toggleShuffle() {
    _handler.toggleShuffle();
    state = state.copyWith(isShuffle: _handler.isShuffle);
  }

  void toggleLoop() {
    _handler.toggleLoopMode();
    state = state.copyWith(loopMode: _handler.loopMode);
  }

  void setPlaybackMode(PlaybackMode mode) {
    _handler.setPlaybackMode(mode);
    state = state.copyWith(loopMode: _handler.loopMode);
  }
}

final playerProvider = StateNotifierProvider<PlayerNotifier, MusicPlayerState>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  return PlayerNotifier(handler);
});

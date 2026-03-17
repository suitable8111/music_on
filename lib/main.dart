import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'app.dart';
import 'data/models/song.dart';
import 'data/models/playlist.dart';
import 'data/repositories/downloaded_songs_repository.dart';
import 'data/repositories/favorites_repository.dart';
import 'data/repositories/playlist_repository.dart';
import 'providers/audio_provider.dart';
import 'providers/downloaded_songs_provider.dart';
import 'providers/favorites_provider.dart';
import 'providers/playlist_provider.dart';
import 'services/audio_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hive 초기화
  await Hive.initFlutter();
  Hive.registerAdapter(SongAdapter());
  Hive.registerAdapter(PlaylistAdapter());
  await Hive.openBox('settings');

  // Repository 초기화
  final favoritesRepo = FavoritesRepository();
  final playlistRepo = PlaylistRepository();
  final downloadedSongsRepo = DownloadedSongsRepository();
  await favoritesRepo.init();
  await playlistRepo.init();
  await downloadedSongsRepo.init();

  // 저장된 재생 모드 불러오기
  final savedModeName = Hive.box('settings').get('playback_mode', defaultValue: 'repeatAll') as String;
  final savedMode = PlaybackMode.values.firstWhere((e) => e.name == savedModeName, orElse: () => PlaybackMode.repeatAll);

  // AudioService 초기화
  final audioHandler = await AudioService.init(
    builder: () => MusicAudioHandler()
      ..downloadedSongsRepo = downloadedSongsRepo
      ..setPlaybackMode(savedMode),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.daniel.music_on.audio',
      androidNotificationChannelName: 'Music On',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );

  runApp(
    ProviderScope(
      overrides: [
        audioHandlerProvider.overrideWithValue(audioHandler),
        favoritesRepositoryProvider.overrideWithValue(favoritesRepo),
        playlistRepositoryProvider.overrideWithValue(playlistRepo),
        downloadedSongsRepositoryProvider.overrideWithValue(downloadedSongsRepo),
      ],
      child: const MusicOnApp(),
    ),
  );
}

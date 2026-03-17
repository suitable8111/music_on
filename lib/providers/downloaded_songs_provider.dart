import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/song.dart';
import '../data/repositories/downloaded_songs_repository.dart';

final downloadedSongsRepositoryProvider = Provider<DownloadedSongsRepository>((ref) {
  throw UnimplementedError('DownloadedSongsRepository must be initialized');
});

final downloadedSongsProvider =
    StateNotifierProvider<DownloadedSongsNotifier, List<Song>>((ref) {
  final repo = ref.watch(downloadedSongsRepositoryProvider);
  return DownloadedSongsNotifier(repo);
});

class DownloadedSongsNotifier extends StateNotifier<List<Song>> {
  final DownloadedSongsRepository _repo;

  DownloadedSongsNotifier(this._repo) : super(_repo.getAll());

  void refresh() => state = _repo.getAll();

  Future<void> saveSong(Song song) async {
    await _repo.saveSong(song);
    refresh();
  }

  Future<void> removeSong(String videoId) async {
    await _repo.removeSong(videoId);
    refresh();
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/playlist.dart';
import '../data/models/song.dart';
import '../data/repositories/playlist_repository.dart';

final playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  throw UnimplementedError('PlaylistRepository must be initialized');
});

class PlaylistNotifier extends StateNotifier<List<Playlist>> {
  final PlaylistRepository _repo;

  PlaylistNotifier(this._repo) : super(_repo.getAll());

  void _refresh() => state = _repo.getAll();

  Future<Playlist> create(String name) async {
    final pl = await _repo.create(name);
    _refresh();
    return pl;
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    _refresh();
  }

  Future<void> rename(String id, String name) async {
    await _repo.rename(id, name);
    _refresh();
  }

  Future<void> addSong(String playlistId, Song song) async {
    await _repo.addSong(playlistId, song);
    _refresh();
  }

  Future<void> removeSong(String playlistId, String songId) async {
    await _repo.removeSong(playlistId, songId);
    _refresh();
  }

  Future<void> reorder(String playlistId, int oldIndex, int newIndex) async {
    await _repo.reorderSongs(playlistId, oldIndex, newIndex);
    _refresh();
  }

  Future<void> reorderPlaylists(int oldIndex, int newIndex) async {
    await _repo.reorderPlaylists(oldIndex, newIndex);
    _refresh();
  }
}

final playlistProvider = StateNotifierProvider<PlaylistNotifier, List<Playlist>>((ref) {
  final repo = ref.watch(playlistRepositoryProvider);
  return PlaylistNotifier(repo);
});

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/song.dart';
import '../data/repositories/favorites_repository.dart';

final favoritesRepositoryProvider = Provider<FavoritesRepository>((ref) {
  throw UnimplementedError('FavoritesRepository must be initialized');
});

class FavoritesNotifier extends StateNotifier<List<Song>> {
  final FavoritesRepository _repo;

  FavoritesNotifier(this._repo) : super(_repo.getAll());

  void _refresh() => state = _repo.getAll();

  Future<void> toggle(Song song) async {
    await _repo.toggle(song);
    _refresh();
  }

  bool isFavorite(String songId) => _repo.isFavorite(songId);
}

final favoritesProvider = StateNotifierProvider<FavoritesNotifier, List<Song>>((ref) {
  final repo = ref.watch(favoritesRepositoryProvider);
  return FavoritesNotifier(repo);
});

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/song.dart';

class FavoritesRepository {
  static const _boxName = 'favorites';
  late Box<Song> _box;

  Future<void> init() async {
    _box = await Hive.openBox<Song>(_boxName);
  }

  List<Song> getAll() => _box.values.toList().reversed.toList();

  bool isFavorite(String songId) => _box.containsKey(songId);

  Future<void> add(Song song) async {
    await _box.put(song.id, song);
  }

  Future<void> remove(String songId) async {
    await _box.delete(songId);
  }

  Future<void> toggle(Song song) async {
    if (isFavorite(song.id)) {
      await remove(song.id);
    } else {
      await add(song);
    }
  }

  ValueListenable<Box<Song>> listenable() => _box.listenable();
}

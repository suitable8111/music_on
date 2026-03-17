import 'package:hive_flutter/hive_flutter.dart';
import '../models/song.dart';

class DownloadedSongsRepository {
  static const _boxName = 'downloaded_songs';
  late Box<Song> _box;

  Future<void> init() async {
    _box = await Hive.openBox<Song>(_boxName);
  }

  Future<void> saveSong(Song song) async {
    await _box.put(song.id, song);
  }

  List<Song> getAll() {
    final list = _box.values.toList();
    list.sort((a, b) => b.addedAt.compareTo(a.addedAt)); // 최신순
    return list;
  }

  bool contains(String videoId) => _box.containsKey(videoId);

  Future<void> removeSong(String videoId) async {
    await _box.delete(videoId);
  }
}

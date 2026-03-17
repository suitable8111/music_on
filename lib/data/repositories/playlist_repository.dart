import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/playlist.dart';
import '../models/song.dart';

class PlaylistRepository {
  static const _boxName = 'playlists';
  late Box<Playlist> _box;

  Future<void> init() async {
    _box = await Hive.openBox<Playlist>(_boxName);
  }

  List<String> _getOrder() {
    final raw = Hive.box('settings').get('playlist_order');
    if (raw == null) return _box.keys.cast<String>().toList();
    return List<String>.from(raw as List);
  }

  Future<void> _saveOrder(List<String> order) async {
    await Hive.box('settings').put('playlist_order', order);
  }

  List<Playlist> getAll() {
    final order = _getOrder();
    final result = <Playlist>[];
    for (final id in order) {
      final pl = _box.get(id);
      if (pl != null) result.add(pl);
    }
    for (final pl in _box.values) {
      if (!order.contains(pl.id)) result.add(pl);
    }
    return result;
  }

  Playlist? getById(String id) => _box.get(id);

  Future<Playlist> create(String name) async {
    final playlist = Playlist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      songs: [],
      createdAt: DateTime.now(),
    );
    await _box.put(playlist.id, playlist);
    final order = _getOrder()..add(playlist.id);
    await _saveOrder(order);
    return playlist;
  }

  Future<void> rename(String playlistId, String newName) async {
    final playlist = _box.get(playlistId);
    if (playlist != null) {
      playlist.name = newName;
      await playlist.save();
    }
  }

  Future<void> delete(String playlistId) async {
    await _box.delete(playlistId);
    final order = _getOrder()..remove(playlistId);
    await _saveOrder(order);
  }

  Future<void> addSong(String playlistId, Song song) async {
    final playlist = _box.get(playlistId);
    if (playlist != null) {
      final already = playlist.songs.any((s) => s.id == song.id);
      if (!already) {
        playlist.songs.add(song);
        await playlist.save();
      }
    }
  }

  Future<void> removeSong(String playlistId, String songId) async {
    final playlist = _box.get(playlistId);
    if (playlist != null) {
      playlist.songs.removeWhere((s) => s.id == songId);
      await playlist.save();
    }
  }

  Future<void> reorderSongs(String playlistId, int oldIndex, int newIndex) async {
    final playlist = _box.get(playlistId);
    if (playlist != null) {
      final song = playlist.songs.removeAt(oldIndex);
      playlist.songs.insert(newIndex, song);
      await playlist.save();
    }
  }

  Future<void> reorderPlaylists(int oldIndex, int newIndex) async {
    final order = _getOrder();
    if (oldIndex < 0 || oldIndex >= order.length) return;
    if (newIndex < 0 || newIndex >= order.length) return;
    final id = order.removeAt(oldIndex);
    order.insert(newIndex, id);
    await _saveOrder(order);
  }

  ValueListenable<Box<Playlist>> listenable() => _box.listenable();
}

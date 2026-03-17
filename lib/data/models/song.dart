import 'package:hive/hive.dart';

part 'song.g.dart';

@HiveType(typeId: 0)
class Song extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String title;

  @HiveField(2)
  final String channelName;

  @HiveField(3)
  final String thumbnailUrl;

  @HiveField(4)
  final String youtubeUrl;

  @HiveField(5)
  final DateTime addedAt;

  @HiveField(6)
  final String? lyrics;

  Song({
    required this.id,
    required this.title,
    required this.channelName,
    required this.thumbnailUrl,
    required this.youtubeUrl,
    required this.addedAt,
    this.lyrics,
  });

  Song copyWith({
    String? id,
    String? title,
    String? channelName,
    String? thumbnailUrl,
    String? youtubeUrl,
    DateTime? addedAt,
    String? lyrics,
    bool clearLyrics = false,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      channelName: channelName ?? this.channelName,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      youtubeUrl: youtubeUrl ?? this.youtubeUrl,
      addedAt: addedAt ?? this.addedAt,
      lyrics: clearLyrics ? null : (lyrics ?? this.lyrics),
    );
  }
}

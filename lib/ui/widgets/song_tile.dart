import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/constants/app_colors.dart';
import '../../data/models/song.dart';

class SongTile extends StatelessWidget {
  final Song song;
  final bool isPlaying;
  final bool isFavorite;
  final VoidCallback onTap;
  final VoidCallback? onFavoriteToggle;
  final List<Widget>? trailing;

  const SongTile({
    super.key,
    required this.song,
    this.isPlaying = false,
    this.isFavorite = false,
    required this.onTap,
    this.onFavoriteToggle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(
              imageUrl: song.thumbnailUrl,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                color: AppColors.surface,
                width: 56,
                height: 56,
                child: const Icon(Icons.music_note, color: AppColors.primary),
              ),
              errorWidget: (_, __, ___) => Container(
                color: AppColors.surface,
                width: 56,
                height: 56,
                child: const Icon(Icons.music_note, color: AppColors.primary),
              ),
            ),
          ),
          if (isPlaying)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.graphic_eq, color: AppColors.primary, size: 24),
              ),
            ),
        ],
      ),
      title: Text(
        song.title,
        style: TextStyle(
          color: isPlaying ? AppColors.primary : AppColors.textPrimary,
          fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
          fontSize: 14,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        song.channelName,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing != null
          ? Row(mainAxisSize: MainAxisSize.min, children: trailing!)
          : (onFavoriteToggle != null
              ? IconButton(
                  icon: Icon(
                    isFavorite ? Icons.favorite : Icons.favorite_border,
                    color: isFavorite ? AppColors.primary : AppColors.textSecondary,
                  ),
                  onPressed: onFavoriteToggle,
                )
              : null),
    );
  }
}

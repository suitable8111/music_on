class YoutubeUtils {
  static String? extractVideoId(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;

    // youtu.be/VIDEO_ID
    if (uri.host == 'youtu.be') {
      return uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    }

    // youtube.com/watch?v=VIDEO_ID
    if (uri.host.contains('youtube.com')) {
      return uri.queryParameters['v'];
    }

    return null;
  }

  static bool isValidYoutubeUrl(String url) {
    return extractVideoId(url) != null;
  }

  static String thumbnailUrl(String videoId) {
    return 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';
  }
}

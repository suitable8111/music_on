import 'dart:async';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// youtube.com 도메인에서 InnerTube API를 직접 호출해 스트림 URL을 반환합니다.
/// 같은 origin이므로 CORS 없음, 브라우저 쿠키/헤더 자동 첨부.
class YoutubeWebService {
  Future<String> getAudioUrl(String videoId) async {
    final completer = Completer<String>();
    HeadlessInAppWebView? webView;
    bool _apiCalled = false;

    webView = HeadlessInAppWebView(
      // youtube.com 도메인에서 실행해야 same-origin API 호출 가능
      initialUrlRequest: URLRequest(
        url: WebUri('https://www.youtube.com/'),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        userAgent:
            'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) '
            'Version/18.0 Mobile/15E148 Safari/604.1',
      ),
      onWebViewCreated: (controller) {
        controller.addJavaScriptHandler(
          handlerName: 'onAudioUrl',
          callback: (args) {
            if (completer.isCompleted) return;
            final url = args.isNotEmpty ? (args[0] as String?) ?? '' : '';
            if (url.isNotEmpty) {
              completer.complete(url);
            } else {
              completer.completeError(Exception('스트림 URL을 찾지 못했습니다'));
            }
            webView?.dispose();
          },
        );
      },
      onLoadStop: (controller, url) async {
        // youtube.com 페이지 로드 완료 → InnerTube API 호출 (한 번만)
        if (_apiCalled) return;
        if (!(url?.toString().contains('youtube.com') ?? false)) return;
        _apiCalled = true;
        await controller.evaluateJavascript(source: _buildApiJs(videoId));
      },
    );

    await webView.run();

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        webView?.dispose();
        throw Exception('YouTube 스트림 URL 추출 시간 초과');
      },
    );
  }

  static String _buildApiJs(String videoId) => '''
    (async () => {
      try {
        // youtube.com와 same-origin: CORS 없음, 브라우저 인증 자동 첨부
        const res = await fetch('/youtubei/v1/player', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({
            videoId: '$videoId',
            context: {
              client: {
                clientName: 'IOS',
                clientVersion: '20.10.4',
                deviceMake: 'Apple',
                deviceModel: 'iPhone16,2',
                osName: 'IOS',
                osVersion: '18.1.0.22B83',
                hl: 'en',
                gl: 'US',
                utcOffsetMinutes: 0
              }
            }
          })
        });

        const data = await res.json();
        const formats = data?.streamingData?.adaptiveFormats ?? [];

        // mp4 오디오만 필터, 비트레이트 내림차순
        const audio = formats
          .filter(f => f.url && f.mimeType && f.mimeType.includes('audio/mp4'));
        audio.sort((a, b) => (b.bitrate ?? 0) - (a.bitrate ?? 0));

        if (audio.length > 0) {
          window.flutter_inappwebview.callHandler('onAudioUrl', audio[0].url);
        } else {
          window.flutter_inappwebview.callHandler('onAudioUrl', '');
        }
      } catch (e) {
        window.flutter_inappwebview.callHandler('onAudioUrl', '');
      }
    })();
  ''';
}

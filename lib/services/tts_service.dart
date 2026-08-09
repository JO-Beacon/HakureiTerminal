import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';

class TtsServiceException implements Exception {
  const TtsServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class TtsProviderClient {
  TtsProviderClient({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;

  Future<List<int>> synthesize(String text, TtsSettings settings) async {
    final input = text.trim();
    if (input.isEmpty) throw const TtsServiceException('没有可朗读的文本');
    if (!settings.isConfigured) {
      throw const TtsServiceException('请先在设置中启用并配置 TTS Provider');
    }
    final uri = _speechUri(settings.baseUrl);
    final request = await _httpClient.postUrl(uri);
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'audio/*');
    if (settings.apiKey.trim().isNotEmpty) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${settings.apiKey.trim()}',
      );
    }
    request.write(
      jsonEncode(<String, dynamic>{
        'model': settings.model.trim(),
        'voice': settings.voice.trim(),
        'input': input,
        'speed': settings.speed,
        'response_format': settings.responseFormat,
      }),
    );
    final response = await request.close();
    final bytes = await response.fold<List<int>>(<int>[], (buffer, chunk) {
      if (buffer.length + chunk.length > 32 * 1024 * 1024) {
        throw const TtsServiceException('TTS 音频超过 32 MiB 限制');
      }
      buffer.addAll(chunk);
      return buffer;
    });
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TtsServiceException(
        response.statusCode == HttpStatus.unauthorized
            ? 'TTS Provider 认证失败'
            : 'TTS Provider 请求失败（HTTP ${response.statusCode}）',
      );
    }
    if (bytes.isEmpty) {
      throw const TtsServiceException('TTS Provider 返回了空音频');
    }
    return bytes;
  }

  void dispose() => _httpClient.close(force: true);

  static Uri _speechUri(String rawBaseUrl) {
    final base = Uri.tryParse(rawBaseUrl.trim());
    if (base == null || !base.hasScheme || base.host.isEmpty) {
      throw const TtsServiceException('TTS Base URL 无效');
    }
    final loopback =
        base.host == 'localhost' ||
        base.host == '127.0.0.1' ||
        base.host == '::1';
    if (base.scheme != 'https' && !(base.scheme == 'http' && loopback)) {
      throw const TtsServiceException('远程 TTS Provider 必须使用 HTTPS');
    }
    if (base.userInfo.isNotEmpty || base.hasQuery || base.hasFragment) {
      throw const TtsServiceException('TTS Base URL 不得包含凭据、查询或片段');
    }
    final segments = <String>[
      ...base.pathSegments.where((item) => item.isNotEmpty),
    ];
    if (segments.length < 2 ||
        segments[segments.length - 2] != 'audio' ||
        segments.last != 'speech') {
      segments.addAll(const <String>['audio', 'speech']);
    }
    return base.replace(pathSegments: segments);
  }
}

class TtsService {
  TtsService({TtsProviderClient? providerClient, AudioPlayer? player})
    : _providerClient = providerClient ?? TtsProviderClient(),
      _player = player ?? AudioPlayer();

  final TtsProviderClient _providerClient;
  final AudioPlayer _player;
  File? _temporaryAudio;

  PlayerState get state => _player.state;
  Stream<PlayerState> get states => _player.onPlayerStateChanged;

  Future<void> speak(String text, TtsSettings settings) async {
    final bytes = await _providerClient.synthesize(text, settings);
    await stop();
    final directory = await getTemporaryDirectory();
    final extension = _safeFormat(settings.responseFormat);
    final file = File(
      '${directory.path}${Platform.pathSeparator}hakurei_tts_${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
    await file.writeAsBytes(bytes, flush: true);
    _temporaryAudio = file;
    await _player.play(DeviceFileSource(file.path));
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.resume();

  Future<void> stop() async {
    await _player.stop();
    final file = _temporaryAudio;
    _temporaryAudio = null;
    if (file != null && await file.exists()) {
      try {
        await file.delete();
      } on FileSystemException {
        // Temporary audio can be cleaned by the operating system later.
      }
    }
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
    _providerClient.dispose();
  }

  static String _safeFormat(String value) => switch (value.toLowerCase()) {
    'wav' => 'wav',
    'opus' => 'opus',
    'aac' => 'aac',
    'flac' => 'flac',
    _ => 'mp3',
  };
}

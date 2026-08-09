import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/models/app_settings.dart';
import 'package:hakurei_terminal/services/tts_service.dart';

void main() {
  group('TtsProviderClient', () {
    late HttpServer server;
    late TtsProviderClient client;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client = TtsProviderClient();
    });

    tearDown(() async {
      client.dispose();
      await server.close(force: true);
    });

    test('sends an authenticated OpenAI-compatible speech request', () async {
      final requestHandled = Completer<void>();
      unawaited(() async {
        final request = await server.first;
        expect(request.method, 'POST');
        expect(request.uri.path, '/v1/audio/speech');
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer tts-secret',
        );
        expect(request.headers.contentType?.mimeType, 'application/json');
        expect(request.headers.value(HttpHeaders.acceptHeader), 'audio/*');
        final payload =
            jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(payload, <String, dynamic>{
          'model': 'voice-model',
          'voice': 'reimu',
          'input': '你好，幻想乡',
          'speed': 1.25,
          'response_format': 'wav',
        });
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.add(<int>[1, 2, 3, 4]);
        await request.response.close();
        requestHandled.complete();
      }());

      final audio = await client.synthesize(
        '  你好，幻想乡  ',
        TtsSettings(
          enabled: true,
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          apiKey: 'tts-secret',
          model: 'voice-model',
          voice: 'reimu',
          speed: 1.25,
          responseFormat: 'wav',
        ),
      );

      await requestHandled.future;
      expect(audio, <int>[1, 2, 3, 4]);
    });

    test('rejects plaintext non-loopback providers', () async {
      await expectLater(
        client.synthesize(
          'hello',
          const TtsSettings(
            enabled: true,
            baseUrl: 'http://voice.example/v1',
            model: 'voice-model',
            voice: 'default',
          ),
        ),
        throwsA(
          isA<TtsServiceException>().having(
            (error) => error.message,
            'message',
            '远程 TTS Provider 必须使用 HTTPS',
          ),
        ),
      );
    });
  });
}

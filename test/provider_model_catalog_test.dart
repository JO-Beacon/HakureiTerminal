import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/services/provider_model_catalog.dart';

void main() {
  group('HttpProviderModelCatalog', () {
    test('reads all OpenAI-compatible Provider model lists', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        expect(request.uri.path, '/v1/models');
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer provider-token',
        );
        await _jsonResponse(request.response, <String, dynamic>{
          'data': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'model-z'},
            <String, dynamic>{'id': 'model-a', 'name': 'Model A'},
            <String, dynamic>{'id': 'model-a', 'name': 'Duplicate'},
          ],
        });
      });

      for (final provider in <String>[
        'openai',
        'openai_responses',
        'openrouter',
        'deepseek',
      ]) {
        final models = await HttpProviderModelCatalog().listModels(
          provider: provider,
          baseUrl: 'http://127.0.0.1:${server.port}/v1/chat/completions',
          apiKey: 'provider-token',
        );

        expect(models.map((model) => model.id), <String>['model-a', 'model-z']);
        expect(models.first.name, 'Model A');
      }
      expect(requests, 4);
    });

    test('reads an Ollama tags response', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.uri.path, '/api/tags');
        await _jsonResponse(request.response, <String, dynamic>{
          'models': <Map<String, dynamic>>[
            <String, dynamic>{'model': 'qwen3:8b'},
            <String, dynamic>{'name': 'gemma3:4b'},
          ],
        });
      });

      final models = await HttpProviderModelCatalog().listModels(
        provider: 'ollama',
        baseUrl: 'http://localhost:${server.port}',
        apiKey: '',
      );

      expect(models.map((model) => model.id), <String>[
        'gemma3:4b',
        'qwen3:8b',
      ]);
    });

    test('reads every Anthropic model page with provider headers', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        expect(request.uri.path, '/custom/v1/models');
        expect(request.headers.value('x-api-key'), 'anthropic-token');
        expect(request.headers.value('anthropic-version'), '2023-06-01');
        if (requests == 1) {
          expect(request.uri.queryParameters['after_id'], isNull);
          await _jsonResponse(request.response, <String, dynamic>{
            'data': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'claude-a', 'display_name': 'Claude A'},
            ],
            'has_more': true,
            'last_id': 'claude-a',
          });
        } else {
          expect(request.uri.queryParameters['after_id'], 'claude-a');
          await _jsonResponse(request.response, <String, dynamic>{
            'data': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'claude-b'},
            ],
            'has_more': false,
          });
        }
      });

      final models = await HttpProviderModelCatalog().listModels(
        provider: 'anthropic',
        baseUrl: 'http://127.0.0.1:${server.port}/custom',
        apiKey: 'anthropic-token',
      );

      expect(requests, 2);
      expect(models.map((model) => model.id), <String>['claude-a', 'claude-b']);
    });

    test(
      'reads every Gemini model page without putting the key in the URL',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var requests = 0;
        server.listen((request) async {
          requests++;
          expect(request.uri.path, '/v1beta/models');
          expect(request.uri.queryParameters.containsKey('key'), isFalse);
          expect(request.headers.value('x-goog-api-key'), 'gemini-token');
          if (requests == 1) {
            await _jsonResponse(request.response, <String, dynamic>{
              'models': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': 'models/gemini-a',
                  'displayName': 'Gemini A',
                },
              ],
              'nextPageToken': 'next-page',
            });
          } else {
            expect(request.uri.queryParameters['pageToken'], 'next-page');
            await _jsonResponse(request.response, <String, dynamic>{
              'models': <Map<String, dynamic>>[
                <String, dynamic>{'name': 'models/gemini-b'},
              ],
            });
          }
        });

        final models = await HttpProviderModelCatalog().listModels(
          provider: 'gemini',
          baseUrl: 'http://127.0.0.1:${server.port}/v1beta',
          apiKey: 'gemini-token',
        );

        expect(requests, 2);
        expect(models.map((model) => model.id), <String>[
          'models/gemini-a',
          'models/gemini-b',
        ]);
      },
    );

    test('rejects unsafe HTTP and redirects without retrying', () async {
      final catalog = HttpProviderModelCatalog();
      await expectLater(
        catalog.listModels(
          provider: 'openai',
          baseUrl: 'http://192.168.1.10/v1',
          apiKey: '',
        ),
        throwsA(
          isA<ProviderModelCatalogException>().having(
            (error) => error.message,
            'message',
            contains('仅 localhost'),
          ),
        ),
      );

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'https://example.invalid/models',
          );
        await request.response.close();
      });

      await expectLater(
        catalog.listModels(
          provider: 'openai',
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          apiKey: '',
        ),
        throwsA(
          isA<ProviderModelCatalogException>().having(
            (error) => error.message,
            'message',
            contains('不允许重定向'),
          ),
        ),
      );
    });
  });
}

Future<void> _jsonResponse(
  HttpResponse response,
  Map<String, dynamic> payload,
) async {
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(payload));
  await response.close();
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/models/app_settings.dart';
import 'package:hakurei_terminal/services/app_logger.dart';
import 'package:hakurei_terminal/services/runtime/http_runtime_client.dart';
import 'package:hakurei_terminal/services/runtime/runtime_connection.dart';
import 'package:hakurei_terminal/services/runtime/runtime_stream_event.dart';

void main() {
  group('RuntimeEndpointPolicy', () {
    const policy = RuntimeEndpointPolicy();

    test('allows HTTPS and explicit loopback HTTP only', () {
      expect(
        policy.rpcUri('https://runtime.example/api').toString(),
        'https://runtime.example/api/rpc',
      );
      expect(
        policy.webSocketUri('http://127.0.0.1:8765').toString(),
        'ws://127.0.0.1:8765/ws',
      );
      expect(
        policy.webSocketUri('https://runtime.example/api').toString(),
        'wss://runtime.example/api/ws',
      );
      expect(
        policy.readinessUri('https://runtime.example/api').toString(),
        'https://runtime.example/api/ready',
      );
      expect(
        () => policy.normalize('http://runtime.example'),
        throwsFormatException,
      );
      expect(
        () => policy.normalize('https://runtime.example?token=secret'),
        throwsFormatException,
      );
    });
  });

  group('GensokyoAiHttpRuntimeClient', () {
    late HttpServer server;
    late GensokyoAiHttpRuntimeClient client;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client = GensokyoAiHttpRuntimeClient(
        connection: ExternalRuntimeConnectionSettings(
          id: 'runtime-1',
          agentId: 'agent-runtime-1',
          displayName: 'Fixture',
          baseUrl: 'http://127.0.0.1:${server.port}',
          authToken: 'runtime-token',
        ),
      );
    });

    tearDown(() async {
      await client.dispose();
      await server.close(force: true);
    });

    test('sends authenticated RPC envelopes and returns a result', () async {
      unawaited(
        _serveOnce(server, (request) async {
          expect(request.uri.path, '/rpc');
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer runtime-token',
          );
          final payload =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(payload['method'], 'runtime.info');
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'id': payload['id'],
              'ok': true,
              'result': <String, dynamic>{'protocol_major_version': 2},
            }),
          );
          await request.response.close();
        }),
      );

      final result = await client.call('runtime.info');

      expect(result, <String, dynamic>{'protocol_major_version': 2});
    });

    test('renames a session with its authoritative revision', () async {
      final serverTask = () async {
        await for (final request in server) {
          final payload =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          if (payload['method'] == 'session.messages') {
            await _writeRpcResult(request, payload['id'], <String, dynamic>{
              'session_id': 'session-1',
              'revision': 7,
              'messages': const <Object>[],
              'has_more': false,
            });
            continue;
          }
          expect(payload['method'], 'session.rename');
          expect(
            payload['params'],
            containsPair('agent_id', 'agent-runtime-1'),
          );
          expect(payload['params'], containsPair('session_id', 'session-1'));
          expect(payload['params'], containsPair('expected_revision', 7));
          expect(payload['params'], containsPair('title', '新会话'));
          await _writeRpcResult(request, payload['id'], <String, dynamic>{
            'session_id': 'session-1',
            'revision': 8,
            'metadata': <String, dynamic>{'title': '新会话'},
          });
          break;
        }
      }();
      await client.call('session.messages', <String, dynamic>{
        'session_id': 'session-1',
      });

      final renamed = await client.renameSession(
        sessionId: 'session-1',
        title: '新会话',
      );
      await serverTask;
      expect(renamed['metadata'], <String, dynamic>{'title': '新会话'});
    });

    test('reads authenticated Runtime readiness', () async {
      unawaited(
        _serveOnce(server, (request) async {
          expect(request.uri.path, '/ready');
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer runtime-token',
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{'ok': true, 'ready': true}),
          );
          await request.response.close();
        }),
      );

      expect(await client.readiness(), <String, dynamic>{
        'ok': true,
        'ready': true,
      });
    });

    test('uploads media through the public multipart endpoint', () async {
      unawaited(
        _serveOnce(server, (request) async {
          expect(request.uri.path, '/media');
          expect(request.uri.queryParameters['agent_id'], 'agent-runtime-1');
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer runtime-token',
          );
          expect(request.headers.contentType?.mimeType, 'multipart/form-data');
          final body = await utf8.decoder.bind(request).join();
          expect(body, contains('name="file"; filename="image.png"'));
          expect(body, contains('Content-Type: image/png'));
          expect(body, contains('fixture-image'));
          request.response.statusCode = HttpStatus.created;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'media_id': 'media-1',
              'content_type': 'image/png',
            }),
          );
          await request.response.close();
        }),
      );

      final result = await client.uploadMedia(
        filename: 'image.png',
        bytes: utf8.encode('fixture-image'),
        contentType: 'image/png',
      );
      expect(result['media_id'], 'media-1');
    });

    test('uploads character packages with explicit admin options', () async {
      unawaited(
        _serveOnce(server, (request) async {
          expect(request.uri.path, '/character-packages');
          expect(request.uri.queryParameters, <String, String>{
            'locale': 'zh_cn',
            'overwrite': 'true',
            'allow_untrusted': 'true',
          });
          final body = await utf8.decoder.bind(request).join();
          expect(
            body,
            contains('name="file"; filename="reimu.gensokyo-character"'),
          );
          expect(body, contains('Content-Type: application/zip'));
          request.response.statusCode = HttpStatus.created;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'imported': true,
              'character': 'reimu',
            }),
          );
          await request.response.close();
        }),
      );

      final result = await client.uploadCharacterPackage(
        filename: 'reimu.gensokyo-character',
        bytes: utf8.encode('fixture-package'),
        locale: 'zh_cn',
        overwrite: true,
        allowUntrusted: true,
      );
      expect(result['imported'], isTrue);
    });

    test('rejects protocol v1 without a compatibility fallback', () async {
      unawaited(
        _serveOnce(server, (request) async {
          final payload =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          await _writeRpcResult(request, payload['id'], <String, dynamic>{
            ..._runtimeInfoV2,
            'protocol_major_version': 1,
          });
        }),
      );

      await expectLater(
        client.negotiate(),
        throwsA(
          isA<RuntimeConnectionException>().having(
            (error) => error.kind,
            'kind',
            '仅支持 GensokyoAI Agent v2',
          ),
        ),
      );
    });

    test('sends read-only world RPC with the persisted agent id', () async {
      unawaited(
        _serveOnce(server, (request) async {
          final payload =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(payload['method'], 'world.state');
          expect(
            payload['params'],
            containsPair('agent_id', 'agent-runtime-1'),
          );
          await _writeRpcResult(request, payload['id'], <String, dynamic>{
            'world_id': 'gensokyo',
            'session_id': 'world-session',
          });
        }),
      );

      final result = await client.call('world.state');

      expect(result, containsPair('world_id', 'gensokyo'));
      expect(client.activeSessionId, isNull);
    });

    test('rejects world write RPC before contacting the Runtime', () async {
      await expectLater(
        client.call('world.session.delete', <String, dynamic>{
          'session_id': 'world-session',
        }),
        throwsUnsupportedError,
      );
    });

    test(
      'maps structured HTTP authentication failures without exposing a token',
      () async {
        unawaited(
          _serveOnce(server, (request) async {
            request.response.statusCode = HttpStatus.unauthorized;
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode(<String, dynamic>{
                'ok': false,
                'error': <String, dynamic>{
                  'code': 'authentication_failed',
                  'message':
                      'runtime-token must not appear in the client error',
                },
              }),
            );
            await request.response.close();
          }),
        );

        await expectLater(
          client.call('runtime.info'),
          throwsA(
            isA<RuntimeConnectionException>().having(
              (error) => error.kind,
              'kind',
              '认证失败',
            ),
          ),
        );
      },
    );

    test('maps Runtime 2.2 structured error codes', () async {
      final errors = <String, String>{
        'authorization.forbidden': '当前身份没有执行此操作的权限',
        'agent.limit_exceeded': '当前用户创建的 Agent 数量已达到上限',
        'session.not_found': '远程会话不存在或已被删除',
        'message.operation_outcome_unknown': '消息结果未知，请刷新会话确认后再发送',
        'pagination.invalid_cursor': '分页期间远端资源已变化，请重新读取',
      };
      unawaited(() async {
        await for (final request in server) {
          final payload =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final code = payload['params']['code'] as String;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'id': payload['id'],
              'ok': false,
              'error': <String, dynamic>{'code': code},
            }),
          );
          await request.response.close();
        }
      }());

      for (final entry in errors.entries) {
        await expectLater(
          client.call('runtime.info', <String, dynamic>{'code': entry.key}),
          throwsA(
            isA<RuntimeConnectionException>()
                .having((error) => error.code, 'code', entry.key)
                .having((error) => error.kind, 'kind', entry.value),
          ),
        );
      }
    });

    test('maps v2 Provider credential errors to an actionable error', () async {
      unawaited(
        _serveOnce(server, (request) async {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'id': 'request-1',
              'ok': false,
              'error': <String, dynamic>{
                'code': 'runtime.error',
                'message': 'Missing credentials. Please pass an api_key.',
                'recoverable': true,
              },
            }),
          );
          await request.response.close();
        }),
      );

      await expectLater(
        client.initialize(characterId: 'HakureiReimu', newSession: true),
        throwsA(
          isA<RuntimeConnectionException>().having(
            (error) => error.kind,
            'kind',
            '模型服务缺少凭据，请在 GensokyoAI 配置 Provider Key，或为此连接启用 Provider 委托',
          ),
        ),
      );
    });

    test('delegates only public agent.init override fields', () async {
      unawaited(
        _serveOnce(server, (request) async {
          final payload =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(payload['method'], 'agent.init');
          final params = payload['params'] as Map;
          expect(params['agent_id'], 'agent-runtime-1');
          expect(params['character'], 'reimu');
          expect(params['new_session'], isTrue);
          expect(params['model_overrides'], <String, dynamic>{
            'provider': 'openai',
            'name': 'gpt-test',
            'base_url': 'https://provider.example/v1',
            'api_key': 'provider-secret',
            'temperature': 0.3,
            'top_p': 0.8,
            'max_tokens': 512,
            'stream': true,
          });
          expect(params['embedding_overrides'], <String, dynamic>{
            'provider': 'openai',
            'name': 'embedding-test',
            'base_url': 'https://embedding.example/v1',
            'api_key': 'embedding-secret',
          });
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'id': payload['id'],
              'ok': true,
              'result': <String, dynamic>{
                'agent_id': 'agent-runtime-1',
                'started': true,
                'session': <String, dynamic>{
                  'session_id': 'session-1',
                  'revision': 0,
                },
              },
            }),
          );
          await request.response.close();
        }),
      );

      await client.initialize(
        characterId: 'reimu',
        newSession: true,
        profile: const ModelProfile(
          id: 'default',
          name: 'Default',
          model: ModelServiceSettings(
            provider: 'openai',
            model: 'gpt-test',
            baseUrl: 'https://provider.example/v1',
            apiKey: 'provider-secret',
            temperature: '0.3',
            topP: '0.8',
            maxTokens: '512',
            timeout: '20',
            useProxy: true,
          ),
          embedding: EmbeddingServiceSettings(
            provider: 'openai',
            model: 'embedding-test',
            baseUrl: 'https://embedding.example/v1',
            apiKey: 'embedding-secret',
            dimensions: '1536',
            timeout: '20',
            useProxy: true,
          ),
        ),
      );
    });

    test('agent.init omits Provider overrides without delegation', () async {
      unawaited(
        _serveOnce(server, (request) async {
          final payload =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final params = payload['params'] as Map;
          expect(params['agent_id'], 'agent-runtime-1');
          expect(params, isNot(contains('model_overrides')));
          expect(params, isNot(contains('embedding_overrides')));
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'id': payload['id'],
              'ok': true,
              'result': <String, dynamic>{
                'agent_id': 'agent-runtime-1',
                'started': true,
                'session': <String, dynamic>{
                  'session_id': 'session-1',
                  'revision': 0,
                },
              },
            }),
          );
          await request.response.close();
        }),
      );

      await client.initialize(characterId: 'reimu');
    });

    test(
      'connect opens WebSocket without subscribing before agent.init',
      () async {
        final socketFuture = _acceptV2WebSocket(server);
        final connect = client.connect();
        final socket = await socketFuture;
        await connect;

        await expectLater(
          socket.first.timeout(const Duration(milliseconds: 100)),
          throwsA(isA<TimeoutException>()),
        );
        await socket.close();
      },
    );

    test('concurrent connect calls share one WebSocket handshake', () async {
      final socketReady = _acceptV2WebSocket(server);

      await Future.wait(<Future<void>>[
        client.connect(),
        client.connect(),
        client.connect(),
      ]);

      await (await socketReady).close();
    });

    test('logs a redacted WebSocket handshake failure', () async {
      final serverPort = server.port;
      final directory = await Directory.systemTemp.createTemp(
        'hakurei_runtime_log_test_',
      );
      final logger = AppLogger();
      await logger.initialize(directory);
      await client.dispose();
      client = GensokyoAiHttpRuntimeClient(
        connection: ExternalRuntimeConnectionSettings(
          id: 'runtime-1',
          agentId: 'agent-runtime-1',
          displayName: 'Fixture',
          baseUrl: 'http://127.0.0.1:$serverPort',
          authToken: 'runtime-token-must-not-be-logged',
        ),
        logger: logger,
        webSocketConnector: (url, {headers}) async {
          expect(url, 'ws://127.0.0.1:$serverPort/ws');
          expect(
            headers?[HttpHeaders.authorizationHeader],
            'Bearer runtime-token-must-not-be-logged',
          );
          throw const HandshakeException('TLS certificate rejected');
        },
      );
      unawaited(
        _serveOnce(server, (request) async {
          final payload =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          await _writeRpcResult(request, payload['id'], _runtimeInfoV2);
        }),
      );

      await expectLater(client.connect(), throwsA(isA<HandshakeException>()));
      await logger.flush();

      final logs = await logger.activeFile!.readAsString();
      expect(logs, contains('runtime.websocket.handshake_failed'));
      expect(logs, contains('TLS certificate rejected'));
      expect(logs, contains('ws://127.0.0.1:$serverPort/ws'));
      expect(logs, isNot(contains('runtime-token-must-not-be-logged')));
      await client.dispose();
      await logger.flush();
      await directory.delete(recursive: true);
    });

    test(
      'uses authoritative completion content when it is fuller than deltas',
      () async {
        unawaited(
          _serveOnce(server, (request) async {
            expect(request.uri.path, '/ws');
            expect(
              request.headers.value(HttpHeaders.authorizationHeader),
              'Bearer runtime-token',
            );
            final socket = await WebSocketTransformer.upgrade(request);
            await for (final raw in socket) {
              final payload = jsonDecode(raw as String) as Map;
              expect(payload['method'], 'agent.send_message_stream');
              expect(
                payload['params'],
                containsPair('agent_id', 'agent-runtime-1'),
              );
              expect(
                payload['params'],
                containsPair('session_id', 'session-1'),
              );
              expect(payload['params'], containsPair('expected_revision', 4));
              expect(
                (payload['params'] as Map)['idempotency_key'],
                isA<String>().having((value) => value.length, 'length', 36),
              );
              final id = payload['id'];
              socket.add(
                jsonEncode(<String, dynamic>{
                  'id': id,
                  'ok': true,
                  'result': <String, dynamic>{
                    'stream_id': 'stream-1',
                    'generation_id': 'generation-1',
                  },
                }),
              );
              socket.add(
                jsonEncode(<String, dynamic>{
                  'id': id,
                  'ok': true,
                  'stream_id': 'stream-1',
                  'generation_id': 'generation-1',
                  'event': <String, dynamic>{
                    'type': 'content',
                    'index': 0,
                    'content': 'hello ',
                    'generation_id': 'generation-1',
                  },
                }),
              );
              socket.add(
                jsonEncode(<String, dynamic>{
                  'id': id,
                  'ok': true,
                  'stream_id': 'stream-1',
                  'generation_id': 'generation-1',
                  'done': true,
                  'result': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'hello runtime',
                    'generation_id': 'generation-1',
                    'events': const <Object>[],
                    'session': <String, dynamic>{
                      'session_id': 'session-1',
                      'revision': 6,
                    },
                  },
                }),
              );
              await socket.close();
              break;
            }
          }),
        );

        final events = await client
            .streamMessage(
              sessionId: 'session-1',
              expectedRevision: 4,
              latestUserInput: 'hello',
            )
            .toList();

        expect(events.whereType<RuntimeStreamStarted>(), hasLength(1));
        expect(events.whereType<RuntimeStreamDelta>().single.text, 'hello ');
        expect(
          events.whereType<RuntimeStreamCompleted>().single.reply.content,
          'hello runtime',
        );
      },
    );

    test(
      'separates reasoning content and tool updates from reply text',
      () async {
        unawaited(
          _serveOnce(server, (request) async {
            final socket = await WebSocketTransformer.upgrade(request);
            final payload = jsonDecode(await socket.first as String) as Map;
            final id = payload['id'];
            socket.add(
              jsonEncode(<String, dynamic>{
                'id': id,
                'ok': true,
                'result': <String, dynamic>{
                  'stream_id': 'stream-structured',
                  'generation_id': 'generation-structured',
                },
              }),
            );
            socket.add(
              jsonEncode(<String, dynamic>{
                'id': id,
                'ok': true,
                'stream_id': 'stream-structured',
                'generation_id': 'generation-structured',
                'event': <String, dynamic>{
                  'type': 'reasoning',
                  'index': 0,
                  'reasoning_content': 'reasoning',
                  'generation_id': 'generation-structured',
                },
              }),
            );
            socket.add(
              jsonEncode(<String, dynamic>{
                'id': id,
                'ok': true,
                'stream_id': 'stream-structured',
                'generation_id': 'generation-structured',
                'event': <String, dynamic>{
                  'type': 'content',
                  'index': 1,
                  'content': 'answer',
                  'is_tool_call': true,
                  'tool_info': <String, dynamic>{'name': 'lookup'},
                  'status': 'running',
                },
              }),
            );
            socket.add(
              jsonEncode(<String, dynamic>{
                'id': id,
                'ok': true,
                'stream_id': 'stream-structured',
                'generation_id': 'generation-structured',
                'done': true,
                'result': <String, dynamic>{
                  'content': 'final answer',
                  'reasoning_content': 'reasoning',
                  'generation_id': 'generation-structured',
                  'session': <String, dynamic>{
                    'session_id': 'session-1',
                    'revision': 6,
                  },
                },
              }),
            );
            await socket.close();
          }),
        );

        final events = await client
            .streamMessage(
              sessionId: 'session-1',
              expectedRevision: 4,
              latestUserInput: 'hello',
            )
            .toList();

        expect(
          events.whereType<RuntimeStreamReasoningDelta>().single.text,
          'reasoning',
        );
        expect(events.whereType<RuntimeStreamDelta>().single.text, 'answer');
        expect(
          events.whereType<RuntimeStreamToolUpdate>().single.info['name'],
          'lookup',
        );
        final reply = events.whereType<RuntimeStreamCompleted>().single.reply;
        expect(reply.content, 'final answer');
        expect(reply.reasoningContent, 'reasoning');
        expect(reply.toolEvents, hasLength(1));
      },
    );

    test('cancels with the server-confirmed stream ID', () async {
      final serverFinished = Completer<void>();
      String? streamRequestId;
      unawaited(
        _serveOnce(server, (request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          await for (final raw in socket) {
            final payload = jsonDecode(raw as String) as Map;
            final id = payload['id'];
            if (payload['method'] == 'agent.send_message_stream') {
              streamRequestId = id.toString();
              socket.add(
                jsonEncode(<String, dynamic>{
                  'id': id,
                  'ok': true,
                  'result': <String, dynamic>{
                    'stream_id': 'server-stream-42',
                    'generation_id': 'generation-42',
                  },
                }),
              );
              socket.add(
                jsonEncode(<String, dynamic>{
                  'id': id,
                  'ok': true,
                  'stream_id': 'server-stream-42',
                  'generation_id': 'generation-42',
                  'event': <String, dynamic>{
                    'type': 'content',
                    'content': 'partial',
                    'generation_id': 'generation-42',
                  },
                }),
              );
            } else if (payload['method'] == 'runtime.cancel_stream') {
              expect(
                (payload['params'] as Map)['stream_id'],
                'server-stream-42',
              );
              socket.add(
                jsonEncode(<String, dynamic>{
                  'id': id,
                  'ok': true,
                  'result': const <String, dynamic>{
                    'stream_id': 'server-stream-42',
                    'cancel_requested': true,
                  },
                }),
              );
              socket.add(
                jsonEncode(<String, dynamic>{
                  'id': streamRequestId,
                  'ok': true,
                  'stream_id': 'server-stream-42',
                  'generation_id': 'generation-42',
                  'event': const <String, dynamic>{
                    'type': 'cancelled',
                    'generation_id': 'generation-42',
                  },
                }),
              );
              serverFinished.complete();
              break;
            }
          }
        }),
      );

      final events = <RuntimeStreamEvent>[];
      final streamDone = Completer<void>();
      final subscription = client
          .streamMessage(
            sessionId: 'session-1',
            expectedRevision: 4,
            latestUserInput: 'hello',
          )
          .listen(events.add, onDone: streamDone.complete);
      await client.connectionStates.firstWhere((connected) => connected);
      while (events.whereType<RuntimeStreamDelta>().isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }

      await client.cancelActiveStream();
      await serverFinished.future;
      await streamDone.future;

      expect(events.whereType<RuntimeStreamCancelled>(), hasLength(1));
      await subscription.cancel();
    });

    test('maps the Runtime stream timeout to an actionable failure', () async {
      final recoveryMethods = <String>[];
      unawaited(() async {
        await for (final request in server) {
          if (request.uri.path == '/rpc') {
            final payload =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            final method = payload['method']?.toString();
            recoveryMethods.add(method!);
            final result = method == 'message.status'
                ? <String, dynamic>{
                    'status': 'failed',
                    'idempotency_key':
                        (payload['params'] as Map)['idempotency_key'],
                    'error': <String, dynamic>{'code': 'agent.stream.timeout'},
                  }
                : <String, dynamic>{
                    'session_id': 'session-1',
                    'revision': 4,
                    'messages': const <Object>[],
                    'has_more': false,
                  };
            await _writeRpcResult(request, payload['id'], result);
            continue;
          }
          final socket = await WebSocketTransformer.upgrade(request);
          final payload = jsonDecode(await socket.first as String) as Map;
          socket.add(
            jsonEncode(<String, dynamic>{
              'id': payload['id'],
              'ok': true,
              'result': <String, dynamic>{
                'stream_id': 'stream-timeout',
                'generation_id': 'generation-timeout',
              },
            }),
          );
          socket.add(
            jsonEncode(<String, dynamic>{
              'id': payload['id'],
              'ok': true,
              'stream_id': 'stream-timeout',
              'generation_id': 'generation-timeout',
              'event': <String, dynamic>{
                'type': 'error',
                'generation_id': 'generation-timeout',
                'error': const <String, dynamic>{
                  'code': 'agent.stream.timeout',
                  'recoverable': true,
                },
              },
            }),
          );
        }
      }());

      final failure =
          (await client
                  .streamMessage(
                    sessionId: 'session-1',
                    expectedRevision: 4,
                    latestUserInput: 'hello',
                  )
                  .toList())
              .whereType<RuntimeStreamFailed>()
              .single;

      expect(failure.message, '消息生成失败，已与服务端状态完成对账');
      expect(failure.metadata['code'], 'agent.stream.timeout');
      expect(recoveryMethods, <String>['message.status', 'session.messages']);
    });

    test(
      'failed stream setup does not leave a phantom active stream',
      () async {
        await server.close(force: true);

        await expectLater(
          client.streamMessage(
            sessionId: 'session-1',
            expectedRevision: 4,
            latestUserInput: 'hello',
          ),
          emitsError(isA<SocketException>()),
        );

        expect(client.hasActiveStream, isFalse);
      },
    );

    test(
      'disconnect fails an active stream and reconnects only when requested',
      () async {
        var handshakes = 0;
        final firstClosed = Completer<void>();
        final secondConnected = Completer<WebSocket>();
        unawaited(() async {
          await for (final request in server) {
            if (request.uri.path == '/rpc') {
              final payload =
                  jsonDecode(await utf8.decoder.bind(request).join()) as Map;
              final method = payload['method']?.toString();
              final result = switch (method) {
                'runtime.info' => _runtimeInfoV2,
                'message.status' => <String, dynamic>{
                  'status': 'cancelled',
                  'idempotency_key':
                      (payload['params'] as Map)['idempotency_key'],
                },
                'session.messages' => <String, dynamic>{
                  'session_id': 'session-1',
                  'revision': 4,
                  'messages': const <Object>[],
                  'has_more': false,
                },
                _ => throw StateError('Unexpected RPC method: $method'),
              };
              await _writeRpcResult(request, payload['id'], result);
              continue;
            }
            handshakes++;
            final socket = await WebSocketTransformer.upgrade(request);
            if (handshakes == 1) {
              await for (final raw in socket) {
                final payload = jsonDecode(raw as String) as Map;
                socket.add(
                  jsonEncode(<String, dynamic>{
                    'id': payload['id'],
                    'ok': true,
                    'result': <String, dynamic>{
                      'stream_id': 'server-stream',
                      'generation_id': 'generation-disconnect',
                    },
                  }),
                );
                socket.add(
                  jsonEncode(<String, dynamic>{
                    'id': payload['id'],
                    'ok': true,
                    'stream_id': 'server-stream',
                    'generation_id': 'generation-disconnect',
                    'event': const <String, dynamic>{
                      'type': 'content',
                      'content': 'partial',
                      'generation_id': 'generation-disconnect',
                    },
                  }),
                );
                await socket.close();
                firstClosed.complete();
                break;
              }
            } else {
              secondConnected.complete(socket);
              break;
            }
          }
        }());

        final events = await client
            .streamMessage(
              sessionId: 'session-1',
              expectedRevision: 4,
              latestUserInput: 'hello',
            )
            .toList();
        await firstClosed.future;
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(events.whereType<RuntimeStreamDelta>(), hasLength(1));
        expect(events.whereType<RuntimeStreamCancelled>(), hasLength(1));
        expect(client.hasActiveStream, isFalse);
        expect(handshakes, 1);

        await client.connect();
        expect(handshakes, 2);
        await (await secondConnected.future).close();
      },
    );

    test('dispose is idempotent', () async {
      await Future.wait(<Future<void>>[client.dispose(), client.dispose()]);
      await client.dispose();
    });

    test(
      'routes subscribed Runtime events from the single WebSocket',
      () async {
        unawaited(
          _serveOnce(server, (request) async {
            final socket = await WebSocketTransformer.upgrade(request);
            await for (final raw in socket) {
              final payload = jsonDecode(raw as String) as Map;
              expect(payload['method'], 'runtime.subscribe');
              expect((payload['params'] as Map)['agent_id'], 'agent-runtime-1');
              expect((payload['params'] as Map)['replay_limit'], 500);
              final id = payload['id'];
              socket.add(
                jsonEncode(<String, dynamic>{
                  'id': id,
                  'ok': true,
                  'result': <String, dynamic>{
                    'subscription_id': 'subscription-1',
                    'event_types': const <String>[],
                  },
                }),
              );
              socket.add(
                jsonEncode(<String, dynamic>{
                  'id': id,
                  'ok': true,
                  'subscription_id': 'subscription-1',
                  'event': <String, dynamic>{
                    'id': 'event-1',
                    'event_id': 'stable-event-1',
                    'sequence': 9,
                    'recorded_at': '2026-07-26T00:00:01Z',
                    'type': 'runtime.backpressure.dropped',
                    'source': 'runtime',
                    'timestamp': '2026-07-26T00:00:00Z',
                    'data': <String, dynamic>{'dropped': 2},
                  },
                }),
              );
              break;
            }
          }),
        );

        final eventFuture = client.events.first;
        await client.subscribe();
        final event = await eventFuture;

        expect(event.id, 'event-1');
        expect(event.eventId, 'stable-event-1');
        expect(event.sequence, 9);
        expect(event.type, 'runtime.backpressure.dropped');
      },
    );

    test('resumes event replay from the last observed sequence', () async {
      final firstDisconnected = Completer<void>();
      final secondSubscribed = Completer<void>();
      unawaited(() async {
        var connectionCount = 0;
        await for (final request in server) {
          final socket = await WebSocketTransformer.upgrade(request);
          connectionCount++;
          await for (final raw in socket) {
            final payload = jsonDecode(raw as String) as Map;
            final params = payload['params'] as Map;
            if (connectionCount == 1) {
              expect(params.containsKey('after_sequence'), isFalse);
              socket.add(
                jsonEncode(<String, dynamic>{
                  'id': payload['id'],
                  'ok': true,
                  'result': <String, dynamic>{
                    'subscription_id': 'subscription-1',
                  },
                }),
              );
              socket.add(
                jsonEncode(<String, dynamic>{
                  'type': 'runtime.event',
                  'event': <String, dynamic>{
                    'event_id': 'event-7',
                    'sequence': 7,
                    'type': 'message.sent',
                  },
                }),
              );
              await socket.close();
              firstDisconnected.complete();
            } else {
              expect(params['after_sequence'], 7);
              expect(params['replay_limit'], 500);
              socket.add(
                jsonEncode(<String, dynamic>{
                  'id': payload['id'],
                  'ok': true,
                  'result': <String, dynamic>{
                    'subscription_id': 'subscription-2',
                  },
                }),
              );
              secondSubscribed.complete();
              await socket.close();
            }
            break;
          }
          if (connectionCount == 2) break;
        }
      }());

      final eventFuture = client.events.first;
      await client.subscribe();
      expect((await eventFuture).sequence, 7);
      await firstDisconnected.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await client.subscribe();
      await secondSubscribed.future;
    });
  });
}

Future<void> _serveOnce(
  HttpServer server,
  Future<void> Function(HttpRequest request) handler,
) async {
  await for (final request in server) {
    await handler(request);
    break;
  }
}

Future<WebSocket> _acceptV2WebSocket(HttpServer server) async {
  await for (final request in server) {
    if (request.uri.path == '/rpc') {
      final payload =
          jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(payload['method'], 'runtime.info');
      await _writeRpcResult(request, payload['id'], _runtimeInfoV2);
      continue;
    }
    expect(request.uri.path, '/ws');
    return WebSocketTransformer.upgrade(request);
  }
  throw StateError('Runtime server closed before WebSocket connection');
}

Future<void> _writeRpcResult(
  HttpRequest request,
  Object? id,
  Object? result,
) async {
  request.response.headers.contentType = ContentType.json;
  request.response.write(
    jsonEncode(<String, dynamic>{'id': id, 'ok': true, 'result': result}),
  );
  await request.response.close();
}

final Map<String, dynamic> _runtimeInfoV2 = <String, dynamic>{
  'protocol_major_version': 2,
  'capabilities': const <String>['media.upload', 'media.image_input'],
  'methods': const <String>[
    'runtime.info',
    'runtime.health',
    'agent.init',
    'agent.list',
    'agent.delete',
    'agent.send_message',
    'agent.send_message_stream',
    'message.status',
    'character.list',
    'session.create',
    'session.list',
    'session.messages',
  ],
  'active_transport': const <String, dynamic>{'disabled_methods': <String>[]},
  'stream_protocol': const <String, dynamic>{
    'version': 2,
    'start_acknowledgement': true,
  },
  'transports': const <Map<String, dynamic>>[
    <String, dynamic>{'name': 'websocket', 'streaming': 'incremental'},
  ],
};

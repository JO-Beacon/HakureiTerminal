import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/models/app_settings.dart';
import 'package:hakurei_terminal/models/chat_message.dart';
import 'package:hakurei_terminal/services/runtime/gensokyoai_conversation_runtime.dart';
import 'package:hakurei_terminal/services/runtime/http_runtime_client.dart';
import 'package:hakurei_terminal/services/runtime/runtime_conversation_controller.dart';

void main() {
  test(
    'real conversation stack follows the public HTTP and WS protocol',
    () async {
      final fixture = await _RuntimeFixture.start();
      final client = GensokyoAiHttpRuntimeClient(
        connection: ExternalRuntimeConnectionSettings(
          id: 'fixture',
          agentId: 'agent-fixture',
          displayName: 'Fixture',
          baseUrl: fixture.baseUrl,
        ),
      );
      final runtime = GensokyoAiConversationRuntime(client: client);
      final controller = RuntimeConversationController(
        runtime: runtime,
        clock: () => DateTime.utc(2026, 7, 26),
      );
      final controllerNotified = Completer<void>();
      final connectionSubscription = client.connectionStates.listen((
        connected,
      ) {
        if (!connected && !controllerNotified.isCompleted) {
          controller.notifyRuntimeDisconnected();
          controllerNotified.complete();
        }
      });
      addTearDown(() async {
        await connectionSubscription.cancel();
        await controller.dispose();
        await fixture.close();
      });

      await controller.connect();
      await _flush();

      expect(fixture.protocol, <String>['http.runtime.info', 'ws.connect']);
      expect(fixture.webSocketMethods, isEmpty);

      await controller.activate(characterId: 'HakureiReimu', newSession: true);

      expect(fixture.protocol, <String>[
        'http.runtime.info',
        'ws.connect',
        'http.agent.init',
        'ws.runtime.subscribe',
        'http.session.messages',
      ]);
      expect(fixture.initCount, 1);
      expect(fixture.initParams, <String, dynamic>{
        'agent_id': 'agent-fixture',
        'character': 'HakureiReimu',
        'new_session': true,
      });
      expect(controller.snapshot.sessionId, 'session-1');
      expect(controller.snapshot.authoritativeMessages, hasLength(1));
      expect(
        controller.snapshot.authoritativeMessages.single.content,
        'authoritative before send',
      );

      final deltaSnapshot = controller.snapshots.firstWhere(
        (snapshot) => snapshot.streamingAssistant?.content == 'hello ',
      );
      final firstSend = controller.send('hello');
      await fixture.firstSendReceived.future;
      final streaming = await deltaSnapshot;

      expect(controller.snapshot.phase, RuntimeConversationPhase.sending);
      expect(controller.snapshot.pendingUser?.content, 'hello');
      expect(controller.snapshot.pendingUser?.status, 'pending');
      expect(streaming.streamingAssistant?.status, 'streaming');

      fixture.releaseFirstCompletion.complete();
      await fixture.firstReconciliationRequested.future;

      expect(controller.snapshot.phase, RuntimeConversationPhase.reconciling);
      expect(controller.snapshot.pendingUser?.content, 'hello');
      expect(controller.snapshot.streamingAssistant?.content, 'hello runtime');
      expect(controller.snapshot.streamingAssistant?.status, 'completed');
      expect(fixture.initCount, 1);

      fixture.releaseFirstReconciliation.complete();
      await firstSend;

      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
      expect(
        controller.snapshot.authoritativeMessages.map(
          (message) => message.role,
        ),
        <ChatMessageRole>[ChatMessageRole.user, ChatMessageRole.assistant],
      );
      expect(
        controller.snapshot.authoritativeMessages.map(
          (message) => message.content,
        ),
        <String>['hello', 'hello runtime'],
      );
      expect(controller.snapshot.pendingUser, isNull);
      expect(controller.snapshot.streamingAssistant, isNull);

      final cancelledSnapshot = controller.snapshots.firstWhere(
        (snapshot) => snapshot.streamingAssistant?.content == 'cancel me',
      );
      final secondSend = controller.send('cancel this');
      await fixture.secondSendReceived.future;
      await cancelledSnapshot;
      await controller.cancel();
      await secondSend;

      expect(fixture.cancelledStreamId, 'server-stream-2');
      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
      expect(fixture.initCount, 1);

      await fixture.disconnectWebSocket();
      await controllerNotified.future;

      expect(controller.snapshot.phase, RuntimeConversationPhase.disconnected);
      expect(controller.snapshot.displayMessages, isEmpty);
    },
  );
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _RuntimeFixture {
  _RuntimeFixture._(this._server);

  static Future<_RuntimeFixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _RuntimeFixture._(server);
    fixture._requests = server.listen((request) {
      unawaited(fixture._handleRequest(request));
    });
    return fixture;
  }

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _requests;
  final List<String> protocol = <String>[];
  final List<String> webSocketMethods = <String>[];
  final Completer<void> firstSendReceived = Completer<void>();
  final Completer<void> releaseFirstCompletion = Completer<void>();
  final Completer<void> firstReconciliationRequested = Completer<void>();
  final Completer<void> releaseFirstReconciliation = Completer<void>();
  final Completer<void> secondSendReceived = Completer<void>();

  WebSocket? _socket;
  Map<String, dynamic>? initParams;
  String? cancelledStreamId;
  String? _secondStreamRequestId;
  int initCount = 0;
  int _historyCount = 0;
  int _sendCount = 0;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path == '/ws') {
      protocol.add('ws.connect');
      final socket = await WebSocketTransformer.upgrade(request);
      _socket = socket;
      await for (final raw in socket) {
        await _handleWebSocketFrame(
          socket,
          Map<String, dynamic>.from(jsonDecode(raw as String) as Map),
        );
      }
      return;
    }

    final payload = Map<String, dynamic>.from(
      jsonDecode(await utf8.decoder.bind(request).join()) as Map,
    );
    final method = payload['method'] as String;
    protocol.add('http.$method');
    final result = switch (method) {
      'runtime.info' => _runtimeInfo(),
      'agent.init' => _initialize(payload),
      'session.messages' => await _history(),
      _ => throw StateError('Unexpected HTTP method: $method'),
    };
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode(<String, dynamic>{
        'id': payload['id'],
        'ok': true,
        'result': result,
      }),
    );
    await request.response.close();
  }

  Map<String, dynamic> _initialize(Map<String, dynamic> payload) {
    initCount++;
    initParams = Map<String, dynamic>.from(payload['params'] as Map);
    return <String, dynamic>{
      'agent_id': 'agent-fixture',
      'session': <String, dynamic>{'session_id': 'session-1', 'revision': 1},
    };
  }

  Map<String, dynamic> _runtimeInfo() => <String, dynamic>{
    'protocol_major_version': 2,
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

  Future<Map<String, dynamic>> _history() async {
    _historyCount++;
    if (_historyCount == 1) {
      return <String, dynamic>{
        'session_id': 'session-1',
        'revision': 1,
        'messages': <Map<String, dynamic>>[
          _message('initial-1', 'assistant', 'authoritative before send'),
        ],
      };
    }
    if (_historyCount == 2) {
      firstReconciliationRequested.complete();
      await releaseFirstReconciliation.future;
    }
    if (_historyCount >= 3) {
      return <String, dynamic>{
        'session_id': 'session-1',
        'revision': 4,
        'messages': <Map<String, dynamic>>[
          _message('user-1', 'user', 'hello'),
          _message('assistant-1', 'assistant', 'hello runtime'),
          _message('user-2', 'user', 'cancel this'),
        ],
      };
    }
    return <String, dynamic>{
      'session_id': 'session-1',
      'revision': 3,
      'messages': <Map<String, dynamic>>[
        _message('user-1', 'user', 'hello'),
        _message('assistant-1', 'assistant', 'hello runtime'),
      ],
    };
  }

  Future<void> _handleWebSocketFrame(
    WebSocket socket,
    Map<String, dynamic> payload,
  ) async {
    final method = payload['method'] as String;
    webSocketMethods.add(method);
    protocol.add('ws.$method');
    final id = payload['id'];
    if (method == 'runtime.subscribe') {
      expect((payload['params'] as Map)['agent_id'], 'agent-fixture');
      socket.add(
        jsonEncode(<String, dynamic>{
          'id': id,
          'ok': true,
          'result': <String, dynamic>{'subscription_id': 'subscription-1'},
        }),
      );
      return;
    }
    if (method == 'agent.send_message_stream') {
      final params = payload['params'] as Map;
      expect(params['agent_id'], 'agent-fixture');
      expect(params['session_id'], 'session-1');
      expect(params['idempotency_key'], isA<String>());
      _sendCount++;
      if (_sendCount == 1) {
        expect(params['expected_revision'], 1);
        socket.add(
          jsonEncode(<String, dynamic>{
            'id': id,
            'ok': true,
            'result': <String, dynamic>{
              'stream_id': 'server-stream-1',
              'generation_id': 'generation-1',
            },
          }),
        );
        socket.add(
          jsonEncode(<String, dynamic>{
            'id': id,
            'ok': true,
            'stream_id': 'server-stream-1',
            'generation_id': 'generation-1',
            'event': <String, dynamic>{'type': 'content', 'content': 'hello '},
          }),
        );
        firstSendReceived.complete();
        await releaseFirstCompletion.future;
        socket.add(
          jsonEncode(<String, dynamic>{
            'id': id,
            'ok': true,
            'stream_id': 'server-stream-1',
            'generation_id': 'generation-1',
            'done': true,
            'result': <String, dynamic>{
              'content': 'hello runtime',
              'generation_id': 'generation-1',
              'session': <String, dynamic>{
                'session_id': 'session-1',
                'revision': 3,
              },
            },
          }),
        );
      } else {
        expect(params['expected_revision'], 3);
        _secondStreamRequestId = id.toString();
        socket.add(
          jsonEncode(<String, dynamic>{
            'id': id,
            'ok': true,
            'result': <String, dynamic>{
              'stream_id': 'server-stream-2',
              'generation_id': 'generation-2',
            },
          }),
        );
        socket.add(
          jsonEncode(<String, dynamic>{
            'id': id,
            'ok': true,
            'stream_id': 'server-stream-2',
            'generation_id': 'generation-2',
            'event': <String, dynamic>{
              'type': 'content',
              'content': 'cancel me',
            },
          }),
        );
        secondSendReceived.complete();
      }
      return;
    }
    if (method == 'runtime.cancel_stream') {
      cancelledStreamId = (payload['params'] as Map)['stream_id'] as String;
      socket.add(jsonEncode(<String, dynamic>{'id': id, 'ok': true}));
      socket.add(
        jsonEncode(<String, dynamic>{
          'id': _secondStreamRequestId,
          'ok': true,
          'stream_id': 'server-stream-2',
          'generation_id': 'generation-2',
          'event': <String, dynamic>{'type': 'cancelled'},
        }),
      );
      return;
    }
    throw StateError('Unexpected WebSocket method: $method');
  }

  Map<String, dynamic> _message(String id, String role, String content) {
    return <String, dynamic>{
      'id': id,
      'role': role,
      'content': content,
      'created_at': '2026-07-26T00:00:00Z',
    };
  }

  Future<void> disconnectWebSocket() async {
    await _socket!.close();
  }

  Future<void> close() async {
    await _socket?.close();
    await _requests.cancel();
    await _server.close(force: true);
  }
}

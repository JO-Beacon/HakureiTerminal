import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/models/app_settings.dart';
import 'package:hakurei_terminal/models/chat_message.dart';
import 'package:hakurei_terminal/services/runtime/gensokyoai_conversation_runtime.dart';
import 'package:hakurei_terminal/services/runtime/http_runtime_client.dart';
import 'package:hakurei_terminal/services/runtime/runtime_conversation_controller.dart';
import 'package:hakurei_terminal/services/runtime/runtime_reply.dart';
import 'package:hakurei_terminal/services/runtime/runtime_stream_event.dart';

void main() {
  late _FakeRuntimeClient client;
  late GensokyoAiConversationRuntime runtime;

  setUp(() {
    client = _FakeRuntimeClient();
    runtime = GensokyoAiConversationRuntime(client: client);
  });

  tearDown(() => client.dispose());

  test('activation forwards create flag and reads nested session ID', () async {
    client.initializeResult = <String, dynamic>{
      'session': <String, dynamic>{'session_id': 'created-session'},
    };

    final activation = await runtime.activate(
      characterId: 'reimu',
      newSession: true,
    );

    expect(activation.sessionId, 'created-session');
    expect(client.initializeCount, 1);
    expect(client.initializedCharacterId, 'reimu');
    expect(client.initializedNewSession, isTrue);
    expect(client.subscribeCount, 1);
  });

  test('activation rejects a response without a session ID', () async {
    client.initializeResult = <String, dynamic>{
      'session': <String, dynamic>{'character': 'reimu'},
    };

    await expectLater(
      runtime.activate(characterId: 'reimu'),
      throwsA(isA<FormatException>()),
    );
  });

  test('history maps authoritative message fields', () async {
    client.callResult = <String, dynamic>{
      'revision': 4,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'message-1',
          'role': 'assistant',
          'content': 'Hello',
          'created_at': '2026-07-26T10:11:12Z',
        },
      ],
    };

    final messages = await runtime.history('session-1');

    expect(client.calledMethod, 'session.messages');
    expect(client.calledParams, <String, dynamic>{
      'session_id': 'session-1',
      'limit': 500,
    });
    expect(messages.single.id, 'message-1');
    expect(messages.single.role, ChatMessageRole.assistant);
    expect(messages.single.content, 'Hello');
    expect(messages.single.createdAt, DateTime.utc(2026, 7, 26, 10, 11, 12));
    expect(messages.single.conversationId, 'session-1');
  });

  test('history assigns stable display ids when Runtime omits ids', () async {
    client.callResult = <String, dynamic>{
      'revision': 4,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': 'hello',
          'created_at': '2026-07-26T00:00:00Z',
        },
        <String, dynamic>{
          'role': 'assistant',
          'content': 'reply',
          'created_at': '2026-07-26T00:00:01Z',
        },
      ],
    };

    final first = await runtime.history('session-1');
    final second = await runtime.history('session-1');

    expect(first.map((message) => message.id), <String>[
      'runtime-history:session-1:0',
      'runtime-history:session-1:1',
    ]);
    expect(
      second.map((message) => message.id),
      first.map((message) => message.id),
    );
    expect(first.map((message) => message.id).toSet(), hasLength(2));
  });

  test('history preserves reasoning tools images and unknown fields', () async {
    client.callResult = <String, dynamic>{
      'revision': 4,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'assistant',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'caption'},
            <String, dynamic>{
              'type': 'image',
              'image': <String, dynamic>{
                'url': 'https://runtime.example/image.png',
                'mime_type': 'image/png',
              },
            },
          ],
          'reasoning_content': 'private reasoning channel',
          'tool_calls': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'call-1',
              'type': 'function',
              'function': <String, dynamic>{
                'name': 'lookup',
                'arguments': <String, dynamic>{'query': 'value'},
              },
            },
          ],
          'future_field': <String, dynamic>{'enabled': true},
        },
      ],
    };

    final message = (await runtime.history('session-1')).single;

    expect(message.content, 'caption');
    expect(message.contentParts, hasLength(2));
    expect(message.contentParts.last.image['mime_type'], 'image/png');
    expect(message.reasoningContent, 'private reasoning channel');
    expect(message.toolCalls.single['id'], 'call-1');
    expect(message.extensions['future_field'], <String, dynamic>{
      'enabled': true,
    });
    expect(message.toJson()['content'], isA<List<dynamic>>());
    expect(message.toJson()['future_field'], <String, dynamic>{
      'enabled': true,
    });
  });

  test('unknown history roles do not impersonate the user', () async {
    client.callResult = <String, dynamic>{
      'revision': 4,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'future_event', 'content': 'payload'},
      ],
    };

    final message = (await runtime.history('session-1')).single;

    expect(message.role, ChatMessageRole.unknown);
    expect(message.rawRole, 'future_event');
  });

  test(
    'history maps Runtime media references to authenticated image URLs',
    () async {
      client.callResult = <String, dynamic>{
        'revision': 4,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'media',
                'media_id': 'media-1',
                'detail': 'auto',
              },
            ],
          },
        ],
      };

      final part = (await runtime.history(
        'session-1',
      )).single.contentParts.single;

      expect(part.type, 'image');
      expect(
        part.image['url'],
        'http://127.0.0.1:1/media/agent-fixture/media-1',
      );
      expect(part.image['detail'], 'auto');
    },
  );

  test('send streams input without reinitializing the agent', () async {
    final events = await runtime
        .send(
          sessionId: 'session-1',
          characterId: 'reimu',
          input: 'latest input',
        )
        .toList();

    expect(client.initializeCount, 0);
    expect(client.streamedInput, 'latest input');
    expect(events, hasLength(1));
    expect(events.single, isA<RuntimeStreamCompleted>());
  });

  test('structured send forwards Runtime media content parts', () async {
    final events = await runtime
        .sendStructured(
          sessionId: 'session-1',
          characterId: 'reimu',
          input: RuntimeMessageInput(
            text: 'look',
            runtimeContentParts: <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': 'look'},
              <String, dynamic>{
                'type': 'media',
                'media_id': 'media-1',
                'detail': 'auto',
              },
            ],
            displayContentParts: const <ChatContentPart>[],
          ),
        )
        .toList();

    expect(client.streamedParts, <Map<String, dynamic>>[
      <String, dynamic>{'type': 'text', 'text': 'look'},
      <String, dynamic>{
        'type': 'media',
        'media_id': 'media-1',
        'detail': 'auto',
      },
    ]);
    expect(events.single, isA<RuntimeStreamCompleted>());
  });
}

class _FakeRuntimeClient extends GensokyoAiHttpRuntimeClient {
  _FakeRuntimeClient()
    : super(
        connection: const ExternalRuntimeConnectionSettings(
          id: 'fixture',
          agentId: 'agent-fixture',
          displayName: 'Fixture',
          baseUrl: 'http://127.0.0.1:1',
        ),
      );

  Map<String, dynamic> initializeResult = <String, dynamic>{
    'session_id': 'session-1',
  };
  dynamic callResult;
  int initializeCount = 0;
  int subscribeCount = 0;
  String? initializedCharacterId;
  bool? initializedNewSession;
  String? calledMethod;
  Map<String, dynamic>? calledParams;
  String? streamedInput;
  List<Map<String, dynamic>>? streamedParts;

  @override
  int? sessionRevision(String sessionId) => 4;

  @override
  Future<Map<String, dynamic>> initialize({
    required String characterId,
    String? sessionId,
    bool newSession = false,
    ModelProfile? profile,
  }) async {
    initializeCount++;
    initializedCharacterId = characterId;
    initializedNewSession = newSession;
    return initializeResult;
  }

  @override
  Future<void> subscribe({
    Map<String, dynamic> params = const <String, dynamic>{},
  }) async {
    subscribeCount++;
  }

  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    calledMethod = method;
    calledParams = params;
    return callResult;
  }

  @override
  Stream<RuntimeStreamEvent> streamMessage({
    required String sessionId,
    required int expectedRevision,
    required String latestUserInput,
    String? idempotencyKey,
  }) async* {
    streamedInput = latestUserInput;
    yield const RuntimeStreamCompleted(RuntimeReply(content: 'reply'));
  }

  @override
  Stream<RuntimeStreamEvent> streamMessageParts({
    required String sessionId,
    required int expectedRevision,
    required List<Map<String, dynamic>> contentParts,
    String? idempotencyKey,
  }) async* {
    streamedParts = contentParts;
    yield const RuntimeStreamCompleted(RuntimeReply(content: 'reply'));
  }
}

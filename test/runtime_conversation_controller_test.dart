import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/models/chat_message.dart';
import 'package:hakurei_terminal/services/runtime/runtime_conversation_controller.dart';
import 'package:hakurei_terminal/services/runtime/runtime_reply.dart';
import 'package:hakurei_terminal/services/runtime/runtime_stream_event.dart';

void main() {
  late _ControlledRuntime runtime;
  late RuntimeConversationController controller;

  setUp(() {
    runtime = _ControlledRuntime();
    controller = RuntimeConversationController(
      runtime: runtime,
      clock: () => DateTime.utc(2026),
    );
  });

  tearDown(() async {
    await controller.dispose();
    await runtime.close();
  });

  test(
    'an out-of-order history response cannot replace a newer revision',
    () async {
      await controller.connect();
      final firstActivation = controller.activate(characterId: 'reimu');
      await _flush();
      runtime.activations.removeFirst().complete(
        const RuntimeConversationActivation(sessionId: 'session'),
      );
      await _flush();
      final oldHistory = runtime.histories.removeFirst();

      await controller.disconnect();
      await controller.connect();
      final secondActivation = controller.activate(characterId: 'reimu');
      await _flush();
      runtime.activations.removeFirst().complete(
        const RuntimeConversationActivation(sessionId: 'session'),
      );
      await _flush();
      final newHistory = runtime.histories.removeFirst();
      newHistory.complete(<ChatMessage>[_message('new')]);
      await secondActivation;

      oldHistory.complete(<ChatMessage>[_message('old')]);
      await firstActivation;

      expect(controller.snapshot.authoritativeMessages.single.content, 'new');
      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
    },
  );

  test('switching conversations is rejected while sending', () async {
    await _activateReady(controller, runtime);
    final send = controller.send('hello');
    await _flush();

    expect(
      () => controller.activate(characterId: 'marisa'),
      throwsA(isA<RuntimeConversationConflict>()),
    );

    runtime.sends.single.add(
      const RuntimeStreamCompleted(RuntimeReply(content: 'reply')),
    );
    await _flush();
    runtime.histories.removeFirst().complete(<ChatMessage>[
      _message('hello', role: ChatMessageRole.user),
      _message('reply'),
    ]);
    await send;
  });

  test(
    'structured send keeps display parts while forwarding Runtime parts',
    () async {
      await _activateReady(controller, runtime);
      final displayParts = <ChatContentPart>[
        ChatContentPart(
          type: 'image',
          data: <String, dynamic>{
            'type': 'image',
            'image': <String, dynamic>{'data': 'fixture'},
          },
        ),
      ];
      final input = RuntimeMessageInput(
        text: '',
        runtimeContentParts: <Map<String, dynamic>>[
          <String, dynamic>{'type': 'media', 'media_id': 'media-1'},
        ],
        displayContentParts: displayParts,
      );

      final send = controller.sendStructured(input);
      await _flush();

      expect(
        runtime.structuredInputs.single.runtimeContentParts.single,
        <String, dynamic>{'type': 'media', 'media_id': 'media-1'},
      );
      expect(
        controller.snapshot.pendingUser?.contentParts.single.type,
        'image',
      );
      runtime.sends.single.add(
        const RuntimeStreamCompleted(RuntimeReply(content: 'reply')),
      );
      await _flush();
      runtime.histories.removeFirst().complete(<ChatMessage>[
        ChatMessage(
          id: 'user-media',
          role: ChatMessageRole.user,
          content: '',
          contentParts: displayParts,
          createdAt: DateTime.utc(2026),
          conversationId: 'session',
        ),
        _message('reply'),
      ]);
      await send;
    },
  );

  test(
    'stream failure preserves display and allows an explicit retry',
    () async {
      await _activateReady(controller, runtime);
      final send = controller.send('hello');
      await _flush();
      runtime.sends.single.add(
        const RuntimeStreamFailed(
          message: 'Runtime 响应超时，请稍后重新发送',
          metadata: <String, dynamic>{'code': 'agent.stream.timeout'},
        ),
      );

      await expectLater(send, throwsA(isA<RuntimeConversationSendFailure>()));
      expect(controller.snapshot.error.toString(), 'Runtime 响应超时，请稍后重新发送');
      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
      expect(controller.snapshot.pendingUser, isNull);
      expect(
        controller.snapshot.unsyncedDisplayMessages.map(
          (message) => message.content,
        ),
        <String>['hello'],
      );

      final retry = controller.send('retry');
      await _flush();
      expect(runtime.sendInputs.last, 'retry');
      runtime.sends.last.add(
        const RuntimeStreamCompleted(RuntimeReply(content: 'reply')),
      );
      await _flush();
      runtime.histories.removeFirst().complete(<ChatMessage>[
        _message('hello', role: ChatMessageRole.user),
        _message('retry', role: ChatMessageRole.user),
        _message('reply'),
      ]);
      await retry;
    },
  );

  test('activate forwards new-session intent to the runtime', () async {
    await controller.connect();
    final activation = controller.activate(
      characterId: 'reimu',
      newSession: true,
    );
    await _flush();

    expect(runtime.activationRequests.single.newSession, isTrue);
    runtime.activations.removeFirst().complete(
      const RuntimeConversationActivation(sessionId: 'created'),
    );
    await _flush();
    runtime.histories.removeFirst().complete(<ChatMessage>[
      _message('new', role: ChatMessageRole.user),
      _message('new reply'),
    ]);
    await activation;
  });

  test(
    'connect calls are serialized and stale completion is ignored',
    () async {
      runtime.controlConnections = true;
      final first = controller.connect();
      final second = controller.connect();
      await _flush();

      expect(runtime.connects, hasLength(1));
      runtime.connects.removeFirst().complete();
      await first;
      await _flush();
      expect(controller.snapshot.phase, RuntimeConversationPhase.disconnected);
      expect(runtime.connects, hasLength(1));

      runtime.connects.removeFirst().complete();
      await second;
      expect(controller.snapshot.phase, RuntimeConversationPhase.connected);
    },
  );

  test('old send finally cannot clear a newer send guard', () async {
    await _activateReady(controller, runtime);
    final oldSend = controller.send('old');
    await _flush();
    final oldStream = runtime.sends.single;

    await controller.disconnect();
    await _activateReady(controller, runtime);
    final newSend = controller.send('new');
    await _flush();

    await oldStream.close();
    await oldSend;
    expect(
      () => controller.refresh(),
      throwsA(isA<RuntimeConversationConflict>()),
    );

    runtime.sends.last.add(
      const RuntimeStreamCompleted(RuntimeReply(content: 'new reply')),
    );
    await _flush();
    runtime.histories.removeFirst().complete(<ChatMessage>[
      _message('hello', role: ChatMessageRole.user),
      _message('final'),
    ]);
    await newSend;
  });

  test('streaming assistant keeps one local id across all events', () async {
    await _activateReady(controller, runtime);
    final ids = <String>[];
    final subscription = controller.snapshots.listen((snapshot) {
      final assistant = snapshot.streamingAssistant;
      if (assistant != null) ids.add(assistant.id);
    });
    final send = controller.send('hello');
    await _flush();
    runtime.sends.single.add(const RuntimeStreamDelta('a'));
    runtime.sends.single.add(const RuntimeStreamDelta('b'));
    runtime.sends.single.add(
      const RuntimeStreamCompleted(RuntimeReply(content: 'final')),
    );
    await _flush();

    expect(ids, hasLength(3));
    expect(ids.toSet(), hasLength(1));
    runtime.histories.removeFirst().complete(<ChatMessage>[]);
    await send;
    await subscription.cancel();
  });

  test('reasoning and tool updates never enter assistant body text', () async {
    await _activateReady(controller, runtime);
    final send = controller.send('hello');
    await _flush();
    runtime.sends.single.add(
      const RuntimeStreamReasoningDelta('internal reasoning'),
    );
    runtime.sends.single.add(
      const RuntimeStreamToolUpdate(
        <String, dynamic>{'name': 'lookup'},
        metadata: <String, dynamic>{
          'status': 'running',
          'tool_info': <String, dynamic>{'name': 'lookup'},
        },
      ),
    );
    runtime.sends.single.add(const RuntimeStreamDelta('visible answer'));
    await _flush();

    expect(controller.snapshot.streamingAssistant?.content, 'visible answer');
    expect(
      controller.snapshot.streamingAssistant?.reasoningContent,
      'internal reasoning',
    );
    expect(controller.snapshot.streamingAssistant?.toolEvents, hasLength(1));

    runtime.sends.single.add(
      const RuntimeStreamCompleted(
        RuntimeReply(
          content: 'final answer',
          reasoningContent: 'internal reasoning',
          toolEvents: <Map<String, dynamic>>[
            <String, dynamic>{'status': 'completed'},
          ],
        ),
      ),
    );
    await _flush();
    runtime.histories.removeFirst().complete(<ChatMessage>[
      _message('hello', role: ChatMessageRole.user),
      ChatMessage(
        id: 'answer',
        role: ChatMessageRole.assistant,
        content: 'final answer',
        reasoningContent: 'internal reasoning',
        createdAt: DateTime.utc(2026),
        conversationId: 'session',
      ),
    ]);
    await send;

    expect(
      controller.snapshot.authoritativeMessages.last.reasoningContent,
      'internal reasoning',
    );
  });

  test(
    'cancel delegates and cancellation reconciles without send failure',
    () async {
      await _activateReady(controller, runtime);
      final send = controller.send('hello');
      await _flush();
      runtime.sends.single.add(const RuntimeStreamDelta('partial'));
      await _flush();

      await controller.cancel();
      expect(runtime.cancelCount, 1);
      runtime.sends.single.add(
        const RuntimeStreamCancelled(partialContent: 'partial kept'),
      );
      await _flush();
      expect(controller.snapshot.phase, RuntimeConversationPhase.reconciling);
      expect(controller.snapshot.pendingUser?.status, 'pending');
      expect(controller.snapshot.streamingAssistant?.content, 'partial kept');
      expect(controller.snapshot.streamingAssistant?.status, 'cancelled');
      expect(controller.snapshot.error, isNull);

      runtime.histories.removeFirst().complete(<ChatMessage>[
        _message('hello', role: ChatMessageRole.user),
        _message('partial kept'),
      ]);
      await send;
      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
    },
  );

  test(
    'cancellation sync failure preserves display and returns normally',
    () async {
      await _activateReady(controller, runtime);
      final send = controller.send('hello');
      await _flush();
      runtime.sends.single.add(
        const RuntimeStreamCancelled(partialContent: 'partial'),
      );
      await _flush();
      runtime.histories.removeFirst().completeError(StateError('sync failed'));

      await send;
      expect(controller.snapshot.phase, RuntimeConversationPhase.failed);
      expect(controller.snapshot.pendingUser?.content, 'hello');
      expect(controller.snapshot.streamingAssistant?.content, 'partial');
      expect(controller.snapshot.streamingAssistant?.status, 'cancelled');
      expect(controller.snapshot.syncError, isA<StateError>());
      expect(controller.snapshot.error, isNull);
    },
  );

  test(
    'cancellation with stale history becomes ready with unsynced display',
    () async {
      await _activateReady(controller, runtime);
      final send = controller.send('hello');
      await _flush();
      runtime.sends.single.add(
        const RuntimeStreamCancelled(partialContent: 'partial'),
      );
      await _flush();
      runtime.histories.removeFirst().complete(<ChatMessage>[]);

      await send;

      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
      expect(controller.snapshot.pendingUser, isNull);
      expect(controller.snapshot.streamingAssistant, isNull);
      expect(
        controller.snapshot.unsyncedDisplayMessages.map(
          (message) => message.content,
        ),
        <String>['hello', 'partial'],
      );
      expect(
        controller.snapshot.unsyncedDisplayMessages.last.status,
        'cancelled',
      );
      expect(
        controller.snapshot.syncError,
        isA<RuntimeConversationSyncPending>(),
      );
    },
  );

  test('runtime disconnect notification invalidates in-flight work', () async {
    await _activateReady(controller, runtime);
    final send = controller.send('hello');
    await _flush();
    final stream = runtime.sends.single;

    controller.notifyRuntimeDisconnected();
    stream.add(const RuntimeStreamDelta('stale'));
    await stream.close();
    await send;

    expect(runtime.disconnectCount, 0);
    expect(controller.snapshot.phase, RuntimeConversationPhase.disconnected);
    expect(controller.snapshot.displayMessages, isEmpty);
  });

  test(
    'completion content is displayed before history reconciliation',
    () async {
      await _activateReady(controller, runtime);
      final send = controller.send('hello');
      await _flush();
      runtime.sends.single.add(const RuntimeStreamDelta('partial'));
      runtime.sends.single.add(
        const RuntimeStreamCompleted(RuntimeReply(content: 'final content')),
      );
      await _flush();

      expect(controller.snapshot.phase, RuntimeConversationPhase.reconciling);
      expect(controller.snapshot.pendingUser?.content, 'hello');
      expect(controller.snapshot.streamingAssistant?.content, 'final content');
      expect(controller.snapshot.streamingAssistant?.status, 'completed');

      runtime.histories.removeFirst().complete(<ChatMessage>[
        _message('hello', role: ChatMessageRole.user),
        _message('final content'),
      ]);
      await send;
      expect(controller.snapshot.streamingAssistant, isNull);
      expect(controller.snapshot.authoritativeMessages, hasLength(2));
    },
  );

  test('empty completion converges when history contains the user', () async {
    await _activateReady(controller, runtime);
    final send = controller.send('hello');
    await _flush();
    runtime.sends.single.add(
      const RuntimeStreamCompleted(RuntimeReply(content: '')),
    );
    await _flush();

    expect(controller.snapshot.phase, RuntimeConversationPhase.reconciling);
    expect(controller.snapshot.pendingUser?.content, 'hello');
    expect(controller.snapshot.streamingAssistant, isNull);
    expect(
      controller.snapshot.displayMessages.map((message) => message.content),
      <String>['hello'],
    );

    final converged = <ChatMessage>[
      _message('hello', role: ChatMessageRole.user),
    ];
    runtime.histories.removeFirst().complete(converged);
    await send;

    expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
    expect(controller.snapshot.authoritativeMessages, converged);
    expect(controller.snapshot.pendingUser, isNull);
    expect(controller.snapshot.streamingAssistant, isNull);
    expect(controller.snapshot.unsyncedDisplayMessages, isEmpty);
    expect(controller.snapshot.syncError, isNull);
    expect(
      controller.snapshot.displayMessages.map((message) => message.content),
      <String>['hello'],
    );
  });

  test(
    'stale history keeps only user after empty completion until convergence',
    () async {
      await _activateReady(controller, runtime);
      final send = controller.send('hello');
      await _flush();
      runtime.sends.single.add(
        const RuntimeStreamCompleted(RuntimeReply(content: '')),
      );
      await _flush();
      runtime.histories.removeFirst().complete(<ChatMessage>[]);
      await send;

      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
      expect(controller.snapshot.authoritativeMessages, isEmpty);
      expect(controller.snapshot.pendingUser, isNull);
      expect(controller.snapshot.streamingAssistant, isNull);
      expect(
        controller.snapshot.unsyncedDisplayMessages.map(
          (message) => message.content,
        ),
        <String>['hello'],
      );
      expect(
        controller.snapshot.syncError,
        isA<RuntimeConversationSyncPending>(),
      );
      expect(
        controller.snapshot.displayMessages.map((message) => message.content),
        <String>['hello'],
      );

      final refresh = controller.refresh();
      await _flush();
      final converged = <ChatMessage>[
        _message('hello', role: ChatMessageRole.user),
      ];
      runtime.histories.removeFirst().complete(converged);
      await refresh;

      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
      expect(controller.snapshot.authoritativeMessages, converged);
      expect(controller.snapshot.unsyncedDisplayMessages, isEmpty);
      expect(controller.snapshot.syncError, isNull);
      expect(
        controller.snapshot.displayMessages.map((message) => message.content),
        <String>['hello'],
      );
    },
  );

  test('events from a stale connection generation are ignored', () async {
    await _activateReady(controller, runtime);
    final send = controller.send('hello');
    await _flush();
    final oldStream = runtime.sends.single;

    await controller.disconnect();
    oldStream.add(const RuntimeStreamDelta('stale'));
    oldStream.add(
      const RuntimeStreamCompleted(RuntimeReply(content: 'stale final')),
    );
    await oldStream.close();
    await send;

    expect(controller.snapshot.phase, RuntimeConversationPhase.disconnected);
    expect(controller.snapshot.streamingAssistant, isNull);
  });

  test(
    'reconciliation failure preserves completed display and sync error',
    () async {
      await _activateReady(controller, runtime);
      final send = controller.send('hello');
      await _flush();
      runtime.sends.single.add(
        const RuntimeStreamCompleted(RuntimeReply(content: 'kept')),
      );
      await _flush();
      runtime.histories.removeFirst().completeError(StateError('sync failed'));

      await send;
      expect(controller.snapshot.phase, RuntimeConversationPhase.failed);
      expect(controller.snapshot.streamingAssistant?.content, 'kept');
      expect(controller.snapshot.pendingUser?.content, 'hello');
      expect(controller.snapshot.syncError, isA<StateError>());
      expect(controller.snapshot.error, isNull);
    },
  );

  test('activate refresh and connect are rejected during send', () async {
    await _activateReady(controller, runtime);
    final send = controller.send('hello');
    await _flush();

    for (final operation in <Future<void> Function()>[
      () => controller.activate(characterId: 'marisa'),
      controller.refresh,
      controller.connect,
    ]) {
      expect(operation, throwsA(isA<RuntimeConversationConflict>()));
    }

    runtime.sends.single.add(
      const RuntimeStreamCompleted(RuntimeReply(content: 'reply')),
    );
    await _flush();
    runtime.histories.removeFirst().complete(<ChatMessage>[
      _message('hello', role: ChatMessageRole.user),
      _message('reply'),
    ]);
    await send;
  });

  test(
    'empty successful history preserves completed display as sync pending',
    () async {
      await _activateReady(controller, runtime);
      final send = controller.send('hello');
      await _flush();
      runtime.sends.single.add(
        const RuntimeStreamCompleted(RuntimeReply(content: 'reply')),
      );
      await _flush();
      runtime.histories.removeFirst().complete(<ChatMessage>[]);

      await send;

      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
      expect(controller.snapshot.authoritativeMessages, isEmpty);
      expect(controller.snapshot.pendingUser, isNull);
      expect(controller.snapshot.streamingAssistant, isNull);
      expect(
        controller.snapshot.unsyncedDisplayMessages.map(
          (message) => message.content,
        ),
        <String>['hello', 'reply'],
      );
      expect(
        controller.snapshot.unsyncedDisplayMessages.last.status,
        'completed',
      );
      expect(
        controller.snapshot.syncError,
        isA<RuntimeConversationSyncPending>(),
      );
      expect(controller.snapshot.error, isNull);
    },
  );

  test('stale baseline history remains sync pending', () async {
    final baseline = <ChatMessage>[_message('before')];
    await _activateReady(controller, runtime, history: baseline);
    final send = controller.send('hello');
    await _flush();
    runtime.sends.single.add(
      const RuntimeStreamCompleted(RuntimeReply(content: 'reply')),
    );
    await _flush();
    runtime.histories.removeFirst().complete(baseline);

    await send;

    expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
    expect(controller.snapshot.authoritativeMessages, baseline);
    expect(controller.snapshot.displayMessages, hasLength(3));
    expect(
      controller.snapshot.syncError,
      isA<RuntimeConversationSyncPending>(),
    );
  });

  test(
    'manual refresh preserves stale layers then accepts convergence',
    () async {
      final baseline = <ChatMessage>[_message('before')];
      await _activateReady(controller, runtime, history: baseline);
      final send = controller.send('hello');
      await _flush();
      runtime.sends.single.add(
        const RuntimeStreamCompleted(RuntimeReply(content: 'reply')),
      );
      await _flush();
      runtime.histories.removeFirst().complete(<ChatMessage>[]);
      await send;

      final staleRefresh = controller.refresh();
      await _flush();
      runtime.histories.removeFirst().complete(baseline);
      await staleRefresh;
      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
      expect(
        controller.snapshot.unsyncedDisplayMessages.map(
          (message) => message.content,
        ),
        <String>['hello', 'reply'],
      );

      final convergedRefresh = controller.refresh();
      await _flush();
      final converged = <ChatMessage>[
        ...baseline,
        _message('hello', role: ChatMessageRole.user),
        _message('reply'),
      ];
      runtime.histories.removeFirst().complete(converged);
      await convergedRefresh;

      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
      expect(controller.snapshot.authoritativeMessages, converged);
      expect(controller.snapshot.pendingUser, isNull);
      expect(controller.snapshot.streamingAssistant, isNull);
      expect(controller.snapshot.unsyncedDisplayMessages, isEmpty);
      expect(controller.snapshot.syncError, isNull);
    },
  );

  test('normal converged history clears transient layers', () async {
    final baseline = <ChatMessage>[_message('before')];
    await _activateReady(controller, runtime, history: baseline);
    final send = controller.send('hello');
    await _flush();
    runtime.sends.single.add(
      const RuntimeStreamCompleted(RuntimeReply(content: 'reply')),
    );
    await _flush();
    final converged = <ChatMessage>[
      ...baseline,
      _message('hello', role: ChatMessageRole.user),
      _message('reply'),
    ];
    runtime.histories.removeFirst().complete(converged);

    await send;

    expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
    expect(controller.snapshot.authoritativeMessages, converged);
    expect(controller.snapshot.pendingUser, isNull);
    expect(controller.snapshot.streamingAssistant, isNull);
    expect(controller.snapshot.unsyncedDisplayMessages, isEmpty);
    expect(controller.snapshot.syncError, isNull);
  });

  test(
    'two sends accumulate display only until ordered history convergence',
    () async {
      final baseline = <ChatMessage>[_message('before')];
      await _activateReady(controller, runtime, history: baseline);

      final firstSend = controller.send('first');
      await _flush();
      runtime.sends.single.add(
        const RuntimeStreamCompleted(RuntimeReply(content: 'first reply')),
      );
      await _flush();
      runtime.histories.removeFirst().complete(baseline);
      await firstSend;

      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
      expect(
        controller.snapshot.unsyncedDisplayMessages.map(
          (message) => message.content,
        ),
        <String>['first', 'first reply'],
      );
      expect(
        () => controller.snapshot.unsyncedDisplayMessages.add(_message('no')),
        throwsUnsupportedError,
      );

      final secondSend = controller.send('second');
      await _flush();
      expect(
        controller.snapshot.displayMessages.map((message) => message.content),
        <String>['before', 'first', 'first reply', 'second'],
      );
      expect(runtime.sendInputs, <String>['first', 'second']);

      runtime.sends.last.add(
        const RuntimeStreamCompleted(RuntimeReply(content: 'second reply')),
      );
      await _flush();
      runtime.histories.removeFirst().complete(baseline);
      await secondSend;

      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
      expect(
        controller.snapshot.unsyncedDisplayMessages.map(
          (message) => message.content,
        ),
        <String>['first', 'first reply', 'second', 'second reply'],
      );
      expect(
        controller.snapshot.displayMessages.map((message) => message.content),
        <String>['before', 'first', 'first reply', 'second', 'second reply'],
      );

      final refresh = controller.refresh();
      await _flush();
      final converged = <ChatMessage>[
        ...baseline,
        _message('server note'),
        _message('first', role: ChatMessageRole.user),
        _message('first reply'),
        _message('other server message'),
        _message('second', role: ChatMessageRole.user),
        _message('second reply'),
      ];
      runtime.histories.removeFirst().complete(converged);
      await refresh;

      expect(controller.snapshot.phase, RuntimeConversationPhase.ready);
      expect(controller.snapshot.authoritativeMessages, converged);
      expect(controller.snapshot.unsyncedDisplayMessages, isEmpty);
      expect(controller.snapshot.syncError, isNull);
      expect(runtime.sendInputs, <String>['first', 'second']);
    },
  );

  test('cancel is rejected when no send is active', () {
    expect(
      () => controller.cancel(),
      throwsA(isA<RuntimeConversationConflict>()),
    );
  });

  test('dispose disconnects once and tolerates disconnect failure', () async {
    runtime.disconnectError = StateError('transport gone');
    await controller.dispose();
    await controller.dispose();

    expect(runtime.disconnectCount, 1);
    expect(() => controller.connect(), throwsA(isA<StateError>()));
  });
}

Future<void> _activateReady(
  RuntimeConversationController controller,
  _ControlledRuntime runtime, {
  List<ChatMessage> history = const <ChatMessage>[],
}) async {
  await controller.connect();
  final activation = controller.activate(characterId: 'reimu');
  await _flush();
  runtime.activations.removeFirst().complete(
    const RuntimeConversationActivation(sessionId: 'session'),
  );
  await _flush();
  runtime.histories.removeFirst().complete(history);
  await activation;
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

ChatMessage _message(
  String content, {
  ChatMessageRole role = ChatMessageRole.assistant,
}) {
  return ChatMessage(
    id: content,
    role: role,
    content: content,
    createdAt: DateTime.utc(2026),
    conversationId: 'session',
  );
}

class _ControlledRuntime
    implements ConversationRuntime, StructuredConversationRuntime {
  final Queue<Completer<void>> connects = Queue<Completer<void>>();
  final Queue<Completer<RuntimeConversationActivation>> activations =
      Queue<Completer<RuntimeConversationActivation>>();
  final Queue<Completer<List<ChatMessage>>> histories =
      Queue<Completer<List<ChatMessage>>>();
  final List<StreamController<RuntimeStreamEvent>> sends =
      <StreamController<RuntimeStreamEvent>>[];
  final List<String> sendInputs = <String>[];
  final List<RuntimeMessageInput> structuredInputs = <RuntimeMessageInput>[];
  final List<_ActivationRequest> activationRequests = <_ActivationRequest>[];
  bool controlConnections = false;
  Object? disconnectError;
  int disconnectCount = 0;
  int cancelCount = 0;

  @override
  Future<void> connect() {
    if (!controlConnections) return Future<void>.value();
    final completer = Completer<void>();
    connects.add(completer);
    return completer.future;
  }

  @override
  Future<void> disconnect() {
    disconnectCount++;
    final error = disconnectError;
    if (error != null) return Future<void>.error(error);
    return Future<void>.value();
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
  }

  @override
  Future<RuntimeConversationActivation> activate({
    required String characterId,
    String? sessionId,
    bool newSession = false,
  }) {
    activationRequests.add(
      _ActivationRequest(
        characterId: characterId,
        sessionId: sessionId,
        newSession: newSession,
      ),
    );
    final completer = Completer<RuntimeConversationActivation>();
    activations.add(completer);
    return completer.future;
  }

  @override
  Future<List<ChatMessage>> history(String sessionId) {
    final completer = Completer<List<ChatMessage>>();
    histories.add(completer);
    return completer.future;
  }

  @override
  Stream<RuntimeStreamEvent> send({
    required String sessionId,
    required String characterId,
    required String input,
  }) {
    sendInputs.add(input);
    final controller = StreamController<RuntimeStreamEvent>();
    sends.add(controller);
    return controller.stream;
  }

  @override
  Stream<RuntimeStreamEvent> sendStructured({
    required String sessionId,
    required String characterId,
    required RuntimeMessageInput input,
  }) {
    structuredInputs.add(input);
    final controller = StreamController<RuntimeStreamEvent>();
    sends.add(controller);
    return controller.stream;
  }

  Future<void> close() async {
    for (final send in sends) {
      if (!send.isClosed) await send.close();
    }
  }
}

class _ActivationRequest {
  const _ActivationRequest({
    required this.characterId,
    required this.sessionId,
    required this.newSession,
  });

  final String characterId;
  final String? sessionId;
  final bool newSession;
}

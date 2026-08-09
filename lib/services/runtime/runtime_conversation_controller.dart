import 'dart:async';
import 'dart:convert';

import '../../models/chat_message.dart';
import 'runtime_stream_event.dart';

abstract interface class ConversationRuntime {
  Future<void> connect();

  Future<void> disconnect();

  Future<void> cancel();

  Future<RuntimeConversationActivation> activate({
    required String characterId,
    String? sessionId,
    bool newSession = false,
  });

  Future<List<ChatMessage>> history(String sessionId);

  Stream<RuntimeStreamEvent> send({
    required String sessionId,
    required String characterId,
    required String input,
  });
}

abstract interface class StructuredConversationRuntime {
  Stream<RuntimeStreamEvent> sendStructured({
    required String sessionId,
    required String characterId,
    required RuntimeMessageInput input,
  });
}

class RuntimeMessageInput {
  RuntimeMessageInput({
    required this.text,
    required List<Map<String, dynamic>> runtimeContentParts,
    required List<ChatContentPart> displayContentParts,
  }) : runtimeContentParts = List<Map<String, dynamic>>.unmodifiable(
         runtimeContentParts,
       ),
       displayContentParts = List<ChatContentPart>.unmodifiable(
         displayContentParts,
       );

  final String text;
  final List<Map<String, dynamic>> runtimeContentParts;
  final List<ChatContentPart> displayContentParts;
}

class RuntimeConversationActivation {
  const RuntimeConversationActivation({required this.sessionId});

  final String sessionId;
}

enum RuntimeConversationPhase {
  disconnected,
  connected,
  activating,
  ready,
  sending,
  reconciling,
  failed,
}

class RuntimeConversationConflict implements Exception {
  const RuntimeConversationConflict(this.message);

  final String message;

  @override
  String toString() => 'RuntimeConversationConflict: $message';
}

class RuntimeConversationSyncPending implements Exception {
  const RuntimeConversationSyncPending();

  @override
  String toString() =>
      'RuntimeConversationSyncPending: Runtime history has not converged';
}

class RuntimeConversationSendFailure implements Exception {
  const RuntimeConversationSendFailure(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

class RuntimeConversationSnapshot {
  RuntimeConversationSnapshot({
    required this.phase,
    required this.connectionGeneration,
    required this.activationGeneration,
    this.characterId,
    this.sessionId,
    List<ChatMessage> authoritativeMessages = const <ChatMessage>[],
    List<ChatMessage> unsyncedDisplayMessages = const <ChatMessage>[],
    this.pendingUser,
    this.streamingAssistant,
    this.error,
    this.syncError,
  }) : authoritativeMessages = List<ChatMessage>.unmodifiable(
         authoritativeMessages,
       ),
       unsyncedDisplayMessages = List<ChatMessage>.unmodifiable(
         unsyncedDisplayMessages,
       );

  factory RuntimeConversationSnapshot.disconnected() {
    return RuntimeConversationSnapshot(
      phase: RuntimeConversationPhase.disconnected,
      connectionGeneration: 0,
      activationGeneration: 0,
    );
  }

  final RuntimeConversationPhase phase;
  final int connectionGeneration;
  final int activationGeneration;
  final String? characterId;
  final String? sessionId;
  final List<ChatMessage> authoritativeMessages;
  final List<ChatMessage> unsyncedDisplayMessages;
  final ChatMessage? pendingUser;
  final ChatMessage? streamingAssistant;
  final Object? error;
  final Object? syncError;

  List<ChatMessage> get displayMessages =>
      List<ChatMessage>.unmodifiable(<ChatMessage>[
        ...authoritativeMessages,
        ...unsyncedDisplayMessages,
        ?pendingUser,
        ?streamingAssistant,
      ]);
}

class RuntimeConversationController {
  RuntimeConversationController({
    required ConversationRuntime runtime,
    DateTime Function()? clock,
  }) : _runtime = runtime,
       _clock = clock ?? DateTime.now;

  final ConversationRuntime _runtime;
  final DateTime Function() _clock;
  final StreamController<RuntimeConversationSnapshot> _snapshots =
      StreamController<RuntimeConversationSnapshot>.broadcast(sync: true);
  final Map<String, int> _historyRevisions = <String, int>{};

  RuntimeConversationSnapshot _snapshot =
      RuntimeConversationSnapshot.disconnected();
  Future<void> _operationTail = Future<void>.value();
  Future<void> _connectionTail = Future<void>.value();
  Future<void>? _disposeRequest;
  bool _disposed = false;
  Object? _activeSend;
  int _operationGeneration = 0;
  int _localMessageId = 0;
  _PendingReconciliation? _pendingReconciliation;

  RuntimeConversationSnapshot get snapshot => _snapshot;

  Stream<RuntimeConversationSnapshot> get snapshots => _snapshots.stream;

  Future<void> connect() async {
    _checkAvailableForOperation('connect');
    final connectionGeneration = _snapshot.connectionGeneration + 1;
    _invalidateOperations();
    _emit(
      RuntimeConversationSnapshot(
        phase: RuntimeConversationPhase.disconnected,
        connectionGeneration: connectionGeneration,
        activationGeneration: _snapshot.activationGeneration + 1,
      ),
    );

    try {
      await _serializeConnection(_runtime.connect);
      if (!_isCurrentConnection(connectionGeneration)) return;
      _emit(
        RuntimeConversationSnapshot(
          phase: RuntimeConversationPhase.connected,
          connectionGeneration: connectionGeneration,
          activationGeneration: _snapshot.activationGeneration,
        ),
      );
    } catch (error) {
      if (!_isCurrentConnection(connectionGeneration)) return;
      _emit(
        RuntimeConversationSnapshot(
          phase: RuntimeConversationPhase.failed,
          connectionGeneration: connectionGeneration,
          activationGeneration: _snapshot.activationGeneration,
          error: error,
        ),
      );
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _checkNotDisposed();
    final connectionGeneration = _snapshot.connectionGeneration + 1;
    _invalidateOperations();
    _emit(
      RuntimeConversationSnapshot(
        phase: RuntimeConversationPhase.disconnected,
        connectionGeneration: connectionGeneration,
        activationGeneration: _snapshot.activationGeneration + 1,
      ),
    );
    try {
      await _serializeConnection(_runtime.disconnect);
    } catch (error) {
      if (!_isCurrentConnection(connectionGeneration)) return;
      _emitFailure(error);
      rethrow;
    }
  }

  /// Invalidates local operations after an unsolicited transport disconnect.
  /// The runtime already knows about this disconnect, so it is not called.
  void notifyRuntimeDisconnected() {
    _checkNotDisposed();
    _invalidateOperations();
    _emit(
      RuntimeConversationSnapshot(
        phase: RuntimeConversationPhase.disconnected,
        connectionGeneration: _snapshot.connectionGeneration + 1,
        activationGeneration: _snapshot.activationGeneration + 1,
      ),
    );
  }

  Future<void> activate({
    required String characterId,
    String? sessionId,
    bool newSession = false,
  }) {
    _checkAvailableForOperation('activate');
    return _serialize(() async {
      final connectionGeneration = _requireConnection();
      final activationGeneration = _snapshot.activationGeneration + 1;
      _pendingReconciliation = null;
      _emit(
        RuntimeConversationSnapshot(
          phase: RuntimeConversationPhase.activating,
          connectionGeneration: connectionGeneration,
          activationGeneration: activationGeneration,
          characterId: characterId,
          sessionId: sessionId,
        ),
      );

      try {
        final activation = await _runtime.activate(
          characterId: characterId,
          sessionId: sessionId,
          newSession: newSession,
        );
        if (!_isCurrent(connectionGeneration, activationGeneration)) return;
        _emit(
          RuntimeConversationSnapshot(
            phase: RuntimeConversationPhase.activating,
            connectionGeneration: connectionGeneration,
            activationGeneration: activationGeneration,
            characterId: characterId,
            sessionId: activation.sessionId,
          ),
        );
        await _loadHistory(
          activation.sessionId,
          connectionGeneration: connectionGeneration,
          activationGeneration: activationGeneration,
          successPhase: RuntimeConversationPhase.ready,
        );
      } catch (error) {
        if (!_isCurrent(connectionGeneration, activationGeneration)) return;
        _emitFailure(error);
        rethrow;
      }
    });
  }

  Future<void> refresh() {
    _checkAvailableForOperation('refresh');
    return _serialize(() async {
      final connectionGeneration = _requireConnection();
      final activationGeneration = _snapshot.activationGeneration;
      final sessionId = _requireSession();
      try {
        await _loadHistory(
          sessionId,
          connectionGeneration: connectionGeneration,
          activationGeneration: activationGeneration,
          successPhase: RuntimeConversationPhase.ready,
        );
      } catch (error) {
        if (!_isCurrent(connectionGeneration, activationGeneration)) return;
        _emitFailure(error);
        rethrow;
      }
    });
  }

  Future<void> send(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(input, 'input', 'must not be empty');
    }
    return _send(
      RuntimeMessageInput(
        text: trimmed,
        runtimeContentParts: <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': trimmed},
        ],
        displayContentParts: const <ChatContentPart>[],
      ),
      structured: false,
    );
  }

  Future<void> sendStructured(RuntimeMessageInput input) {
    if (input.runtimeContentParts.isEmpty) {
      throw ArgumentError.value(
        input.runtimeContentParts,
        'runtimeContentParts',
        'must not be empty',
      );
    }
    if (_runtime is! StructuredConversationRuntime) {
      throw const RuntimeConversationConflict(
        'Runtime does not support structured messages',
      );
    }
    return _send(input, structured: true);
  }

  Future<void> _send(RuntimeMessageInput input, {required bool structured}) {
    _checkAvailableForOperation('send');
    if (_snapshot.phase != RuntimeConversationPhase.ready) {
      throw RuntimeConversationConflict(
        'Cannot send while conversation is ${_snapshot.phase.name}',
      );
    }
    final sendToken = Object();
    _activeSend = sendToken;
    final operation = _serialize(() async {
      final connectionGeneration = _requireConnection();
      final activationGeneration = _snapshot.activationGeneration;
      final sessionId = _requireSession();
      final characterId = _snapshot.characterId!;
      final pendingUser = ChatMessage(
        id: 'local-${++_localMessageId}',
        role: ChatMessageRole.user,
        content: input.text,
        contentParts: input.displayContentParts,
        createdAt: _clock(),
        conversationId: sessionId,
        status: 'pending',
      );
      final authoritativeBaseline = _snapshot.authoritativeMessages;
      final unsyncedDisplayMessages = _snapshot.unsyncedDisplayMessages;
      _emit(
        RuntimeConversationSnapshot(
          phase: RuntimeConversationPhase.sending,
          connectionGeneration: connectionGeneration,
          activationGeneration: activationGeneration,
          characterId: characterId,
          sessionId: sessionId,
          authoritativeMessages: _snapshot.authoritativeMessages,
          unsyncedDisplayMessages: unsyncedDisplayMessages,
          pendingUser: pendingUser,
          syncError: _snapshot.syncError,
        ),
      );

      var content = '';
      var reasoningContent = '';
      final toolEvents = <Map<String, dynamic>>[];
      final assistantId = 'local-${++_localMessageId}';
      final assistantCreatedAt = _clock();
      var shouldReconcile = false;
      try {
        final stream = structured
            ? (_runtime as StructuredConversationRuntime).sendStructured(
                sessionId: sessionId,
                characterId: characterId,
                input: input,
              )
            : _runtime.send(
                sessionId: sessionId,
                characterId: characterId,
                input: input.text,
              );
        await for (final event in stream) {
          if (!_isCurrent(connectionGeneration, activationGeneration)) return;
          if (event is RuntimeStreamDelta) {
            content += event.text;
            _emitAssistant(
              content,
              reasoningContent: reasoningContent,
              toolEvents: toolEvents,
              id: assistantId,
              createdAt: assistantCreatedAt,
              status: 'streaming',
            );
          } else if (event is RuntimeStreamReasoningDelta) {
            reasoningContent += event.text;
            _emitAssistant(
              content,
              reasoningContent: reasoningContent,
              toolEvents: toolEvents,
              id: assistantId,
              createdAt: assistantCreatedAt,
              status: 'streaming',
            );
          } else if (event is RuntimeStreamToolUpdate) {
            toolEvents.add(event.metadata);
            _emitAssistant(
              content,
              reasoningContent: reasoningContent,
              toolEvents: toolEvents,
              id: assistantId,
              createdAt: assistantCreatedAt,
              status: 'streaming',
            );
          } else if (event is RuntimeStreamCompleted) {
            shouldReconcile = true;
            content = event.reply.content;
            reasoningContent = event.reply.reasoningContent;
            toolEvents
              ..clear()
              ..addAll(event.reply.toolEvents);
            final hasAssistantDisplay =
                content.isNotEmpty ||
                reasoningContent.isNotEmpty ||
                toolEvents.isNotEmpty;
            if (!hasAssistantDisplay) {
              _emit(
                RuntimeConversationSnapshot(
                  phase: RuntimeConversationPhase.reconciling,
                  connectionGeneration: connectionGeneration,
                  activationGeneration: activationGeneration,
                  characterId: characterId,
                  sessionId: sessionId,
                  authoritativeMessages: _snapshot.authoritativeMessages,
                  unsyncedDisplayMessages: unsyncedDisplayMessages,
                  pendingUser: pendingUser,
                  syncError: _snapshot.syncError,
                ),
              );
            } else {
              _emitAssistant(
                content,
                reasoningContent: reasoningContent,
                toolEvents: toolEvents,
                id: assistantId,
                createdAt: assistantCreatedAt,
                status: 'completed',
                phase: RuntimeConversationPhase.reconciling,
              );
            }
            _pendingReconciliation = _PendingReconciliation(
              authoritativeBaseline: authoritativeBaseline,
              displayMessages: <ChatMessage>[
                ...unsyncedDisplayMessages,
                pendingUser,
                if (hasAssistantDisplay) _snapshot.streamingAssistant!,
              ],
            );
            break;
          } else if (event is RuntimeStreamFailed) {
            content = event.partialContent;
            reasoningContent = event.partialReasoning;
            toolEvents
              ..clear()
              ..addAll(event.toolEvents);
            if (content.isNotEmpty ||
                reasoningContent.isNotEmpty ||
                toolEvents.isNotEmpty) {
              _emitAssistant(
                content,
                reasoningContent: reasoningContent,
                toolEvents: toolEvents,
                id: assistantId,
                createdAt: assistantCreatedAt,
                status: 'failed',
              );
            }
            throw RuntimeConversationSendFailure(
              event.message,
              code: event.metadata['code']?.toString(),
            );
          } else if (event is RuntimeStreamCancelled) {
            shouldReconcile = true;
            if (event.partialContent.isNotEmpty) {
              content = event.partialContent;
            }
            if (event.partialReasoning.isNotEmpty) {
              reasoningContent = event.partialReasoning;
            }
            if (event.toolEvents.isNotEmpty) {
              toolEvents
                ..clear()
                ..addAll(event.toolEvents);
            }
            _emitAssistant(
              content,
              reasoningContent: reasoningContent,
              toolEvents: toolEvents,
              id: assistantId,
              createdAt: assistantCreatedAt,
              status: 'cancelled',
              phase: RuntimeConversationPhase.reconciling,
            );
            _pendingReconciliation = _PendingReconciliation(
              authoritativeBaseline: authoritativeBaseline,
              displayMessages: <ChatMessage>[
                ...unsyncedDisplayMessages,
                pendingUser,
                if (content.isNotEmpty ||
                    reasoningContent.isNotEmpty ||
                    toolEvents.isNotEmpty)
                  _snapshot.streamingAssistant!,
              ],
            );
            break;
          }
        }
        if (!shouldReconcile) {
          throw StateError('Runtime send ended without completion');
        }
      } catch (error) {
        if (!_isCurrent(connectionGeneration, activationGeneration)) return;
        if (error is RuntimeConversationSendFailure) {
          final failedDisplayMessages = <ChatMessage>[
            ...unsyncedDisplayMessages,
            pendingUser,
            if (_snapshot.streamingAssistant != null)
              _snapshot.streamingAssistant!,
          ];
          _pendingReconciliation = _PendingReconciliation(
            authoritativeBaseline: authoritativeBaseline,
            displayMessages: failedDisplayMessages,
          );
          _emit(
            RuntimeConversationSnapshot(
              phase: RuntimeConversationPhase.ready,
              connectionGeneration: connectionGeneration,
              activationGeneration: activationGeneration,
              characterId: characterId,
              sessionId: sessionId,
              authoritativeMessages: authoritativeBaseline,
              unsyncedDisplayMessages: failedDisplayMessages,
              error: error,
              syncError: const RuntimeConversationSyncPending(),
            ),
          );
          rethrow;
        }
        _emitFailure(error);
        rethrow;
      }

      try {
        await _loadHistory(
          sessionId,
          connectionGeneration: connectionGeneration,
          activationGeneration: activationGeneration,
          successPhase: RuntimeConversationPhase.ready,
        );
      } catch (error) {
        if (!_isCurrent(connectionGeneration, activationGeneration)) return;
        _emit(
          RuntimeConversationSnapshot(
            phase: RuntimeConversationPhase.failed,
            connectionGeneration: connectionGeneration,
            activationGeneration: activationGeneration,
            characterId: characterId,
            sessionId: sessionId,
            authoritativeMessages: _snapshot.authoritativeMessages,
            unsyncedDisplayMessages: _snapshot.unsyncedDisplayMessages,
            pendingUser: _snapshot.pendingUser,
            streamingAssistant: _snapshot.streamingAssistant,
            syncError: error,
          ),
        );
      }
    });
    return operation.whenComplete(() {
      if (identical(_activeSend, sendToken)) _activeSend = null;
    });
  }

  Future<void> cancel() {
    _checkNotDisposed();
    if (_activeSend == null) {
      throw const RuntimeConversationConflict('No send is in progress');
    }
    return _runtime.cancel();
  }

  Future<void> dispose() => _disposeRequest ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _invalidateOperations();
    try {
      await _serializeConnection(_runtime.disconnect);
    } catch (_) {
      // Disposal must still release the snapshot stream after transport errors.
    } finally {
      await _snapshots.close();
    }
  }

  Future<void> _loadHistory(
    String sessionId, {
    required int connectionGeneration,
    required int activationGeneration,
    required RuntimeConversationPhase successPhase,
  }) async {
    final revision = (_historyRevisions[sessionId] ?? 0) + 1;
    _historyRevisions[sessionId] = revision;
    final messages = await _runtime.history(sessionId);
    if (!_isCurrent(connectionGeneration, activationGeneration) ||
        _historyRevisions[sessionId] != revision) {
      return;
    }
    final pendingReconciliation = _pendingReconciliation;
    if (pendingReconciliation != null &&
        !pendingReconciliation.hasConverged(messages)) {
      _emit(
        RuntimeConversationSnapshot(
          phase: RuntimeConversationPhase.ready,
          connectionGeneration: connectionGeneration,
          activationGeneration: activationGeneration,
          characterId: _snapshot.characterId,
          sessionId: sessionId,
          authoritativeMessages: pendingReconciliation.authoritativeBaseline,
          unsyncedDisplayMessages: pendingReconciliation.displayMessages,
          syncError: const RuntimeConversationSyncPending(),
        ),
      );
      return;
    }
    _pendingReconciliation = null;
    _emit(
      RuntimeConversationSnapshot(
        phase: successPhase,
        connectionGeneration: connectionGeneration,
        activationGeneration: activationGeneration,
        characterId: _snapshot.characterId,
        sessionId: sessionId,
        authoritativeMessages: messages,
      ),
    );
  }

  void _emitAssistant(
    String content, {
    required String reasoningContent,
    required List<Map<String, dynamic>> toolEvents,
    required String id,
    required DateTime createdAt,
    required String status,
    RuntimeConversationPhase phase = RuntimeConversationPhase.sending,
  }) {
    _emit(
      RuntimeConversationSnapshot(
        phase: phase,
        connectionGeneration: _snapshot.connectionGeneration,
        activationGeneration: _snapshot.activationGeneration,
        characterId: _snapshot.characterId,
        sessionId: _snapshot.sessionId,
        authoritativeMessages: _snapshot.authoritativeMessages,
        unsyncedDisplayMessages: _snapshot.unsyncedDisplayMessages,
        pendingUser: _snapshot.pendingUser,
        streamingAssistant: ChatMessage(
          id: id,
          role: ChatMessageRole.assistant,
          content: content,
          reasoningContent: reasoningContent,
          toolEvents: List<Map<String, dynamic>>.unmodifiable(toolEvents),
          createdAt: createdAt,
          conversationId: _snapshot.sessionId!,
          status: status,
        ),
        syncError: _snapshot.syncError,
      ),
    );
  }

  void _emitFailure(Object error) {
    _emit(
      RuntimeConversationSnapshot(
        phase: RuntimeConversationPhase.failed,
        connectionGeneration: _snapshot.connectionGeneration,
        activationGeneration: _snapshot.activationGeneration,
        characterId: _snapshot.characterId,
        sessionId: _snapshot.sessionId,
        authoritativeMessages: _snapshot.authoritativeMessages,
        unsyncedDisplayMessages: _snapshot.unsyncedDisplayMessages,
        pendingUser: _snapshot.pendingUser,
        streamingAssistant: _snapshot.streamingAssistant,
        error: error,
        syncError: _snapshot.syncError,
      ),
    );
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final operationGeneration = _operationGeneration;
    final result = _operationTail.then<void>((_) async {
      if (operationGeneration != _operationGeneration) return;
      await operation();
    });
    _operationTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<T> _serializeConnection<T>(Future<T> Function() operation) {
    final result = _connectionTail.then((_) => operation());
    _connectionTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  void _invalidateOperations() {
    _operationGeneration++;
    _operationTail = Future<void>.value();
    _activeSend = null;
    _pendingReconciliation = null;
  }

  int _requireConnection() {
    if (_snapshot.phase == RuntimeConversationPhase.disconnected) {
      throw const RuntimeConversationConflict('Runtime is disconnected');
    }
    return _snapshot.connectionGeneration;
  }

  String _requireSession() {
    final sessionId = _snapshot.sessionId;
    if (sessionId == null || _snapshot.characterId == null) {
      throw const RuntimeConversationConflict('No conversation is active');
    }
    return sessionId;
  }

  void _checkAvailableForOperation(String operation) {
    _checkNotDisposed();
    if (_activeSend != null) {
      throw RuntimeConversationConflict(
        'Cannot $operation while a send is in progress',
      );
    }
  }

  bool _isCurrentConnection(int connectionGeneration) {
    return _snapshot.connectionGeneration == connectionGeneration;
  }

  bool _isCurrent(int connectionGeneration, int activationGeneration) {
    return _snapshot.connectionGeneration == connectionGeneration &&
        _snapshot.activationGeneration == activationGeneration;
  }

  void _emit(RuntimeConversationSnapshot snapshot) {
    if (_disposed) return;
    _snapshot = snapshot;
    _snapshots.add(snapshot);
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('RuntimeConversationController is disposed');
    }
  }
}

class _PendingReconciliation {
  const _PendingReconciliation({
    required this.authoritativeBaseline,
    required this.displayMessages,
  });

  final List<ChatMessage> authoritativeBaseline;
  final List<ChatMessage> displayMessages;

  bool hasConverged(List<ChatMessage> messages) {
    final postBaseline = messages
        .where(
          (message) => !authoritativeBaseline.any(
            (baseline) => _sameAuthoritativeMessage(baseline, message),
          ),
        )
        .toList(growable: false);
    var historyIndex = 0;
    for (final expected in displayMessages) {
      final index = _indexWhereFrom(
        postBaseline,
        historyIndex,
        (message) => _sameDisplayMessage(message, expected),
      );
      if (index < 0) return false;
      historyIndex = index + 1;
    }
    return displayMessages.isNotEmpty;
  }

  bool _sameDisplayMessage(ChatMessage message, ChatMessage expected) {
    if (message.role != expected.role) return false;
    if (message.content != expected.content) return false;
    if (expected.reasoningContent.isNotEmpty &&
        message.reasoningContent != expected.reasoningContent) {
      return false;
    }
    if (expected.contentParts.isNotEmpty &&
        _structuredValue(message.contentParts.map((part) => part.toJson())) !=
            _structuredValue(
              expected.contentParts.map((part) => part.toJson()),
            )) {
      return false;
    }
    if (expected.toolCalls.isNotEmpty &&
        _structuredValue(message.toolCalls) !=
            _structuredValue(expected.toolCalls)) {
      return false;
    }
    return true;
  }

  String _structuredValue(Iterable<Object?> value) =>
      jsonEncode(value.toList());

  int _indexWhereFrom(
    List<ChatMessage> messages,
    int start,
    bool Function(ChatMessage message) matches,
  ) {
    for (var index = start; index < messages.length; index++) {
      if (matches(messages[index])) return index;
    }
    return -1;
  }

  bool _sameAuthoritativeMessage(ChatMessage baseline, ChatMessage current) {
    if (baseline.id.isNotEmpty || current.id.isNotEmpty) {
      return baseline.id == current.id;
    }
    return baseline.role == current.role &&
        baseline.content == current.content &&
        baseline.reasoningContent == current.reasoningContent &&
        baseline.createdAt == current.createdAt;
  }
}

import '../../models/app_settings.dart';
import '../../models/chat_message.dart';
import 'http_runtime_client.dart';
import 'runtime_conversation_controller.dart';
import 'runtime_stream_event.dart';

/// Adapts GensokyoAI's public runtime protocol to the conversation controller.
class GensokyoAiConversationRuntime
    implements ConversationRuntime, StructuredConversationRuntime {
  const GensokyoAiConversationRuntime({required this.client, this.profile});

  final GensokyoAiHttpRuntimeClient client;
  final ModelProfile? profile;

  @override
  Future<void> connect() => client.connect();

  @override
  Future<void> disconnect() => client.dispose();

  @override
  Future<void> cancel() => client.cancelActiveStream();

  @override
  Future<RuntimeConversationActivation> activate({
    required String characterId,
    String? sessionId,
    bool newSession = false,
  }) async {
    final result = await client.initialize(
      characterId: characterId,
      sessionId: sessionId,
      newSession: newSession,
      profile: profile,
    );
    await client.subscribe();

    final session = result['session'];
    final activatedSessionId = session is Map
        ? session['session_id']?.toString().trim()
        : result['session_id']?.toString().trim();
    final fallbackSessionId = result['session_id']?.toString().trim();
    final resolvedSessionId = activatedSessionId?.isNotEmpty == true
        ? activatedSessionId
        : fallbackSessionId;
    if (resolvedSessionId == null || resolvedSessionId.isEmpty) {
      throw const FormatException(
        'GensokyoAI activation response is missing a session ID',
      );
    }
    return RuntimeConversationActivation(sessionId: resolvedSessionId);
  }

  @override
  Future<List<ChatMessage>> history(String sessionId) async {
    await client.reconcilePendingMessage(sessionId);
    final mappedMessages = <Map<String, dynamic>>[];
    final seenCursors = <String>{};
    String? cursor;
    int? observedRevision;
    while (true) {
      final result = await client.call('session.messages', <String, dynamic>{
        'session_id': sessionId,
        'limit': 500,
        if (cursor case final String cursorValue) 'cursor': cursorValue,
      });
      final resultMap = result is Map
          ? Map<String, dynamic>.from(result)
          : const <String, dynamic>{};
      final revision = int.tryParse(resultMap['revision']?.toString() ?? '');
      if (revision == null || revision < 0) {
        throw const FormatException(
          'GensokyoAI session.messages response is missing revision',
        );
      }
      observedRevision ??= revision;
      if (observedRevision != revision) {
        throw const RuntimeConversationConflict('会话在分页读取期间发生变化，请重新读取');
      }
      final messages = resultMap['messages'];
      if (messages is List) {
        mappedMessages.addAll(
          messages.whereType<Map>().map(Map<String, dynamic>.from),
        );
      }
      final hasMore = resultMap['has_more'] == true;
      final nextCursor = resultMap['next_cursor']?.toString().trim();
      if (!hasMore || nextCursor == null || nextCursor.isEmpty) break;
      if (!seenCursors.add(nextCursor)) {
        throw const FormatException(
          'GensokyoAI session.messages returned a repeated pagination cursor',
        );
      }
      cursor = nextCursor;
    }

    final mapped = <ChatMessage>[];
    for (final json in mappedMessages) {
      final content = json['content'];
      if (content is List) {
        json['content'] = content
            .map((part) {
              if (part is! Map || part['type'] != 'media') return part;
              final mediaId = part['media_id']?.toString().trim();
              if (mediaId == null || mediaId.isEmpty) return part;
              return <String, dynamic>{
                'type': 'image',
                'image': <String, dynamic>{
                  'url': client.mediaDownloadUri(mediaId).toString(),
                  if (client.mediaRequestHeaders.isNotEmpty)
                    'headers': client.mediaRequestHeaders,
                  if (part['detail'] != null) 'detail': part['detail'],
                },
              };
            })
            .toList(growable: false);
      }
      final remoteId = (json['id'] ?? json['message_id'])?.toString().trim();
      mapped.add(
        ChatMessage.fromJson(<String, dynamic>{
          ...json,
          if (remoteId == null || remoteId.isEmpty)
            'id': 'runtime-history:$sessionId:${mapped.length}',
          'conversation_id': sessionId,
        }),
      );
    }
    return mapped;
  }

  @override
  Stream<RuntimeStreamEvent> send({
    required String sessionId,
    required String characterId,
    required String input,
  }) {
    final revision = client.sessionRevision(sessionId);
    if (revision == null) {
      return Stream<RuntimeStreamEvent>.value(
        const RuntimeStreamFailed(
          message: '会话修订号尚未读取，请先刷新会话',
          metadata: <String, dynamic>{'code': 'session.revision_required'},
        ),
      );
    }
    return client.streamMessage(
      sessionId: sessionId,
      expectedRevision: revision,
      latestUserInput: input,
    );
  }

  @override
  Stream<RuntimeStreamEvent> sendStructured({
    required String sessionId,
    required String characterId,
    required RuntimeMessageInput input,
  }) {
    final revision = client.sessionRevision(sessionId);
    if (revision == null) {
      return Stream<RuntimeStreamEvent>.value(
        const RuntimeStreamFailed(
          message: '会话修订号尚未读取，请先刷新会话',
          metadata: <String, dynamic>{'code': 'session.revision_required'},
        ),
      );
    }
    return client.streamMessageParts(
      sessionId: sessionId,
      expectedRevision: revision,
      contentParts: input.runtimeContentParts,
    );
  }
}

enum ChatMessageRole { user, assistant, system, tool, unknown }

class ChatContentPart {
  const ChatContentPart({required this.type, required this.data});

  final String type;
  final Map<String, dynamic> data;

  String get text => data['text'] is String ? data['text'] as String : '';

  Map<String, dynamic> get image {
    final value = data['image'];
    return value is Map
        ? Map<String, dynamic>.from(value)
        : const <String, dynamic>{};
  }

  Map<String, dynamic> toJson() => <String, dynamic>{...data, 'type': type};

  factory ChatContentPart.fromJson(Map<String, dynamic> json) {
    return ChatContentPart(
      type: json['type']?.toString() ?? 'unknown',
      data: Map<String, dynamic>.from(json),
    );
  }
}

class ChatMessage {
  const ChatMessage({
    this.id = '',
    required this.role,
    required this.content,
    required this.createdAt,
    this.rawRole = '',
    this.contentParts = const <ChatContentPart>[],
    this.reasoningContent = '',
    this.toolCalls = const <Map<String, dynamic>>[],
    this.toolEvents = const <Map<String, dynamic>>[],
    this.toolCallId = '',
    this.conversationId = '',
    this.assistantId = '',
    this.thinkingEngineId = '',
    this.backendId = '',
    this.assistantProviderId = '',
    this.compatibility = '',
    this.capabilityLosses = const <Map<String, dynamic>>[],
    this.modelResolved = const <String, dynamic>{},
    this.status = 'completed',
    this.parentMessageId = '',
    this.metadata = const <String, dynamic>{},
    this.extensions = const <String, dynamic>{},
  });

  final String id;
  final ChatMessageRole role;
  final String rawRole;
  final String content;
  final List<ChatContentPart> contentParts;
  final String reasoningContent;
  final List<Map<String, dynamic>> toolCalls;
  final List<Map<String, dynamic>> toolEvents;
  final String toolCallId;
  final DateTime createdAt;
  final String conversationId;
  final String assistantId;
  final String thinkingEngineId;
  final String backendId;
  final String assistantProviderId;
  final String compatibility;
  final List<Map<String, dynamic>> capabilityLosses;
  final Map<String, dynamic> modelResolved;
  final String status;
  final String parentMessageId;
  final Map<String, dynamic> metadata;
  final Map<String, dynamic> extensions;

  bool get hasDisplayContent =>
      content.isNotEmpty ||
      contentParts.isNotEmpty ||
      reasoningContent.isNotEmpty ||
      toolCalls.isNotEmpty ||
      toolEvents.isNotEmpty ||
      toolCallId.isNotEmpty;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      ...extensions,
      'id': id,
      'role': rawRole.isNotEmpty ? rawRole : role.name,
      'content': contentParts.isEmpty
          ? content
          : contentParts.map((part) => part.toJson()).toList(growable: false),
      'reasoning_content': reasoningContent,
      'tool_calls': toolCalls,
      'tool_events': toolEvents,
      'tool_call_id': toolCallId,
      'created_at': createdAt.toIso8601String(),
      'conversation_id': conversationId,
      'assistant_id': assistantId,
      'thinking_engine_id': thinkingEngineId,
      'backend_id': backendId,
      'assistant_provider_id': assistantProviderId,
      'compatibility': compatibility,
      'capability_losses': capabilityLosses,
      'model_resolved': modelResolved,
      'status': status,
      'parent_message_id': parentMessageId,
      'metadata': metadata,
    }..removeWhere(
      (_, value) =>
          value == null ||
          value == '' ||
          (value is List && value.isEmpty) ||
          (value is Map && value.isEmpty),
    );
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawRole = json['role']?.toString() ?? '';
    final rawContent = json['content'];
    final contentParts = _contentPartsFromJson(rawContent);
    return ChatMessage(
      id: json['id']?.toString() ?? json['message_id']?.toString() ?? '',
      role: ChatMessageRole.values.firstWhere(
        (item) => item != ChatMessageRole.unknown && item.name == rawRole,
        orElse: () => ChatMessageRole.unknown,
      ),
      rawRole: rawRole,
      content: rawContent is String
          ? rawContent
          : contentParts
                .where((part) => part.type == 'text')
                .map((part) => part.text)
                .join(),
      contentParts: contentParts,
      reasoningContent: json['reasoning_content'] is String
          ? json['reasoning_content'] as String
          : '',
      toolCalls: _listOfMapFromJson(json['tool_calls']),
      toolEvents: _listOfMapFromJson(json['tool_events']),
      toolCallId: json['tool_call_id']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      conversationId: json['conversation_id']?.toString() ?? '',
      assistantId: json['assistant_id']?.toString() ?? '',
      thinkingEngineId: json['thinking_engine_id']?.toString() ?? '',
      backendId: json['backend_id']?.toString() ?? '',
      assistantProviderId: json['assistant_provider_id']?.toString() ?? '',
      compatibility: json['compatibility']?.toString() ?? '',
      capabilityLosses: _listOfMapFromJson(json['capability_losses']),
      modelResolved: _mapFromJson(json['model_resolved']),
      status: json['status']?.toString() ?? 'completed',
      parentMessageId: json['parent_message_id']?.toString() ?? '',
      metadata: _mapFromJson(json['metadata']),
      extensions: <String, dynamic>{
        for (final entry in json.entries)
          if (!_knownMessageFields.contains(entry.key)) entry.key: entry.value,
      },
    );
  }
}

const Set<String> _knownMessageFields = <String>{
  'id',
  'message_id',
  'role',
  'content',
  'reasoning_content',
  'tool_calls',
  'tool_events',
  'tool_call_id',
  'created_at',
  'conversation_id',
  'assistant_id',
  'thinking_engine_id',
  'backend_id',
  'assistant_provider_id',
  'compatibility',
  'capability_losses',
  'model_resolved',
  'status',
  'parent_message_id',
  'metadata',
};

List<ChatContentPart> _contentPartsFromJson(Object? value) {
  if (value is! List) return const <ChatContentPart>[];
  return value
      .whereType<Map>()
      .map((item) => ChatContentPart.fromJson(Map<String, dynamic>.from(item)))
      .toList(growable: false);
}

List<Map<String, dynamic>> _listOfMapFromJson(Object? value) {
  if (value is! List) return const <Map<String, dynamic>>[];
  return value
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}

Map<String, dynamic> _mapFromJson(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return const <String, dynamic>{};
}

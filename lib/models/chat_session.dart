import 'runtime_capabilities.dart';
import 'avatar_transform.dart';

enum ExternalMappingStatus {
  verified,
  unverified,
  stale,
  inaccessible;

  static ExternalMappingStatus fromValue(Object? value) {
    final name = value?.toString();
    return ExternalMappingStatus.values.firstWhere(
      (status) => status.name == name,
      orElse: () => ExternalMappingStatus.unverified,
    );
  }
}

class ChatSession {
  const ChatSession({
    required this.sessionId,
    this.title = '',
    this.backendId = 'gensokyoai',
    this.externalConnectionId = '',
    this.externalSessionId = '',
    this.externalCharacterId = '',
    this.externalMappingStatus = ExternalMappingStatus.unverified,
    this.activeAssistantId = '',
    this.totalTurns = 0,
    this.summary = '',
    this.backgroundImagePath = '',
    this.avatarImagePath = '',
    this.avatarTransform = const AvatarTransform(),
    this.listOrder,
    this.createdAt,
    this.lastActive,
    this.assistantExecutionBindings =
        const <String, AssistantExecutionBinding>{},
    this.metadata = const <String, dynamic>{},
  });

  final String sessionId;
  final String title;
  final String backendId;
  final String externalConnectionId;
  final String externalSessionId;
  final String externalCharacterId;
  final ExternalMappingStatus externalMappingStatus;
  final String activeAssistantId;
  final int totalTurns;
  final String summary;
  final String backgroundImagePath;
  final String avatarImagePath;
  final AvatarTransform avatarTransform;
  final int? listOrder;
  final DateTime? createdAt;
  final DateTime? lastActive;
  final Map<String, AssistantExecutionBinding> assistantExecutionBindings;
  final Map<String, dynamic> metadata;

  ChatSession copyWith({
    String? sessionId,
    String? title,
    String? backendId,
    String? externalConnectionId,
    String? externalSessionId,
    String? externalCharacterId,
    ExternalMappingStatus? externalMappingStatus,
    String? activeAssistantId,
    int? totalTurns,
    String? summary,
    String? backgroundImagePath,
    String? avatarImagePath,
    AvatarTransform? avatarTransform,
    int? listOrder,
    DateTime? createdAt,
    DateTime? lastActive,
    Map<String, AssistantExecutionBinding>? assistantExecutionBindings,
    Map<String, dynamic>? metadata,
  }) {
    return ChatSession(
      sessionId: sessionId ?? this.sessionId,
      title: title ?? this.title,
      backendId: backendId ?? this.backendId,
      externalConnectionId: externalConnectionId ?? this.externalConnectionId,
      externalSessionId: externalSessionId ?? this.externalSessionId,
      externalCharacterId: externalCharacterId ?? this.externalCharacterId,
      externalMappingStatus:
          externalMappingStatus ?? this.externalMappingStatus,
      activeAssistantId: activeAssistantId ?? this.activeAssistantId,
      totalTurns: totalTurns ?? this.totalTurns,
      summary: summary ?? this.summary,
      backgroundImagePath: backgroundImagePath ?? this.backgroundImagePath,
      avatarImagePath: avatarImagePath ?? this.avatarImagePath,
      avatarTransform: avatarTransform ?? this.avatarTransform,
      listOrder: listOrder ?? this.listOrder,
      createdAt: createdAt ?? this.createdAt,
      lastActive: lastActive ?? this.lastActive,
      assistantExecutionBindings:
          assistantExecutionBindings ?? this.assistantExecutionBindings,
      metadata: metadata ?? this.metadata,
    );
  }

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    final bindings = _bindingsFromJson(json['assistant_execution_bindings']);
    final activeAssistantId = json['active_assistant_id']?.toString() ?? '';
    final storedBackendId = json['backend_id']?.toString() ?? '';
    final migratedBackendId =
        bindings[activeAssistantId]?.backendId ??
        (bindings.isEmpty ? '' : bindings.values.first.backendId);
    return ChatSession(
      sessionId: json['session_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      backendId: storedBackendId.isNotEmpty
          ? storedBackendId
          : migratedBackendId.isNotEmpty
          ? migratedBackendId
          : 'gensokyoai',
      externalConnectionId: json['external_connection_id']?.toString() ?? '',
      externalSessionId: json['external_session_id']?.toString() ?? '',
      externalCharacterId: json['external_character_id']?.toString() ?? '',
      externalMappingStatus: ExternalMappingStatus.fromValue(
        json['external_mapping_status'],
      ),
      activeAssistantId: activeAssistantId,
      totalTurns: int.tryParse(json['total_turns']?.toString() ?? '') ?? 0,
      summary: json['summary']?.toString() ?? '',
      backgroundImagePath:
          json['background_image_path']?.toString().trim() ?? '',
      avatarImagePath: json['avatar_image_path']?.toString().trim() ?? '',
      avatarTransform: AvatarTransform.fromJson(json['avatar_transform']),
      listOrder: int.tryParse(json['list_order']?.toString() ?? ''),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      lastActive: DateTime.tryParse(json['last_active']?.toString() ?? ''),
      assistantExecutionBindings: bindings,
      metadata: _metadataFromJson(json['metadata']),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'session_id': sessionId,
      'title': title,
      'backend_id': backendId,
      'external_connection_id': externalConnectionId,
      'external_session_id': externalSessionId,
      'external_character_id': externalCharacterId,
      'external_mapping_status': externalMappingStatus.name,
      'active_assistant_id': activeAssistantId,
      'total_turns': totalTurns,
      'summary': summary,
      'background_image_path': backgroundImagePath,
      'avatar_image_path': avatarImagePath,
      'avatar_transform': avatarTransform.toJson(),
      'list_order': listOrder,
      'created_at': createdAt?.toIso8601String(),
      'last_active': lastActive?.toIso8601String(),
      'assistant_execution_bindings': assistantExecutionBindings.map(
        (assistantId, binding) => MapEntry(assistantId, binding.toJson()),
      ),
      'metadata': Map<String, dynamic>.of(metadata)..remove('remote'),
    }..removeWhere((_, value) => value == null);
  }
}

Map<String, AssistantExecutionBinding> _bindingsFromJson(Object? value) {
  if (value is! Map) {
    return const <String, AssistantExecutionBinding>{};
  }
  final bindings = <String, AssistantExecutionBinding>{};
  for (final entry in value.entries) {
    final bindingJson = entry.value;
    if (bindingJson is Map) {
      final binding = AssistantExecutionBinding.fromJson(
        Map<String, dynamic>.from(bindingJson),
      );
      final assistantId = binding.assistantId.isEmpty
          ? entry.key.toString()
          : binding.assistantId;
      bindings[assistantId] = binding;
    }
  }
  return bindings;
}

Map<String, dynamic> _mapFromJson(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const <String, dynamic>{};
}

Map<String, dynamic> _metadataFromJson(Object? value) {
  final metadata = Map<String, dynamic>.of(_mapFromJson(value));
  metadata.remove('remote');
  return metadata;
}

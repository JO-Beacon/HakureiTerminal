import 'assistant.dart';

enum AssistantEngineCompatibility {
  perfect('perfect'),
  partial('partial'),
  unavailable('unavailable');

  const AssistantEngineCompatibility(this.value);

  final String value;

  static AssistantEngineCompatibility fromValue(String? value) {
    return AssistantEngineCompatibility.values.firstWhere(
      (item) => item.value == value,
      orElse: () => AssistantEngineCompatibility.unavailable,
    );
  }
}

class CapabilityLoss {
  const CapabilityLoss({
    required this.code,
    this.severity = 'warning',
    this.title = '',
    this.description = '',
    this.affectedFeatures = const <String>[],
    this.recoverAction = '',
  });

  final String code;
  final String severity;
  final String title;
  final String description;
  final List<String> affectedFeatures;
  final String recoverAction;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'code': code,
      'severity': severity,
      'title': title,
      'description': description,
      'affected_features': affectedFeatures,
      'recover_action': recoverAction,
    };
  }

  factory CapabilityLoss.fromJson(Map<String, dynamic> json) {
    return CapabilityLoss(
      code: json['code']?.toString() ?? '',
      severity: json['severity']?.toString() ?? 'warning',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      affectedFeatures: _stringListFromJson(json['affected_features']),
      recoverAction: json['recover_action']?.toString() ?? '',
    );
  }
}

class ThinkingEngine {
  const ThinkingEngine({
    required this.id,
    required this.name,
    required this.defaultBackendId,
    this.description = '',
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final String name;
  final String description;
  final String defaultBackendId;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'description': description,
      'default_backend_id': defaultBackendId,
      'metadata': metadata,
    };
  }

  factory ThinkingEngine.fromJson(Map<String, dynamic> json) {
    return ThinkingEngine(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      defaultBackendId: json['default_backend_id']?.toString() ?? '',
      metadata: _mapFromJson(json['metadata']),
    );
  }
}

class BackendCapability {
  const BackendCapability({
    required this.id,
    required this.name,
    this.description = '',
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final String name;
  final String description;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'description': description,
      'metadata': metadata,
    };
  }

  factory BackendCapability.fromJson(Map<String, dynamic> json) {
    return BackendCapability(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      metadata: _mapFromJson(json['metadata']),
    );
  }
}

class AssistantExecutionBinding {
  const AssistantExecutionBinding({
    required this.assistantId,
    required this.thinkingEngineId,
    required this.backendId,
    this.compatibility = AssistantEngineCompatibility.unavailable,
    this.initializedFromDefault = true,
    this.userModified = false,
    this.modelOverride = const ModelOverride(),
    this.capabilityLosses = const <CapabilityLoss>[],
    this.updatedAt,
  });

  final String assistantId;
  final String thinkingEngineId;
  final String backendId;
  final AssistantEngineCompatibility compatibility;
  final bool initializedFromDefault;
  final bool userModified;
  final ModelOverride modelOverride;
  final List<CapabilityLoss> capabilityLosses;
  final DateTime? updatedAt;

  AssistantExecutionBinding copyWith({
    String? assistantId,
    String? thinkingEngineId,
    String? backendId,
    AssistantEngineCompatibility? compatibility,
    bool? initializedFromDefault,
    bool? userModified,
    ModelOverride? modelOverride,
    List<CapabilityLoss>? capabilityLosses,
    DateTime? updatedAt,
  }) {
    return AssistantExecutionBinding(
      assistantId: assistantId ?? this.assistantId,
      thinkingEngineId: thinkingEngineId ?? this.thinkingEngineId,
      backendId: backendId ?? this.backendId,
      compatibility: compatibility ?? this.compatibility,
      initializedFromDefault:
          initializedFromDefault ?? this.initializedFromDefault,
      userModified: userModified ?? this.userModified,
      modelOverride: modelOverride ?? this.modelOverride,
      capabilityLosses: capabilityLosses ?? this.capabilityLosses,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'assistant_id': assistantId,
      'thinking_engine_id': thinkingEngineId,
      'backend_id': backendId,
      'compatibility': compatibility.value,
      'initialized_from_default': initializedFromDefault,
      'user_modified': userModified,
      'model_override': modelOverride.toJson(),
      'capability_losses': capabilityLosses
          .map((item) => item.toJson())
          .toList(),
      'updated_at': updatedAt?.toIso8601String(),
    }..removeWhere((_, value) => value == null);
  }

  factory AssistantExecutionBinding.fromJson(Map<String, dynamic> json) {
    return AssistantExecutionBinding(
      assistantId: json['assistant_id']?.toString() ?? '',
      thinkingEngineId: json['thinking_engine_id']?.toString() ?? '',
      backendId: json['backend_id']?.toString() ?? '',
      compatibility: AssistantEngineCompatibility.fromValue(
        json['compatibility']?.toString(),
      ),
      initializedFromDefault: json['initialized_from_default'] != false,
      userModified: json['user_modified'] == true,
      modelOverride: json['model_override'] is Map
          ? ModelOverride.fromJson(
              Map<String, dynamic>.from(json['model_override'] as Map),
            )
          : const ModelOverride(),
      capabilityLosses: _capabilityLossesFromJson(json['capability_losses']),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
    );
  }
}

Map<String, dynamic> _mapFromJson(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const <String, dynamic>{};
}

List<String> _stringListFromJson(Object? value) {
  if (value is List) {
    return value.map((item) => item.toString()).toList(growable: false);
  }
  return const <String>[];
}

List<CapabilityLoss> _capabilityLossesFromJson(Object? value) {
  if (value is! List) {
    return const <CapabilityLoss>[];
  }
  return value
      .whereType<Map>()
      .map((item) => CapabilityLoss.fromJson(Map<String, dynamic>.from(item)))
      .toList(growable: false);
}

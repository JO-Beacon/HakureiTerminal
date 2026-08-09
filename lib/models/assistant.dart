enum AssistantProviderId {
  unknown('unknown'),
  jovBuiltin('jov_builtin'),
  gensokyoAi('gensokyoai');

  const AssistantProviderId(this.value);

  final String value;

  static AssistantProviderId fromValue(String? value) {
    if (value == null || value.isEmpty) {
      return AssistantProviderId.jovBuiltin;
    }
    return AssistantProviderId.values.firstWhere(
      (item) => item.value == value,
      orElse: () => AssistantProviderId.unknown,
    );
  }
}

class Assistant {
  const Assistant({
    required this.id,
    required this.name,
    this.description = '',
    this.avatar = '',
    this.systemPrompt = '',
    this.providerId = AssistantProviderId.unknown,
    this.providerAssistantId = '',
    this.defaultThinkingEngineId = '',
    this.defaultBackendId = '',
    this.modelOverride = const ModelOverride(),
    this.memoryPolicy = const <String, dynamic>{},
    this.metadata = const <String, dynamic>{},
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final String avatar;
  final String systemPrompt;
  final AssistantProviderId providerId;
  final String providerAssistantId;
  final String defaultThinkingEngineId;
  final String defaultBackendId;
  final ModelOverride modelOverride;
  final Map<String, dynamic> memoryPolicy;
  final Map<String, dynamic> metadata;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  Assistant copyWith({
    String? id,
    String? name,
    String? description,
    String? avatar,
    String? systemPrompt,
    AssistantProviderId? providerId,
    String? providerAssistantId,
    String? defaultThinkingEngineId,
    String? defaultBackendId,
    ModelOverride? modelOverride,
    Map<String, dynamic>? memoryPolicy,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Assistant(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      avatar: avatar ?? this.avatar,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      providerId: providerId ?? this.providerId,
      providerAssistantId: providerAssistantId ?? this.providerAssistantId,
      defaultThinkingEngineId:
          defaultThinkingEngineId ?? this.defaultThinkingEngineId,
      defaultBackendId: defaultBackendId ?? this.defaultBackendId,
      modelOverride: modelOverride ?? this.modelOverride,
      memoryPolicy: memoryPolicy ?? this.memoryPolicy,
      metadata: metadata ?? this.metadata,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'description': description,
      'avatar': avatar,
      'system_prompt': systemPrompt,
      'provider_id': providerId.value,
      'provider_assistant_id': providerAssistantId,
      'default_thinking_engine_id': defaultThinkingEngineId,
      'default_backend_id': defaultBackendId,
      'model_override': modelOverride.toJson(),
      'memory_policy': memoryPolicy,
      'metadata': metadata,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    }..removeWhere((_, value) => value == null);
  }

  factory Assistant.fromJson(Map<String, dynamic> json) {
    return Assistant(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      avatar: json['avatar']?.toString() ?? '',
      systemPrompt: json['system_prompt']?.toString() ?? '',
      providerId: AssistantProviderId.fromValue(
        json['provider_id']?.toString(),
      ),
      providerAssistantId: json['provider_assistant_id']?.toString() ?? '',
      defaultThinkingEngineId:
          json['default_thinking_engine_id']?.toString() ?? 'builtin_chat',
      defaultBackendId:
          json['default_backend_id']?.toString() ?? 'hakurei_terminal',
      modelOverride: json['model_override'] is Map
          ? ModelOverride.fromJson(
              Map<String, dynamic>.from(json['model_override'] as Map),
            )
          : const ModelOverride(),
      memoryPolicy: _mapFromJson(json['memory_policy']),
      metadata: _mapFromJson(json['metadata']),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
    );
  }
}

enum OverrideFieldMode {
  inherit('inherit'),
  override('override'),
  clear('clear');

  const OverrideFieldMode(this.value);

  final String value;

  static OverrideFieldMode fromValue(String? value) {
    return OverrideFieldMode.values.firstWhere(
      (item) => item.value == value,
      orElse: () => OverrideFieldMode.inherit,
    );
  }
}

class OverrideField<T> {
  const OverrideField.inherit()
    : mode = OverrideFieldMode.inherit,
      value = null;

  const OverrideField.override(this.value) : mode = OverrideFieldMode.override;

  const OverrideField.clear() : mode = OverrideFieldMode.clear, value = null;

  final OverrideFieldMode mode;
  final T? value;

  Object? resolve(Object? inherited) {
    return switch (mode) {
      OverrideFieldMode.inherit => inherited,
      OverrideFieldMode.override => value,
      OverrideFieldMode.clear => null,
    };
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'mode': mode.value, 'value': value};
  }

  factory OverrideField.fromJson(
    Object? json,
    T Function(Object? value) convert,
  ) {
    if (json is! Map) {
      return OverrideField<T>.inherit();
    }
    final mode = OverrideFieldMode.fromValue(json['mode']?.toString());
    return switch (mode) {
      OverrideFieldMode.inherit => OverrideField<T>.inherit(),
      OverrideFieldMode.clear => OverrideField<T>.clear(),
      OverrideFieldMode.override => OverrideField<T>.override(
        convert(json['value']),
      ),
    };
  }
}

class ModelOverride {
  const ModelOverride({
    this.enabled = false,
    this.provider = const OverrideField<String>.inherit(),
    this.model = const OverrideField<String>.inherit(),
    this.baseUrl = const OverrideField<String>.inherit(),
    this.apiKey = const OverrideField<String>.inherit(),
    this.temperature = const OverrideField<String>.inherit(),
    this.topP = const OverrideField<String>.inherit(),
    this.maxTokens = const OverrideField<String>.inherit(),
    this.timeout = const OverrideField<String>.inherit(),
    this.stream = const OverrideField<bool>.inherit(),
    this.reasoningEffort = const OverrideField<String>.inherit(),
    this.extra = const <String, dynamic>{},
  });

  final bool enabled;
  final OverrideField<String> provider;
  final OverrideField<String> model;
  final OverrideField<String> baseUrl;
  final OverrideField<String> apiKey;
  final OverrideField<String> temperature;
  final OverrideField<String> topP;
  final OverrideField<String> maxTokens;
  final OverrideField<String> timeout;
  final OverrideField<bool> stream;
  final OverrideField<String> reasoningEffort;
  final Map<String, dynamic> extra;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'enabled': enabled,
      'provider': provider.toJson(),
      'model': model.toJson(),
      'base_url': baseUrl.toJson(),
      'api_key': apiKey.toJson(),
      'temperature': temperature.toJson(),
      'top_p': topP.toJson(),
      'max_tokens': maxTokens.toJson(),
      'timeout': timeout.toJson(),
      'stream': stream.toJson(),
      'reasoning_effort': reasoningEffort.toJson(),
      'extra': extra,
    };
  }

  factory ModelOverride.fromJson(Map<String, dynamic> json) {
    return ModelOverride(
      enabled: json['enabled'] == true,
      provider: OverrideField<String>.fromJson(
        json['provider'],
        _stringFromJson,
      ),
      model: OverrideField<String>.fromJson(json['model'], _stringFromJson),
      baseUrl: OverrideField<String>.fromJson(
        json['base_url'],
        _stringFromJson,
      ),
      apiKey: OverrideField<String>.fromJson(json['api_key'], _stringFromJson),
      temperature: OverrideField<String>.fromJson(
        json['temperature'],
        _stringFromJson,
      ),
      topP: OverrideField<String>.fromJson(json['top_p'], _stringFromJson),
      maxTokens: OverrideField<String>.fromJson(
        json['max_tokens'],
        _stringFromJson,
      ),
      timeout: OverrideField<String>.fromJson(json['timeout'], _stringFromJson),
      stream: OverrideField<bool>.fromJson(json['stream'], _boolFromJson),
      reasoningEffort: OverrideField<String>.fromJson(
        json['reasoning_effort'],
        _stringFromJson,
      ),
      extra: _mapFromJson(json['extra']),
    );
  }
}

String _stringFromJson(Object? value) => value?.toString() ?? '';

bool _boolFromJson(Object? value) {
  if (value is bool) {
    return value;
  }
  final text = value?.toString().toLowerCase();
  return text == 'true' || text == '1' || text == 'yes';
}

Map<String, dynamic> _mapFromJson(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const <String, dynamic>{};
}

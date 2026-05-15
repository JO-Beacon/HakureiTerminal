class ModelServiceSettings {
  const ModelServiceSettings({
    required this.provider,
    required this.model,
    this.baseUrl = '',
    this.apiKey = '',
    this.temperature = '',
    this.topP = '',
    this.maxTokens = '',
    this.timeout = '',
    this.stream = true,
    this.think = false,
    this.reasoningEffort = '',
    this.useProxy = false,
  });

  final String provider;
  final String model;
  final String baseUrl;
  final String apiKey;
  final String temperature;
  final String topP;
  final String maxTokens;
  final String timeout;
  final bool stream;
  final bool think;
  final String reasoningEffort;
  final bool useProxy;

  ModelServiceSettings copyWith({
    String? provider,
    String? model,
    String? baseUrl,
    String? apiKey,
    String? temperature,
    String? topP,
    String? maxTokens,
    String? timeout,
    bool? stream,
    bool? think,
    String? reasoningEffort,
    bool? useProxy,
  }) {
    return ModelServiceSettings(
      provider: provider ?? this.provider,
      model: model ?? this.model,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      maxTokens: maxTokens ?? this.maxTokens,
      timeout: timeout ?? this.timeout,
      stream: stream ?? this.stream,
      think: think ?? this.think,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      useProxy: useProxy ?? this.useProxy,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'provider': provider,
      'model': model,
      'base_url': baseUrl,
      'api_key': apiKey,
      'temperature': temperature,
      'top_p': topP,
      'max_tokens': maxTokens,
      'timeout': timeout,
      'stream': stream,
      'think': think,
      'reasoning_effort': reasoningEffort,
      'use_proxy': useProxy,
    };
  }

  Map<String, dynamic> toBridgeOverrides() {
    return <String, dynamic>{
      'provider': provider.trim(),
      'name': model.trim(),
      'base_url': _normalizeOpenAiBaseUrl(baseUrl),
      'api_key': _nullableTrim(apiKey),
      'temperature': double.tryParse(temperature.trim()),
      'top_p': double.tryParse(topP.trim()),
      'max_tokens': int.tryParse(maxTokens.trim()),
      'timeout': int.tryParse(timeout.trim()),
      'stream': stream,
      'think': think,
      'reasoning_effort': _nullableTrim(reasoningEffort),
      'use_proxy': useProxy,
    }..removeWhere((_, value) => value == null || value == '');
  }

  List<String> validate() {
    final errors = <String>[];
    if (provider.trim().isEmpty) {
      errors.add('主模型 Provider 不能为空');
    }
    if (model.trim().isEmpty) {
      errors.add('主模型名不能为空');
    }
    _validateDouble(errors, temperature, 'Temperature');
    _validateDouble(errors, topP, 'Top P');
    _validateInt(errors, maxTokens, 'Max Tokens');
    _validateInt(errors, timeout, '主模型 Timeout');
    return errors;
  }

  factory ModelServiceSettings.fromJson(Map<String, dynamic> json) {
    return ModelServiceSettings(
      provider: json['provider']?.toString() ?? '',
      model: json['model']?.toString() ?? json['name']?.toString() ?? '',
      baseUrl: json['base_url']?.toString() ?? '',
      apiKey: json['api_key']?.toString() ?? '',
      temperature: json['temperature']?.toString() ?? '',
      topP: json['top_p']?.toString() ?? '',
      maxTokens: json['max_tokens']?.toString() ?? '',
      timeout: json['timeout']?.toString() ?? '',
      stream: _boolFromJson(json['stream'], fallback: true),
      think: _boolFromJson(json['think']),
      reasoningEffort: json['reasoning_effort']?.toString() ?? '',
      useProxy: _boolFromJson(json['use_proxy']),
    );
  }
}

class EmbeddingServiceSettings {
  const EmbeddingServiceSettings({
    this.provider = '',
    this.model = '',
    this.baseUrl = '',
    this.apiKey = '',
    this.dimensions = '',
    this.timeout = '',
    this.useProxy = false,
  });

  final String provider;
  final String model;
  final String baseUrl;
  final String apiKey;
  final String dimensions;
  final String timeout;
  final bool useProxy;

  EmbeddingServiceSettings copyWith({
    String? provider,
    String? model,
    String? baseUrl,
    String? apiKey,
    String? dimensions,
    String? timeout,
    bool? useProxy,
  }) {
    return EmbeddingServiceSettings(
      provider: provider ?? this.provider,
      model: model ?? this.model,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      dimensions: dimensions ?? this.dimensions,
      timeout: timeout ?? this.timeout,
      useProxy: useProxy ?? this.useProxy,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'provider': provider,
      'model': model,
      'base_url': baseUrl,
      'api_key': apiKey,
      'dimensions': dimensions,
      'timeout': timeout,
      'use_proxy': useProxy,
    };
  }

  Map<String, dynamic> toBridgeOverrides() {
    return <String, dynamic>{
      'provider': _nullableTrim(provider),
      'name': _nullableTrim(model),
      'base_url': _normalizeOpenAiBaseUrl(baseUrl),
      'api_key': _nullableTrim(apiKey),
      'dimensions': int.tryParse(dimensions.trim()),
      'timeout': int.tryParse(timeout.trim()),
      'use_proxy': useProxy,
    }..removeWhere((_, value) => value == null || value == '');
  }

  List<String> validate() {
    final errors = <String>[];
    final hasEmbedding = provider.trim().isNotEmpty || model.trim().isNotEmpty;
    if (hasEmbedding && provider.trim().isEmpty) {
      errors.add('Embedding Provider 不能为空');
    }
    if (hasEmbedding && model.trim().isEmpty) {
      errors.add('Embedding 模型名不能为空');
    }
    _validateInt(errors, dimensions, 'Embedding 维度');
    _validateInt(errors, timeout, 'Embedding Timeout');
    return errors;
  }

  factory EmbeddingServiceSettings.fromJson(Map<String, dynamic> json) {
    return EmbeddingServiceSettings(
      provider: json['provider']?.toString() ?? '',
      model: json['model']?.toString() ?? json['name']?.toString() ?? '',
      baseUrl: json['base_url']?.toString() ?? '',
      apiKey: json['api_key']?.toString() ?? '',
      dimensions: json['dimensions']?.toString() ?? '',
      timeout: json['timeout']?.toString() ?? '',
      useProxy: _boolFromJson(json['use_proxy']),
    );
  }
}

enum DependencyInstallPolicy {
  auto,
  ask,
  manual;

  static DependencyInstallPolicy fromJson(Object? value) {
    final text = value?.toString();
    return DependencyInstallPolicy.values.firstWhere(
      (policy) => policy.name == text,
      orElse: () => DependencyInstallPolicy.auto,
    );
  }
}

class ModelProfile {
  const ModelProfile({
    required this.id,
    required this.name,
    required this.model,
    required this.embedding,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final ModelServiceSettings model;
  final EmbeddingServiceSettings embedding;
  final DateTime createdAt;
  final DateTime updatedAt;

  static ModelProfile defaultProfile() {
    final now = DateTime.now();
    return ModelProfile(
      id: 'default',
      name: '默认配置',
      model: const ModelServiceSettings(
        provider: 'deepseek',
        model: 'deepseek-chat',
      ),
      embedding: const EmbeddingServiceSettings(
        provider: 'openai',
        model: 'text-embedding-3-small',
      ),
      createdAt: now,
      updatedAt: now,
    );
  }

  ModelProfile copyWith({
    String? id,
    String? name,
    ModelServiceSettings? model,
    EmbeddingServiceSettings? embedding,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ModelProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      model: model ?? this.model,
      embedding: embedding ?? this.embedding,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  ModelProfile duplicate({required String id, required String name}) {
    final now = DateTime.now();
    return copyWith(id: id, name: name, createdAt: now, updatedAt: now);
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'model': model.toJson(),
      'embedding': embedding.toJson(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  List<String> validate() {
    return <String>[
      if (name.trim().isEmpty) '配置名称不能为空',
      ...model.validate(),
      ...embedding.validate(),
    ];
  }

  factory ModelProfile.fromJson(Map<String, dynamic> json) {
    final modelJson = json['model'];
    final embeddingJson = json['embedding'];
    return ModelProfile(
      id: json['id']?.toString() ?? _newProfileId(),
      name: json['name']?.toString() ?? '未命名配置',
      model: modelJson is Map
          ? ModelServiceSettings.fromJson(Map<String, dynamic>.from(modelJson))
          : AppSettings.defaultSettings.model,
      embedding: embeddingJson is Map
          ? EmbeddingServiceSettings.fromJson(
              Map<String, dynamic>.from(embeddingJson),
            )
          : AppSettings.defaultSettings.embedding,
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class AppSettings {
  const AppSettings({
    required this.profiles,
    required this.activeProfileId,
    this.dependencyInstallPolicy = DependencyInstallPolicy.auto,
  });

  final List<ModelProfile> profiles;
  final String activeProfileId;
  final DependencyInstallPolicy dependencyInstallPolicy;

  static final defaultSettings = AppSettings(
    profiles: <ModelProfile>[ModelProfile.defaultProfile()],
    activeProfileId: 'default',
  );

  ModelProfile get activeProfile {
    return profiles.firstWhere(
      (profile) => profile.id == activeProfileId,
      orElse: () => profiles.isNotEmpty
          ? profiles.first
          : AppSettings.defaultSettings.profiles.first,
    );
  }

  ModelServiceSettings get model => activeProfile.model;

  EmbeddingServiceSettings get embedding => activeProfile.embedding;

  AppSettings copyWith({
    List<ModelProfile>? profiles,
    String? activeProfileId,
    DependencyInstallPolicy? dependencyInstallPolicy,
  }) {
    final nextProfiles = profiles ?? this.profiles;
    var nextActiveProfileId = activeProfileId ?? this.activeProfileId;
    if (nextProfiles.isEmpty) {
      final fallback = ModelProfile.defaultProfile();
      return AppSettings(
        profiles: <ModelProfile>[fallback],
        activeProfileId: fallback.id,
        dependencyInstallPolicy:
            dependencyInstallPolicy ?? this.dependencyInstallPolicy,
      );
    }
    if (!nextProfiles.any((profile) => profile.id == nextActiveProfileId)) {
      nextActiveProfileId = nextProfiles.first.id;
    }
    return AppSettings(
      profiles: List<ModelProfile>.unmodifiable(nextProfiles),
      activeProfileId: nextActiveProfileId,
      dependencyInstallPolicy:
          dependencyInstallPolicy ?? this.dependencyInstallPolicy,
    );
  }

  AppSettings upsertProfile(ModelProfile profile, {bool activate = true}) {
    final nextProfiles = <ModelProfile>[];
    var replaced = false;
    for (final existing in profiles) {
      if (existing.id == profile.id) {
        nextProfiles.add(profile);
        replaced = true;
      } else {
        nextProfiles.add(existing);
      }
    }
    if (!replaced) {
      nextProfiles.add(profile);
    }
    return copyWith(
      profiles: nextProfiles,
      activeProfileId: activate ? profile.id : activeProfileId,
    );
  }

  AppSettings removeProfile(String id) {
    final nextProfiles = profiles.where((profile) => profile.id != id).toList();
    if (nextProfiles.isEmpty) {
      final fallback = ModelProfile.defaultProfile();
      return copyWith(profiles: <ModelProfile>[fallback], activeProfileId: fallback.id);
    }
    return copyWith(profiles: nextProfiles);
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'profiles': profiles.map((profile) => profile.toJson()).toList(growable: false),
      'active_profile_id': activeProfileId,
      'dependency_install_policy': dependencyInstallPolicy.name,
    };
  }

  List<String> dependencyProviders() {
    final providers = <String>[];
    void addProvider(String value) {
      final provider = value.trim();
      if (provider.isNotEmpty && !providers.contains(provider)) {
        providers.add(provider);
      }
    }

    addProvider(model.provider);
    addProvider(embedding.provider);
    return providers;
  }

  Map<String, dynamic> toBridgeInitParams() {
    return <String, dynamic>{
      'model_overrides': model.toBridgeOverrides(),
      'embedding_overrides': embedding.toBridgeOverrides(),
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final profilesJson = json['profiles'];
    if (profilesJson is List) {
      final profiles = profilesJson
          .whereType<Map>()
          .map((profile) => ModelProfile.fromJson(Map<String, dynamic>.from(profile)))
          .toList(growable: false);
      if (profiles.isNotEmpty) {
        final activeProfileId = json['active_profile_id']?.toString() ?? profiles.first.id;
        return AppSettings(
          profiles: profiles,
          activeProfileId: profiles.any((profile) => profile.id == activeProfileId)
              ? activeProfileId
              : profiles.first.id,
          dependencyInstallPolicy: DependencyInstallPolicy.fromJson(
            json['dependency_install_policy'],
          ),
        );
      }
    }

    final modelJson = json['model'];
    final embeddingJson = json['embedding'];
    final now = DateTime.now();
    final migratedProfile = ModelProfile(
      id: 'default',
      name: '默认配置',
      model: modelJson is Map
          ? ModelServiceSettings.fromJson(Map<String, dynamic>.from(modelJson))
          : defaultSettings.model,
      embedding: embeddingJson is Map
          ? EmbeddingServiceSettings.fromJson(
              Map<String, dynamic>.from(embeddingJson),
            )
          : defaultSettings.embedding,
      createdAt: now,
      updatedAt: now,
    );
    return AppSettings(
      profiles: <ModelProfile>[migratedProfile],
      activeProfileId: migratedProfile.id,
      dependencyInstallPolicy: DependencyInstallPolicy.fromJson(
        json['dependency_install_policy'],
      ),
    );
  }
}

String _newProfileId() => 'profile_${DateTime.now().microsecondsSinceEpoch}';

DateTime _dateTimeFromJson(Object? value) {
  if (value == null) {
    return DateTime.now();
  }
  return DateTime.tryParse(value.toString()) ?? DateTime.now();
}

bool _boolFromJson(Object? value, {bool fallback = false}) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  final text = value?.toString().toLowerCase();
  if (text == 'true') {
    return true;
  }
  if (text == 'false') {
    return false;
  }
  return fallback;
}

void _validateInt(List<String> errors, String value, String label) {
  final trimmed = value.trim();
  if (trimmed.isNotEmpty && int.tryParse(trimmed) == null) {
    errors.add('$label 必须是整数');
  }
}

void _validateDouble(List<String> errors, String value, String label) {
  final trimmed = value.trim();
  if (trimmed.isNotEmpty && double.tryParse(trimmed) == null) {
    errors.add('$label 必须是数字');
  }
}

String? _nullableTrim(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _normalizeOpenAiBaseUrl(String value) {
  var trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }

  const suffix = '/chat/completions';
  if (trimmed.toLowerCase().endsWith(suffix)) {
    trimmed = trimmed.substring(0, trimmed.length - suffix.length);
  }

  return trimmed.isEmpty ? null : trimmed;
}

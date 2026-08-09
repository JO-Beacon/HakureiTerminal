import 'runtime_identity.dart';

enum SessionTitleMode {
  fixed,
  createdAt,
  firstMessage;

  static SessionTitleMode fromJson(Object? value) {
    return SessionTitleMode.values.firstWhere(
      (item) => item.name == value?.toString(),
      orElse: () => SessionTitleMode.fixed,
    );
  }
}

class ModelCapabilityProfile {
  const ModelCapabilityProfile({
    this.declared = const <String, bool>{},
    this.overrides = const <String, bool>{},
  });

  final Map<String, bool> declared;
  final Map<String, bool> overrides;

  Map<String, bool> get effective => <String, bool>{...declared, ...overrides};

  ModelCapabilityProfile copyWith({
    Map<String, bool>? declared,
    Map<String, bool>? overrides,
  }) {
    return ModelCapabilityProfile(
      declared: declared ?? this.declared,
      overrides: overrides ?? this.overrides,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'declared': declared,
    'overrides': overrides,
  };

  factory ModelCapabilityProfile.fromJson(Map<String, dynamic> json) {
    return ModelCapabilityProfile(
      declared: _boolMapFromJson(json['declared']),
      overrides: _boolMapFromJson(json['overrides']),
    );
  }
}

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
    this.modelCapabilities = const <String, ModelCapabilityProfile>{},
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
  final Map<String, ModelCapabilityProfile> modelCapabilities;

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
    Map<String, ModelCapabilityProfile>? modelCapabilities,
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
      modelCapabilities: modelCapabilities ?? this.modelCapabilities,
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
      'model_capabilities': modelCapabilities.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
    };
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
      modelCapabilities: _capabilityProfilesFromJson(
        json['model_capabilities'],
      ),
    );
  }
}

Map<String, ModelCapabilityProfile> _capabilityProfilesFromJson(Object? value) {
  if (value is! Map) {
    return const <String, ModelCapabilityProfile>{};
  }
  final result = <String, ModelCapabilityProfile>{};
  for (final entry in value.entries) {
    if (entry.value is Map) {
      result[entry.key.toString()] = ModelCapabilityProfile.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
    }
  }
  return result;
}

Map<String, bool> _boolMapFromJson(Object? value) {
  if (value is! Map) {
    return const <String, bool>{};
  }
  final result = <String, bool>{};
  for (final entry in value.entries) {
    final raw = entry.value;
    if (raw is bool) {
      result[entry.key.toString()] = raw;
    } else if (raw is String) {
      final normalized = raw.trim().toLowerCase();
      if (normalized == 'true' || normalized == 'false') {
        result[entry.key.toString()] = normalized == 'true';
      }
    }
  }
  return result;
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

class TtsSettings {
  const TtsSettings({
    this.enabled = false,
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.voice = '',
    this.speed = 1.0,
    this.responseFormat = 'mp3',
  });

  final bool enabled;
  final String baseUrl;
  final String apiKey;
  final String model;
  final String voice;
  final double speed;
  final String responseFormat;

  bool get isConfigured =>
      enabled &&
      baseUrl.trim().isNotEmpty &&
      model.trim().isNotEmpty &&
      voice.trim().isNotEmpty;

  TtsSettings copyWith({
    bool? enabled,
    String? baseUrl,
    String? apiKey,
    String? model,
    String? voice,
    double? speed,
    String? responseFormat,
  }) => TtsSettings(
    enabled: enabled ?? this.enabled,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    voice: voice ?? this.voice,
    speed: speed ?? this.speed,
    responseFormat: responseFormat ?? this.responseFormat,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'enabled': enabled,
    'base_url': baseUrl,
    'api_key': apiKey,
    'model': model,
    'voice': voice,
    'speed': speed,
    'response_format': responseFormat,
  };

  factory TtsSettings.fromJson(Map<String, dynamic> json) => TtsSettings(
    enabled: _boolFromJson(json['enabled']),
    baseUrl: json['base_url']?.toString() ?? '',
    apiKey: json['api_key']?.toString() ?? '',
    model: json['model']?.toString() ?? '',
    voice: json['voice']?.toString() ?? '',
    speed:
        double.tryParse(json['speed']?.toString() ?? '')?.clamp(0.25, 4.0) ??
        1.0,
    responseFormat: json['response_format']?.toString() ?? 'mp3',
  );
}

class ModelProfile {
  const ModelProfile({
    required this.id,
    required this.name,
    required this.model,
    required this.embedding,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final ModelServiceSettings model;
  final EmbeddingServiceSettings embedding;
  final DateTime? createdAt;
  final DateTime? updatedAt;

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
    final now = DateTime.now().toUtc();
    return copyWith(id: id, name: name, createdAt: now, updatedAt: now);
  }

  List<String> validate() {
    return <String>[...model.validate(), ...embedding.validate()];
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'model': model.toJson(),
      'embedding': embedding.toJson(),
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    }..removeWhere((_, value) => value == null);
  }

  factory ModelProfile.fromJson(Map<String, dynamic> json) {
    return ModelProfile(
      id: json['id']?.toString() ?? 'default',
      name: json['name']?.toString() ?? '默认配置',
      model: ModelServiceSettings.fromJson(_mapFromJson(json['model'])),
      embedding: EmbeddingServiceSettings.fromJson(
        _mapFromJson(json['embedding']),
      ),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
    );
  }
}

class BackendSettings {
  const BackendSettings({this.defaultBackendId = 'gensokyoai'});

  final String defaultBackendId;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'default_backend_id': defaultBackendId};
  }

  factory BackendSettings.fromJson(Map<String, dynamic> _) {
    return const BackendSettings();
  }
}

class ExternalRuntimeConnectionSettings {
  const ExternalRuntimeConnectionSettings({
    required this.id,
    required this.agentId,
    required this.displayName,
    required this.baseUrl,
    this.runtimeKind = 'gensokyoai',
    this.authToken = '',
    this.expectedProtocolMajor = 2,
    this.lastVerifiedAt,
    this.lastRuntimeInfo = const <String, dynamic>{},
    this.delegatedProfileId = '',
  });

  final String id;
  final String agentId;
  final String displayName;
  final String runtimeKind;
  final String baseUrl;
  final String authToken;
  final int expectedProtocolMajor;
  final DateTime? lastVerifiedAt;
  final Map<String, dynamic> lastRuntimeInfo;
  final String delegatedProfileId;

  ExternalRuntimeConnectionSettings copyWith({
    String? id,
    String? agentId,
    String? displayName,
    String? runtimeKind,
    String? baseUrl,
    String? authToken,
    int? expectedProtocolMajor,
    DateTime? lastVerifiedAt,
    Map<String, dynamic>? lastRuntimeInfo,
    String? delegatedProfileId,
  }) {
    return ExternalRuntimeConnectionSettings(
      id: id ?? this.id,
      agentId: agentId ?? this.agentId,
      displayName: displayName ?? this.displayName,
      runtimeKind: runtimeKind ?? this.runtimeKind,
      baseUrl: baseUrl ?? this.baseUrl,
      authToken: authToken ?? this.authToken,
      expectedProtocolMajor:
          expectedProtocolMajor ?? this.expectedProtocolMajor,
      lastVerifiedAt: lastVerifiedAt ?? this.lastVerifiedAt,
      lastRuntimeInfo: lastRuntimeInfo ?? this.lastRuntimeInfo,
      delegatedProfileId: delegatedProfileId ?? this.delegatedProfileId,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'agent_id': agentId,
    'display_name': displayName,
    'runtime_kind': runtimeKind,
    'base_url': baseUrl,
    'auth_token': authToken,
    'expected_protocol_major': expectedProtocolMajor,
    'last_verified_at': lastVerifiedAt?.toIso8601String(),
    'last_runtime_info': lastRuntimeInfo,
    'delegated_profile_id': delegatedProfileId,
  }..removeWhere((_, value) => value == null);

  factory ExternalRuntimeConnectionSettings.fromJson(
    Map<String, dynamic> json,
  ) {
    return ExternalRuntimeConnectionSettings(
      id: json['id']?.toString() ?? '',
      agentId: json['agent_id']?.toString().trim().isNotEmpty == true
          ? json['agent_id'].toString().trim()
          : generateRuntimeUuidV4(),
      displayName: json['display_name']?.toString() ?? '',
      runtimeKind: json['runtime_kind']?.toString() ?? 'gensokyoai',
      baseUrl: json['base_url']?.toString() ?? '',
      authToken: json['auth_token']?.toString() ?? '',
      expectedProtocolMajor: 2,
      lastVerifiedAt: DateTime.tryParse(
        json['last_verified_at']?.toString() ?? '',
      ),
      lastRuntimeInfo: _mapFromJson(json['last_runtime_info']),
      delegatedProfileId: json['delegated_profile_id']?.toString() ?? '',
    );
  }
}

/// 开发者选项。真实生效并随 settings.json 持久化。
class DeveloperSettings {
  const DeveloperSettings({this.showDebugInfo = false});

  /// 在界面上显示调试信息（会话 ID 等内部标识）。默认关闭。
  final bool showDebugInfo;

  DeveloperSettings copyWith({bool? showDebugInfo}) {
    return DeveloperSettings(
      showDebugInfo: showDebugInfo ?? this.showDebugInfo,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'show_debug_info': showDebugInfo};
  }

  factory DeveloperSettings.fromJson(Map<String, dynamic> json) {
    return DeveloperSettings(
      showDebugInfo: _boolFromJson(json['show_debug_info']),
    );
  }
}

abstract final class AppShortcutId {
  static const String sendMessage = 'send_message';
  static const String sendMessageOnEnter = 'send_message_on_enter';
  static const String newSession = 'new_session';
  static const String openSettings = 'open_settings';
  static const String previousSession = 'previous_session';
  static const String nextSession = 'next_session';
  static const String focusComposer = 'focus_composer';
  static const String renameSession = 'rename_session';
  static const String deleteSession = 'delete_session';

  static const List<String> values = <String>[
    sendMessage,
    sendMessageOnEnter,
    newSession,
    openSettings,
    previousSession,
    nextSession,
    focusComposer,
    renameSession,
    deleteSession,
  ];
}

class ShortcutSettings {
  const ShortcutSettings({this.enabled = const <String, bool>{}});

  final Map<String, bool> enabled;

  bool isEnabled(String shortcutId) {
    final configured =
        enabled[shortcutId] ?? shortcutId != AppShortcutId.sendMessageOnEnter;
    if (shortcutId == AppShortcutId.sendMessageOnEnter &&
        configured &&
        (enabled[AppShortcutId.sendMessage] ?? true)) {
      return false;
    }
    return configured;
  }

  ShortcutSettings setEnabled(String shortcutId, bool value) {
    final next = <String, bool>{...enabled, shortcutId: value};
    if (value && shortcutId == AppShortcutId.sendMessage) {
      next[AppShortcutId.sendMessageOnEnter] = false;
    } else if (value && shortcutId == AppShortcutId.sendMessageOnEnter) {
      next[AppShortcutId.sendMessage] = false;
    }
    return ShortcutSettings(enabled: next);
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      for (final shortcutId in AppShortcutId.values)
        shortcutId: isEnabled(shortcutId),
    };
  }

  factory ShortcutSettings.fromJson(Map<String, dynamic> json) {
    return ShortcutSettings(
      enabled: <String, bool>{
        for (final shortcutId in AppShortcutId.values)
          if (json[shortcutId] is bool) shortcutId: json[shortcutId] as bool,
      },
    );
  }
}

class CustomThemeSettings {
  const CustomThemeSettings({
    required this.id,
    required this.name,
    this.colors = const <String, String>{},
  });

  final String id;
  final String name;
  final Map<String, String> colors;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'id': id, 'name': name, 'colors': colors};
  }

  factory CustomThemeSettings.fromJson(Map<String, dynamic> json) {
    final colors = <String, String>{};
    final rawColors = json['colors'];
    if (rawColors is Map) {
      for (final entry in rawColors.entries) {
        colors[entry.key.toString()] = entry.value.toString();
      }
    }
    return CustomThemeSettings(
      id: json['id']?.toString().trim() ?? '',
      name: json['name']?.toString().trim() ?? '',
      colors: colors,
    );
  }
}

class AppearanceSettings {
  const AppearanceSettings({
    this.themeId = defaultThemeId,
    this.customThemes = const <CustomThemeSettings>[],
    this.backgroundImagePath = '',
    this.backgroundImageOpacity = 1.0,
    this.fontFamilyId = defaultFontFamilyId,
    this.fontSize = defaultFontSize,
    this.uiDensity = defaultUiDensity,
    this.cornerRadius = defaultCornerRadius,
    this.bubbleStyle = defaultBubbleStyle,
  });

  static const String defaultThemeId = 'preset_sakura_dark';
  static const String defaultFontFamilyId = 'source_han_sans_sc';
  static const double defaultFontSize = 14.0;
  static const String defaultUiDensity = 'standard';
  static const double defaultCornerRadius = 4.0;
  static const String defaultBubbleStyle = 'classic';

  final String themeId;
  final List<CustomThemeSettings> customThemes;
  final String backgroundImagePath;
  final double backgroundImageOpacity;
  final String fontFamilyId;
  final double fontSize;
  final String uiDensity;
  final double cornerRadius;
  final String bubbleStyle;

  AppearanceSettings copyWith({
    String? themeId,
    List<CustomThemeSettings>? customThemes,
    String? backgroundImagePath,
    double? backgroundImageOpacity,
    String? fontFamilyId,
    double? fontSize,
    String? uiDensity,
    double? cornerRadius,
    String? bubbleStyle,
  }) {
    return AppearanceSettings(
      themeId: themeId ?? this.themeId,
      customThemes: customThemes ?? this.customThemes,
      backgroundImagePath: backgroundImagePath ?? this.backgroundImagePath,
      backgroundImageOpacity:
          backgroundImageOpacity ?? this.backgroundImageOpacity,
      fontFamilyId: fontFamilyId ?? this.fontFamilyId,
      fontSize: fontSize ?? this.fontSize,
      uiDensity: uiDensity ?? this.uiDensity,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      bubbleStyle: bubbleStyle ?? this.bubbleStyle,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'theme_id': themeId,
      'custom_themes': customThemes.map((theme) => theme.toJson()).toList(),
      'background_image_path': backgroundImagePath,
      'background_image_opacity': backgroundImageOpacity,
      'font_family_id': fontFamilyId,
      'font_size': fontSize,
      'ui_density': uiDensity,
      'corner_radius': cornerRadius,
      'bubble_style': bubbleStyle,
    };
  }

  factory AppearanceSettings.fromJson(Map<String, dynamic> json) {
    final customThemes = <CustomThemeSettings>[];
    final rawThemes = json['custom_themes'];
    if (rawThemes is List) {
      for (final rawTheme in rawThemes) {
        if (rawTheme is! Map) {
          continue;
        }
        final theme = CustomThemeSettings.fromJson(
          Map<String, dynamic>.from(rawTheme),
        );
        if (theme.id.isNotEmpty && theme.name.isNotEmpty) {
          customThemes.add(theme);
        }
      }
    }
    final themeId = json['theme_id']?.toString().trim() ?? '';
    return AppearanceSettings(
      themeId: themeId.isEmpty ? defaultThemeId : themeId,
      customThemes: customThemes,
      backgroundImagePath:
          json['background_image_path']?.toString().trim() ?? '',
      backgroundImageOpacity: _backgroundImageOpacityFromJson(
        json['background_image_opacity'],
      ),
      fontFamilyId: _fontFamilyIdFromJson(json['font_family_id']),
      fontSize: _appearanceDoubleFromJson(
        json['font_size'],
        fallback: defaultFontSize,
        min: 10,
        max: 22,
      ),
      uiDensity: _appearanceChoiceFromJson(json['ui_density'], const <String>{
        'comfortable',
        'standard',
        'compact',
      }, defaultUiDensity),
      cornerRadius: _appearanceDoubleFromJson(
        json['corner_radius'],
        fallback: defaultCornerRadius,
        min: 0,
        max: 12,
      ),
      bubbleStyle: _appearanceChoiceFromJson(
        json['bubble_style'],
        const <String>{'classic', 'flat', 'plain'},
        defaultBubbleStyle,
      ),
    );
  }
}

double _appearanceDoubleFromJson(
  Object? value, {
  required double fallback,
  required double min,
  required double max,
}) {
  final parsed = value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');
  if (parsed == null || !parsed.isFinite) {
    return fallback;
  }
  return parsed.clamp(min, max);
}

String _appearanceChoiceFromJson(
  Object? value,
  Set<String> allowed,
  String fallback,
) {
  final candidate = value?.toString().trim() ?? '';
  return allowed.contains(candidate) ? candidate : fallback;
}

double _backgroundImageOpacityFromJson(Object? value) {
  final parsed = value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');
  if (parsed == null || !parsed.isFinite) {
    return 1.0;
  }
  return parsed.clamp(0.0, 1.0);
}

class UserRoleSettings {
  const UserRoleSettings({
    required this.id,
    required this.nickname,
    this.bio = '',
    this.avatarImagePath = '',
  });

  final String id;
  final String nickname;
  final String bio;
  final String avatarImagePath;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'nickname': nickname,
      'bio': bio,
      'avatar_image_path': avatarImagePath,
    };
  }

  factory UserRoleSettings.fromJson(Map<String, dynamic> json) {
    return UserRoleSettings(
      id: json['id']?.toString().trim() ?? '',
      nickname: json['nickname']?.toString().trim() ?? '',
      bio: json['bio']?.toString().trim() ?? '',
      avatarImagePath: json['avatar_image_path']?.toString().trim() ?? '',
    );
  }
}

class AppSettings {
  const AppSettings({
    this.activeProfileId = 'default',
    this.profiles = const <ModelProfile>[
      ModelProfile(
        id: 'default',
        name: '默认配置',
        model: ModelServiceSettings(provider: '', model: ''),
        embedding: EmbeddingServiceSettings(),
      ),
    ],
    this.backend = const BackendSettings(),
    this.externalRuntimeConnections =
        const <ExternalRuntimeConnectionSettings>[],
    this.selectedExternalRuntimeConnectionId = '',
    this.newSessionTitleMode = SessionTitleMode.fixed,
    this.developer = const DeveloperSettings(),
    this.shortcuts = const ShortcutSettings(),
    this.appearance = const AppearanceSettings(),
    this.tts = const TtsSettings(),
    this.activeUserRoleId = 'user_default',
    this.userRoles = const <UserRoleSettings>[
      UserRoleSettings(id: 'user_default', nickname: '你'),
    ],
  });

  static const AppSettings defaultSettings = AppSettings();

  final String activeProfileId;
  final List<ModelProfile> profiles;
  final BackendSettings backend;
  final List<ExternalRuntimeConnectionSettings> externalRuntimeConnections;
  final String selectedExternalRuntimeConnectionId;
  final SessionTitleMode newSessionTitleMode;
  final DeveloperSettings developer;
  final ShortcutSettings shortcuts;
  final AppearanceSettings appearance;
  final TtsSettings tts;
  final String activeUserRoleId;
  final List<UserRoleSettings> userRoles;

  String get activeUserNickname {
    for (final role in userRoles) {
      if (role.id == activeUserRoleId && role.nickname.trim().isNotEmpty) {
        return role.nickname.trim();
      }
    }
    return '你';
  }

  ModelProfile get activeProfile {
    return profiles.firstWhere(
      (profile) => profile.id == activeProfileId,
      orElse: () =>
          profiles.isNotEmpty ? profiles.first : defaultSettings.profiles.first,
    );
  }

  ModelServiceSettings get model => activeProfile.model;

  EmbeddingServiceSettings get embedding => activeProfile.embedding;

  AppSettings copyWith({
    String? activeProfileId,
    List<ModelProfile>? profiles,
    BackendSettings? backend,
    List<ExternalRuntimeConnectionSettings>? externalRuntimeConnections,
    String? selectedExternalRuntimeConnectionId,
    SessionTitleMode? newSessionTitleMode,
    DeveloperSettings? developer,
    ShortcutSettings? shortcuts,
    AppearanceSettings? appearance,
    TtsSettings? tts,
    String? activeUserRoleId,
    List<UserRoleSettings>? userRoles,
  }) {
    final nextProfiles = profiles ?? this.profiles;
    var nextActiveId = activeProfileId ?? this.activeProfileId;
    if (nextProfiles.isNotEmpty &&
        !nextProfiles.any((profile) => profile.id == nextActiveId)) {
      nextActiveId = nextProfiles.first.id;
    }
    var nextUserRoles = userRoles ?? this.userRoles;
    if (nextUserRoles.isEmpty) {
      nextUserRoles = defaultSettings.userRoles;
    }
    var nextActiveUserRoleId = activeUserRoleId ?? this.activeUserRoleId;
    if (!nextUserRoles.any((role) => role.id == nextActiveUserRoleId)) {
      nextActiveUserRoleId = nextUserRoles.first.id;
    }
    final nextExternalConnections =
        externalRuntimeConnections ?? this.externalRuntimeConnections;
    var nextExternalConnectionId =
        selectedExternalRuntimeConnectionId ??
        this.selectedExternalRuntimeConnectionId;
    if (!nextExternalConnections.any(
      (connection) => connection.id == nextExternalConnectionId,
    )) {
      nextExternalConnectionId = nextExternalConnections.isEmpty
          ? ''
          : nextExternalConnections.first.id;
    }
    return AppSettings(
      activeProfileId: nextActiveId,
      profiles: nextProfiles,
      backend: backend ?? this.backend,
      externalRuntimeConnections: nextExternalConnections,
      selectedExternalRuntimeConnectionId: nextExternalConnectionId,
      newSessionTitleMode: newSessionTitleMode ?? this.newSessionTitleMode,
      developer: developer ?? this.developer,
      shortcuts: shortcuts ?? this.shortcuts,
      appearance: appearance ?? this.appearance,
      tts: tts ?? this.tts,
      activeUserRoleId: nextActiveUserRoleId,
      userRoles: nextUserRoles,
    );
  }

  AppSettings upsertProfile(ModelProfile profile, {bool activate = true}) {
    final nextProfiles = <ModelProfile>[];
    var replaced = false;
    for (final item in profiles) {
      if (item.id == profile.id) {
        nextProfiles.add(profile);
        replaced = true;
      } else {
        nextProfiles.add(item);
      }
    }
    if (!replaced) {
      nextProfiles.add(profile);
    }
    return copyWith(
      activeProfileId: activate ? profile.id : activeProfileId,
      profiles: nextProfiles,
    );
  }

  AppSettings removeProfile(String profileId) {
    final nextProfiles = profiles
        .where((profile) => profile.id != profileId)
        .toList(growable: false);
    return copyWith(
      activeProfileId: activeProfileId == profileId && nextProfiles.isNotEmpty
          ? nextProfiles.first.id
          : activeProfileId,
      profiles: nextProfiles.isEmpty ? defaultSettings.profiles : nextProfiles,
    );
  }

  ExternalRuntimeConnectionSettings? get selectedExternalRuntimeConnection {
    return externalRuntimeConnectionById(selectedExternalRuntimeConnectionId) ??
        (externalRuntimeConnections.isEmpty
            ? null
            : externalRuntimeConnections.first);
  }

  ExternalRuntimeConnectionSettings? externalRuntimeConnectionById(String id) {
    for (final connection in externalRuntimeConnections) {
      if (connection.id == id) {
        return connection;
      }
    }
    return null;
  }

  AppSettings upsertExternalRuntimeConnection(
    ExternalRuntimeConnectionSettings connection, {
    bool select = false,
  }) {
    final connections = <ExternalRuntimeConnectionSettings>[];
    var replaced = false;
    for (final existing in externalRuntimeConnections) {
      if (existing.id == connection.id) {
        connections.add(connection);
        replaced = true;
      } else {
        connections.add(existing);
      }
    }
    if (!replaced) {
      connections.add(connection);
    }
    return copyWith(
      externalRuntimeConnections: connections,
      selectedExternalRuntimeConnectionId:
          select || selectedExternalRuntimeConnectionId.isEmpty
          ? connection.id
          : selectedExternalRuntimeConnectionId,
    );
  }

  AppSettings removeExternalRuntimeConnection(String connectionId) {
    final connections = externalRuntimeConnections
        .where((connection) => connection.id != connectionId)
        .toList(growable: false);
    return copyWith(
      externalRuntimeConnections: connections,
      selectedExternalRuntimeConnectionId:
          selectedExternalRuntimeConnectionId == connectionId
          ? (connections.isEmpty ? '' : connections.first.id)
          : selectedExternalRuntimeConnectionId,
    );
  }

  AppSettings selectExternalRuntimeConnection(String connectionId) {
    if (externalRuntimeConnectionById(connectionId) == null) {
      throw ArgumentError.value(
        connectionId,
        'connectionId',
        'Unknown Runtime connection',
      );
    }
    return copyWith(selectedExternalRuntimeConnectionId: connectionId);
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'active_profile_id': activeProfileId,
      'profiles': profiles.map((profile) => profile.toJson()).toList(),
      'backend': backend.toJson(),
      'external_runtime_connections': externalRuntimeConnections
          .map((connection) => connection.toJson())
          .toList(growable: false),
      'selected_external_runtime_connection_id':
          selectedExternalRuntimeConnectionId,
      'new_session_title_mode': newSessionTitleMode.name,
      'developer': developer.toJson(),
      'shortcuts': shortcuts.toJson(),
      'appearance': appearance.toJson(),
      'tts': tts.toJson(),
      'active_user_role_id': activeUserRoleId,
      'user_roles': userRoles.map((role) => role.toJson()).toList(),
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final profilesJson = json['profiles'];
    final profiles = <ModelProfile>[];
    if (profilesJson is List) {
      for (final item in profilesJson) {
        if (item is Map) {
          profiles.add(ModelProfile.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    if (profiles.isEmpty) {
      profiles.add(
        ModelProfile(
          id: 'default',
          name: '默认配置',
          model: ModelServiceSettings.fromJson(_mapFromJson(json['model'])),
          embedding: EmbeddingServiceSettings.fromJson(
            _mapFromJson(json['embedding']),
          ),
        ),
      );
    }
    final requestedActiveProfileId =
        json['active_profile_id']?.toString() ?? profiles.first.id;
    final activeProfileId =
        profiles.any((profile) => profile.id == requestedActiveProfileId)
        ? requestedActiveProfileId
        : profiles.first.id;
    final externalConnections = <ExternalRuntimeConnectionSettings>[];
    final externalConnectionsJson = json['external_runtime_connections'];
    if (externalConnectionsJson is List) {
      for (final item in externalConnectionsJson) {
        if (item is Map) {
          final connection = ExternalRuntimeConnectionSettings.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (connection.id.isNotEmpty && connection.baseUrl.isNotEmpty) {
            externalConnections.add(connection);
          }
        }
      }
    }
    final userRoles = <UserRoleSettings>[];
    final userRolesJson = json['user_roles'];
    if (userRolesJson is List) {
      for (final item in userRolesJson) {
        if (item is Map) {
          final role = UserRoleSettings.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (role.id.isNotEmpty && role.nickname.isNotEmpty) {
            userRoles.add(role);
          }
        }
      }
    }
    if (userRoles.isEmpty) {
      userRoles.add(AppSettings.defaultSettings.userRoles.first);
    }
    final requestedUserRoleId =
        json['active_user_role_id']?.toString() ?? userRoles.first.id;
    final activeUserRoleId =
        userRoles.any((role) => role.id == requestedUserRoleId)
        ? requestedUserRoleId
        : userRoles.first.id;
    final requestedExternalConnectionId =
        json['selected_external_runtime_connection_id']?.toString() ?? '';
    final selectedExternalConnectionId =
        externalConnections.any(
          (connection) => connection.id == requestedExternalConnectionId,
        )
        ? requestedExternalConnectionId
        : (externalConnections.isEmpty ? '' : externalConnections.first.id);
    return AppSettings(
      activeProfileId: activeProfileId,
      profiles: profiles,
      backend: json['backend'] is Map
          ? BackendSettings.fromJson(
              Map<String, dynamic>.from(json['backend'] as Map),
            )
          : const BackendSettings(),
      externalRuntimeConnections: externalConnections,
      selectedExternalRuntimeConnectionId: selectedExternalConnectionId,
      newSessionTitleMode: SessionTitleMode.fromJson(
        json['new_session_title_mode'],
      ),
      developer: json['developer'] is Map
          ? DeveloperSettings.fromJson(
              Map<String, dynamic>.from(json['developer'] as Map),
            )
          : const DeveloperSettings(),
      shortcuts: json['shortcuts'] is Map
          ? ShortcutSettings.fromJson(
              Map<String, dynamic>.from(json['shortcuts'] as Map),
            )
          : const ShortcutSettings(),
      appearance: json['appearance'] is Map
          ? AppearanceSettings.fromJson(
              Map<String, dynamic>.from(json['appearance'] as Map),
            )
          : const AppearanceSettings(),
      tts: json['tts'] is Map
          ? TtsSettings.fromJson(Map<String, dynamic>.from(json['tts'] as Map))
          : const TtsSettings(),
      activeUserRoleId: activeUserRoleId,
      userRoles: userRoles,
    );
  }
}

String _fontFamilyIdFromJson(Object? value) {
  final id = value?.toString().trim() ?? '';
  return id.isEmpty ? AppearanceSettings.defaultFontFamilyId : id;
}

bool _boolFromJson(Object? value, {bool fallback = false}) {
  if (value == null) {
    return fallback;
  }
  if (value is bool) {
    return value;
  }
  final text = value.toString().toLowerCase();
  return text == 'true' || text == '1' || text == 'yes';
}

Map<String, dynamic> _mapFromJson(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const <String, dynamic>{};
}

void _validateDouble(List<String> errors, String value, String label) {
  if (value.trim().isEmpty) {
    return;
  }
  if (double.tryParse(value.trim()) == null) {
    errors.add('$label 必须是数字');
  }
}

void _validateInt(List<String> errors, String value, String label) {
  if (value.trim().isEmpty) {
    return;
  }
  if (int.tryParse(value.trim()) == null) {
    errors.add('$label 必须是整数');
  }
}

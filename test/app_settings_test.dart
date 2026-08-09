import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/models/app_settings.dart';
import 'package:hakurei_terminal/services/settings_store.dart';
import 'package:hakurei_terminal/theme/app_theme.dart';

void main() {
  test('AppSettings persists the new session title mode', () {
    final settings = AppSettings.defaultSettings.copyWith(
      newSessionTitleMode: SessionTitleMode.firstMessage,
    );
    final restored = AppSettings.fromJson(settings.toJson());

    expect(restored.newSessionTitleMode, SessionTitleMode.firstMessage);
  });

  group('ModelServiceSettings', () {
    test('serializes and deserializes every model field', () {
      const settings = ModelServiceSettings(
        provider: 'openai',
        model: 'gpt-4o',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-test',
        temperature: '0.7',
        topP: '0.9',
        maxTokens: '2048',
        timeout: '60',
        stream: false,
        think: true,
        reasoningEffort: 'high',
        useProxy: true,
        modelCapabilities: <String, ModelCapabilityProfile>{
          'openai\u0000gpt-4o': ModelCapabilityProfile(
            declared: <String, bool>{'multimodal': true, 'reasoning': false},
            overrides: <String, bool>{'tool_calling': true},
          ),
        },
      );

      final json = settings.toJson();
      expect(json['provider'], 'openai');
      expect(json['model'], 'gpt-4o');
      expect(json['base_url'], 'https://api.openai.com/v1');
      expect(json['api_key'], 'sk-test');
      expect(json['temperature'], '0.7');
      expect(json['top_p'], '0.9');
      expect(json['max_tokens'], '2048');
      expect(json['timeout'], '60');
      expect(json['stream'], isFalse);
      expect(json['think'], isTrue);
      expect(json['reasoning_effort'], 'high');
      expect(json['use_proxy'], isTrue);

      final restored = ModelServiceSettings.fromJson(json);
      expect(restored.provider, settings.provider);
      expect(restored.model, settings.model);
      expect(restored.baseUrl, settings.baseUrl);
      expect(restored.apiKey, settings.apiKey);
      expect(restored.temperature, settings.temperature);
      expect(restored.topP, settings.topP);
      expect(restored.maxTokens, settings.maxTokens);
      expect(restored.timeout, settings.timeout);
      expect(restored.stream, settings.stream);
      expect(restored.think, settings.think);
      expect(restored.reasoningEffort, settings.reasoningEffort);
      expect(restored.useProxy, settings.useProxy);
      final capabilities = restored.modelCapabilities['openai\u0000gpt-4o']!;
      expect(capabilities.declared['multimodal'], isTrue);
      expect(capabilities.declared['reasoning'], isFalse);
      expect(capabilities.effective['tool_calling'], isTrue);
    });

    test('accepts legacy name field when deserializing', () {
      final settings = ModelServiceSettings.fromJson(<String, dynamic>{
        'provider': 'deepseek',
        'name': 'deepseek-chat',
        'stream': 'false',
        'think': 'true',
        'use_proxy': 1,
      });

      expect(settings.provider, 'deepseek');
      expect(settings.model, 'deepseek-chat');
      expect(settings.stream, isFalse);
      expect(settings.think, isTrue);
      expect(settings.useProxy, isTrue);
    });
  });

  group('EmbeddingServiceSettings', () {
    test('serializes and deserializes every embedding field', () {
      const settings = EmbeddingServiceSettings(
        provider: 'openai',
        model: 'text-embedding-3-large',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-embedding',
        dimensions: '3072',
        timeout: '30',
        useProxy: true,
      );

      final json = settings.toJson();
      expect(json['provider'], 'openai');
      expect(json['model'], 'text-embedding-3-large');
      expect(json['base_url'], 'https://api.openai.com/v1');
      expect(json['api_key'], 'sk-embedding');
      expect(json['dimensions'], '3072');
      expect(json['timeout'], '30');
      expect(json['use_proxy'], isTrue);

      final restored = EmbeddingServiceSettings.fromJson(json);
      expect(restored.provider, settings.provider);
      expect(restored.model, settings.model);
      expect(restored.baseUrl, settings.baseUrl);
      expect(restored.apiKey, settings.apiKey);
      expect(restored.dimensions, settings.dimensions);
      expect(restored.timeout, settings.timeout);
      expect(restored.useProxy, settings.useProxy);
    });

    test('accepts legacy name field when deserializing', () {
      final settings = EmbeddingServiceSettings.fromJson(<String, dynamic>{
        'provider': 'openai',
        'name': 'text-embedding-3-small',
        'use_proxy': 'true',
      });

      expect(settings.provider, 'openai');
      expect(settings.model, 'text-embedding-3-small');
      expect(settings.useProxy, isTrue);
    });
  });

  group('AppSettings', () {
    test('round-trips an external Runtime connection', () {
      final settings = AppSettings.defaultSettings
          .upsertExternalRuntimeConnection(
            ExternalRuntimeConnectionSettings(
              id: 'runtime-1',
              agentId: 'agent-runtime-1',
              displayName: 'Remote Runtime',
              baseUrl: 'https://runtime.example/api',
              authToken: 'runtime-token',
              lastVerifiedAt: DateTime.utc(2026, 7, 26),
              lastRuntimeInfo: const <String, dynamic>{
                'protocol_major_version': 2,
              },
            ),
          );

      final restored = AppSettings.fromJson(settings.toJson());

      expect(restored.externalRuntimeConnections, hasLength(1));
      expect(restored.selectedExternalRuntimeConnection?.id, 'runtime-1');
      expect(
        restored.selectedExternalRuntimeConnection?.authToken,
        'runtime-token',
      );
      expect(
        restored
            .selectedExternalRuntimeConnection
            ?.lastRuntimeInfo['protocol_major_version'],
        2,
      );
      expect(
        restored.selectedExternalRuntimeConnection?.agentId,
        'agent-runtime-1',
      );
    });

    test('selects saved Runtime connections', () {
      const first = ExternalRuntimeConnectionSettings(
        id: 'runtime-1',
        agentId: 'agent-1',
        displayName: 'Runtime One',
        baseUrl: 'https://one.example',
      );
      const second = ExternalRuntimeConnectionSettings(
        id: 'runtime-2',
        agentId: 'agent-2',
        displayName: 'Runtime Two',
        baseUrl: 'https://two.example',
      );

      final settings = AppSettings.defaultSettings
          .upsertExternalRuntimeConnection(first)
          .upsertExternalRuntimeConnection(second)
          .selectExternalRuntimeConnection(second.id);

      expect(settings.selectedExternalRuntimeConnection?.id, second.id);
    });

    test('updating a Runtime connection does not change the selection', () {
      const first = ExternalRuntimeConnectionSettings(
        id: 'runtime-1',
        agentId: 'agent-1',
        displayName: 'Runtime One',
        baseUrl: 'https://one.example',
      );
      const second = ExternalRuntimeConnectionSettings(
        id: 'runtime-2',
        agentId: 'agent-2',
        displayName: 'Runtime Two',
        baseUrl: 'https://two.example',
      );
      final settings = AppSettings.defaultSettings
          .upsertExternalRuntimeConnection(first)
          .upsertExternalRuntimeConnection(second)
          .upsertExternalRuntimeConnection(
            second.copyWith(displayName: 'Updated Runtime Two'),
          );

      expect(settings.selectedExternalRuntimeConnectionId, first.id);
      expect(
        settings.externalRuntimeConnectionById(second.id)?.displayName,
        'Updated Runtime Two',
      );
    });

    test('migrates v1 connections to one persisted v2 agent identity', () async {
      final directory = await Directory.systemTemp.createTemp(
        'hakurei_runtime_identity_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}settings.json',
      );
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'external_runtime_connections': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'legacy-runtime',
              'display_name': 'Legacy Runtime',
              'base_url': 'https://runtime.example',
              'expected_protocol_major': 1,
              'enabled': true,
            },
          ],
          'selected_external_runtime_connection_id': 'legacy-runtime',
        }),
      );

      final loaded = await SettingsStore(file: file).load();
      final connection = loaded.externalRuntimeConnections.single;
      expect(connection.expectedProtocolMajor, 2);
      expect(
        connection.agentId,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );

      final persisted =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final persistedConnection =
          (persisted['external_runtime_connections'] as List).single as Map;
      expect(persistedConnection['agent_id'], connection.agentId);
      expect(persistedConnection['expected_protocol_major'], 2);
      expect(persistedConnection.containsKey('enabled'), isFalse);
    });

    test('round-trips multiple profiles', () {
      final createdAt = DateTime.utc(2026, 5, 7, 1, 2, 3);
      final updatedAt = DateTime.utc(2026, 5, 7, 4, 5, 6);
      final settings = AppSettings(
        activeProfileId: 'profile-2',
        profiles: <ModelProfile>[
          ModelProfile(
            id: 'profile-1',
            name: 'DeepSeek',
            model: const ModelServiceSettings(
              provider: 'deepseek',
              model: 'deepseek-chat',
              baseUrl: 'https://api.deepseek.com/v1',
              apiKey: 'deepseek-key',
              temperature: '0.8',
              topP: '0.95',
              maxTokens: '4096',
              timeout: '120',
              stream: true,
              think: false,
              useProxy: false,
            ),
            embedding: const EmbeddingServiceSettings(
              provider: 'openai',
              model: 'text-embedding-3-small',
              dimensions: '1536',
            ),
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          ModelProfile(
            id: 'profile-2',
            name: 'Claude',
            model: const ModelServiceSettings(
              provider: 'claude',
              model: 'claude-3-5-sonnet-latest',
              stream: false,
              think: true,
              reasoningEffort: 'medium',
              useProxy: true,
            ),
            embedding: const EmbeddingServiceSettings(),
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
        ],
      );

      final restored = AppSettings.fromJson(settings.toJson());

      expect(restored.profiles, hasLength(2));
      expect(restored.activeProfileId, 'profile-2');
      expect(restored.activeProfile.name, 'Claude');
      expect(restored.profiles.first.createdAt, createdAt);
      expect(restored.profiles.first.updatedAt, updatedAt);
      expect(restored.profiles.first.model.provider, 'deepseek');
      expect(restored.profiles.first.model.model, 'deepseek-chat');
      expect(restored.profiles.first.model.maxTokens, '4096');
      expect(restored.profiles.first.embedding.model, 'text-embedding-3-small');
      expect(restored.profiles.last.model.provider, 'claude');
      expect(restored.profiles.last.model.stream, isFalse);
      expect(restored.profiles.last.model.think, isTrue);
      expect(restored.profiles.last.model.useProxy, isTrue);
    });

    test('migrates legacy single-profile settings to default ModelProfile', () {
      final migrated = AppSettings.fromJson(<String, dynamic>{
        'dependency_install_policy': 'manual',
        'model': <String, dynamic>{
          'provider': 'openai',
          'name': 'gpt-4o-mini',
          'base_url': 'https://api.openai.com/v1',
          'api_key': 'legacy-model-key',
          'temperature': 0.6,
          'top_p': 0.85,
          'max_tokens': 1024,
          'timeout': 45,
          'stream': false,
          'think': true,
          'reasoning_effort': 'low',
          'use_proxy': true,
        },
        'embedding': <String, dynamic>{
          'provider': 'openai',
          'name': 'text-embedding-3-large',
          'base_url': 'https://api.openai.com/v1',
          'api_key': 'legacy-embedding-key',
          'dimensions': 3072,
          'timeout': 20,
          'use_proxy': true,
        },
      });

      expect(migrated.profiles, hasLength(1));
      expect(migrated.activeProfileId, 'default');
      expect(migrated.activeProfile.name, '默认配置');
      expect(migrated.model.provider, 'openai');
      expect(migrated.model.model, 'gpt-4o-mini');
      expect(migrated.model.baseUrl, 'https://api.openai.com/v1');
      expect(migrated.model.apiKey, 'legacy-model-key');
      expect(migrated.model.temperature, '0.6');
      expect(migrated.model.topP, '0.85');
      expect(migrated.model.maxTokens, '1024');
      expect(migrated.model.timeout, '45');
      expect(migrated.model.stream, isFalse);
      expect(migrated.model.think, isTrue);
      expect(migrated.model.reasoningEffort, 'low');
      expect(migrated.model.useProxy, isTrue);
      expect(migrated.embedding.provider, 'openai');
      expect(migrated.embedding.model, 'text-embedding-3-large');
      expect(migrated.embedding.dimensions, '3072');
      expect(migrated.embedding.timeout, '20');
      expect(migrated.embedding.useProxy, isTrue);
    });

    test('falls back to first profile when active profile id is missing', () {
      final settings = AppSettings.fromJson(<String, dynamic>{
        'active_profile_id': 'missing-profile',
        'profiles': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'profile-1',
            'name': 'Only Profile',
            'model': <String, dynamic>{
              'provider': 'deepseek',
              'model': 'deepseek-chat',
            },
            'embedding': <String, dynamic>{
              'provider': 'openai',
              'model': 'text-embedding-3-small',
            },
            'created_at': '2026-05-07T00:00:00.000Z',
            'updated_at': '2026-05-07T01:00:00.000Z',
          },
        ],
      });

      expect(settings.activeProfileId, 'profile-1');
      expect(settings.activeProfile.name, 'Only Profile');
    });

    test('drops the legacy dependency install policy when saving', () {
      final settings = AppSettings.fromJson(<String, dynamic>{
        'dependency_install_policy': 'manual',
      });

      expect(settings.toJson(), isNot(contains('dependency_install_policy')));
    });

    test('round-trips developer settings and defaults show_debug_info off', () {
      expect(AppSettings.defaultSettings.developer.showDebugInfo, isFalse);

      final enabled = AppSettings.defaultSettings.copyWith(
        developer: const DeveloperSettings(showDebugInfo: true),
      );
      final restored = AppSettings.fromJson(enabled.toJson());
      expect(restored.developer.showDebugInfo, isTrue);

      // 旧版 settings.json 没有 developer 字段时保持默认关闭。
      final legacy = AppSettings.fromJson(
        AppSettings.defaultSettings.toJson()..remove('developer'),
      );
      expect(legacy.developer.showDebugInfo, isFalse);
    });

    test('round-trips appearance settings and custom theme colors', () {
      final settings = AppSettings.defaultSettings.copyWith(
        appearance: const AppearanceSettings(
          themeId: 'custom_midnight',
          backgroundImagePath: 'appearance/backgrounds/global.webp',
          backgroundImageOpacity: 0.42,
          fontFamilyId: 'jetbrains_mono',
          fontSize: 18,
          uiDensity: 'compact',
          cornerRadius: 9,
          bubbleStyle: 'plain',
          customThemes: <CustomThemeSettings>[
            CustomThemeSettings(
              id: 'custom_midnight',
              name: '自定义午夜',
              colors: <String, String>{
                '主色': '#ffaabbcc',
                '强调色': '#ffccbbaa',
                '背景色': '#ff101214',
                '表面色': '#ff1a1d20',
                '文字颜色': '#fff1f3f5',
                '次要文字颜色': '#ffaab0b6',
                '边框颜色': '#ff3b4147',
              },
            ),
          ],
        ),
      );

      final restored = AppSettings.fromJson(settings.toJson());

      expect(restored.appearance.themeId, 'custom_midnight');
      expect(restored.appearance.customThemes, hasLength(1));
      expect(restored.appearance.customThemes.single.name, '自定义午夜');
      expect(
        restored.appearance.backgroundImagePath,
        'appearance/backgrounds/global.webp',
      );
      expect(restored.appearance.fontFamilyId, 'jetbrains_mono');
      expect(restored.appearance.backgroundImageOpacity, 0.42);
      expect(restored.appearance.fontSize, 18);
      expect(restored.appearance.uiDensity, 'compact');
      expect(restored.appearance.cornerRadius, 9);
      expect(restored.appearance.bubbleStyle, 'plain');
      expect(
        restored.appearance.customThemes.single.colors['背景色'],
        '#ff101214',
      );

      final legacyJson = settings.toJson();
      (legacyJson['appearance'] as Map<String, dynamic>).remove(
        'background_image_opacity',
      );
      expect(
        AppSettings.fromJson(legacyJson).appearance.backgroundImageOpacity,
        1.0,
      );
    });

    test('legacy settings without appearance use the default theme', () {
      final legacyJson = AppSettings.defaultSettings.toJson()
        ..remove('appearance');

      final restored = AppSettings.fromJson(legacyJson);

      expect(restored.appearance.themeId, AppearanceSettings.defaultThemeId);
      expect(restored.appearance.customThemes, isEmpty);
      expect(restored.appearance.backgroundImagePath, isEmpty);
      expect(restored.appearance.backgroundImageOpacity, 1.0);
      expect(
        restored.appearance.fontFamilyId,
        AppearanceSettings.defaultFontFamilyId,
      );
      expect(restored.appearance.fontSize, AppearanceSettings.defaultFontSize);
      expect(
        restored.appearance.uiDensity,
        AppearanceSettings.defaultUiDensity,
      );
      expect(
        restored.appearance.cornerRadius,
        AppearanceSettings.defaultCornerRadius,
      );
      expect(
        restored.appearance.bubbleStyle,
        AppearanceSettings.defaultBubbleStyle,
      );
    });

    test('validates persisted appearance implementation values', () {
      final restored = AppearanceSettings.fromJson(<String, dynamic>{
        'font_size': 99,
        'ui_density': 'unknown',
        'corner_radius': -5,
        'bubble_style': 'unknown',
      });

      expect(restored.fontSize, 22);
      expect(restored.uiDensity, AppearanceSettings.defaultUiDensity);
      expect(restored.cornerRadius, 0);
      expect(restored.bubbleStyle, AppearanceSettings.defaultBubbleStyle);
    });

    test('chooses the first-run Sakura theme from platform brightness', () {
      expect(
        defaultThemeIdForPlatformBrightness(Brightness.light),
        'preset_sakura_light',
      );
      expect(
        defaultThemeIdForPlatformBrightness(Brightness.dark),
        'preset_sakura_dark',
      );
      expect(defaultThemeIdForPlatformBrightness(null), 'preset_sakura_dark');
      expect(AppearanceSettings.defaultThemeId, 'preset_sakura_dark');
    });

    test(
      'SettingsStore applies the detected theme to legacy settings',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'jov_system_theme_test_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final file = File(
          '${tempDir.path}${Platform.pathSeparator}settings.json',
        );
        await file.writeAsString('{"profiles": []}');
        final defaults = AppSettings.defaultSettings.copyWith(
          appearance: const AppearanceSettings(themeId: 'preset_sakura_light'),
        );
        final store = SettingsStore(file: file, defaultSettings: defaults);

        final restored = await store.load();

        expect(restored.appearance.themeId, 'preset_sakura_light');
      },
    );

    test('round-trips persistent user roles and active selection', () {
      final settings = AppSettings.defaultSettings.copyWith(
        activeUserRoleId: 'user_work',
        userRoles: const <UserRoleSettings>[
          UserRoleSettings(id: 'user_default', nickname: '你'),
          UserRoleSettings(
            id: 'user_work',
            nickname: '工作身份',
            bio: '偏好简洁的技术讨论。',
            avatarImagePath: 'media/avatar_sha256',
          ),
        ],
      );

      final restored = AppSettings.fromJson(settings.toJson());

      expect(restored.activeUserRoleId, 'user_work');
      expect(restored.userRoles, hasLength(2));
      expect(restored.userRoles.last.nickname, '工作身份');
      expect(restored.userRoles.last.bio, '偏好简洁的技术讨论。');
      expect(restored.userRoles.last.avatarImagePath, 'media/avatar_sha256');

      final legacy = AppSettings.fromJson(
        settings.toJson()
          ..remove('active_user_role_id')
          ..remove('user_roles'),
      );
      expect(legacy.activeUserRoleId, 'user_default');
      expect(legacy.userRoles.single.nickname, '你');
    });

    test('restores a non-empty default user from invalid persisted roles', () {
      final restored = AppSettings.fromJson(<String, dynamic>{
        'user_roles': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'user_default', 'nickname': '   '},
        ],
        'active_user_role_id': 'user_default',
      });

      expect(restored.activeUserRoleId, 'user_default');
      expect(restored.userRoles.single.nickname, '你');
      expect(restored.activeUserNickname, '你');
    });

    test('shortcut send modes have compatible defaults and stay exclusive', () {
      const defaults = ShortcutSettings();
      expect(defaults.isEnabled(AppShortcutId.sendMessage), isTrue);
      expect(defaults.isEnabled(AppShortcutId.sendMessageOnEnter), isFalse);

      final enterToSend = defaults.setEnabled(
        AppShortcutId.sendMessageOnEnter,
        true,
      );
      expect(enterToSend.isEnabled(AppShortcutId.sendMessage), isFalse);
      expect(enterToSend.isEnabled(AppShortcutId.sendMessageOnEnter), isTrue);

      final controlEnterToSend = enterToSend.setEnabled(
        AppShortcutId.sendMessage,
        true,
      );
      expect(controlEnterToSend.isEnabled(AppShortcutId.sendMessage), isTrue);
      expect(
        controlEnterToSend.isEnabled(AppShortcutId.sendMessageOnEnter),
        isFalse,
      );

      final noSendShortcut = defaults.setEnabled(
        AppShortcutId.sendMessage,
        false,
      );
      expect(noSendShortcut.isEnabled(AppShortcutId.sendMessage), isFalse);
      expect(
        noSendShortcut.isEnabled(AppShortcutId.sendMessageOnEnter),
        isFalse,
      );

      final settings = AppSettings.defaultSettings.copyWith(
        shortcuts: defaults
            .setEnabled(AppShortcutId.sendMessage, false)
            .setEnabled(AppShortcutId.deleteSession, false),
      );

      final restored = AppSettings.fromJson(settings.toJson());

      expect(restored.shortcuts.isEnabled(AppShortcutId.sendMessage), isFalse);
      expect(
        restored.shortcuts.isEnabled(AppShortcutId.sendMessageOnEnter),
        isFalse,
      );
      expect(
        restored.shortcuts.isEnabled(AppShortcutId.deleteSession),
        isFalse,
      );
      expect(restored.shortcuts.isEnabled(AppShortcutId.newSession), isTrue);

      final conflicting = ShortcutSettings.fromJson(<String, dynamic>{
        AppShortcutId.sendMessage: true,
        AppShortcutId.sendMessageOnEnter: true,
      });
      expect(conflicting.isEnabled(AppShortcutId.sendMessage), isTrue);
      expect(conflicting.isEnabled(AppShortcutId.sendMessageOnEnter), isFalse);
    });

    test('persists appearance and user roles through SettingsStore', () async {
      final tempDir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}jov_theme_settings_${DateTime.now().microsecondsSinceEpoch}',
      )..createSync(recursive: true);
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final store = SettingsStore(
        file: File('${tempDir.path}${Platform.pathSeparator}settings.json'),
      );
      final settings = AppSettings.defaultSettings.copyWith(
        appearance: const AppearanceSettings(
          themeId: 'preset_graphite_dark',
          backgroundImagePath: 'appearance/backgrounds/persisted.png',
        ),
        activeUserRoleId: 'user_saved',
        userRoles: const <UserRoleSettings>[
          UserRoleSettings(
            id: 'user_saved',
            nickname: '已保存用户',
            avatarImagePath: 'media/saved_avatar',
          ),
        ],
      );

      await store.save(settings);
      final restored = await store.load();

      expect(restored.appearance.themeId, 'preset_graphite_dark');
      expect(
        restored.appearance.backgroundImagePath,
        'appearance/backgrounds/persisted.png',
      );
      expect(restored.activeUserRoleId, 'user_saved');
      expect(restored.userRoles.single.nickname, '已保存用户');
      expect(restored.activeUserNickname, '已保存用户');
      expect(restored.userRoles.single.avatarImagePath, 'media/saved_avatar');
    });

    test('loads a legacy default backend without retaining install data', () {
      final restored = BackendSettings.fromJson(<String, dynamic>{
        'default_backend_id': 'gensokyoai',
        'backend_path': 'C:/legacy/backend',
        'backend_version': '2026.5.13.0',
      });

      expect(restored.defaultBackendId, 'gensokyoai');
      expect(restored.toJson(), <String, dynamic>{
        'default_backend_id': 'gensokyoai',
      });
    });

    test('legacy local installation falls back to the remote-only default', () {
      final restored = BackendSettings.fromJson(<String, dynamic>{
        'backend_path': 'C:/legacy/backend',
        'selected_backend_id': 'gensokyoai',
      });

      expect(restored.defaultBackendId, 'gensokyoai');
    });
  });
}

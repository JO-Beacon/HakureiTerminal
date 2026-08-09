import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/models/assistant.dart';
import 'package:hakurei_terminal/models/app_settings.dart';
import 'package:hakurei_terminal/models/chat_message.dart';
import 'package:hakurei_terminal/models/chat_session.dart';
import 'package:hakurei_terminal/models/runtime_capabilities.dart';
import 'package:hakurei_terminal/repositories/archive_repositories.dart';
import 'package:hakurei_terminal/repositories/media_repository.dart';
import 'package:archive/archive_io.dart';

void main() {
  test(
    'non-Windows default archive paths use the writable app support directory',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'jov_android_root_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final paths = await ArchivePaths.createDefault(
        isWindows: false,
        applicationSupportDirectoryProvider: () async => tempDir,
      );
      final repository = ConversationArchiveRepository(paths: paths);
      await repository.createConversation(
        ChatSession(
          sessionId: 'android-session',
          title: 'Android session',
          lastActive: DateTime.utc(2026, 7, 20),
        ),
      );

      expect(paths.root.path, tempDir.path);
      expect(await paths.conversationFile('android-session').exists(), isTrue);
      expect(paths.root.path, isNot(Directory('/').path));
    },
  );

  group('MediaRepository', () {
    test('stores identical media bytes only once by SHA-256', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'jov_media_dedup_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final repository = MediaRepository(paths: ArchivePaths(root: tempDir));
      final bytes = <int>[1, 2, 3, 4, 5];

      final firstPath = await repository.storeBytes(bytes);
      final secondPath = await repository.storeBytes(List<int>.from(bytes));
      final files = await repository.listManagedFiles();

      expect(secondPath, firstPath);
      expect(firstPath, startsWith('media/'));
      expect(files, hasLength(1));
      expect(files.single.relativePath, firstPath);
      expect(files.single.byteLength, bytes.length);
      expect(files.single.contentAddressed, isTrue);
    });

    test('full archive restores user roles and avatar media', () async {
      final sourceDir = await Directory.systemTemp.createTemp(
        'jov_user_role_export_',
      );
      final targetDir = await Directory.systemTemp.createTemp(
        'jov_user_role_import_',
      );
      addTearDown(() => sourceDir.delete(recursive: true));
      addTearDown(() => targetDir.delete(recursive: true));
      final sourcePaths = ArchivePaths(root: sourceDir);
      final avatarPath = await MediaRepository(
        paths: sourcePaths,
      ).storeBytes(<int>[9, 8, 7, 6]);
      final output = File('${sourceDir.path}${Platform.pathSeparator}all.zip');

      await JovArchiveExportRepository(paths: sourcePaths).exportAllToFile(
        output,
        activeUserRoleId: 'user_work',
        userRoles: <UserRoleSettings>[
          UserRoleSettings(
            id: 'user_work',
            nickname: '工作身份',
            avatarImagePath: avatarPath,
          ),
        ],
      );
      final summary = await JovArchiveExportRepository(
        paths: ArchivePaths(root: targetDir),
      ).importAllFromBytes(await output.readAsBytes());

      expect(summary.activeUserRoleId, 'user_work');
      expect(summary.userRoles?.single.nickname, '工作身份');
      expect(summary.userRoles?.single.avatarImagePath, avatarPath);
      expect(
        ArchivePaths(
          root: targetDir,
        ).managedMediaFile(avatarPath)?.existsSync(),
        isTrue,
      );
    });
  });

  group('AssistantArchiveRepository', () {
    test('saves, lists, loads, and deletes assistants', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'jov_archive_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final repository = AssistantArchiveRepository(
        paths: ArchivePaths(root: tempDir),
      );
      const assistant = Assistant(
        id: 'assistant_reimu',
        name: 'Reimu',
        systemPrompt: 'You are Reimu.',
      );

      await repository.saveAssistant(assistant);

      final listed = await repository.listAssistants();
      final loaded = await repository.getAssistant('assistant_reimu');
      expect(listed, hasLength(1));
      expect(listed.single.id, 'assistant_reimu');
      expect(loaded?.systemPrompt, 'You are Reimu.');

      await repository.deleteAssistant('assistant_reimu');
      expect(await repository.getAssistant('assistant_reimu'), isNull);
    });
  });

  group('ConversationArchiveRepository', () {
    test('rejects conversation IDs that are unsafe directory names', () {
      final paths = ArchivePaths(root: Directory.systemTemp);
      const invalidIds = <String>[
        '',
        '..',
        '../escape',
        r'..\escape',
        '/absolute',
        r'\absolute',
        r'C:\absolute',
        'with/slash',
        r'with\slash',
        'less<than',
        'greater>than',
        'colon:name',
        'quote"name',
        'pipe|name',
        'question?name',
        'star*name',
        'control\u0001name',
        'trailing.',
        'trailing ',
        'CON',
        'con.txt',
        'PrN.log',
        'AUX',
        'nul.data',
        'COM1',
        'com9.json',
        'LPT1',
        'lpt9.ext',
      ];

      for (final conversationId in invalidIds) {
        expect(
          () => paths.conversationDir(conversationId),
          throwsArgumentError,
          reason: conversationId,
        );
      }
    });

    test('preserves valid existing conversation IDs exactly', () {
      final paths = ArchivePaths(root: Directory.systemTemp);
      const validIds = <String>[
        'conv_1',
        'conversation.v1',
        '.conversation',
        'session name',
        '会话-01',
      ];

      for (final conversationId in validIds) {
        expect(
          paths.conversationDir(conversationId).path,
          '${paths.conversationsDir.path}${Platform.pathSeparator}$conversationId',
        );
      }
    });

    test('validates IDs for metadata, messages, context, and delete', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'jov_conversation_boundary_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final repository = ConversationArchiveRepository(
        paths: ArchivePaths(root: tempDir),
      );
      final message = ChatMessage(
        role: ChatMessageRole.user,
        content: 'unsafe',
        createdAt: DateTime.utc(2026, 7, 26),
        conversationId: '..',
      );
      const context = ConversationContextState(summary: 'unsafe');

      final operations = <Future<void> Function()>[
        () => repository.saveConversation(
          const ChatSession(sessionId: '..', title: 'Unsafe'),
        ),
        () async => repository.getConversation('..'),
        () => repository.appendMessage('..', message),
        () async => repository.listMessages('..'),
        () => repository.saveContext('..', context),
        () async => repository.getContext('..'),
        () => repository.deleteConversation('..'),
      ];

      for (final operation in operations) {
        await expectLater(operation(), throwsArgumentError);
      }
    });

    test(
      'path traversal cannot escape and delete cannot remove the root',
      () async {
        final parentDir = await Directory.systemTemp.createTemp(
          'jov_conversation_escape_test_',
        );
        addTearDown(() => parentDir.delete(recursive: true));
        final root = Directory(
          '${parentDir.path}${Platform.pathSeparator}repository',
        );
        await root.create();
        final sentinel = File('${root.path}${Platform.pathSeparator}sentinel');
        await sentinel.writeAsString('keep');
        final repository = ConversationArchiveRepository(
          paths: ArchivePaths(root: root),
        );

        await expectLater(
          repository.saveConversation(
            const ChatSession(sessionId: '../escaped', title: 'Unsafe'),
          ),
          throwsArgumentError,
        );
        await expectLater(
          repository.deleteConversation('..'),
          throwsArgumentError,
        );

        expect(
          await Directory(
            '${root.path}${Platform.pathSeparator}escaped',
          ).exists(),
          isFalse,
        );
        expect(await root.exists(), isTrue);
        expect(await sentinel.readAsString(), 'keep');
      },
    );

    test('migrates a legacy session backend from its active binding', () {
      final session = ChatSession.fromJson(<String, dynamic>{
        'session_id': 'legacy',
        'active_assistant_id': 'assistant_reimu',
        'assistant_execution_bindings': <String, dynamic>{
          'assistant_reimu': <String, dynamic>{
            'assistant_id': 'assistant_reimu',
            'thinking_engine_id': 'gensokyoai_agent',
            'backend_id': 'gensokyoai',
          },
        },
      });

      expect(session.backendId, 'gensokyoai');
    });

    test('saves conversation metadata and jsonl messages', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'jov_conversation_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final repository = ConversationArchiveRepository(
        paths: ArchivePaths(root: tempDir),
      );
      final conversation = ChatSession(
        sessionId: 'conv_1',
        title: '测试会话',
        backendId: 'hakurei_terminal',
        activeAssistantId: 'assistant_reimu',
        avatarImagePath: 'media/persisted_session_avatar',
        createdAt: DateTime.utc(2026, 5, 15),
        lastActive: DateTime.utc(2026, 5, 15, 1),
        assistantExecutionBindings: <String, AssistantExecutionBinding>{
          'assistant_reimu': AssistantExecutionBinding(
            assistantId: 'assistant_reimu',
            thinkingEngineId: 'builtin_chat',
            backendId: 'hakurei_terminal',
            compatibility: AssistantEngineCompatibility.perfect,
            modelOverride: const ModelOverride(
              enabled: true,
              model: OverrideField<String>.override('session-model'),
            ),
            updatedAt: DateTime.utc(2026, 5, 15, 1),
          ),
        },
      );
      final message = ChatMessage(
        role: ChatMessageRole.assistant,
        content: '你好',
        createdAt: DateTime.utc(2026, 5, 15, 1),
        conversationId: 'conv_1',
        assistantId: 'assistant_reimu',
        thinkingEngineId: 'builtin_chat',
        backendId: 'hakurei_terminal',
      );

      await repository.saveConversation(conversation);
      await repository.appendMessage('conv_1', message);

      final conversations = await repository.listConversations();
      final loadedConversation = await repository.getConversation('conv_1');
      final messages = await repository.listMessages('conv_1');

      expect(conversations.single.sessionId, 'conv_1');
      expect(
        conversations
            .single
            .assistantExecutionBindings['assistant_reimu']
            ?.thinkingEngineId,
        'builtin_chat',
      );
      expect(loadedConversation?.activeAssistantId, 'assistant_reimu');
      expect(loadedConversation?.backendId, 'hakurei_terminal');
      expect(
        loadedConversation?.avatarImagePath,
        'media/persisted_session_avatar',
      );
      expect(
        loadedConversation
            ?.assistantExecutionBindings['assistant_reimu']
            ?.backendId,
        'hakurei_terminal',
      );
      expect(
        loadedConversation
            ?.assistantExecutionBindings['assistant_reimu']
            ?.compatibility,
        AssistantEngineCompatibility.perfect,
      );
      expect(
        loadedConversation
            ?.assistantExecutionBindings['assistant_reimu']
            ?.modelOverride
            .enabled,
        isTrue,
      );
      expect(
        loadedConversation
            ?.assistantExecutionBindings['assistant_reimu']
            ?.modelOverride
            .model
            .value,
        'session-model',
      );
      expect(messages.single.assistantId, 'assistant_reimu');
      expect(messages.single.thinkingEngineId, 'builtin_chat');
    });

    test('skips a malformed conversation while listing valid data', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'jov_malformed_conversation_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final paths = ArchivePaths(root: tempDir);
      final repository = ConversationArchiveRepository(paths: paths);
      await repository.createConversation(
        ChatSession(
          sessionId: 'valid',
          title: 'Valid conversation',
          lastActive: DateTime.utc(2026, 7, 16),
        ),
      );
      final malformed = paths.conversationFile('malformed');
      await malformed.parent.create(recursive: true);
      await malformed.writeAsString('{not valid json');

      final conversations = await repository.listConversations();

      expect(conversations, hasLength(1));
      expect(conversations.single.sessionId, 'valid');
    });

    test('persists manual order and deep-copies a conversation', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'jov_duplicate_conversation_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final repository = ConversationArchiveRepository(
        paths: ArchivePaths(root: tempDir),
      );
      final newer = ChatSession(
        sessionId: 'newer',
        title: '较新的会话',
        listOrder: 1,
        lastActive: DateTime.utc(2026, 7, 19),
      );
      final source = ChatSession(
        sessionId: 'source',
        title: '源会话',
        activeAssistantId: 'assistant_reimu',
        totalTurns: 1,
        summary: '摘要',
        avatarImagePath: 'media/copied_session_avatar',
        listOrder: 0,
        lastActive: DateTime.utc(2026, 7, 18),
        metadata: const <String, dynamic>{'custom': true},
      );
      await repository.saveConversation(newer);
      await repository.saveConversation(source);
      await repository.appendMessage(
        source.sessionId,
        ChatMessage(
          id: 'message_1',
          role: ChatMessageRole.user,
          content: '第一条',
          createdAt: DateTime.utc(2026, 7, 18, 1),
          conversationId: source.sessionId,
        ),
      );
      await repository.appendMessage(
        source.sessionId,
        ChatMessage(
          id: 'message_2',
          role: ChatMessageRole.assistant,
          content: '第二条',
          createdAt: DateTime.utc(2026, 7, 18, 2),
          conversationId: source.sessionId,
          parentMessageId: 'message_1',
        ),
      );
      await repository.saveContext(
        source.sessionId,
        const ConversationContextState(
          truncatedBeforeMessageId: 'message_1',
          excludedMessageIds: <String>{'message_2'},
        ),
      );

      expect(
        (await repository.listConversations()).map((item) => item.sessionId),
        <String>['source', 'newer'],
      );

      final duplicate = ChatSession(
        sessionId: 'duplicate',
        title: source.title,
        activeAssistantId: source.activeAssistantId,
        totalTurns: source.totalTurns,
        summary: source.summary,
        avatarImagePath: source.avatarImagePath,
        listOrder: 1,
        lastActive: source.lastActive,
        metadata: source.metadata,
      );
      await repository.duplicateConversation(source.sessionId, duplicate);

      final restored = await repository.getConversation('duplicate');
      final copiedMessages = await repository.listMessages('duplicate');
      final copiedContext = await repository.getContext('duplicate');
      expect(restored?.title, source.title);
      expect(restored?.metadata, source.metadata);
      expect(restored?.avatarImagePath, source.avatarImagePath);
      expect(copiedMessages, hasLength(2));
      expect(copiedMessages.first.id, isNot('message_1'));
      expect(copiedMessages.first.conversationId, 'duplicate');
      expect(copiedMessages.last.parentMessageId, copiedMessages.first.id);
      expect(copiedContext?.truncatedBeforeMessageId, copiedMessages.first.id);
      expect(copiedContext?.excludedMessageIds, <String>{
        copiedMessages.last.id,
      });
    });

    test('saves conversation context and exports jovarchive', () async {
      final tempDir = await Directory.systemTemp.createTemp('jov_export_test_');
      addTearDown(() => tempDir.delete(recursive: true));
      final paths = ArchivePaths(root: tempDir);
      final repository = ConversationArchiveRepository(paths: paths);
      final exporter = JovArchiveExportRepository(paths: paths);
      final avatarPath = await MediaRepository(
        paths: paths,
      ).storeBytes(<int>[1, 2, 3, 4]);
      final conversation = ChatSession(
        sessionId: 'conv_export',
        title: '导出会话',
        backgroundImagePath:
            'conversations/conv_export/backgrounds/session.png',
        avatarImagePath: avatarPath,
        createdAt: DateTime.utc(2026, 5, 17),
      );
      final context = ConversationContextState(
        summary: '用户正在测试导出。',
        includedMessageCount: 8,
        truncatedBeforeMessageId: 'msg_1',
        excludedMessageIds: const <String>{'msg_2'},
        estimatedTokens: 1024,
        estimatedBudgetTokens: 800,
        estimatedMessageCount: 9,
        excludedMessageCount: 1,
        overBudget: true,
        metadata: const <String, dynamic>{'strategy': 'manual_exclusion'},
        updatedAt: DateTime.utc(2026, 5, 17, 1),
      );

      await repository.saveConversation(conversation);
      final backgroundFile = paths.managedConversationBackgroundFile(
        'conv_export',
        conversation.backgroundImagePath,
      )!;
      await backgroundFile.parent.create(recursive: true);
      await backgroundFile.writeAsBytes(<int>[4, 3, 2, 1]);
      await repository.saveContext('conv_export', context);
      await repository.appendMessage(
        'conv_export',
        ChatMessage(
          role: ChatMessageRole.user,
          content: '导出测试',
          createdAt: DateTime.utc(2026, 5, 17, 1),
          conversationId: 'conv_export',
        ),
      );

      final loadedContext = await repository.getContext('conv_export');
      final archiveFile = await exporter.exportConversation(
        'conv_export',
        archiveId: 'export_test',
      );
      final archive = ZipDecoder().decodeBytes(await archiveFile.readAsBytes());
      final entries = archive.files.map((file) => file.name).toSet();
      final manifestFile = archive.files.firstWhere(
        (file) => file.name == 'manifest.json',
      );
      final manifest = jsonDecode(
        utf8.decode(manifestFile.content as List<int>),
      );

      expect(loadedContext?.summary, '用户正在测试导出。');
      expect(loadedContext?.includedMessageCount, 8);
      expect(loadedContext?.excludedMessageIds, contains('msg_2'));
      expect(loadedContext?.estimatedTokens, 1024);
      expect(loadedContext?.estimatedBudgetTokens, 800);
      expect(loadedContext?.estimatedMessageCount, 9);
      expect(loadedContext?.excludedMessageCount, 1);
      expect(loadedContext?.overBudget, isTrue);
      expect(entries, contains('manifest.json'));
      expect(entries, contains('conversations/conv_export/conversation.json'));
      expect(entries, contains('conversations/conv_export/messages.jsonl'));
      expect(entries, contains('conversations/conv_export/context.json'));
      expect(
        entries,
        contains('conversations/conv_export/backgrounds/session.png'),
      );
      expect(entries, contains(avatarPath));
      expect(loadedContext, isNotNull);
      expect(
        (await repository.getConversation('conv_export'))?.backgroundImagePath,
        conversation.backgroundImagePath,
      );
      expect(
        (await repository.getConversation('conv_export'))?.avatarImagePath,
        avatarPath,
      );
      expect(manifest['format'], 'jovarchive');
      expect(manifest['scope'], 'conversation');
      expect(manifest['conversation_id'], 'conv_export');
    });
  });

  group('Full jovarchive appearance resources', () {
    test('restores credentials without Runtime Provider delegation', () async {
      final sourceRoot = await Directory.systemTemp.createTemp(
        'jov_settings_export_',
      );
      final targetRoot = await Directory.systemTemp.createTemp(
        'jov_settings_import_',
      );
      addTearDown(() => sourceRoot.delete(recursive: true));
      addTearDown(() => targetRoot.delete(recursive: true));
      final output = File(
        '${sourceRoot.path}${Platform.pathSeparator}settings.jovarchive',
      );
      final settings = AppSettings(
        profiles: const <ModelProfile>[
          ModelProfile(
            id: 'default',
            name: 'Default',
            model: ModelServiceSettings(
              provider: 'openai',
              model: 'gpt-test',
              apiKey: 'provider-secret',
            ),
            embedding: EmbeddingServiceSettings(),
          ),
        ],
        externalRuntimeConnections: const <ExternalRuntimeConnectionSettings>[
          ExternalRuntimeConnectionSettings(
            id: 'runtime-1',
            agentId: 'agent-runtime-1',
            displayName: 'Runtime',
            baseUrl: 'https://runtime.example',
            authToken: 'runtime-secret',
            delegatedProfileId: 'default',
          ),
        ],
        selectedExternalRuntimeConnectionId: 'runtime-1',
      );

      await JovArchiveExportRepository(
        paths: ArchivePaths(root: sourceRoot),
      ).exportAllToFile(output, settings: settings);
      final summary = await JovArchiveExportRepository(
        paths: ArchivePaths(root: targetRoot),
      ).importAllFromBytes(await output.readAsBytes());

      expect(summary.settings?.model.apiKey, 'provider-secret');
      expect(
        summary.settings?.externalRuntimeConnections.single.authToken,
        'runtime-secret',
      );
      expect(
        summary.settings?.externalRuntimeConnections.single.delegatedProfileId,
        isEmpty,
      );
      expect(
        summary.settings?.selectedExternalRuntimeConnectionId,
        'runtime-1',
      );
    });

    test('exports a shared content-addressed media file once', () async {
      final sourceRoot = await Directory.systemTemp.createTemp(
        'jov_media_export_',
      );
      final targetRoot = await Directory.systemTemp.createTemp(
        'jov_media_import_',
      );
      addTearDown(() => sourceRoot.delete(recursive: true));
      addTearDown(() => targetRoot.delete(recursive: true));
      final sourcePaths = ArchivePaths(root: sourceRoot);
      final sourceMedia = MediaRepository(paths: sourcePaths);
      final mediaPath = await sourceMedia.storeBytes(<int>[9, 8, 7, 6]);
      await ConversationArchiveRepository(paths: sourcePaths).saveConversation(
        ChatSession(
          sessionId: 'shared_media',
          title: 'Shared media',
          backgroundImagePath: mediaPath,
        ),
      );
      final output = File(
        '${sourceRoot.path}${Platform.pathSeparator}shared.jovarchive',
      );

      await JovArchiveExportRepository(paths: sourcePaths).exportAllToFile(
        output,
        appearance: AppearanceSettings(backgroundImagePath: mediaPath),
      );

      final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
      expect(
        archive.files.where((file) => file.name == mediaPath),
        hasLength(1),
      );
      final importer = JovArchiveExportRepository(
        paths: ArchivePaths(root: targetRoot),
      );
      final summary = await importer.importAllFromBytes(
        await output.readAsBytes(),
      );
      final restored = importer.paths.managedMediaFile(mediaPath)!;
      expect(summary.appearance?.backgroundImagePath, mediaPath);
      expect(await restored.readAsBytes(), <int>[9, 8, 7, 6]);
    });

    test('exports and restores the independent background image', () async {
      final sourceRoot = await Directory.systemTemp.createTemp(
        'jov_appearance_export_',
      );
      final targetRoot = await Directory.systemTemp.createTemp(
        'jov_appearance_import_',
      );
      addTearDown(() => sourceRoot.delete(recursive: true));
      addTearDown(() => targetRoot.delete(recursive: true));
      final sourcePaths = ArchivePaths(root: sourceRoot);
      const backgroundPath = 'appearance/backgrounds/global_test.png';
      final sourceBackground = sourcePaths.managedAppearanceFile(
        backgroundPath,
      )!;
      await sourceBackground.parent.create(recursive: true);
      await sourceBackground.writeAsBytes(<int>[1, 2, 3, 4]);
      final output = File(
        '${sourceRoot.path}${Platform.pathSeparator}appearance.jovarchive',
      );
      final exporter = JovArchiveExportRepository(paths: sourcePaths);

      await exporter.exportAllToFile(
        output,
        appearance: const AppearanceSettings(
          themeId: 'preset_ocean_dark',
          backgroundImagePath: backgroundPath,
        ),
      );

      final bytes = await output.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final entries = archive.files.map((file) => file.name).toSet();
      expect(entries, contains('appearance/settings.json'));
      expect(entries, contains(backgroundPath));

      final importer = JovArchiveExportRepository(
        paths: ArchivePaths(root: targetRoot),
      );
      final summary = await importer.importAllFromBytes(bytes);
      final restoredBackground = importer.paths.managedAppearanceFile(
        backgroundPath,
      )!;

      expect(summary.appearance?.themeId, 'preset_ocean_dark');
      expect(summary.appearance?.backgroundImagePath, backgroundPath);
      expect(await restoredBackground.readAsBytes(), <int>[1, 2, 3, 4]);
    });

    test('rejects an appearance config whose background is missing', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'jov_appearance_invalid_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final archive = Archive();
      final appearanceBytes = utf8.encode(
        jsonEncode(<String, dynamic>{
          'theme_id': AppearanceSettings.defaultThemeId,
          'background_image_path': 'appearance/backgrounds/missing.png',
        }),
      );
      final manifestBytes = utf8.encode(
        jsonEncode(<String, dynamic>{'format': 'jovarchive'}),
      );
      archive
        ..addFile(
          ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
        )
        ..addFile(
          ArchiveFile(
            'appearance/settings.json',
            appearanceBytes.length,
            appearanceBytes,
          ),
        );

      final importer = JovArchiveExportRepository(
        paths: ArchivePaths(root: tempDir),
      );

      expect(
        () => importer.importAllFromBytes(ZipEncoder().encode(archive)),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'rejects a media entry whose content does not match its hash',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'jov_media_hash_mismatch_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final archive = Archive();
        final manifestBytes = utf8.encode(
          jsonEncode(<String, dynamic>{'format': 'jovarchive'}),
        );
        final invalidPath = 'media/${List<String>.filled(64, '0').join()}';
        archive
          ..addFile(
            ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
          )
          ..addFile(ArchiveFile(invalidPath, 3, <int>[1, 2, 3]));

        final importer = JovArchiveExportRepository(
          paths: ArchivePaths(root: tempDir),
        );

        expect(
          () => importer.importAllFromBytes(ZipEncoder().encode(archive)),
          throwsA(isA<FormatException>()),
        );
      },
    );
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hakurei_terminal/main.dart';
import 'package:hakurei_terminal/models/app_settings.dart';
import 'package:hakurei_terminal/models/assistant.dart';
import 'package:hakurei_terminal/models/chat_message.dart';
import 'package:hakurei_terminal/models/chat_session.dart';
import 'package:hakurei_terminal/repositories/archive_repositories.dart';
import 'package:hakurei_terminal/screens/settings_screen.dart';
import 'package:hakurei_terminal/services/app_logger.dart';
import 'package:hakurei_terminal/services/provider_model_catalog.dart';
import 'package:hakurei_terminal/services/runtime/external_agent_runtime.dart';
import 'package:hakurei_terminal/services/runtime/external_runtime_event.dart';
import 'package:hakurei_terminal/services/runtime/runtime_connection.dart';
import 'package:hakurei_terminal/services/runtime/runtime_conversation_controller.dart';
import 'package:hakurei_terminal/services/runtime/runtime_reply.dart';
import 'package:hakurei_terminal/services/runtime/runtime_stream_event.dart';

void main() {
  test('TTS startup stop event keeps the active message controls', () {
    expect(
      shouldClearTtsMessage(state: PlayerState.stopped, busy: true),
      isFalse,
    );
    expect(
      shouldClearTtsMessage(state: PlayerState.completed, busy: false),
      isTrue,
    );
  });

  test('remote session title reads Runtime metadata.title', () {
    expect(
      sessionTitleFromRemoteJson(<String, dynamic>{
        'session_id': 'session-1',
        'metadata': <String, dynamic>{'title': '红魔馆夜谈'},
      }),
      '红魔馆夜谈',
    );
    expect(
      sessionTitleFromRemoteJson(<String, dynamic>{'session_id': 'session-2'}),
      'GensokyoAI 会话',
    );
  });

  test('near-bottom scroll threshold preserves a user-scrolled position', () {
    expect(isNearScrollBottom(pixels: 920, maxScrollExtent: 1000), isTrue);
    expect(isNearScrollBottom(pixels: 919, maxScrollExtent: 1000), isFalse);
  });

  test('in-flight display messages append and update by request id', () {
    final now = DateTime.utc(2026, 7, 26);
    final user = ChatMessage(
      id: 'pending-user-1',
      role: ChatMessageRole.user,
      content: '你好',
      createdAt: now,
      conversationId: 'session-1',
    );
    final partial = ChatMessage(
      id: 'pending-assistant-1',
      role: ChatMessageRole.assistant,
      content: '你',
      createdAt: now,
      conversationId: 'session-1',
    );
    final completedPartial = ChatMessage(
      id: partial.id,
      role: partial.role,
      content: '你好',
      createdAt: now,
      conversationId: 'session-1',
    );

    final sending = upsertDisplayMessage(const <ChatMessage>[], user);
    final streaming = upsertDisplayMessage(sending, partial);
    final updated = upsertDisplayMessage(streaming, completedPartial);

    expect(updated, hasLength(2));
    expect(updated.first.content, '你好');
    expect(updated.last.content, '你好');
  });

  test('remote sessions merge with cached mappings across characters', () {
    final daiId = localExternalSessionId(
      'runtime',
      'dai-1',
      characterId: 'Daiyousei',
    );
    final cirnoId = localExternalSessionId(
      'runtime',
      'cirno-1',
      characterId: 'Cirno',
    );
    final cachedDaiyousei = ChatSession(
      sessionId: daiId,
      title: '大妖精会话',
      externalConnectionId: 'runtime',
      externalSessionId: 'dai-1',
      externalCharacterId: 'Daiyousei',
      totalTurns: 1,
      lastActive: DateTime.utc(2026, 7, 25),
    );
    final cachedCirno = ChatSession(
      sessionId: cirnoId,
      title: '琪露诺会话',
      externalConnectionId: 'runtime',
      externalSessionId: 'cirno-1',
      externalCharacterId: 'Cirno',
      totalTurns: 1,
    );
    final remoteCirno = cachedCirno.copyWith(totalTurns: 2);

    final merged = mergeRemoteSessionMappings(
      <ChatSession>[cachedDaiyousei, cachedCirno],
      <ChatSession>[remoteCirno],
      activeCharacterId: 'Cirno',
    );

    expect(merged, hasLength(2));
    final mergedDaiyousei = merged.singleWhere(
      (item) => item.sessionId == daiId,
    );
    expect(
      mergedDaiyousei.externalSessionId,
      cachedDaiyousei.externalSessionId,
    );
    expect(mergedDaiyousei.title, cachedDaiyousei.title);
    expect(
      mergedDaiyousei.externalMappingStatus,
      ExternalMappingStatus.unverified,
    );
    expect(
      merged.singleWhere((item) => item.sessionId == cirnoId).totalTurns,
      2,
    );
    expect(
      merged
          .singleWhere((item) => item.sessionId == cirnoId)
          .externalMappingStatus,
      ExternalMappingStatus.verified,
    );
  });

  test('external session mapping ids are Windows path safe and stable', () {
    final id = localExternalSessionId(
      'runtime:connection/一',
      'c6612e26-5f8f-49b4-919d-92dd7e38df37',
    );

    expect(id, startsWith('external_'));
    expect(id, isNot(contains(RegExp(r'[<>:"/\\|?*]'))));
    expect(
      localExternalSessionId(
        'runtime:connection/一',
        'c6612e26-5f8f-49b4-919d-92dd7e38df37',
      ),
      id,
    );
  });

  test('legacy colon session mappings normalize before persistence', () {
    const legacy = ChatSession(
      sessionId: 'runtime:remote-session',
      externalConnectionId: 'runtime',
      externalSessionId: 'remote-session',
    );

    final normalized = mergeRemoteSessionMappings(
      const <ChatSession>[legacy],
      const <ChatSession>[],
      activeCharacterId: '',
    ).single;

    expect(
      normalized.sessionId,
      localExternalSessionId('runtime', 'remote-session'),
    );
    expect(normalized.externalSessionId, 'remote-session');
  });

  test('active character remote deletion marks cached mapping stale', () {
    const cached = ChatSession(
      sessionId: 'legacy',
      externalConnectionId: 'runtime',
      externalSessionId: 'deleted',
      externalCharacterId: 'reimu',
      externalMappingStatus: ExternalMappingStatus.verified,
    );

    final reconciled = mergeRemoteSessionMappings(
      const <ChatSession>[cached],
      const <ChatSession>[],
      activeCharacterId: 'reimu',
    ).single;

    expect(reconciled.externalMappingStatus, ExternalMappingStatus.stale);
  });

  test('remote authority wins while local presentation fields survive', () {
    final cached = ChatSession(
      sessionId: 'legacy',
      title: 'cached',
      externalConnectionId: 'runtime',
      externalSessionId: 'session',
      externalCharacterId: 'reimu',
      totalTurns: 1,
      backgroundImagePath: 'background.png',
      avatarImagePath: 'avatar.png',
      listOrder: 4,
      metadata: const <String, dynamic>{
        'remote': <String, dynamic>{'large': true},
      },
    );
    final remote = cached.copyWith(
      title: 'authoritative',
      totalTurns: 9,
      createdAt: DateTime.utc(2026, 7, 1),
      lastActive: DateTime.utc(2026, 7, 26),
      backgroundImagePath: '',
      avatarImagePath: '',
      listOrder: 0,
      metadata: const <String, dynamic>{'state_authority': 'external_runtime'},
    );

    final reconciled = mergeRemoteSessionMappings(
      <ChatSession>[cached],
      <ChatSession>[remote],
      activeCharacterId: 'reimu',
    ).single;

    expect(reconciled.title, 'authoritative');
    expect(reconciled.totalTurns, 9);
    expect(reconciled.lastActive, DateTime.utc(2026, 7, 26));
    expect(reconciled.backgroundImagePath, 'background.png');
    expect(reconciled.avatarImagePath, 'avatar.png');
    expect(reconciled.listOrder, 4);
    expect(reconciled.toJson()['metadata'], isNot(contains('remote')));
  });

  test(
    'session identity includes character to prevent remote id collisions',
    () {
      final reimu = localExternalSessionId(
        'runtime',
        'shared',
        characterId: 'reimu',
      );
      final marisa = localExternalSessionId(
        'runtime',
        'shared',
        characterId: 'marisa',
      );

      expect(reimu, isNot(marisa));
    },
  );

  test('legacy external mappings default to unverified', () {
    final restored = ChatSession.fromJson(const <String, dynamic>{
      'session_id': 'legacy',
      'external_connection_id': 'runtime',
      'external_session_id': 'remote',
    });

    expect(restored.externalMappingStatus, ExternalMappingStatus.unverified);
  });

  test(
    'remote session character display names resolve to stable Runtime ids',
    () {
      const assistant = Assistant(
        id: 'gensokyoai_runtime_Daiyousei',
        name: '大妖精',
        providerId: AssistantProviderId.gensokyoAi,
        providerAssistantId: 'Daiyousei',
      );

      expect(
        resolveGensokyoAiSessionAssistant('大妖精', const <Assistant>[
          assistant,
        ])?.providerAssistantId,
        'Daiyousei',
      );
      expect(
        resolveGensokyoAiSessionAssistant('Daiyousei', const <Assistant>[
          assistant,
        ])?.id,
        assistant.id,
      );
    },
  );

  testWidgets('startup does not connect a saved Runtime', (tester) async {
    final temp = Directory.systemTemp.createTempSync('hakurei_startup_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final connection = ExternalRuntimeConnectionSettings(
      id: 'runtime',
      agentId: 'agent-runtime',
      displayName: 'Configured',
      baseUrl: 'http://127.0.0.1:9',
    );
    final settings = AppSettings.defaultSettings.copyWith(
      externalRuntimeConnections: <ExternalRuntimeConnectionSettings>[
        connection,
      ],
      selectedExternalRuntimeConnectionId: connection.id,
    );
    final controller = ChatScreenController();

    await tester.pumpWidget(
      HakureiTerminalApp(
        controller: controller,
        archivePaths: ArchivePaths(root: temp),
        initialSettings: settings,
        skipInitialLoad: true,
      ),
    );
    await tester.pump();

    expect(controller.sessionsLoaded, isTrue);
    expect(find.textContaining('请先显式连接 GensokyoAI'), findsWidgets);
  });

  testWidgets('no connection blocks session creation and has no fallback', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('hakurei_blocked_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final controller = ChatScreenController();
    await tester.pumpWidget(
      HakureiTerminalApp(
        controller: controller,
        archivePaths: ArchivePaths(root: temp),
        initialSettings: AppSettings.defaultSettings,
        skipInitialLoad: true,
      ),
    );
    await tester.pump();

    await controller.createRemoteSession();
    await controller.sendMessage('must not execute locally');
    await tester.pump();

    expect(controller.sessionIds, isEmpty);
    expect(controller.currentError, contains('请先选择或创建会话'));
    expect(find.textContaining('请先显式连接 GensokyoAI'), findsWidgets);
  });

  testWidgets('connection loads cache without listing before activation', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('hakurei_read_only_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final screenController = ChatScreenController();
    final runtime = _WidgetConversationRuntime();
    var listCalls = 0;
    final repository = ConversationArchiveRepository(
      paths: ArchivePaths(root: temp),
    );
    await tester.runAsync(
      () => repository.saveConversation(
        const ChatSession(
          sessionId: 'cached',
          title: 'Cached mapping',
          externalConnectionId: 'runtime',
          externalSessionId: 'cached-remote',
          externalCharacterId: 'reimu',
          externalMappingStatus: ExternalMappingStatus.verified,
        ),
      ),
    );

    await tester.pumpWidget(
      HakureiTerminalApp(
        controller: screenController,
        archivePaths: ArchivePaths(root: temp),
        conversationRepository: repository,
        skipInitialLoad: true,
      ),
    );
    await tester.runAsync(() async {
      final conversationController = RuntimeConversationController(
        runtime: runtime,
      );
      await screenController.attachRuntime(
        conversationController: conversationController,
        connectionId: 'runtime',
        assistants: const <Assistant>[
          Assistant(
            id: 'gensokyoai_reimu',
            name: 'Reimu',
            providerId: AssistantProviderId.gensokyoAi,
            providerAssistantId: 'reimu',
          ),
        ],
        listSessions: () async {
          listCalls++;
          return _remoteSessions;
        },
      );
      await screenController.reloadSessionsReadOnly();
    });
    await tester.pump();

    expect(listCalls, 0);
    expect(runtime.activationRequests, isEmpty);
    expect(screenController.selectedSessionId, isNull);
    expect(screenController.sessionIds, hasLength(1));
    expect(
      screenController.sessionMappingStatuses,
      const <ExternalMappingStatus>[ExternalMappingStatus.unverified],
    );
  });

  testWidgets('selecting an unverified mapping activates and verifies it', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('hakurei_verify_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final paths = ArchivePaths(root: temp);
    final repository = ConversationArchiveRepository(paths: paths);
    final screenController = ChatScreenController();
    final runtime = _WidgetConversationRuntime();
    var listCalls = 0;
    await tester.runAsync(
      () => repository.saveConversation(
        const ChatSession(
          sessionId: 'cached',
          title: 'Cached mapping',
          externalConnectionId: 'runtime',
          externalSessionId: 'remote-1',
          externalCharacterId: 'reimu',
        ),
      ),
    );
    await tester.pumpWidget(
      HakureiTerminalApp(
        controller: screenController,
        archivePaths: paths,
        conversationRepository: repository,
        skipInitialLoad: true,
      ),
    );

    await tester.runAsync(() async {
      await screenController.attachRuntime(
        conversationController: RuntimeConversationController(runtime: runtime),
        connectionId: 'runtime',
        assistants: const <Assistant>[
          Assistant(
            id: 'gensokyoai_reimu',
            name: 'Reimu',
            providerId: AssistantProviderId.gensokyoAi,
            providerAssistantId: 'reimu',
          ),
        ],
        listSessions: () async {
          listCalls++;
          return _remoteSessions;
        },
      );
      await screenController.reloadSessionsReadOnly();
      await screenController.selectSession(screenController.sessionIds.single);
    });

    expect(runtime.activationRequests, <(String, String?, bool)>[
      ('reimu', 'remote-1', false),
    ]);
    expect(listCalls, 1);
    expect(
      screenController.sessionMappingStatuses,
      everyElement(ExternalMappingStatus.verified),
    );
    expect(screenController.sendBlockerCodes, isEmpty);
  });

  testWidgets('missing remote session marks cached mapping stale', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('hakurei_missing_remote_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final paths = ArchivePaths(root: temp);
    final repository = ConversationArchiveRepository(paths: paths);
    final screenController = ChatScreenController();
    final runtime = _WidgetConversationRuntime()
      ..activationError = const RuntimeConnectionException(
        '远程会话不存在或已被删除',
        code: 'session.not_found',
        recoverable: true,
      );
    await tester.runAsync(
      () => repository.saveConversation(
        ChatSession(
          sessionId: localExternalSessionId(
            'runtime',
            'missing-remote',
            characterId: 'reimu',
          ),
          title: 'Missing remotely',
          externalConnectionId: 'runtime',
          externalSessionId: 'missing-remote',
          externalCharacterId: 'reimu',
        ),
      ),
    );
    await tester.pumpWidget(
      HakureiTerminalApp(
        controller: screenController,
        archivePaths: paths,
        conversationRepository: repository,
        skipInitialLoad: true,
      ),
    );

    await tester.runAsync(() async {
      await screenController.attachRuntime(
        conversationController: RuntimeConversationController(runtime: runtime),
        connectionId: 'runtime',
        assistants: const <Assistant>[
          Assistant(
            id: 'gensokyoai_reimu',
            name: 'Reimu',
            providerId: AssistantProviderId.gensokyoAi,
            providerAssistantId: 'reimu',
          ),
        ],
        listSessions: () async => const <Map<String, dynamic>>[],
      );
      await screenController.reloadSessionsReadOnly();
      await screenController.selectSession(screenController.sessionIds.single);
    });

    expect(
      screenController.sessionMappingStatuses,
      const <ExternalMappingStatus>[ExternalMappingStatus.stale],
    );
    expect(screenController.currentError, contains('本地映射已标记为失效'));
    final persisted = await tester.runAsync(repository.listConversations);
    expect(
      persisted!.single.externalMappingStatus,
      ExternalMappingStatus.stale,
    );
  });

  testWidgets(
    'authoritative remote deletion becomes stale and blocks selection',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('hakurei_stale_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final paths = ArchivePaths(root: temp);
      final repository = ConversationArchiveRepository(paths: paths);
      final screenController = ChatScreenController();
      final runtime = _WidgetConversationRuntime();
      await tester.runAsync(
        () => repository.saveConversation(
          const ChatSession(
            sessionId: 'cached',
            title: 'Deleted remotely',
            externalConnectionId: 'runtime',
            externalSessionId: 'deleted',
            externalCharacterId: 'reimu',
            externalMappingStatus: ExternalMappingStatus.verified,
          ),
        ),
      );
      await tester.pumpWidget(
        HakureiTerminalApp(
          controller: screenController,
          archivePaths: paths,
          conversationRepository: repository,
          skipInitialLoad: true,
        ),
      );

      await tester.runAsync(() async {
        final conversationController = RuntimeConversationController(
          runtime: runtime,
        );
        await screenController.attachRuntime(
          conversationController: conversationController,
          connectionId: 'runtime',
          assistants: const <Assistant>[
            Assistant(
              id: 'gensokyoai_reimu',
              name: 'Reimu',
              providerId: AssistantProviderId.gensokyoAi,
              providerAssistantId: 'reimu',
            ),
          ],
          listSessions: () async => const <Map<String, dynamic>>[],
        );
        await conversationController.activate(
          characterId: 'reimu',
          sessionId: 'deleted',
        );
        runtime.activationRequests.clear();
        await screenController.reloadSessionsReadOnly();
        await screenController.selectSession(
          screenController.sessionIds.single,
        );
      });

      expect(
        screenController.sessionMappingStatuses,
        const <ExternalMappingStatus>[ExternalMappingStatus.stale],
      );
      expect(screenController.currentError, contains('重新验证'));
      expect(screenController.sendBlockerCodes, contains('mapping_stale'));
      expect(runtime.activationRequests, isEmpty);
    },
  );

  testWidgets('conflicting session selection is blocked during send', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('hakurei_send_lock_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final screenController = ChatScreenController();
    final runtime = _WidgetConversationRuntime();
    late RuntimeConversationController conversationController;

    await tester.pumpWidget(
      HakureiTerminalApp(
        controller: screenController,
        archivePaths: ArchivePaths(root: temp),
        skipInitialLoad: true,
      ),
    );
    await tester.runAsync(() async {
      conversationController = RuntimeConversationController(runtime: runtime);
      await screenController.attachRuntime(
        conversationController: conversationController,
        connectionId: 'runtime',
        assistants: const <Assistant>[
          Assistant(
            id: 'gensokyoai_reimu',
            name: 'Reimu',
            providerId: AssistantProviderId.gensokyoAi,
            providerAssistantId: 'reimu',
          ),
        ],
        listSessions: () async => _remoteSessions,
      );
      await conversationController.activate(
        characterId: 'reimu',
        sessionId: 'remote-1',
      );
      runtime.activationRequests.clear();
      await screenController.reloadSessionsReadOnly();
      runtime.activationRequests.clear();
    });
    final first = screenController.sessionIds.first;
    final second = screenController.sessionIds.last;
    await tester.runAsync(() => screenController.selectSession(first));

    late Future<void> send;
    await tester.runAsync(() async {
      send = screenController.sendMessage('hello');
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(
      conversationController.snapshot.phase,
      RuntimeConversationPhase.sending,
    );

    await tester.runAsync(() => screenController.selectSession(second));
    expect(screenController.selectedSessionId, first);
    expect(runtime.activationRequests, hasLength(1));

    runtime.completeSend();
    await tester.runAsync(() => send);
  });

  testWidgets(
    'send reconciliation refreshes session metadata once without activation',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'hakurei_metadata_refresh_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final screenController = ChatScreenController();
      final runtime = _WidgetConversationRuntime();
      var listCalls = 0;
      var returnUpdatedMetadata = false;
      final metadataListCalled = Completer<void>();

      await tester.pumpWidget(
        HakureiTerminalApp(
          controller: screenController,
          archivePaths: ArchivePaths(root: temp),
          skipInitialLoad: true,
        ),
      );
      late RuntimeConversationController conversationController;
      await tester.runAsync(() async {
        conversationController = RuntimeConversationController(
          runtime: runtime,
        );
        await screenController.attachRuntime(
          conversationController: conversationController,
          connectionId: 'runtime',
          assistants: const <Assistant>[
            Assistant(
              id: 'gensokyoai_reimu',
              name: 'Reimu',
              providerId: AssistantProviderId.gensokyoAi,
              providerAssistantId: 'reimu',
            ),
          ],
          listSessions: () {
            listCalls++;
            if (returnUpdatedMetadata && !metadataListCalled.isCompleted) {
              metadataListCalled.complete();
            }
            return Future.value(
              returnUpdatedMetadata
                  ? <Map<String, dynamic>>[
                      <String, dynamic>{
                        ..._remoteSessions.first,
                        'total_turns': 7,
                        'last_active': '2026-07-26T12:00:00Z',
                      },
                      _remoteSessions.last,
                    ]
                  : _remoteSessions,
            );
          },
        );
        await conversationController.activate(
          characterId: 'reimu',
          sessionId: 'remote-1',
        );
        await screenController.reloadSessionsReadOnly();
        await screenController.selectSession(
          localExternalSessionId('runtime', 'remote-1', characterId: 'reimu'),
        );
        runtime.activationRequests.clear();
        listCalls = 0;
        returnUpdatedMetadata = true;
        expect(screenController.selectedSessionId, isNotNull);
        expect(screenController.sendBlockerCodes, isEmpty);
        expect(
          conversationController.snapshot.phase,
          RuntimeConversationPhase.ready,
        );

        final send = conversationController.send('hello');
        await Future<void>.delayed(Duration.zero);
        expect(
          conversationController.snapshot.phase,
          RuntimeConversationPhase.sending,
        );
        runtime.historyMessages = <ChatMessage>[
          ChatMessage(
            id: 'user-1',
            role: ChatMessageRole.user,
            content: 'hello',
            createdAt: DateTime.utc(2026, 7, 26),
            conversationId: 'remote-1',
          ),
          ChatMessage(
            id: 'assistant-1',
            role: ChatMessageRole.assistant,
            content: 'completed',
            createdAt: DateTime.utc(2026, 7, 26),
            conversationId: 'remote-1',
          ),
        ];
        runtime.completeSend();
        await send.timeout(const Duration(seconds: 5));
        expect(screenController.sessionMetadataRefreshPending, isTrue);
      });
      await tester.pump();
      await tester.runAsync(
        () => metadataListCalled.future.timeout(const Duration(seconds: 5)),
      );
      await tester.pump();

      expect(listCalls, 1);
      expect(runtime.activationRequests, isEmpty);
      expect(screenController.selectedSessionId, isNotNull);
      expect(screenController.selectedSessionTotalTurns, 7);
      expect(screenController.currentMessageContents, <String>[
        'hello',
        'completed',
      ]);
    },
  );

  testWidgets('rapid stream reconciliation does not jump the chat to top', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('hakurei_scroll_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final screenController = ChatScreenController();
    final runtime = _WidgetConversationRuntime();
    runtime.historyMessages = List<ChatMessage>.generate(
      40,
      (index) => ChatMessage(
        id: 'history-$index',
        role: index.isEven ? ChatMessageRole.user : ChatMessageRole.assistant,
        content: 'History message $index ${'content ' * 8}',
        createdAt: DateTime.utc(2026, 7, 26, 0, index),
        conversationId: 'remote-1',
      ),
    );

    await tester.pumpWidget(
      HakureiTerminalApp(
        controller: screenController,
        archivePaths: ArchivePaths(root: temp),
        skipInitialLoad: true,
      ),
    );
    late RuntimeConversationController conversationController;
    await tester.runAsync(() async {
      conversationController = RuntimeConversationController(runtime: runtime);
      await screenController.attachRuntime(
        conversationController: conversationController,
        connectionId: 'runtime',
        assistants: const <Assistant>[
          Assistant(
            id: 'gensokyoai_reimu',
            name: 'Reimu',
            providerId: AssistantProviderId.gensokyoAi,
            providerAssistantId: 'reimu',
          ),
        ],
        listSessions: () async => _remoteSessions,
      );
      await conversationController.activate(
        characterId: 'reimu',
        sessionId: 'remote-1',
      );
      await screenController.reloadSessionsReadOnly();
      await screenController.selectSession(
        localExternalSessionId('runtime', 'remote-1', characterId: 'reimu'),
      );
    });
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(
        const ValueKey<String>(
          'messageList:external_cnVudGltZQ_cmVpbXU_cmVtb3RlLTE',
        ),
      ),
      const Offset(0, -10000),
    );
    await tester.pumpAndSettle();
    expect(screenController.messageScrollOffset, greaterThan(0));

    late Future<void> send;
    await tester.runAsync(() async {
      send = conversationController.send('hello');
      await Future<void>.delayed(Duration.zero);
      runtime.emitDelta('one ');
      runtime.emitDelta('two ');
      runtime.emitDelta('three');
      runtime.historyMessages = <ChatMessage>[
        ...runtime.historyMessages,
        ChatMessage(
          id: 'server-user',
          role: ChatMessageRole.user,
          content: 'hello',
          createdAt: DateTime.utc(2026, 7, 26, 1),
          conversationId: 'remote-1',
        ),
        ChatMessage(
          id: 'server-assistant',
          role: ChatMessageRole.assistant,
          content: 'completed',
          createdAt: DateTime.utc(2026, 7, 26, 1, 1),
          conversationId: 'remote-1',
        ),
      ];
      runtime.completeSend();
      await send;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(screenController.messageScrollOffset, greaterThan(0));
    expect(
      screenController.messageScrollOffset,
      closeTo(screenController.messageScrollMaxExtent!, 1),
    );
  });

  testWidgets('stream timeout banner does not jump the chat to top', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('hakurei_timeout_scroll_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final screenController = ChatScreenController();
    final runtime = _WidgetConversationRuntime();
    runtime.historyMessages = List<ChatMessage>.generate(
      40,
      (index) => ChatMessage(
        id: 'timeout-history-$index',
        role: index.isEven ? ChatMessageRole.user : ChatMessageRole.assistant,
        content: 'History message $index ${'content ' * 8}',
        createdAt: DateTime.utc(2026, 7, 26, 0, index),
        conversationId: 'remote-1',
      ),
    );

    await tester.pumpWidget(
      HakureiTerminalApp(
        controller: screenController,
        archivePaths: ArchivePaths(root: temp),
        skipInitialLoad: true,
      ),
    );
    await tester.runAsync(() async {
      final conversationController = RuntimeConversationController(
        runtime: runtime,
      );
      await screenController.attachRuntime(
        conversationController: conversationController,
        connectionId: 'runtime',
        assistants: const <Assistant>[
          Assistant(
            id: 'gensokyoai_reimu',
            name: 'Reimu',
            providerId: AssistantProviderId.gensokyoAi,
            providerAssistantId: 'reimu',
          ),
        ],
        listSessions: () async => _remoteSessions,
      );
      await conversationController.activate(
        characterId: 'reimu',
        sessionId: 'remote-1',
      );
      await screenController.reloadSessionsReadOnly();
      await screenController.selectSession(
        localExternalSessionId('runtime', 'remote-1', characterId: 'reimu'),
      );
    });
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(
        const ValueKey<String>(
          'messageList:external_cnVudGltZQ_cmVpbXU_cmVtb3RlLTE',
        ),
      ),
      const Offset(0, -10000),
    );
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      final send = screenController.sendMessage('hello');
      await Future<void>.delayed(Duration.zero);
      runtime.emitDelta('partial');
      runtime.failSend(
        message: 'Runtime 响应超时，请稍后重新发送',
        code: 'agent.stream.timeout',
      );
      await send;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(screenController.currentError, contains('Runtime 响应超时'));
    expect(screenController.messageScrollOffset, greaterThan(0));
    expect(
      screenController.messageScrollOffset,
      closeTo(screenController.messageScrollMaxExtent!, 1),
    );
  });

  testWidgets('first sync-pending banner preserves the bottom position', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('hakurei_sync_scroll_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final screenController = ChatScreenController();
    final runtime = _WidgetConversationRuntime();
    final baseline = List<ChatMessage>.generate(
      40,
      (index) => ChatMessage(
        id: 'sync-history-$index',
        role: index.isEven ? ChatMessageRole.user : ChatMessageRole.assistant,
        content: 'History message $index ${'content ' * 8}',
        createdAt: DateTime.utc(2026, 7, 26, 0, index),
        conversationId: 'remote-1',
      ),
    );
    runtime.historyMessages = baseline;

    await tester.pumpWidget(
      HakureiTerminalApp(
        controller: screenController,
        archivePaths: ArchivePaths(root: temp),
        skipInitialLoad: true,
      ),
    );
    await tester.runAsync(() async {
      final conversationController = RuntimeConversationController(
        runtime: runtime,
      );
      await screenController.attachRuntime(
        conversationController: conversationController,
        connectionId: 'runtime',
        assistants: const <Assistant>[
          Assistant(
            id: 'gensokyoai_reimu',
            name: 'Reimu',
            providerId: AssistantProviderId.gensokyoAi,
            providerAssistantId: 'reimu',
          ),
        ],
        listSessions: () async => _remoteSessions,
      );
      await conversationController.activate(
        characterId: 'reimu',
        sessionId: 'remote-1',
      );
      await screenController.reloadSessionsReadOnly();
      await screenController.selectSession(
        localExternalSessionId('runtime', 'remote-1', characterId: 'reimu'),
      );
    });
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(
        const ValueKey<String>(
          'messageList:external_cnVudGltZQ_cmVpbXU_cmVtb3RlLTE',
        ),
      ),
      const Offset(0, -10000),
    );
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      final send = screenController.sendMessage('hello');
      await Future<void>.delayed(Duration.zero);
      runtime.historyMessages = baseline;
      runtime.completeSend();
      await send;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey<String>('conversationSyncBanner')),
      findsOneWidget,
    );
    expect(screenController.messageScrollOffset, greaterThan(0));
    expect(
      screenController.messageScrollOffset,
      closeTo(screenController.messageScrollMaxExtent!, 1),
    );
  });

  test('local drafts are non-executable and draft CRUD is offline', () async {
    final temp = Directory.systemTemp.createTempSync('hakurei_draft_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final repository = AssistantArchiveRepository(
      paths: ArchivePaths(root: temp),
    );
    const draft = Assistant(
      id: 'draft_reimu',
      name: 'Reimu draft',
      description: 'local authoring only',
      defaultThinkingEngineId: '',
      defaultBackendId: '',
      metadata: <String, dynamic>{'executable': false},
    );

    await repository.saveAssistant(draft);
    final restored = await repository.getAssistant(draft.id);
    await repository.deleteAssistant(draft.id);

    expect(restored?.defaultBackendId, isEmpty);
    expect(restored?.metadata['executable'], isFalse);
    expect(await repository.listAssistants(), isEmpty);
  });

  test('new assistants have inert execution defaults', () {
    const assistant = Assistant(id: 'draft', name: 'Draft');

    expect(assistant.providerId, AssistantProviderId.unknown);
    expect(assistant.defaultThinkingEngineId, isEmpty);
    expect(assistant.defaultBackendId, isEmpty);
    expect(
      AssistantProviderId.fromValue('unsupported'),
      AssistantProviderId.unknown,
    );
  });

  testWidgets('draft management keeps package upload disconnected', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('hakurei_settings_');
    addTearDown(() => temp.deleteSync(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaultSettings,
          initialPage: SettingsInitialPage.assistantManagement,
          assistantRepository: AssistantArchiveRepository(
            paths: ArchivePaths(root: temp),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('新建角色草稿'), findsOneWidget);
    expect(find.text('上传 GensokyoAI 角色包'), findsOneWidget);
    expect(find.textContaining('连接 Runtime 后'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey<String>('uploadCharacterPackageButton')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('storage settings expose structured log management', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('hakurei_logs_ui_');
    addTearDown(() => temp.deleteSync(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaultSettings,
          initialPage: SettingsInitialPage.storage,
          assistantRepository: AssistantArchiveRepository(
            paths: ArchivePaths(root: temp),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.scrollUntilVisible(
      find.text('日志管理'),
      500,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey<String>('storageSettingsPage')),
            matching: find.byType(Scrollable),
          )
          .first,
    );

    expect(find.text('日志管理'), findsOneWidget);
    expect(find.text('导出诊断日志'), findsOneWidget);
    expect(find.textContaining('日志采用 JSON Lines'), findsOneWidget);
    expect(find.textContaining('最多保留 5 个文件'), findsOneWidget);
    expect(find.textContaining('不包含设置、凭据、消息正文或模型输入'), findsOneWidget);
  });

  testWidgets('GensokyoAI settings expose 2.2 initiative and memory add', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('hakurei_settings_v22_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final runtime = _InteractiveExternalAgentRuntime();
    const connection = ExternalRuntimeConnectionSettings(
      id: 'runtime-v22',
      agentId: 'agent-v22',
      displayName: 'Runtime 2.2',
      baseUrl: 'http://127.0.0.1:8765',
    );
    final settings = AppSettings.defaultSettings.copyWith(
      externalRuntimeConnections: const <ExternalRuntimeConnectionSettings>[
        connection,
      ],
      selectedExternalRuntimeConnectionId: connection.id,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: settings,
          initialPage: SettingsInitialPage.gensokyoAi,
          externalAgentRuntime: runtime,
          assistantRepository: AssistantArchiveRepository(
            paths: ArchivePaths(root: temp),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('犹豫'), findsNothing);
    final initiativeToggle = find.byKey(
      const ValueKey<String>('gensokyoAiInitiativeToggle'),
    );
    final settingsList = find.byKey(
      const ValueKey<String>('gensokyoAiSettingsPage'),
    );
    while (initiativeToggle.evaluate().isEmpty) {
      await tester.drag(settingsList, const Offset(0, -500));
      await tester.pump();
    }
    expect(initiativeToggle, findsOneWidget);
    final addButton = find.byKey(
      const ValueKey<String>('gensokyoAiAddMemoryButton'),
    );
    while (addButton.evaluate().isEmpty) {
      await tester.drag(settingsList, const Offset(0, -500));
      await tester.pump();
    }
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('gensokyoAiMemoryContentField')),
      '用户喜欢喝茶',
    );
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();

    expect(runtime.addedMemory, '用户喜欢喝茶');
  });

  testWidgets(
    'disabled optional scenes do not mark Runtime status unavailable',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'hakurei_settings_scene_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialSettings: AppSettings.defaultSettings,
            initialPage: SettingsInitialPage.gensokyoAi,
            externalAgentRuntime: _SceneDisabledExternalAgentRuntime(),
            assistantRepository: AssistantArchiveRepository(
              paths: ArchivePaths(root: temp),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('部分状态不可用'), findsNothing);
      final settingsList = find.byKey(
        const ValueKey<String>('gensokyoAiSettingsPage'),
      );
      final sceneUnavailable = find.text('场景系统当前不可用');
      for (
        var attempt = 0;
        attempt < 10 && sceneUnavailable.evaluate().isEmpty;
        attempt += 1
      ) {
        await tester.drag(settingsList, const Offset(0, -500));
        await tester.pump();
      }
      expect(sceneUnavailable, findsOneWidget);
    },
  );

  testWidgets(
    'backend settings surface the Agent v2 identity and verification state',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'hakurei_agent_identity_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      const connection = ExternalRuntimeConnectionSettings(
        id: 'runtime-main',
        agentId: '12345678-1234-4abc-8def-1234567890ab',
        displayName: '本地 Runtime',
        baseUrl: 'http://127.0.0.1:8787',
        lastVerifiedAt: null,
      );
      final verified = connection.copyWith(
        lastVerifiedAt: DateTime.utc(2026, 7, 30),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialSettings: AppSettings.defaultSettings.copyWith(
              externalRuntimeConnections: <ExternalRuntimeConnectionSettings>[
                verified,
              ],
            ),
            initialPage: SettingsInitialPage.backend,
            assistantRepository: AssistantArchiveRepository(
              paths: ArchivePaths(root: temp),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      final summary = find.byKey(
        const ValueKey<String>('externalRuntimeAgentSummary:runtime-main'),
      );
      expect(summary, findsOneWidget);
      expect(
        find.descendant(of: summary, matching: find.textContaining('Agent v2')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: summary,
          matching: find.textContaining('Agent ID 12345678'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: summary, matching: find.textContaining('已验证')),
        findsOneWidget,
      );
    },
  );

  testWidgets('Runtime connection actions target their own saved profile', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync(
      'hakurei_runtime_profiles_',
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    const first = ExternalRuntimeConnectionSettings(
      id: 'runtime-a',
      agentId: 'agent-a',
      displayName: 'Runtime A',
      baseUrl: 'http://127.0.0.1:8787',
      lastVerifiedAt: null,
    );
    const second = ExternalRuntimeConnectionSettings(
      id: 'runtime-b',
      agentId: 'agent-b',
      displayName: 'Runtime B',
      baseUrl: 'http://127.0.0.1:8788',
      lastVerifiedAt: null,
    );
    final activatedIds = <String>[];
    final savedSelections = <String>[];
    var disconnectCount = 0;
    final paths = ArchivePaths(root: temp);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaultSettings.copyWith(
            externalRuntimeConnections:
                const <ExternalRuntimeConnectionSettings>[first, second],
            selectedExternalRuntimeConnectionId: second.id,
          ),
          initialPage: SettingsInitialPage.backend,
          assistantRepository: AssistantArchiveRepository(paths: paths),
          conversationRepository: ConversationArchiveRepository(paths: paths),
          onOperation: (operation) async {
            final settings = operation.settings;
            if (settings != null) {
              savedSelections.add(settings.selectedExternalRuntimeConnectionId);
            }
          },
          onActivateExternalRuntime: (settings, connectionId) async {
            activatedIds.add(connectionId);
            return _CountingExternalAgentRuntime();
          },
          onDeactivateExternalRuntime: () async {
            disconnectCount++;
          },
        ),
      ),
    );
    await tester.pump();

    final connectFirst = find.byKey(
      const ValueKey<String>('connectExternalRuntime:runtime-a'),
    );
    await tester.ensureVisible(connectFirst);
    await tester.tap(connectFirst);
    await tester.pumpAndSettle();

    expect(activatedIds, <String>['runtime-a']);
    expect(savedSelections.last, 'runtime-a');
    expect(find.text('已连接：Runtime A'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('disconnectExternalRuntime:runtime-a')),
      findsOneWidget,
    );

    final selectSecond = find.byKey(
      const ValueKey<String>('selectExternalRuntime:runtime-b'),
    );
    await tester.ensureVisible(selectSecond);
    await tester.tap(selectSecond);
    await tester.pumpAndSettle();

    expect(activatedIds, <String>['runtime-a']);
    expect(savedSelections.last, 'runtime-b');
    expect(disconnectCount, 0);
    expect(find.text('已连接：Runtime A'), findsOneWidget);

    final connectSecond = find.byKey(
      const ValueKey<String>('connectExternalRuntime:runtime-b'),
    );
    await tester.ensureVisible(connectSecond);
    await tester.tap(connectSecond);
    await tester.pumpAndSettle();

    expect(activatedIds, <String>['runtime-a', 'runtime-b']);
    expect(find.text('已连接：Runtime B'), findsOneWidget);
  });

  testWidgets('Runtime connection management fits a compact viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = Directory.systemTemp.createTempSync(
      'hakurei_runtime_compact_',
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    final paths = ArchivePaths(root: temp);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaultSettings.copyWith(
            externalRuntimeConnections:
                const <ExternalRuntimeConnectionSettings>[
                  ExternalRuntimeConnectionSettings(
                    id: 'compact-a',
                    agentId: 'agent-compact-a',
                    displayName: 'A Runtime With A Longer Display Name',
                    baseUrl: 'http://127.0.0.1:8787',
                  ),
                  ExternalRuntimeConnectionSettings(
                    id: 'compact-b',
                    agentId: 'agent-compact-b',
                    displayName: 'Runtime B',
                    baseUrl: 'http://127.0.0.1:8788',
                  ),
                ],
          ),
          initialPage: SettingsInitialPage.backend,
          assistantRepository: AssistantArchiveRepository(paths: paths),
          conversationRepository: ConversationArchiveRepository(paths: paths),
        ),
      ),
    );
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('connectExternalRuntime:compact-b')),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('Provider models load only after an explicit refresh', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = Directory.systemTemp.createTempSync(
      'hakurei_provider_models_',
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    final paths = ArchivePaths(root: temp);
    final catalog = _FakeProviderModelCatalog(
      models: const <ProviderModelCatalogEntry>[
        ProviderModelCatalogEntry(id: 'model-b', name: 'Model B'),
        ProviderModelCatalogEntry(id: 'model-a', name: 'Model A'),
      ],
    );
    const profile = ModelProfile(
      id: 'default',
      name: 'Provider Profile',
      model: ModelServiceSettings(
        provider: 'openai',
        model: 'manual-model',
        baseUrl: 'https://provider.example/v1',
        apiKey: 'provider-token',
      ),
      embedding: EmbeddingServiceSettings(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaultSettings.copyWith(
            profiles: const <ModelProfile>[profile],
          ),
          initialPage: SettingsInitialPage.modelProvider,
          assistantRepository: AssistantArchiveRepository(paths: paths),
          conversationRepository: ConversationArchiveRepository(paths: paths),
          providerModelCatalog: catalog,
        ),
      ),
    );
    await tester.pump();

    expect(catalog.calls, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('providerModelManualField')),
      findsOneWidget,
    );

    final fetchButton = find.byKey(
      const ValueKey<String>('fetchProviderModels'),
    );
    await tester.drag(
      find.byKey(const ValueKey<String>('modelSettingsList')),
      const Offset(0, -500),
    );
    await tester.pump();
    expect(tester.widget<IconButton>(fetchButton).onPressed, isNotNull);
    await tester.tap(fetchButton);
    await tester.pumpAndSettle();

    expect(catalog.calls, hasLength(1));
    expect(catalog.calls.single.provider, 'openai');
    expect(catalog.calls.single.baseUrl, 'https://provider.example/v1');
    expect(catalog.calls.single.apiKey, 'provider-token');
    expect(
      find.byKey(const ValueKey<String>('providerModelDropdown')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('providerModelsCount')),
      findsOneWidget,
    );

    final dropdown = find.byKey(
      const ValueKey<String>('providerModelDropdown'),
    );
    final editable = find.descendant(
      of: dropdown,
      matching: find.byType(EditableText),
    );
    expect(
      tester.widget<EditableText>(editable).controller.text,
      'manual-model',
    );

    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('model-b · Model B').last);
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(editable).controller.text, 'model-b');

    await tester.enterText(
      find.byKey(const ValueKey<String>('providerBaseUrlField')),
      'https://other-provider.example/v1',
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('providerModelDropdown')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('providerModelManualField')),
      findsOneWidget,
    );
    expect(catalog.calls, hasLength(1));
  });

  testWidgets('message bubble separates reasoning tools and image parts', (
    tester,
  ) async {
    final imageData = base64Encode(<int>[
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubbleTestHost(
            assistantName: 'Reimu',
            message: ChatMessage(
              id: 'structured',
              role: ChatMessageRole.assistant,
              content: 'visible answer',
              reasoningContent: 'hidden reasoning',
              contentParts: <ChatContentPart>[
                const ChatContentPart(
                  type: 'text',
                  data: <String, dynamic>{
                    'type': 'text',
                    'text': 'visible answer',
                  },
                ),
                ChatContentPart(
                  type: 'image',
                  data: <String, dynamic>{
                    'type': 'image',
                    'image': <String, dynamic>{'data': imageData},
                  },
                ),
              ],
              toolCalls: const <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'call-1',
                  'function': <String, dynamic>{
                    'name': 'lookup',
                    'arguments': '{"query":"value"}',
                  },
                },
              ],
              createdAt: DateTime.utc(2026),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('messageReasoningSection')),
      findsOneWidget,
    );
    expect(find.text('hidden reasoning'), findsNothing);
    expect(find.text('visible answer'), findsOneWidget);
    expect(find.text('lookup'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('runtimeMessageImage')),
      findsOneWidget,
    );

    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(find.text('hidden reasoning'), findsOneWidget);
  });

  testWidgets('cancelling Runtime connection dialog is lifecycle safe', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('hakurei_runtime_dialog_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final paths = ArchivePaths(root: temp);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaultSettings,
          initialPage: SettingsInitialPage.backend,
          assistantRepository: AssistantArchiveRepository(paths: paths),
          conversationRepository: ConversationArchiveRepository(paths: paths),
        ),
      ),
    );
    await tester.pump();

    final addButton = find.byKey(
      const ValueKey<String>('addExternalRuntimeConnection'),
    );
    tester.widget<OutlinedButton>(addButton).onPressed!.call();
    await tester.pumpAndSettle();
    final urlField = find.byKey(
      const ValueKey<String>('externalRuntimeUrlField'),
    );
    await tester.tap(urlField);
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('添加 GensokyoAI 连接'), findsOneWidget);
    expect(urlField, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Runtime connection dialog explains HTTP and WebSocket URLs', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync(
      'hakurei_runtime_url_help_',
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    final paths = ArchivePaths(root: temp);
    final logger = _RecordingAppLogger();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaultSettings,
          initialPage: SettingsInitialPage.backend,
          assistantRepository: AssistantArchiveRepository(paths: paths),
          conversationRepository: ConversationArchiveRepository(paths: paths),
          logger: logger,
        ),
      ),
    );
    await tester.pump();
    tester
        .widget<OutlinedButton>(
          find.byKey(const ValueKey<String>('addExternalRuntimeConnection')),
        )
        .onPressed!
        .call();
    await tester.pumpAndSettle();

    final urlField = find.byKey(
      const ValueKey<String>('externalRuntimeUrlField'),
    );
    expect(find.text('Runtime 根地址（HTTP/HTTPS）'), findsOneWidget);
    expect(find.textContaining('不要填写 ws://、wss://'), findsOneWidget);
    expect(find.text('WebSocket 地址会由客户端自动生成。'), findsOneWidget);

    await tester.enterText(urlField, 'wss://127.0.0.1:8765');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();

    expect(
      find.text('请填写 HTTP/HTTPS 根地址，不要填写 ws:// 或 wss://。'),
      findsOneWidget,
    );
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.enterText(urlField, 'http://127.0.0.1:8765');
    await tester.pump();

    expect(find.text('WebSocket 将自动连接：ws://127.0.0.1:8765/ws'), findsOneWidget);
    expect(find.text('请填写 HTTP/HTTPS 根地址，不要填写 ws:// 或 wss://。'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final logText = jsonEncode(logger.events);
    expect(logText, contains('runtime.connection_profile.validation_rejected'));
    expect(logText, contains('runtime.connection_profile.validated'));
    expect(logText, isNot(contains('wss://127.0.0.1:8765')));
  });

  testWidgets('settings session management loads read-only Runtime state', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync(
      'hakurei_settings_sessions_',
    );
    final runtime = _CountingExternalAgentRuntime();
    addTearDown(() => temp.deleteSync(recursive: true));
    final paths = ArchivePaths(root: temp);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaultSettings,
          initialPage: SettingsInitialPage.gensokyoAi,
          externalAgentRuntime: runtime,
          assistantRepository: AssistantArchiveRepository(paths: paths),
          conversationRepository: ConversationArchiveRepository(paths: paths),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(runtime.readMethods, <String>[
      'runtimeInfo',
      'health',
      'externalToolStatus',
      'listSessions',
    ]);
    expect(runtime.mutationCount, 0);
    expect(
      find.byKey(const ValueKey<String>('gensokyoAiSessionActivationGuidance')),
      findsOneWidget,
    );
    expect(find.text('恢复到聊天'), findsNothing);
    expect(find.textContaining('通过明确的会话选择流程'), findsOneWidget);
  });

  test('settings notice combines completed archive operations', () {
    expect(
      formatSettingsOperationNotice(
        saved: true,
        reloadedAssistants: true,
        reloadedSessions: true,
      ),
      '已保存并重载角色和会话',
    );
  });

  test(
    'archive import saves locally before disconnect and never reloads',
    () async {
      final localSaveCompleter = Completer<void>();
      final callbacks = <String>[];
      SettingsOperation? operation;

      final import = applyArchiveImportOperation(
        settings: AppSettings.defaultSettings,
        disconnectLiveRuntime: true,
        dispatch: (value) async {
          operation = value;
          callbacks.add('local-save');
          await localSaveCompleter.future;
        },
        disconnect: () async => callbacks.add('disconnect'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(operation?.activateExternalRuntime, isFalse);
      expect(operation?.deactivateExternalRuntime, isFalse);
      expect(operation?.reloadAssistants, isFalse);
      expect(operation?.reloadSessions, isFalse);
      expect(callbacks, <String>['local-save']);

      localSaveCompleter.complete();
      await import;

      expect(callbacks, <String>['local-save', 'disconnect']);
    },
  );
}

const List<Map<String, dynamic>> _remoteSessions = <Map<String, dynamic>>[
  <String, dynamic>{
    'session_id': 'remote-1',
    'character_id': 'reimu',
    'title': 'First',
  },
  <String, dynamic>{
    'session_id': 'remote-2',
    'character_id': 'reimu',
    'title': 'Second',
  },
];

class _FakeProviderModelCatalog implements ProviderModelCatalog {
  _FakeProviderModelCatalog({required this.models});

  final List<ProviderModelCatalogEntry> models;
  final List<
    ({
      String provider,
      String baseUrl,
      String apiKey,
      Duration timeout,
      bool useProxy,
    })
  >
  calls =
      <
        ({
          String provider,
          String baseUrl,
          String apiKey,
          Duration timeout,
          bool useProxy,
        })
      >[];

  @override
  Future<List<ProviderModelCatalogEntry>> listModels({
    required String provider,
    required String baseUrl,
    required String apiKey,
    Duration timeout = const Duration(seconds: 30),
    bool useProxy = false,
  }) async {
    calls.add((
      provider: provider,
      baseUrl: baseUrl,
      apiKey: apiKey,
      timeout: timeout,
      useProxy: useProxy,
    ));
    return models;
  }
}

class _WidgetConversationRuntime implements ConversationRuntime {
  final List<(String, String?, bool)> activationRequests =
      <(String, String?, bool)>[];
  StreamController<RuntimeStreamEvent>? _send;
  List<ChatMessage> historyMessages = const <ChatMessage>[];
  Object? activationError;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<RuntimeConversationActivation> activate({
    required String characterId,
    String? sessionId,
    bool newSession = false,
  }) async {
    activationRequests.add((characterId, sessionId, newSession));
    final error = activationError;
    if (error != null) {
      throw error;
    }
    return RuntimeConversationActivation(sessionId: sessionId ?? 'remote-new');
  }

  @override
  Future<List<ChatMessage>> history(String sessionId) async => historyMessages;

  @override
  Stream<RuntimeStreamEvent> send({
    required String sessionId,
    required String characterId,
    required String input,
  }) {
    _send = StreamController<RuntimeStreamEvent>();
    return _send!.stream;
  }

  void completeSend() {
    _send!.add(
      const RuntimeStreamCompleted(RuntimeReply(content: 'completed')),
    );
    unawaited(_send!.close());
  }

  void emitDelta(String content) {
    _send!.add(RuntimeStreamDelta(content));
  }

  void failSend({required String message, required String code}) {
    _send!.add(
      RuntimeStreamFailed(
        message: message,
        partialContent: 'partial',
        metadata: <String, dynamic>{'code': code},
      ),
    );
  }
}

class _CountingExternalAgentRuntime implements ExternalAgentRuntime {
  final List<String> readMethods = <String>[];
  int mutationCount = 0;

  @override
  Stream<ExternalRuntimeEvent> get events =>
      const Stream<ExternalRuntimeEvent>.empty();

  @override
  Future<Map<String, dynamic>> runtimeInfo() async {
    readMethods.add('runtimeInfo');
    return const <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> health() async {
    readMethods.add('health');
    return const <String, dynamic>{'initialized': false};
  }

  @override
  Future<Map<String, dynamic>> externalToolStatus({
    bool includeTools = true,
  }) async {
    readMethods.add('externalToolStatus');
    return const <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> listSessions() async {
    readMethods.add('listSessions');
    return const <Map<String, dynamic>>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    mutationCount++;
    return super.noSuchMethod(invocation);
  }
}

class _InteractiveExternalAgentRuntime extends _CountingExternalAgentRuntime {
  String? addedMemory;

  @override
  Future<Map<String, dynamic>> health() async => const <String, dynamic>{
    'initialized': true,
  };

  @override
  Future<Map<String, dynamic>> currentSession() async =>
      const <String, dynamic>{'session_id': 'session-v22'};

  @override
  Future<Map<String, dynamic>> currentInitiativeTimer() async =>
      const <String, dynamic>{};

  @override
  Future<List<Map<String, dynamic>>> listMemory({
    String? topicName,
    int limit = 50,
    int offset = 0,
  }) async => const <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> listScenes() async =>
      const <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> currentScene() async =>
      const <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> addMemory(
    String content, {
    String? topicName,
    double importance = 0,
    double emotionalValence = 0,
  }) async {
    addedMemory = content;
    return const <String, dynamic>{'added': true};
  }
}

class _SceneDisabledExternalAgentRuntime
    extends _InteractiveExternalAgentRuntime {
  @override
  Future<List<Map<String, dynamic>>> listScenes() async {
    throw StateError('Scene system is not enabled');
  }

  @override
  Future<Map<String, dynamic>> currentScene() async {
    throw StateError('Scene system is not enabled');
  }
}

class _RecordingAppLogger extends AppLogger {
  final List<Map<String, Object?>> events = <Map<String, Object?>>[];

  @override
  void info(
    String event, {
    required String component,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    events.add(<String, Object?>{
      'level': 'info',
      'event': event,
      'component': component,
      'data': data,
    });
  }

  @override
  void warning(
    String event, {
    required String component,
    Map<String, Object?> data = const <String, Object?>{},
    Object? error,
  }) {
    events.add(<String, Object?>{
      'level': 'warning',
      'event': event,
      'component': component,
      'data': data,
    });
  }
}

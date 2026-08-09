import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;
import 'dart:ui' as ui show instantiateImageCodec;

import 'package:file_selector/file_selector.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/app_settings.dart';
import 'models/assistant.dart';
import 'models/avatar_transform.dart';
import 'models/chat_message.dart';
import 'models/chat_session.dart';
import 'models/runtime_capabilities.dart';
import 'repositories/archive_repositories.dart';
import 'repositories/media_repository.dart';
import 'screens/settings_screen.dart';
import 'services/runtime/assistant_provider_adapters.dart';
import 'services/runtime/external_runtime_event.dart';
import 'services/runtime/external_agent_runtime.dart';
import 'services/runtime/gensokyoai_conversation_runtime.dart';
import 'services/runtime/http_runtime_client.dart';
import 'services/runtime/runtime_connection.dart';
import 'services/runtime/runtime_conversation_controller.dart';
import 'services/settings_store.dart';
import 'services/tts_service.dart';
import 'theme/app_theme.dart';
import 'widgets/text_context_menu.dart';
import 'widgets/top_notice.dart';
import 'widgets/app_background.dart';
import 'widgets/avatar_editor_dialog.dart';
import 'widgets/avatar_image.dart';
import 'widgets/markdown_message.dart';

@visibleForTesting
bool isNearScrollBottom({
  required double pixels,
  required double maxScrollExtent,
  double threshold = 80,
}) => maxScrollExtent - pixels <= threshold;

@visibleForTesting
bool shouldClearTtsMessage({required PlayerState state, required bool busy}) =>
    !busy && (state == PlayerState.completed || state == PlayerState.stopped);

@visibleForTesting
String? formatSettingsOperationNotice({
  required bool saved,
  required bool reloadedAssistants,
  required bool reloadedSessions,
}) {
  if (!saved && !reloadedAssistants && !reloadedSessions) {
    return null;
  }
  final reloaded = switch ((reloadedAssistants, reloadedSessions)) {
    (true, true) => '重载角色和会话',
    (true, false) => '重载角色',
    (false, true) => '重载会话',
    (false, false) => '',
  };
  if (saved && reloaded.isNotEmpty) {
    return '已保存并$reloaded';
  }
  return saved ? '已保存' : '已$reloaded';
}

@visibleForTesting
Assistant? resolveGensokyoAiSessionAssistant(
  String remoteCharacterId,
  Iterable<Assistant> assistants,
) {
  final value = remoteCharacterId.trim();
  if (value.isEmpty) {
    return null;
  }
  return assistants
      .where(
        (assistant) =>
            assistant.providerId == AssistantProviderId.gensokyoAi &&
            (assistant.providerAssistantId == value || assistant.name == value),
      )
      .firstOrNull;
}

@visibleForTesting
String sessionTitleFromRemoteJson(Map<String, dynamic> json) {
  final topLevel = json['title']?.toString().trim() ?? '';
  if (topLevel.isNotEmpty) {
    return topLevel;
  }
  final metadata = json['metadata'];
  if (metadata is Map) {
    final nested = metadata['title']?.toString().trim() ?? '';
    if (nested.isNotEmpty) {
      return nested;
    }
  }
  return 'GensokyoAI 会话';
}

@visibleForTesting
List<ChatMessage> upsertDisplayMessage(
  Iterable<ChatMessage> messages,
  ChatMessage message,
) {
  final updated = List<ChatMessage>.of(messages);
  final index = updated.indexWhere((item) => item.id == message.id);
  if (index < 0) {
    updated.add(message);
  } else {
    updated[index] = message;
  }
  return updated;
}

@visibleForTesting
List<ChatSession> mergeRemoteSessionMappings(
  Iterable<ChatSession> cached,
  Iterable<ChatSession> remote, {
  required String activeCharacterId,
}) {
  ChatSession normalized(ChatSession session) {
    if (session.externalConnectionId.isEmpty ||
        session.externalSessionId.isEmpty) {
      return session;
    }
    return session.copyWith(
      sessionId: localExternalSessionId(
        session.externalConnectionId,
        session.externalSessionId,
        characterId: session.externalCharacterId,
      ),
    );
  }

  final merged = <String, ChatSession>{};
  for (final session in cached) {
    final value = normalized(
      session.copyWith(
        externalMappingStatus: session.externalCharacterId == activeCharacterId
            ? ExternalMappingStatus.stale
            : ExternalMappingStatus.unverified,
      ),
    );
    merged[value.sessionId] = value;
  }
  for (final item in remote) {
    final session = normalized(
      item.copyWith(
        externalMappingStatus: item.externalCharacterId == activeCharacterId
            ? ExternalMappingStatus.verified
            : ExternalMappingStatus.unverified,
      ),
    );
    final previous = merged[session.sessionId];
    merged[session.sessionId] = previous == null
        ? session
        : session.copyWith(
            backgroundImagePath: previous.backgroundImagePath,
            avatarImagePath: previous.avatarImagePath,
            avatarTransform: previous.avatarTransform,
            listOrder: previous.listOrder,
          );
  }
  return merged.values.toList(growable: false);
}

@visibleForTesting
String localExternalSessionId(
  String connectionId,
  String remoteSessionId, {
  String characterId = '',
}) {
  String encode(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');
  final character = characterId.isEmpty ? '' : '${encode(characterId)}_';
  return 'external_${encode(connectionId)}_$character${encode(remoteSessionId)}';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final archivePaths = await ArchivePaths.createDefault();
  Brightness? platformBrightness;
  try {
    platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
  } catch (_) {
    platformBrightness = null;
  }
  final initialSettings = AppSettings.defaultSettings.copyWith(
    appearance: AppSettings.defaultSettings.appearance.copyWith(
      themeId: defaultThemeIdForPlatformBrightness(platformBrightness),
    ),
  );
  runApp(
    HakureiTerminalApp(
      archivePaths: archivePaths,
      settingsStore: SettingsStore(defaultSettings: initialSettings),
      initialSettings: initialSettings,
    ),
  );
}

/// 窗口宽度档位：决定两侧面板的默认呈现形态。
enum _PaneLayout { compact, medium, expanded }

@visibleForTesting
class ChatScreenController {
  _ChatScreenState? _state;

  bool get isAttached => _state != null;
  String? get selectedSessionId => _state?._selectedSession?.sessionId;

  @visibleForTesting
  String? get currentError => _state?._error;

  @visibleForTesting
  String? get sessionListError => _state?._sessionListError;

  @visibleForTesting
  bool get isSending => _state?._sending ?? false;

  @visibleForTesting
  bool get sessionsLoaded => _state?._sessionsLoaded ?? false;

  @visibleForTesting
  List<String> get sessionIds =>
      _state?._sessions.map((session) => session.sessionId).toList() ??
      const <String>[];

  @visibleForTesting
  List<ExternalMappingStatus> get sessionMappingStatuses =>
      _state?._sessions
          .map((session) => session.externalMappingStatus)
          .toList() ??
      const <ExternalMappingStatus>[];

  @visibleForTesting
  int? get selectedSessionTotalTurns => _state?._selectedSession?.totalTurns;

  @visibleForTesting
  List<String> get currentMessageContents =>
      _state?._currentMessages.map((message) => message.content).toList() ??
      const <String>[];

  @visibleForTesting
  bool get sessionMetadataRefreshPending =>
      _state?._sessionMetadataRefreshToken != null;

  @visibleForTesting
  double? get messageScrollOffset =>
      _state?._scrollController.hasClients == true
      ? _state!._scrollController.offset
      : null;

  @visibleForTesting
  double? get messageScrollMaxExtent =>
      _state?._scrollController.hasClients == true
      ? _state!._scrollController.position.maxScrollExtent
      : null;

  void _attach(_ChatScreenState state) {
    _state = state;
  }

  void _detach(_ChatScreenState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }

  Future<void> createRemoteSession() async => _state?._createRemoteSession();

  Future<void> reloadSessions() async => _state?._reloadSessionsWithNotice();

  @visibleForTesting
  Future<bool> reloadSessionsReadOnly() async =>
      await _state?._loadSessions() ?? false;

  Future<void> selectSession(String sessionId) async {
    final state = _state;
    if (state == null) {
      return;
    }
    for (final session in state._sessions) {
      if (session.sessionId == sessionId) {
        await state._initializeSession(session);
        return;
      }
    }
  }

  @visibleForTesting
  Future<void> attachRuntime({
    required RuntimeConversationController conversationController,
    required String connectionId,
    required Future<List<Map<String, dynamic>>> Function() listSessions,
    List<Assistant> assistants = const <Assistant>[],
  }) async {
    await _state?._attachRuntimeForTesting(
      conversationController: conversationController,
      connectionId: connectionId,
      listSessions: listSessions,
      assistants: assistants,
    );
  }

  @visibleForTesting
  Future<void> reorderSessions(int oldIndex, int newIndex) async =>
      _state?._reorderSessions(oldIndex, newIndex);

  @visibleForTesting
  List<String> get sendBlockerCodes =>
      _state
          ?._sendBlockersForCurrentSelection()
          .map((item) => item.code)
          .toList() ??
      const <String>[];

  @visibleForTesting
  Future<void> sendMessage(String text) async {
    final state = _state;
    if (state == null) {
      return;
    }
    state._messageController.text = text;
    await state._sendMessage();
  }
}

class HakureiTerminalApp extends StatefulWidget {
  const HakureiTerminalApp({
    super.key,
    this.initialExternalBackendAvailable = false,
    this.controller,
    this.settingsStore,
    this.archivePaths,
    this.assistantRepository,
    this.conversationRepository,
    this.initialSettings = AppSettings.defaultSettings,
    this.skipInitialLoad = false,
  });

  final bool initialExternalBackendAvailable;
  final ChatScreenController? controller;
  final SettingsStore? settingsStore;
  final ArchivePaths? archivePaths;
  final AssistantArchiveRepository? assistantRepository;
  final ConversationArchiveRepository? conversationRepository;
  final AppSettings initialSettings;
  final bool skipInitialLoad;

  @override
  State<HakureiTerminalApp> createState() => _HakureiTerminalAppState();
}

class _HakureiTerminalAppState extends State<HakureiTerminalApp> {
  late AppSettings _settings;
  late final SettingsStore _settingsStore;
  late final ArchivePaths _archivePaths;
  Future<AppSettings>? _initialSettingsLoad;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    _settingsStore = widget.settingsStore ?? SettingsStore();
    _archivePaths =
        widget.archivePaths ??
        widget.assistantRepository?.paths ??
        widget.conversationRepository?.paths ??
        ArchivePaths();
    if (!widget.skipInitialLoad) {
      _initialSettingsLoad = _settingsStore.load();
      unawaited(_restoreInitialTheme());
    }
  }

  Future<void> _restoreInitialTheme() async {
    final settings = await _initialSettingsLoad;
    if (settings == null || !mounted) {
      return;
    }
    _handleSettingsChanged(settings);
  }

  void _handleSettingsChanged(AppSettings settings) {
    if (identical(settings, _settings)) {
      return;
    }
    setState(() => _settings = settings);
  }

  @override
  Widget build(BuildContext context) {
    final palette = resolveAppTheme(_settings.appearance);
    final backgroundFile = resolveAppBackgroundFile(
      _settings.appearance,
      _archivePaths,
    );
    final baseTheme = buildAppTheme(
      palette,
      fontFamilyId: _settings.appearance.fontFamilyId,
      fontSize: _settings.appearance.fontSize,
      uiDensity: _settings.appearance.uiDensity,
      cornerRadius: _settings.appearance.cornerRadius,
    );
    final theme = backgroundFile == null
        ? baseTheme
        : baseTheme.copyWith(scaffoldBackgroundColor: Colors.transparent);
    return MaterialApp(
      title: 'HakureiTerminal',
      debugShowCheckedModeBanner: false,
      theme: theme,
      themeMode: ThemeMode.light,
      builder: (context, child) => AppBackground(
        file: backgroundFile,
        color: palette.background,
        imageOpacity: _settings.appearance.backgroundImageOpacity,
        child: child ?? const SizedBox.shrink(),
      ),
      home: ChatScreen(
        initialExternalBackendAvailable: widget.initialExternalBackendAvailable,
        controller: widget.controller,
        settingsStore: _settingsStore,
        archivePaths: _archivePaths,
        assistantRepository: widget.assistantRepository,
        conversationRepository: widget.conversationRepository,
        initialSettings: widget.initialSettings,
        skipInitialLoad: widget.skipInitialLoad,
        initialSettingsLoad: _initialSettingsLoad,
        onSettingsChanged: _handleSettingsChanged,
      ),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.initialExternalBackendAvailable = false,
    this.controller,
    this.settingsStore,
    this.archivePaths,
    this.assistantRepository,
    this.conversationRepository,
    this.initialSettings = AppSettings.defaultSettings,
    this.skipInitialLoad = false,
    this.initialSettingsLoad,
    this.onSettingsChanged,
  });

  final bool initialExternalBackendAvailable;
  final ChatScreenController? controller;
  final SettingsStore? settingsStore;
  final ArchivePaths? archivePaths;
  final AssistantArchiveRepository? assistantRepository;
  final ConversationArchiveRepository? conversationRepository;
  final AppSettings initialSettings;
  final bool skipInitialLoad;
  final Future<AppSettings>? initialSettingsLoad;
  final ValueChanged<AppSettings>? onSettingsChanged;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  GensokyoAiHttpRuntimeClient? _externalRuntimeClient;
  RuntimeConversationController? _conversationController;
  RuntimeConversationSnapshot _conversationSnapshot =
      RuntimeConversationSnapshot.disconnected();
  StreamSubscription<RuntimeConversationSnapshot>?
  _conversationSnapshotSubscription;
  late final SettingsStore _settingsStore;
  late final AssistantArchiveRepository _assistantArchiveRepository;
  late final ConversationArchiveRepository _conversationArchiveRepository;
  late final MediaRepository _mediaRepository;
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final ScrollController _composerActionsScrollController = ScrollController();
  bool _scrollToBottomScheduled = false;

  late AppSettings _settings;
  List<ChatSession> _sessions = const <ChatSession>[];
  List<Assistant> _assistants = const <Assistant>[];
  final Map<String, List<ChatMessage>> _sessionMessages =
      <String, List<ChatMessage>>{};
  ChatSession? _selectedSession;
  bool _loading = true;
  bool _sessionsLoaded = false;
  bool _initializing = false;
  bool _sending = false;
  bool _managingSession = false;
  bool _sessionBackgroundBusy = false;
  bool _sessionAvatarBusy = false;
  _ComposerImageAttachment? _composerImage;
  String? _error;
  String? _syncNotice;
  String? _sessionListError;
  bool _externalBackendAvailable = false;
  StreamSubscription<ExternalRuntimeEvent>? _externalRuntimeEventSubscription;
  StreamSubscription<bool>? _externalRuntimeConnectionSubscription;
  final ExternalRuntimeEventDeduplicator _externalEventDeduplicator =
      ExternalRuntimeEventDeduplicator();
  Future<List<Map<String, dynamic>>> Function()? _testSessionList;
  String? _testConnectionId;
  bool _runtimeDisconnectNotified = false;
  bool _deferredConversationRefresh = false;
  bool _conversationRefreshInFlight = false;
  Object? _sessionMetadataRefreshToken;
  Future<void>? _sessionMetadataRefreshFuture;
  Future<void> _liveSettingsWrites = Future<void>.value();
  late final TtsService _ttsService;
  StreamSubscription<PlayerState>? _ttsStateSubscription;
  PlayerState _ttsPlayerState = PlayerState.stopped;
  String? _ttsMessageId;
  bool _ttsBusy = false;

  static const double _minPaneWidth = 220;
  static const double _minChatPaneWidth = 360;
  double _sidebarWidth = 340;
  double _contextPaneWidth = 340;
  // 用户意图：面板是否展开。断点只决定呈现形态，不覆盖这两个值。
  bool _sidebarVisible = true;
  bool _contextPaneVisible = true;
  // medium 档一次只放得下一个面板；记录用户最近想看哪个。
  bool _contextPanePriority = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  List<ChatMessage> get _currentMessages {
    final session = _selectedSession;
    if (session == null) {
      return const <ChatMessage>[];
    }
    final controllerSnapshot = _conversationController?.snapshot;
    if (session.externalSessionId == controllerSnapshot?.sessionId) {
      return controllerSnapshot!.displayMessages;
    }
    return _sessionMessages[session.sessionId] ?? const <ChatMessage>[];
  }

  RuntimeConversationSnapshot get _effectiveConversationSnapshot =>
      _conversationController?.snapshot ?? _conversationSnapshot;

  bool get _conversationBusy => switch (_effectiveConversationSnapshot.phase) {
    RuntimeConversationPhase.activating ||
    RuntimeConversationPhase.sending ||
    RuntimeConversationPhase.reconciling => true,
    _ => false,
  };

  Assistant? get _selectedAssistant {
    final assistantId = _selectedSession?.activeAssistantId;
    if (assistantId == null || assistantId.isEmpty) {
      return null;
    }
    for (final assistant in _assistants) {
      if (assistant.id == assistantId) {
        return assistant;
      }
    }
    if (assistantId.startsWith('gensokyoai_')) {
      final providerAssistantId = assistantId.substring('gensokyoai_'.length);
      for (final assistant in _assistants) {
        if (assistant.providerId == AssistantProviderId.gensokyoAi &&
            assistant.providerAssistantId == providerAssistantId) {
          return assistant;
        }
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    _ttsService = TtsService();
    _ttsStateSubscription = _ttsService.states.listen((state) {
      if (!mounted) return;
      setState(() {
        _ttsPlayerState = state;
        if (shouldClearTtsMessage(state: state, busy: _ttsBusy)) {
          _ttsBusy = false;
          _ttsMessageId = null;
        }
      });
    });
    FocusManager.instance.addEarlyKeyEventHandler(_handleComposerKeyEvent);
    _externalBackendAvailable = widget.initialExternalBackendAvailable;
    _assistants = const <Assistant>[];
    widget.controller?._attach(this);
    _settingsStore = widget.settingsStore ?? SettingsStore();
    _assistantArchiveRepository =
        widget.assistantRepository ??
        AssistantArchiveRepository(paths: widget.archivePaths);
    _conversationArchiveRepository =
        widget.conversationRepository ??
        ConversationArchiveRepository(paths: widget.archivePaths);
    _mediaRepository = MediaRepository(
      paths: _conversationArchiveRepository.paths,
    );
    if (widget.skipInitialLoad) {
      _loading = false;
      _sessionsLoaded = true;
    } else {
      _loadSettingsAndSessions();
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleComposerKeyEvent);
    unawaited(_disposeRuntimeController());
    unawaited(_ttsStateSubscription?.cancel());
    unawaited(_ttsService.dispose());
    _messageController.dispose();
    _messageFocusNode.dispose();
    _scrollController.dispose();
    _composerActionsScrollController.dispose();
    super.dispose();
  }

  Future<void> _speakMessage(ChatMessage message) async {
    if (_ttsBusy) return;
    final text = markdownToSpeechText(
      message.contentParts.isEmpty
          ? message.content
          : message.contentParts
                .where((part) => part.type == 'text')
                .map((part) => part.text)
                .join('\n'),
    );
    setState(() {
      _ttsBusy = true;
      _ttsMessageId = message.id;
      _error = null;
    });
    try {
      await _ttsService.stop();
      await _ttsService.speak(text, _settings.tts);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '语音生成失败：$error';
          _ttsMessageId = null;
        });
      }
    } finally {
      if (mounted) setState(() => _ttsBusy = false);
    }
  }

  Future<void> _toggleTtsPlayback() async {
    if (_ttsPlayerState == PlayerState.paused) {
      await _ttsService.resume();
    } else {
      await _ttsService.pause();
    }
  }

  Future<void> _stopTts() async {
    await _ttsService.stop();
    if (mounted) {
      setState(() {
        _ttsMessageId = null;
        _ttsBusy = false;
      });
    }
  }

  Future<void> _loadSettingsAndSessions() async {
    try {
      var settings =
          await (widget.initialSettingsLoad ?? _settingsStore.load());
      settings = await _migrateGlobalBackground(settings);
      if (!mounted) {
        return;
      }
      widget.onSettingsChanged?.call(settings);
      setState(() => _settings = settings);
      await _loadAssistants();
      await _loadSessions();
    } catch (error) {
      if (mounted) {
        setState(() {
          _sessionsLoaded = true;
          _sessionListError ??= '会话列表加载失败：$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<AppSettings> _migrateGlobalBackground(AppSettings settings) async {
    final relativePath = settings.appearance.backgroundImagePath;
    if (relativePath.isEmpty ||
        MediaRepository.isContentAddressedPath(relativePath)) {
      return settings;
    }
    final source = _assistantArchiveRepository.paths.managedAppearanceFile(
      relativePath,
    );
    if (source == null || !await source.exists()) {
      return settings;
    }
    final mediaRepository = MediaRepository(
      paths: _assistantArchiveRepository.paths,
    );
    final migratedPath = await mediaRepository.storeFile(source);
    final migrated = settings.copyWith(
      appearance: settings.appearance.copyWith(
        backgroundImagePath: migratedPath,
      ),
    );
    await _settingsStore.save(migrated);
    await source.delete();
    return migrated;
  }

  Future<bool> _loadAssistants() async {
    try {
      final client = _externalRuntimeClient;
      final assistants = client == null || !_externalBackendAvailable
          ? const <Assistant>[]
          : await GensokyoAiHttpAssistantProviderAdapter(
              client,
            ).listAssistants();
      if (!mounted) {
        return false;
      }
      setState(() {
        _assistants = assistants;
      });
      return true;
    } catch (error) {
      if (!mounted) {
        return false;
      }
      setState(() {
        _assistants = const <Assistant>[];
        _error = '远程角色列表加载失败：$error';
      });
      return false;
    }
  }

  Future<bool> _loadSessions({
    RuntimeConversationController? expectedController,
    RuntimeConversationSnapshot? expectedSnapshot,
  }) async {
    if (expectedController != null &&
        expectedSnapshot != null &&
        !_matchesMetadataRefreshTarget(expectedController, expectedSnapshot)) {
      return false;
    }
    final selectedSessionId = _selectedSession?.sessionId;
    setState(() {
      _loading = true;
      _sessionListError = null;
    });
    try {
      final client = _externalRuntimeClient;
      final connectionId = _testConnectionId ?? client?.connection.id;
      final cachedById = <String, ChatSession>{};
      if (connectionId != null) {
        final cachedSource = expectedSnapshot == null
            ? await _conversationArchiveRepository.listConversations()
            : _sessions;
        for (final session in cachedSource.where(
          (session) =>
              session.externalConnectionId == connectionId &&
              session.externalSessionId.isNotEmpty,
        )) {
          final normalized = session.copyWith(
            sessionId: localExternalSessionId(
              session.externalConnectionId,
              session.externalSessionId,
              characterId: session.externalCharacterId,
            ),
            externalMappingStatus: ExternalMappingStatus.unverified,
          );
          cachedById[normalized.sessionId] = normalized;
        }
      }
      final cachedSessions = cachedById.values.toList(growable: false);
      final listSessions =
          _testSessionList ??
          () async {
            final result = await client!.call('session.list');
            final values = result is Map ? result['sessions'] : result;
            return values is List
                ? values
                      .whereType<Map>()
                      .map((item) => Map<String, dynamic>.from(item))
                      .toList(growable: false)
                : const <Map<String, dynamic>>[];
          };
      if ((client == null && _testSessionList == null) ||
          !_externalBackendAvailable ||
          connectionId == null) {
        if (!mounted) return false;
        setState(() {
          _sessions = _sortSessions(cachedSessions);
          _selectedSession = null;
          _sessionsLoaded = true;
          _sessionMessages.clear();
        });
        return true;
      }
      final activeCharacterId = _conversationController?.snapshot.characterId;
      final activeSessionId = _conversationController?.snapshot.sessionId;
      if (activeCharacterId == null || activeSessionId == null) {
        if (!mounted) return false;
        setState(() {
          _sessions = _sortSessions(cachedSessions);
          _selectedSession = null;
          _sessionsLoaded = true;
          _sessionMessages.clear();
        });
        await Future.wait(
          cachedSessions.map(_conversationArchiveRepository.saveConversation),
        );
        return true;
      }
      if (expectedController != null &&
          expectedSnapshot != null &&
          !_matchesMetadataRefreshTarget(
            expectedController,
            expectedSnapshot,
          )) {
        return false;
      }
      final remoteSessions = await listSessions();
      if (expectedController != null &&
          expectedSnapshot != null &&
          !_matchesMetadataRefreshTarget(
            expectedController,
            expectedSnapshot,
          )) {
        return false;
      }
      final sessions = _sortSessions(
        mergeRemoteSessionMappings(
          cachedSessions,
          remoteSessions.map(_sessionFromRemoteJson),
          activeCharacterId: activeCharacterId,
        ),
      );
      if (!mounted) {
        return false;
      }
      ChatSession? nextSession;
      if (selectedSessionId != null) {
        nextSession = sessions
            .where((session) => session.sessionId == selectedSessionId)
            .firstOrNull;
      }
      final activeRemoteSessionId = _conversationSnapshot.sessionId;
      if (nextSession == null && activeRemoteSessionId != null) {
        nextSession = sessions
            .where(
              (session) =>
                  session.externalSessionId == activeRemoteSessionId &&
                  session.externalCharacterId == activeCharacterId,
            )
            .firstOrNull;
      }
      final validSessionIds = sessions
          .map((session) => session.sessionId)
          .toSet();
      setState(() {
        _sessions = sessions;
        _selectedSession = nextSession;
        if (nextSession?.externalSessionId ==
            _conversationController?.snapshot.sessionId) {
          _conversationSnapshot = _conversationController!.snapshot;
        }
        _sessionsLoaded = true;
        _sessionMessages.removeWhere(
          (sessionId, _) => !validSessionIds.contains(sessionId),
        );
        if (nextSession != null) {
          _sessionMessages.putIfAbsent(
            nextSession.sessionId,
            () => <ChatMessage>[],
          );
        }
      });
      await Future.wait(
        sessions.map(_conversationArchiveRepository.saveConversation),
      );
      return true;
    } catch (error) {
      if (mounted) {
        final activeCharacterId = _conversationController?.snapshot.characterId;
        final inaccessible = _sessions
            .map(
              (session) => session.externalCharacterId == activeCharacterId
                  ? session.copyWith(
                      externalMappingStatus: ExternalMappingStatus.inaccessible,
                    )
                  : session,
            )
            .toList(growable: false);
        setState(() {
          _sessions = inaccessible;
          final selectedId = _selectedSession?.sessionId;
          _selectedSession = inaccessible
              .where((session) => session.sessionId == selectedId)
              .firstOrNull;
          _sessionsLoaded = true;
          _sessionListError = '会话列表加载失败：$error';
        });
        await Future.wait(
          inaccessible.map(_conversationArchiveRepository.saveConversation),
        );
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  ChatSession _sessionFromRemoteJson(Map<String, dynamic> json) {
    final remoteId =
        json['session_id']?.toString() ?? json['id']?.toString() ?? '';
    final characterId =
        json['character_id']?.toString() ?? json['character']?.toString() ?? '';
    final assistant = resolveGensokyoAiSessionAssistant(
      characterId,
      _assistants,
    );
    final canonicalCharacterId = assistant?.providerAssistantId ?? characterId;
    return ChatSession(
      sessionId: localExternalSessionId(
        _testConnectionId ?? _externalRuntimeClient!.connection.id,
        remoteId,
        characterId: canonicalCharacterId,
      ),
      title: sessionTitleFromRemoteJson(json),
      backendId: 'gensokyoai',
      externalConnectionId:
          _testConnectionId ?? _externalRuntimeClient!.connection.id,
      externalSessionId: remoteId,
      externalCharacterId: canonicalCharacterId,
      externalMappingStatus: ExternalMappingStatus.verified,
      activeAssistantId: assistant?.id ?? '',
      totalTurns: int.tryParse(json['total_turns']?.toString() ?? '') ?? 0,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      lastActive: DateTime.tryParse(json['last_active']?.toString() ?? ''),
      metadata: const <String, dynamic>{'state_authority': 'external_runtime'},
    );
  }

  Future<void> _reloadSessionsWithNotice() async {
    final controller = _conversationController;
    final selected = _selectedSession;
    final snapshot = controller?.snapshot;
    final canRefreshConversation =
        controller != null &&
        selected != null &&
        snapshot?.phase == RuntimeConversationPhase.ready &&
        snapshot?.sessionId == selected.externalSessionId;
    if (canRefreshConversation) {
      try {
        await controller.refresh();
      } catch (error) {
        if (mounted) {
          setState(() => _error = '会话刷新失败：$error');
        }
        return;
      }
    }
    await _applySettingsOperation(
      const SettingsOperation(reloadSessions: true),
    );
  }

  List<ChatSession> _sortSessions(Iterable<ChatSession> sessions) {
    final sorted = sessions.toList(growable: false);
    sorted.sort((a, b) {
      if (a.listOrder != null && b.listOrder != null) {
        final orderComparison = a.listOrder!.compareTo(b.listOrder!);
        if (orderComparison != 0) {
          return orderComparison;
        }
      }
      final aTime =
          a.lastActive ?? a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime =
          b.lastActive ?? b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final timeComparison = bTime.compareTo(aTime);
      return timeComparison != 0
          ? timeComparison
          : a.sessionId.compareTo(b.sessionId);
    });
    return sorted;
  }

  List<ChatSession> _withSessionOrder(Iterable<ChatSession> sessions) {
    final ordered = sessions.toList(growable: false);
    return <ChatSession>[
      for (var index = 0; index < ordered.length; index += 1)
        ordered[index].copyWith(listOrder: index),
    ];
  }

  Future<void> _persistSessionOrder(List<ChatSession> sessions) async {
    await Future.wait(
      sessions.map(_conversationArchiveRepository.saveConversation),
    );
  }

  Future<void> _reorderSessions(int oldIndex, int newIndex) async {
    if (_managingSession || _conversationBusy || oldIndex == newIndex) {
      return;
    }
    final reordered = _sessions.toList(growable: true);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    final ordered = _withSessionOrder(reordered);
    setState(() {
      _managingSession = true;
      _sessions = ordered;
      final selectedId = _selectedSession?.sessionId;
      if (selectedId != null) {
        _selectedSession = ordered.firstWhere(
          (session) => session.sessionId == selectedId,
          orElse: () => moved,
        );
      }
    });
    try {
      await _persistSessionOrder(ordered);
    } catch (error) {
      if (mounted) {
        setState(() => _error = '保存会话顺序失败：$error');
        await _loadSessions();
      }
    } finally {
      if (mounted) {
        setState(() => _managingSession = false);
      }
    }
  }

  Future<void> _initializeSession(ChatSession session) async {
    final controller = _conversationController;
    final assistant = resolveGensokyoAiSessionAssistant(
      session.externalCharacterId,
      _assistants,
    );
    if (session.externalMappingStatus == ExternalMappingStatus.stale) {
      setState(() {
        _selectedSession = session;
        _error = '该会话已不在 Runtime 的角色会话列表中。请加载该角色的历史会话重新验证，或选择其他会话。';
      });
      return;
    }
    if (controller == null || assistant == null || _conversationBusy) {
      if (assistant == null && mounted) {
        setState(() => _error = '远程会话角色不可用');
      }
      return;
    }
    setState(() {
      _selectedSession = session;
      _error = null;
      _sessionMessages.putIfAbsent(session.sessionId, () => <ChatMessage>[]);
    });
    try {
      await controller.activate(
        characterId: assistant.providerAssistantId,
        sessionId: session.externalSessionId,
      );
      await _loadSessions();
      final verified = _sessions
          .where((item) => item.sessionId == session.sessionId)
          .firstOrNull;
      if (verified?.externalMappingStatus != ExternalMappingStatus.verified) {
        throw StateError('Runtime 未能验证所选会话映射，请重新加载该角色的历史会话');
      }
      if (mounted) {
        setState(() => _selectedSession = verified);
      }
    } on RuntimeConnectionException catch (error) {
      if (error.code == 'session.not_found') {
        final stale = session.copyWith(
          externalMappingStatus: ExternalMappingStatus.stale,
        );
        if (mounted) {
          setState(() {
            _sessions = _sessions
                .map((item) => item.sessionId == stale.sessionId ? stale : item)
                .toList(growable: false);
            _selectedSession = stale;
            _error = '该远程会话已不存在。本地映射已标记为失效，请新建会话或加载该角色的其他历史会话。';
          });
        }
        await _conversationArchiveRepository.saveConversation(stale);
        return;
      }
      if (mounted) {
        setState(() => _error = error.kind);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<void> _createRemoteSession() async {
    if (_loading || _managingSession || _conversationBusy) {
      return;
    }
    final controller = _conversationController;
    if (controller == null) {
      setState(() => _error = '请先在服务管理中显式连接 GensokyoAI Runtime。');
      return;
    }
    if (_assistants.isEmpty) {
      setState(() => _error = '已连接的 Runtime 没有可执行角色，无法创建会话。');
      return;
    }
    final assistant = await showDialog<Assistant>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择 GensokyoAI 角色'),
        children: <Widget>[
          for (final item in _assistants)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, item),
              child: Text(item.name),
            ),
        ],
      ),
    );
    if (assistant == null || !mounted) return;
    setState(() {
      _managingSession = true;
      _error = null;
    });
    try {
      await controller.activate(
        characterId: assistant.providerAssistantId,
        newSession: true,
      );
      await _loadSessions();
      final activatedSessionId = controller.snapshot.sessionId;
      if (mounted && activatedSessionId != null) {
        final created = _sessions
            .where((session) => session.externalSessionId == activatedSessionId)
            .firstOrNull;
        if (created != null &&
            _settings.newSessionTitleMode != SessionTitleMode.firstMessage) {
          await _renameRemoteSession(
            created,
            _titleForMode(
              _settings.newSessionTitleMode,
              createdAt: created.createdAt,
            ),
          );
        }
        setState(() {
          _selectedSession = _sessions
              .where(
                (session) => session.externalSessionId == activatedSessionId,
              )
              .firstOrNull;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = '创建会话失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _managingSession = false);
      }
    }
  }

  String _titleForMode(
    SessionTitleMode mode, {
    DateTime? createdAt,
    String? firstMessage,
  }) {
    switch (mode) {
      case SessionTitleMode.fixed:
        return '新会话';
      case SessionTitleMode.createdAt:
        final value = (createdAt ?? DateTime.now()).toLocal();
        String two(int number) => number.toString().padLeft(2, '0');
        return '${value.year}-${two(value.month)}-${two(value.day)} '
            '${two(value.hour)}:${two(value.minute)}';
      case SessionTitleMode.firstMessage:
        final normalized = (firstMessage ?? '').trim().replaceAll(
          RegExp(r'\s+'),
          ' ',
        );
        if (normalized.isEmpty) return '图片消息';
        final runes = normalized.runes.toList(growable: false);
        return String.fromCharCodes(runes.length > 40 ? runes.take(40) : runes);
    }
  }

  Future<void> _renameRemoteSession(ChatSession session, String title) async {
    final client = _externalRuntimeClient;
    if (client == null ||
        session.externalSessionId.isEmpty ||
        title.trim().isEmpty) {
      return;
    }
    try {
      final result = await client.renameSession(
        sessionId: session.externalSessionId,
        title: title,
      );
      final metadata = result['metadata'] is Map
          ? Map<String, dynamic>.from(result['metadata'] as Map)
          : const <String, dynamic>{};
      final confirmedTitle =
          result['title']?.toString().trim().isNotEmpty == true
          ? result['title'].toString().trim()
          : metadata['title']?.toString().trim().isNotEmpty == true
          ? metadata['title'].toString().trim()
          : title.trim();
      final updated = session.copyWith(title: confirmedTitle);
      _replaceSession(updated);
      await _conversationArchiveRepository.saveConversation(updated);
    } catch (error) {
      if (mounted) {
        setState(() => _error = '会话标题设置失败：$error');
      }
    }
  }

  Future<void> _loadCharacterSessions() async {
    final controller = _conversationController;
    if (_loading ||
        _managingSession ||
        _conversationBusy ||
        controller == null) {
      return;
    }
    final assistant = await showDialog<Assistant>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('加载角色历史会话'),
        children: <Widget>[
          for (final item in _assistants)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, item),
              child: Text(item.name),
            ),
        ],
      ),
    );
    if (assistant == null || !mounted) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('切换 Runtime 当前角色？'),
        content: Text('这会将 Runtime 当前角色切换为“${assistant.name}”，并激活该角色的会话。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('切换并加载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _managingSession = true;
      _error = null;
    });
    try {
      await controller.activate(characterId: assistant.providerAssistantId);
      await _loadSessions();
    } catch (error) {
      if (mounted) {
        setState(() => _error = '角色会话加载失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _managingSession = false);
      }
    }
  }

  KeyEventResult _handleComposerKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.enter ||
        !_messageFocusNode.hasFocus) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final shouldSend = keyboard.isControlPressed
        ? _settings.shortcuts.isEnabled(AppShortcutId.sendMessage)
        : _settings.shortcuts.isEnabled(AppShortcutId.sendMessageOnEnter);
    if (!shouldSend) {
      return KeyEventResult.ignored;
    }
    unawaited(_sendMessage());
    return KeyEventResult.handled;
  }

  Map<ShortcutActivator, VoidCallback> _shortcutBindings() {
    final bindings = <ShortcutActivator, VoidCallback>{};
    void add(
      String shortcutId,
      ShortcutActivator activator,
      VoidCallback callback,
    ) {
      if (_settings.shortcuts.isEnabled(shortcutId)) {
        bindings[activator] = callback;
      }
    }

    add(
      AppShortcutId.sendMessage,
      const SingleActivator(LogicalKeyboardKey.enter, control: true),
      () => unawaited(_sendMessage()),
    );
    add(
      AppShortcutId.sendMessageOnEnter,
      const SingleActivator(LogicalKeyboardKey.enter),
      () => unawaited(_sendMessage()),
    );
    add(
      AppShortcutId.newSession,
      const SingleActivator(LogicalKeyboardKey.keyN, control: true),
      () => unawaited(_createRemoteSession()),
    );
    add(
      AppShortcutId.openSettings,
      const SingleActivator(LogicalKeyboardKey.comma, control: true),
      () => unawaited(_openSettings()),
    );
    add(
      AppShortcutId.previousSession,
      const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true),
      () => _selectRelativeSession(-1),
    );
    add(
      AppShortcutId.nextSession,
      const SingleActivator(LogicalKeyboardKey.tab, control: true),
      () => _selectRelativeSession(1),
    );
    add(
      AppShortcutId.focusComposer,
      const SingleActivator(LogicalKeyboardKey.keyL, control: true),
      _messageFocusNode.requestFocus,
    );
    return bindings;
  }

  void _selectRelativeSession(int offset) {
    if (_sessions.length < 2 || _conversationBusy) {
      return;
    }
    final selectedId = _selectedSession?.sessionId;
    final currentIndex = _sessions.indexWhere(
      (session) => session.sessionId == selectedId,
    );
    final baseIndex = currentIndex < 0 ? 0 : currentIndex;
    final nextIndex = (baseIndex + offset) % _sessions.length;
    unawaited(_initializeSession(_sessions[nextIndex]));
  }

  Future<void> _pickSessionBackground(ChatSession session) async {
    final picked = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: '会话背景图片',
          extensions: <String>['png', 'jpg', 'jpeg', 'webp'],
        ),
      ],
    );
    if (picked == null || !mounted) {
      return;
    }
    final extension = picked.name.contains('.')
        ? picked.name.split('.').last.toLowerCase()
        : '';
    if (!const <String>{'png', 'jpg', 'jpeg', 'webp'}.contains(extension)) {
      showTopNotice(context, '请选择 PNG、JPEG 或 WebP 图片');
      return;
    }
    setState(() => _sessionBackgroundBusy = true);
    try {
      final bytes = await picked.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      codec.dispose();
      final relativePath = await _mediaRepository.storeBytes(bytes);
      final updated = session.copyWith(backgroundImagePath: relativePath);
      await _conversationArchiveRepository.saveConversation(updated);
      final previous = _conversationArchiveRepository.paths
          .managedConversationBackgroundFile(
            session.sessionId,
            session.backgroundImagePath,
          );
      if (!mounted) {
        return;
      }
      _replaceSession(updated);
      if (previous != null && await previous.exists()) {
        try {
          await previous.delete();
        } on FileSystemException catch (error) {
          if (mounted) {
            showTopNotice(context, '会话背景已更新，但旧图片清理失败：$error');
          }
        }
      }
    } catch (error) {
      if (mounted) {
        showTopNotice(context, '会话背景设置失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _sessionBackgroundBusy = false);
      }
    }
  }

  Future<void> _removeSessionBackground(ChatSession session) async {
    final file = _conversationArchiveRepository.paths
        .managedConversationBackgroundFile(
          session.sessionId,
          session.backgroundImagePath,
        );
    final updated = session.copyWith(backgroundImagePath: '');
    setState(() => _sessionBackgroundBusy = true);
    try {
      await _conversationArchiveRepository.saveConversation(updated);
      if (!mounted) {
        return;
      }
      _replaceSession(updated);
      if (file != null && await file.exists()) {
        try {
          await file.delete();
        } on FileSystemException catch (error) {
          if (mounted) {
            showTopNotice(context, '会话背景已移除，但旧图片清理失败：$error');
          }
        }
      }
    } catch (error) {
      if (mounted) {
        showTopNotice(context, '移除会话背景失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _sessionBackgroundBusy = false);
      }
    }
  }

  Future<void> _pickSessionAvatar(ChatSession session) async {
    final picked = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: '会话头像',
          extensions: <String>['png', 'jpg', 'jpeg', 'webp'],
        ),
      ],
    );
    if (picked == null || !mounted) {
      return;
    }
    final extension = picked.name.contains('.')
        ? picked.name.split('.').last.toLowerCase()
        : '';
    if (!const <String>{'png', 'jpg', 'jpeg', 'webp'}.contains(extension)) {
      showTopNotice(context, '请选择 PNG、JPEG 或 WebP 图片');
      return;
    }
    setState(() => _sessionAvatarBusy = true);
    try {
      final bytes = Uint8List.fromList(await picked.readAsBytes());
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 128);
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      codec.dispose();
      if (!mounted) {
        return;
      }
      final relativePath = await _mediaRepository.storeBytes(bytes);
      if (!mounted) {
        return;
      }
      final transform = await showDialog<AvatarTransform>(
        context: context,
        builder: (context) => AvatarEditorDialog(
          imageBytes: bytes,
          initialTransform: const AvatarTransform(),
        ),
      );
      if (transform == null || !mounted) {
        return;
      }
      final updated = session.copyWith(
        avatarImagePath: relativePath,
        avatarTransform: transform,
      );
      await _conversationArchiveRepository.saveConversation(updated);
      if (!mounted) {
        return;
      }
      _replaceSession(updated);
    } catch (error) {
      if (mounted) {
        showTopNotice(context, '会话头像设置失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _sessionAvatarBusy = false);
      }
    }
  }

  Future<void> _removeSessionAvatar(ChatSession session) async {
    setState(() => _sessionAvatarBusy = true);
    try {
      final updated = session.copyWith(
        avatarImagePath: '',
        avatarTransform: const AvatarTransform(),
      );
      await _conversationArchiveRepository.saveConversation(updated);
      if (!mounted) {
        return;
      }
      _replaceSession(updated);
    } catch (error) {
      if (mounted) {
        showTopNotice(context, '移除会话头像失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _sessionAvatarBusy = false);
      }
    }
  }

  ImageProvider? _sessionAvatarProvider(ChatSession session) {
    final file = _conversationArchiveRepository.paths.managedMediaFile(
      session.avatarImagePath,
    );
    return file != null && file.existsSync() ? FileImage(file) : null;
  }

  Widget _sessionAvatarWidget(
    ChatSession session, {
    required double radius,
    Key? key,
  }) {
    return AvatarImage(
      key: key,
      radius: radius,
      imageProvider: _sessionAvatarProvider(session),
      transform: session.avatarTransform,
    );
  }

  void _replaceSession(ChatSession updated) {
    setState(() {
      _sessions = _sessions
          .map(
            (session) =>
                session.sessionId == updated.sessionId ? updated : session,
          )
          .toList(growable: false);
      if (_selectedSession?.sessionId == updated.sessionId) {
        _selectedSession = updated;
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    final image = _composerImage;
    final session = _selectedSession;
    final sendBlockers = _sendBlockersForCurrentSelection();
    final controller = _conversationController;
    if ((text.isEmpty && image == null) ||
        _conversationBusy ||
        _sessionMetadataRefreshToken != null ||
        session == null) {
      if (mounted) {
        setState(() {
          _error = text.isEmpty && image == null
              ? '请输入要发送的消息。'
              : session == null
              ? '请先选择或创建会话。'
              : _conversationBusy || _sessionMetadataRefreshToken != null
              ? '会话正在处理其他操作，请稍后重试。'
              : '会话不可用。';
        });
      }
      return;
    }
    if (sendBlockers.isNotEmpty) {
      setState(
        () => _error = '发送前需要修复：${_bindingCapabilityLossSummary(sendBlockers)}',
      );
      return;
    }

    try {
      if (controller == null ||
          controller.snapshot.sessionId != session.externalSessionId) {
        throw StateError('所选会话不是 Runtime 当前活动会话');
      }
      final isFirstUserMessage = !_currentMessages.any(
        (message) => message.role == ChatMessageRole.user,
      );
      setState(() => _error = null);
      if (image == null) {
        _messageController.clear();
        await controller.send(text);
      } else {
        final client = _externalRuntimeClient;
        if (client == null) {
          throw StateError('当前会话没有可用的 Runtime 媒体上传连接');
        }
        final uploaded = await client.uploadMedia(
          filename: image.name,
          bytes: image.bytes,
          contentType: image.contentType,
        );
        final mediaId = uploaded['media_id']?.toString().trim();
        if (mediaId == null || mediaId.isEmpty) {
          throw const FormatException(
            'Runtime media upload response is missing media_id',
          );
        }
        final runtimeParts = <Map<String, dynamic>>[
          if (text.isNotEmpty) <String, dynamic>{'type': 'text', 'text': text},
          <String, dynamic>{
            'type': 'media',
            'media_id': mediaId,
            'detail': 'auto',
          },
        ];
        final displayParts = <ChatContentPart>[
          if (text.isNotEmpty)
            ChatContentPart(
              type: 'text',
              data: <String, dynamic>{'type': 'text', 'text': text},
            ),
          ChatContentPart(
            type: 'image',
            data: <String, dynamic>{
              'type': 'image',
              'image': <String, dynamic>{
                'data': base64Encode(image.bytes),
                'mime_type': image.contentType,
              },
            },
          ),
        ];
        _messageController.clear();
        setState(() => _composerImage = null);
        await controller.sendStructured(
          RuntimeMessageInput(
            text: text,
            runtimeContentParts: runtimeParts,
            displayContentParts: displayParts,
          ),
        );
      }
      if (isFirstUserMessage &&
          _settings.newSessionTitleMode == SessionTitleMode.firstMessage) {
        await _sessionMetadataRefreshFuture;
        final updatedSession = _sessions
            .where((item) => item.sessionId == session.sessionId)
            .firstOrNull;
        if (updatedSession != null) {
          await _renameRemoteSession(
            updatedSession,
            _titleForMode(SessionTitleMode.firstMessage, firstMessage: text),
          );
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = '消息发送失败：$error');
      }
    }
  }

  Future<void> _pickComposerImage() async {
    final picked = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: '图片',
          extensions: <String>['png', 'jpg', 'jpeg', 'webp', 'gif'],
        ),
      ],
    );
    if (picked == null || !mounted) return;
    final contentType = _imageContentType(picked.name);
    if (contentType == null) {
      setState(() => _error = '请选择 PNG、JPEG、WebP 或 GIF 图片。');
      return;
    }
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      _composerImage = _ComposerImageAttachment(
        name: picked.name,
        bytes: bytes,
        contentType: contentType,
      );
      _error = null;
    });
  }

  String? _imageContentType(String filename) {
    final extension = filename.split('.').last.toLowerCase();
    return switch (extension) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => null,
    };
  }

  Future<void> _cancelExternalMessage() async {
    try {
      await _conversationController?.cancel();
    } catch (error) {
      if (mounted) {
        setState(() => _error = '取消消息失败：$error');
      }
    }
  }

  Future<void> _handleExternalRuntimeEvent(ExternalRuntimeEvent event) async {
    if (!mounted) {
      return;
    }
    final connectionGeneration = _conversationSnapshot.connectionGeneration;
    if (_externalEventDeduplicator.wasHandled(event, connectionGeneration)) {
      return;
    }
    try {
      if (!event.isBackpressureDrop &&
          !event.requestsConversationReconciliation) {
        return;
      }
      // The public event payload has no session id. Only the selected Runtime
      // session can be reconciled without guessing service state.
      if (!_requestConversationRefresh()) {
        return;
      }
      _externalEventDeduplicator.commit(event, connectionGeneration);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Runtime 事件处理失败：$error');
      }
    }
  }

  void _handleConversationSnapshot(RuntimeConversationSnapshot snapshot) {
    if (!mounted) return;
    final previousSnapshot = _conversationSnapshot;
    final selected = _selectedSession;
    final matchesSelection =
        selected != null && selected.externalSessionId == snapshot.sessionId;
    if (snapshot.sessionId != null && !matchesSelection) {
      setState(() {
        _initializing = snapshot.phase == RuntimeConversationPhase.activating;
        _sending = snapshot.phase == RuntimeConversationPhase.sending;
      });
      return;
    }
    final wasNearBottom =
        !_scrollController.hasClients ||
        isNearScrollBottom(
          pixels: _scrollController.position.pixels,
          maxScrollExtent: _scrollController.position.maxScrollExtent,
        );
    setState(() {
      _conversationSnapshot = snapshot;
      _initializing = snapshot.phase == RuntimeConversationPhase.activating;
      _sending = snapshot.phase == RuntimeConversationPhase.sending;
      if (matchesSelection) {
        _sessionMessages[selected.sessionId] = snapshot.displayMessages;
        if (snapshot.syncError is RuntimeConversationSyncPending) {
          _syncNotice =
              _runtimeOperationStatusNotice(snapshot.error) ??
              '回复已完成，Runtime 历史尚未同步；当前内容仅作为临时显示保留。';
          _error = null;
        } else {
          _syncNotice = snapshot.syncError == null
              ? null
              : 'Runtime 历史同步失败：${snapshot.syncError}';
          if (snapshot.error != null) {
            _error = snapshot.error.toString();
          } else if (snapshot.syncError != null) {
            _error = snapshot.syncError.toString();
          } else {
            _error = null;
          }
        }
      }
    });
    if (matchesSelection && wasNearBottom) _scrollToBottom();
    if (matchesSelection &&
        previousSnapshot.phase == RuntimeConversationPhase.reconciling &&
        snapshot.phase == RuntimeConversationPhase.ready &&
        previousSnapshot.connectionGeneration ==
            snapshot.connectionGeneration &&
        previousSnapshot.activationGeneration ==
            snapshot.activationGeneration &&
        previousSnapshot.characterId == snapshot.characterId &&
        previousSnapshot.sessionId == snapshot.sessionId) {
      _scheduleSessionMetadataRefresh(snapshot);
    }
    if (_deferredConversationRefresh &&
        snapshot.phase == RuntimeConversationPhase.ready &&
        matchesSelection) {
      unawaited(_drainDeferredConversationRefresh());
    }
  }

  bool _requestConversationRefresh() {
    final selected = _selectedSession;
    final snapshot = _conversationSnapshot;
    if (selected == null || selected.externalSessionId != snapshot.sessionId) {
      return false;
    }
    if (snapshot.phase != RuntimeConversationPhase.ready &&
        snapshot.phase != RuntimeConversationPhase.sending &&
        snapshot.phase != RuntimeConversationPhase.reconciling) {
      return false;
    }
    _deferredConversationRefresh = true;
    if (snapshot.phase == RuntimeConversationPhase.ready) {
      unawaited(_drainDeferredConversationRefresh());
    }
    return true;
  }

  Future<void> _drainDeferredConversationRefresh() async {
    if (!_deferredConversationRefresh || _conversationRefreshInFlight) {
      return;
    }
    final controller = _conversationController;
    final selectedRemoteId = _selectedSession?.externalSessionId;
    if (controller == null ||
        controller.snapshot.phase != RuntimeConversationPhase.ready ||
        controller.snapshot.sessionId != selectedRemoteId) {
      return;
    }
    _deferredConversationRefresh = false;
    if (mounted) {
      setState(() => _conversationRefreshInFlight = true);
    } else {
      _conversationRefreshInFlight = true;
    }
    var refreshSucceeded = false;
    try {
      await controller.refresh();
      refreshSucceeded = true;
    } catch (error) {
      _deferredConversationRefresh = true;
      if (mounted) setState(() => _error = '会话刷新失败：$error');
    } finally {
      if (mounted) {
        setState(() => _conversationRefreshInFlight = false);
      } else {
        _conversationRefreshInFlight = false;
      }
      if (refreshSucceeded && _deferredConversationRefresh && mounted) {
        unawaited(_drainDeferredConversationRefresh());
      }
    }
  }

  String? _runtimeOperationStatusNotice(Object? error) {
    if (error is! RuntimeConversationSendFailure) {
      return null;
    }
    return switch (error.code) {
      'message.operation_pending' => '消息已提交到 Runtime，当前仍在处理中；请刷新并确认服务端状态。',
      'message.operation_status_required' ||
      'message.status_unavailable' => '消息结果尚未确认；请刷新并确认 Runtime 状态，确认前不会重复发送。',
      'message.operation_outcome_unknown' =>
        '消息结果未知；请重新读取会话并确认服务端状态，确认后使用新的发送操作。',
      _ => null,
    };
  }

  bool get _needsRuntimeOperationConfirmation =>
      _runtimeOperationStatusNotice(_conversationSnapshot.error) != null;

  void _subscribeConversationController(
    RuntimeConversationController controller,
  ) {
    _conversationController = controller;
    _conversationSnapshot = controller.snapshot;
    _conversationSnapshotSubscription = controller.snapshots.listen(
      _handleConversationSnapshot,
    );
  }

  Future<void> _disposeRuntimeController() async {
    final subscription = _conversationSnapshotSubscription;
    final controller = _conversationController;
    final eventSubscription = _externalRuntimeEventSubscription;
    final connectionSubscription = _externalRuntimeConnectionSubscription;
    _conversationSnapshotSubscription = null;
    _conversationController = null;
    _externalRuntimeEventSubscription = null;
    _externalRuntimeConnectionSubscription = null;
    _externalRuntimeClient = null;
    _externalEventDeduplicator.reset();
    _deferredConversationRefresh = false;
    _conversationRefreshInFlight = false;
    _sessionMetadataRefreshToken = null;
    _testSessionList = null;
    _testConnectionId = null;
    await subscription?.cancel();
    await eventSubscription?.cancel();
    await connectionSubscription?.cancel();
    await controller?.dispose();
  }

  void _scheduleSessionMetadataRefresh(RuntimeConversationSnapshot snapshot) {
    if (_sessionMetadataRefreshToken != null) return;
    final controller = _conversationController;
    if (controller == null ||
        !_matchesMetadataRefreshTarget(controller, snapshot)) {
      return;
    }
    final token = Object();
    _sessionMetadataRefreshToken = token;
    final refresh = Future<void>.microtask(() async {
      try {
        if (!_matchesMetadataRefreshTarget(controller, snapshot)) return;
        await _loadSessions(
          expectedController: controller,
          expectedSnapshot: snapshot,
        );
      } finally {
        if (identical(_sessionMetadataRefreshToken, token)) {
          _sessionMetadataRefreshToken = null;
        }
      }
    });
    _sessionMetadataRefreshFuture = refresh;
    unawaited(
      refresh.whenComplete(() {
        if (identical(_sessionMetadataRefreshFuture, refresh)) {
          _sessionMetadataRefreshFuture = null;
        }
      }),
    );
  }

  bool _matchesMetadataRefreshTarget(
    RuntimeConversationController controller,
    RuntimeConversationSnapshot expected,
  ) {
    final current = controller.snapshot;
    return mounted &&
        identical(_conversationController, controller) &&
        current.phase == RuntimeConversationPhase.ready &&
        current.connectionGeneration == expected.connectionGeneration &&
        current.activationGeneration == expected.activationGeneration &&
        current.characterId == expected.characterId &&
        current.sessionId == expected.sessionId &&
        _selectedSession?.externalCharacterId == expected.characterId &&
        _selectedSession?.externalSessionId == expected.sessionId;
  }

  Future<void> _attachRuntimeForTesting({
    required RuntimeConversationController conversationController,
    required String connectionId,
    required Future<List<Map<String, dynamic>>> Function() listSessions,
    required List<Assistant> assistants,
  }) async {
    await _disposeRuntimeController();
    _testSessionList = listSessions;
    _testConnectionId = connectionId;
    _assistants = assistants;
    _subscribeConversationController(conversationController);
    await conversationController.connect();
    if (mounted) setState(() => _externalBackendAvailable = true);
  }

  void _scrollToBottom() {
    if (_scrollToBottomScheduled) return;
    _scrollToBottomScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottomScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  Future<void> _openSettings({SettingsInitialPage? initialPage}) async {
    if (_conversationBusy) return;
    final saved = await Navigator.of(context).push<AppSettings>(
      MaterialPageRoute<AppSettings>(
        builder: (context) => SettingsScreen(
          initialSettings: _settings,
          initialPage: initialPage,
          assistantRepository: _assistantArchiveRepository,
          conversationRepository: _conversationArchiveRepository,
          externalBackendAvailable: _externalBackendAvailable,
          activeExternalRuntimeConnectionId: _externalBackendAvailable
              ? _externalRuntimeClient?.connection.id
              : null,
          externalAgentRuntime:
              _externalRuntimeClient == null || !_externalBackendAvailable
              ? null
              : GensokyoAiHttpRuntimeFacade(_externalRuntimeClient!),
          onOperation: _applySettingsOperation,
          onActivateExternalRuntime: _activateExternalRuntimeFacade,
          onDeactivateExternalRuntime: _deactivateExternalRuntime,
        ),
      ),
    );
    if (saved == null || !mounted) {
      return;
    }

    await _liveSettingsWrites;
    if (!mounted) {
      return;
    }
  }

  Future<void> _applySettingsOperation(SettingsOperation operation) {
    final settings = operation.settings;
    final settingsChanged =
        settings != null &&
        jsonEncode(settings.toJson()) != jsonEncode(_settings.toJson());
    if (settingsChanged && mounted) {
      widget.onSettingsChanged?.call(settings);
      setState(() => _settings = settings);
    }

    final task = _liveSettingsWrites.then((_) async {
      var saved = false;
      var reloadedAssistants = false;
      var reloadedSessions = false;
      final failures = <String>[];

      if (settingsChanged) {
        try {
          await _settingsStore.save(settings);
          saved = true;
        } catch (error) {
          failures.add('设置保存失败：$error');
          if (mounted) {
            setState(() => _error = '设置保存失败：$error');
          }
        }
      }
      if (operation.activateExternalRuntime && settings != null) {
        try {
          final connection = settings.selectedExternalRuntimeConnection;
          if (connection == null) {
            throw StateError('没有可用的 Runtime 连接档案');
          }
          await _activateExternalRuntime(settings, connection.id);
          reloadedAssistants = await _loadAssistants();
          reloadedSessions = await _loadSessions();
        } catch (error) {
          failures.add('外部 Runtime 启用失败：$error');
        }
      } else if (operation.deactivateExternalRuntime) {
        await _deactivateExternalRuntime();
        reloadedAssistants = await _loadAssistants();
      }
      if (operation.reloadAssistants) {
        reloadedAssistants = await _loadAssistants();
        if (!reloadedAssistants) {
          failures.add('角色重载失败');
        }
      }
      if (operation.reloadSessions) {
        reloadedSessions = await _loadSessions();
        if (!reloadedSessions) {
          failures.add('会话重载失败');
        }
      }
      if (!mounted) {
        return;
      }
      final notice = formatSettingsOperationNotice(
        saved: saved,
        reloadedAssistants: reloadedAssistants,
        reloadedSessions: reloadedSessions,
      );
      if (notice != null || failures.isNotEmpty) {
        final messages = <String>[...failures];
        if (notice != null) {
          messages.insert(0, notice);
        }
        showTopNotice(context, messages.join('；'));
      }
    });
    _liveSettingsWrites = task;
    return task;
  }

  Future<void> _activateExternalRuntime(
    AppSettings settings,
    String connectionId,
  ) async {
    final connection = settings.externalRuntimeConnectionById(connectionId);
    if (connection == null) {
      throw StateError('Runtime 连接档案不存在：$connectionId');
    }
    await _deactivateExternalRuntime();
    final client = GensokyoAiHttpRuntimeClient(connection: connection);
    final controller = RuntimeConversationController(
      runtime: GensokyoAiConversationRuntime(
        client: client,
        profile: connection.delegatedProfileId == settings.activeProfile.id
            ? settings.activeProfile
            : null,
      ),
    );
    try {
      _externalRuntimeClient = client;
      _runtimeDisconnectNotified = false;
      _subscribeConversationController(controller);
      _externalRuntimeEventSubscription = client.events.listen((event) {
        unawaited(_handleExternalRuntimeEvent(event));
      });
      _externalRuntimeConnectionSubscription = client.connectionStates.listen((
        connected,
      ) {
        if (!connected && !_runtimeDisconnectNotified) {
          _runtimeDisconnectNotified = true;
          if (_conversationController != null &&
              _conversationController!.snapshot.phase !=
                  RuntimeConversationPhase.disconnected) {
            _conversationController!.notifyRuntimeDisconnected();
          }
        }
        if (!connected && mounted) {
          setState(() {
            _externalBackendAvailable = false;
            _error = '外部 Runtime 连接已断开';
          });
        }
      });
      await controller.connect();
    } catch (_) {
      await _disposeRuntimeController();
      if (mounted) {
        setState(() {
          _externalBackendAvailable = false;
          _conversationSnapshot = RuntimeConversationSnapshot.disconnected();
          _assistants = const <Assistant>[];
          _sessions = const <ChatSession>[];
          _selectedSession = null;
        });
      }
      rethrow;
    }
    if (mounted) {
      setState(() => _externalBackendAvailable = true);
    }
  }

  Future<ExternalAgentRuntime> _activateExternalRuntimeFacade(
    AppSettings settings,
    String connectionId,
  ) async {
    await _activateExternalRuntime(settings, connectionId);
    await _loadAssistants();
    await _loadSessions();
    return GensokyoAiHttpRuntimeFacade(_externalRuntimeClient!);
  }

  Future<void> _deactivateExternalRuntime() async {
    await _disposeRuntimeController();
    if (mounted) {
      setState(() {
        _externalBackendAvailable = false;
        _conversationSnapshot = RuntimeConversationSnapshot.disconnected();
        _initializing = false;
        _sending = false;
        _assistants = const <Assistant>[];
        _sessions = const <ChatSession>[];
        _selectedSession = null;
      });
    }
  }

  Future<void> _openBackendSettings() {
    return _openSettings(initialPage: SettingsInitialPage.backend);
  }

  /// Material 3 窗口宽度断点：compact 抽屉化，medium 单侧栏，expanded 三栏。
  _PaneLayout _paneLayoutFor(double logicalWidth) {
    if (logicalWidth < 600) {
      return _PaneLayout.compact;
    }
    if (logicalWidth < 840) {
      return _PaneLayout.medium;
    }
    return _PaneLayout.expanded;
  }

  // build 期间由 LayoutBuilder 写入；MediaQuery 在测试环境不反映
  // setSurfaceSize，统一以实际布局约束为准。
  _PaneLayout _paneLayout = _PaneLayout.expanded;

  void _toggleSidebar(BuildContext context) {
    if (_paneLayout == _PaneLayout.compact) {
      // compact 档面板以抽屉呈现：开关即开关抽屉，不改内嵌意图。
      final scaffold = _scaffoldKey.currentState!;
      if (scaffold.isDrawerOpen) {
        scaffold.closeDrawer();
      } else {
        scaffold.openDrawer();
      }
      return;
    }
    setState(() {
      _sidebarVisible = !_sidebarVisible;
      if (_sidebarVisible) {
        _contextPanePriority = false;
      }
    });
  }

  void _toggleContextPane(BuildContext context) {
    if (_paneLayout == _PaneLayout.compact) {
      final scaffold = _scaffoldKey.currentState!;
      if (scaffold.isEndDrawerOpen) {
        scaffold.closeEndDrawer();
      } else {
        scaffold.openEndDrawer();
      }
      return;
    }
    setState(() {
      _contextPaneVisible = !_contextPaneVisible;
      if (_contextPaneVisible) {
        _contextPanePriority = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: _shortcutBindings(),
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, viewportConstraints) {
            _paneLayout = _paneLayoutFor(viewportConstraints.maxWidth);
            final layout = _paneLayout;
            final compact = layout == _PaneLayout.compact;
            return Scaffold(
              key: _scaffoldKey,
              // compact 档两侧面板改为抽屉呈现，聊天区独占；用户意图字段不变，
              // 窗口拉宽后自动恢复内嵌形态。
              drawer: compact
                  ? Drawer(child: SafeArea(child: _buildSidebar(context)))
                  : null,
              endDrawer: compact
                  ? Drawer(child: SafeArea(child: _buildContextPane(context)))
                  : null,
              body: LayoutBuilder(
                builder: (context, constraints) {
                  if (compact) {
                    return _buildChatPane(context);
                  }
                  // medium 档只放得下一个面板：尊重双开意图，但按最近操作
                  // 只呈现其中一个（被挤掉的不算用户关闭）。
                  var showSidebar = _sidebarVisible;
                  var showContextPane = _contextPaneVisible;
                  if (layout == _PaneLayout.medium &&
                      showSidebar &&
                      showContextPane) {
                    if (_contextPanePriority) {
                      showSidebar = false;
                    } else {
                      showContextPane = false;
                    }
                  }
                  final sidebarWidth = _clampPaneWidth(
                    _sidebarWidth,
                    constraints.maxWidth,
                    paneCount:
                        (showSidebar ? 1 : 0) + (showContextPane ? 1 : 0),
                  );
                  final contextPaneWidth = _clampPaneWidth(
                    _contextPaneWidth,
                    constraints.maxWidth,
                    paneCount:
                        (showSidebar ? 1 : 0) + (showContextPane ? 1 : 0),
                  );
                  return Row(
                    children: <Widget>[
                      TweenAnimationBuilder<double>(
                        key: const ValueKey<String>('sidebarPaneSlot'),
                        tween: Tween<double>(end: showSidebar ? 1 : 0),
                        duration: const Duration(milliseconds: 240),
                        curve: Curves.easeInOut,
                        builder: (context, widthFactor, child) {
                          if (widthFactor <= 0) {
                            return const SizedBox.shrink();
                          }
                          return ExcludeSemantics(
                            excluding: !showSidebar,
                            child: IgnorePointer(
                              ignoring: !showSidebar,
                              child: ClipRect(
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: widthFactor,
                                  child: FractionalTranslation(
                                    translation: Offset(widthFactor - 1, 0),
                                    child: child,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            SizedBox(
                              width: sidebarWidth,
                              child: _buildSidebar(context),
                            ),
                            _PaneResizeHandle(
                              key: const ValueKey<String>(
                                'sidebarResizeHandle',
                              ),
                              onDrag: (delta) {
                                // 返回实际应用的位移，让拖拽控件保留撞到边界
                                // 后尚未应用的部分，反向拖动时先抵消它。
                                final previous = _sidebarWidth;
                                final next = _clampPaneWidth(
                                  previous + delta,
                                  constraints.maxWidth,
                                );
                                if (next != previous) {
                                  setState(() => _sidebarWidth = next);
                                }
                                return next - previous;
                              },
                            ),
                          ],
                        ),
                      ),
                      Expanded(child: _buildChatPane(context)),
                      TweenAnimationBuilder<double>(
                        key: const ValueKey<String>('contextPaneSlot'),
                        tween: Tween<double>(end: showContextPane ? 1 : 0),
                        duration: const Duration(milliseconds: 240),
                        curve: Curves.easeInOut,
                        builder: (context, widthFactor, child) {
                          if (widthFactor <= 0) {
                            return const SizedBox.shrink();
                          }
                          return ExcludeSemantics(
                            excluding: !showContextPane,
                            child: IgnorePointer(
                              ignoring: !showContextPane,
                              child: ClipRect(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  widthFactor: widthFactor,
                                  child: FractionalTranslation(
                                    translation: Offset(1 - widthFactor, 0),
                                    child: child,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            _PaneResizeHandle(
                              key: const ValueKey<String>(
                                'contextPaneResizeHandle',
                              ),
                              onDrag: (delta) {
                                final previous = _contextPaneWidth;
                                final next = _clampPaneWidth(
                                  previous - delta,
                                  constraints.maxWidth,
                                );
                                if (next != previous) {
                                  setState(() => _contextPaneWidth = next);
                                }
                                // 右侧分隔线向右移动会让面板变窄，
                                // 所以实际消耗的鼠标位移方向相反。
                                return previous - next;
                              },
                            ),
                            SizedBox(
                              width: contextPaneWidth,
                              child: _buildContextPane(context),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  double _clampPaneWidth(double width, double totalWidth, {int paneCount = 2}) {
    // 给中间聊天区保留最小空间；按实际展示的面板数分摊剩余宽度。
    final panes = paneCount < 1 ? 1 : paneCount;
    final maxWidth = (totalWidth - _minChatPaneWidth) / panes;
    if (maxWidth <= _minPaneWidth) {
      return _minPaneWidth;
    }
    return width.clamp(_minPaneWidth, maxWidth);
  }

  Widget _buildSidebar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Card(
              elevation: 0,
              margin: const EdgeInsets.all(4),
              child: Padding(
                // Card 默认外边距为 4px；配合这里的 4px 内顶部距，
                // 让标题行距离面板上边缘正好为 8px。
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      key: const ValueKey<String>('sessionListHeader'),
                      children: <Widget>[
                        IconButton.filledTonal(
                          key: const ValueKey<String>('sidebarToggleButton'),
                          tooltip: '收起会话列表',
                          onPressed: () => _toggleSidebar(context),
                          icon: const Icon(Icons.vertical_split_outlined),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '会话列表',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (!_sessionsLoaded || _sessions.isEmpty) ...<Widget>[
                      Text(
                        !_sessionsLoaded
                            ? '正在等待 GensokyoAI 会话列表。'
                            : _externalBackendAvailable
                            ? '在 GensokyoAI 中创建会话后即可开始对话。'
                            : '请先显式连接 GensokyoAI Runtime。',
                      ),
                      const SizedBox(height: 12),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed:
                            _loading || _managingSession || _conversationBusy
                            ? null
                            : _createRemoteSession,
                        icon: const Icon(Icons.add),
                        label: const Text('新会话'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed:
                            _loading ||
                                _managingSession ||
                                _conversationBusy ||
                                !_externalBackendAvailable
                            ? null
                            : _loadCharacterSessions,
                        icon: const Icon(Icons.history),
                        label: const Text('加载角色历史会话'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_sessionListError != null && _sessions.isNotEmpty)
            MaterialBanner(
              content: Text(_sessionListError!),
              actions: <Widget>[
                TextButton(
                  onPressed: _loading || _conversationBusy
                      ? null
                      : _reloadSessionsWithNotice,
                  child: const Text('重试'),
                ),
              ],
            ),
          Expanded(
            child: !_sessionsLoaded && _sessions.isEmpty
                ? _buildLoadingSessionState(context)
                : _sessionListError != null && _sessions.isEmpty
                ? _buildSessionListErrorState(context)
                : _sessions.isEmpty
                ? _buildEmptySessionState(context)
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    buildDefaultDragHandles: false,
                    itemCount: _sessions.length,
                    onReorderItem: _reorderSessions,
                    itemBuilder: (context, index) {
                      final session = _sessions[index];
                      final selected =
                          session.sessionId == _selectedSession?.sessionId;
                      final avatarProvider = _sessionAvatarProvider(session);
                      return Card(
                        key: ValueKey<String>(
                          'sessionCard_${session.sessionId}',
                        ),
                        elevation: selected ? 2 : 0,
                        color: selected ? colorScheme.primaryContainer : null,
                        child: ListTile(
                          selected: selected,
                          leading: ReorderableDragStartListener(
                            key: ValueKey<String>(
                              'sessionDragHandle_${session.sessionId}',
                            ),
                            index: index,
                            enabled: !_conversationBusy,
                            child: Tooltip(
                              message: '拖动排序',
                              child: SizedBox.square(
                                dimension: 40,
                                child: Center(
                                  child: avatarProvider == null
                                      ? const Icon(Icons.drag_indicator)
                                      : _sessionAvatarWidget(
                                          session,
                                          radius: 20,
                                          key: ValueKey<String>(
                                            'sessionAvatar_${session.sessionId}',
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ),
                          title: Text(
                            session.title.isEmpty ? '未命名会话' : session.title,
                          ),
                          subtitle: Text(
                            <String>[
                              _externalMappingStatusLabel(
                                session.externalMappingStatus,
                              ),
                              if (_settings.developer.showDebugInfo)
                                session.sessionId,
                              session.activeAssistantId.isEmpty
                                  ? '${session.totalTurns} 轮'
                                  : '角色：${_assistantDisplayName(session.activeAssistantId)} · ${session.totalTurns} 轮',
                            ].join('\n'),
                          ),
                          isThreeLine: _settings.developer.showDebugInfo,
                          onTap: _managingSession || _conversationBusy
                              ? null
                              : () => _initializeSession(session),
                        ),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    key: const ValueKey<String>('sidebarBrand'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        'HakureiTerminal',
                        style: Theme.of(context).textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '一个 GensokyoAI 客户端',
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  key: const ValueKey<String>('openSettingsButton'),
                  tooltip: '打开设置',
                  onPressed: _conversationBusy ? null : _openSettings,
                  icon: const Icon(Icons.settings),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptySessionState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.inbox_outlined, size: 48),
            const SizedBox(height: 12),
            Text('还没有会话', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              _externalBackendAvailable
                  ? '选择远程角色，由 GensokyoAI 创建并管理会话。'
                  : '请先在服务管理中显式连接 GensokyoAI Runtime。',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loading || _managingSession || _conversationBusy
                  ? null
                  : _createRemoteSession,
              icon: const Icon(Icons.add_comment_outlined),
              label: const Text('创建会话'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingSessionState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(width: 160, child: LinearProgressIndicator()),
          const SizedBox(height: 16),
          Text('正在加载会话…', style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }

  Widget _buildSessionListErrorState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text('会话列表加载失败', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(
              contextMenuBuilder: jovTextContextMenu,
              _sessionListError!,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loading || _conversationBusy
                  ? null
                  : _reloadSessionsWithNotice,
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatPane(BuildContext context) {
    final backgroundFile = resolveSessionBackgroundFile(
      _selectedSession,
      _conversationArchiveRepository.paths,
    );
    return AppBackground(
      file: backgroundFile,
      color: Colors.transparent,
      child: Column(
        children: <Widget>[
          _buildChatHeader(context),
          if (_initializing) const LinearProgressIndicator(),
          if (_error != null) _buildActionableErrorBanner(context),
          if (_syncNotice != null)
            MaterialBanner(
              key: const ValueKey<String>('conversationSyncBanner'),
              content: Text(_syncNotice!),
              leading: const Icon(Icons.sync_outlined),
              actions: <Widget>[
                TextButton(
                  onPressed:
                      _conversationSnapshot.phase ==
                              RuntimeConversationPhase.ready &&
                          !_conversationRefreshInFlight
                      ? _requestConversationRefresh
                      : null,
                  child: Text(
                    _conversationRefreshInFlight
                        ? '确认中…'
                        : _needsRuntimeOperationConfirmation
                        ? '刷新并确认'
                        : '重新同步',
                  ),
                ),
              ],
            ),
          Expanded(
            key: const ValueKey<String>('chatMessagesViewport'),
            child: _currentMessages.isEmpty
                ? _buildChatEmptyState(context)
                : ListView.builder(
                    key: ValueKey<String>(
                      'messageList:${_selectedSession!.sessionId}',
                    ),
                    controller: _scrollController,
                    padding: const EdgeInsets.all(10),
                    itemCount: _currentMessages.length,
                    itemBuilder: (context, index) {
                      final message = _currentMessages[index];
                      return _MessageBubble(
                        key: ValueKey<String>('message:${message.id}'),
                        message: message,
                        assistantName: _assistantNameForMessage(message),
                        avatarProvider: _avatarProviderForMessage(message),
                        bubbleStyle: _settings.appearance.bubbleStyle,
                        cornerRadius: _settings.appearance.cornerRadius,
                        excludedFromContext: false,
                        ttsConfigured: _settings.tts.isConfigured,
                        ttsActive: _ttsMessageId == message.id,
                        ttsPaused: _ttsPlayerState == PlayerState.paused,
                        ttsBusy: _ttsBusy && _ttsMessageId == message.id,
                        onSpeak: () => _speakMessage(message),
                        onToggleTts: _toggleTtsPlayback,
                        onStopTts: _stopTts,
                      );
                    },
                  ),
          ),
          if (_sending ||
              _conversationSnapshot.phase ==
                  RuntimeConversationPhase.reconciling)
            const LinearProgressIndicator(),
          _buildComposer(context),
        ],
      ),
    );
  }

  Widget _buildChatHeader(BuildContext context) {
    final session = _selectedSession;
    final textTheme = Theme.of(context).textTheme;
    final showSidebarButton =
        _paneLayout == _PaneLayout.compact || !_sidebarVisible;
    final showContextPaneButton =
        _paneLayout == _PaneLayout.compact || !_contextPaneVisible;
    final profileChipWidth = _chatHeaderProfileChipWidth(context);
    return Material(
      key: const ValueKey<String>('chatPaneHeader'),
      color: Theme.of(context).colorScheme.surface,
      elevation: 1,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              var occupiedWidth = showSidebarButton ? 60.0 : 0.0;
              if (showContextPaneButton) {
                occupiedWidth += 60;
              }

              final reloadWidth = showContextPaneButton ? 56.0 : 60.0;
              final showReload =
                  occupiedWidth + reloadWidth <= constraints.maxWidth;
              if (showReload) {
                occupiedWidth += reloadWidth;
              }

              final showAvatar =
                  session != null &&
                  showReload &&
                  occupiedWidth + 46 <= constraints.maxWidth;
              if (showAvatar) {
                occupiedWidth += 46;
              }

              final hasTrailingControl = showReload || showContextPaneButton;
              final profileWidth =
                  profileChipWidth + (hasTrailingControl ? 8 : 12);
              final showProfile =
                  showReload &&
                  (session == null || showAvatar) &&
                  occupiedWidth + profileWidth <= constraints.maxWidth;

              final trailingControls = <Widget>[];
              void addTrailingControl(Widget control) {
                trailingControls.add(
                  SizedBox(width: trailingControls.isEmpty ? 12 : 8),
                );
                trailingControls.add(control);
              }

              if (showProfile) {
                addTrailingControl(
                  SizedBox(
                    width: profileChipWidth,
                    child: Chip(
                      key: const ValueKey<String>('chatHeaderProfileChip'),
                      avatar: const Icon(Icons.tune, size: 18),
                      label: Text(
                        _settings.activeProfile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                );
              }
              if (showReload) {
                addTrailingControl(
                  IconButton(
                    key: const ValueKey<String>('reloadSessionsButton'),
                    tooltip: '刷新当前会话和列表',
                    onPressed: _loading || _conversationBusy
                        ? null
                        : _reloadSessionsWithNotice,
                    icon: const Icon(Icons.refresh),
                  ),
                );
              }
              if (showContextPaneButton) {
                addTrailingControl(
                  IconButton.filledTonal(
                    key: const ValueKey<String>('contextPaneToggleButton'),
                    tooltip: '展开会话选项',
                    onPressed: () => _toggleContextPane(context),
                    icon: const Icon(Icons.menu_open_outlined),
                  ),
                );
              }

              return Row(
                children: <Widget>[
                  if (showSidebarButton) ...<Widget>[
                    IconButton.filledTonal(
                      key: const ValueKey<String>('sidebarToggleButton'),
                      tooltip: '展开会话列表',
                      onPressed: () => _toggleSidebar(context),
                      icon: const Icon(Icons.menu_open_outlined),
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (showAvatar) ...<Widget>[
                    _sessionHeaderAvatar(session),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          session == null
                              ? '尚未选择会话'
                              : session.title.isEmpty
                              ? '未命名会话'
                              : session.title,
                          style: textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          session == null
                              ? '从会话列表选择一个会话开始对话'
                              : '${session.totalTurns} 轮 · 最后活动：${session.lastActive?.toLocal().toString() ?? '未知'}',
                          style: textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  ...trailingControls,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  double _chatHeaderProfileChipWidth(BuildContext context) {
    final theme = Theme.of(context);
    final textPainter = TextPainter(
      text: TextSpan(
        text: _settings.activeProfile.name,
        style: theme.chipTheme.labelStyle ?? theme.textTheme.labelLarge,
      ),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = (textPainter.width + 64).clamp(96.0, 240.0).toDouble();
    textPainter.dispose();
    return width;
  }

  String _assistantNameForMessage(ChatMessage message) {
    if (message.role == ChatMessageRole.user) {
      return _settings.activeUserNickname;
    }
    for (final assistant in _assistants) {
      if (assistant.id == message.assistantId) {
        return assistant.name;
      }
    }
    return message.assistantId.isNotEmpty ? message.assistantId : '角色';
  }

  ImageProvider? _avatarProviderForReference(String reference) {
    final normalized = reference.trim();
    if (normalized.isEmpty) {
      return null;
    }
    final file = _conversationArchiveRepository.paths.managedMediaFile(
      normalized,
    );
    if (file != null && file.existsSync()) {
      return FileImage(file);
    }
    final uri = Uri.tryParse(normalized);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return NetworkImage(normalized);
    }
    return null;
  }

  ImageProvider? _activeUserAvatarProvider() {
    for (final role in _settings.userRoles) {
      if (role.id == _settings.activeUserRoleId) {
        return _avatarProviderForReference(role.avatarImagePath);
      }
    }
    return null;
  }

  ImageProvider? _avatarProviderForMessage(ChatMessage message) {
    if (message.role == ChatMessageRole.user) {
      return _activeUserAvatarProvider();
    }
    for (final assistant in _assistants) {
      if (assistant.id == message.assistantId) {
        return _avatarProviderForReference(assistant.avatar);
      }
    }
    return null;
  }

  Widget _sessionHeaderAvatar(ChatSession session) {
    final avatar = _sessionAvatarProvider(session);
    return CircleAvatar(
      key: const ValueKey<String>('chatHeaderSessionAvatar'),
      radius: 18,
      foregroundImage: avatar,
      onForegroundImageError: avatar == null ? null : (_, _) {},
      child: const Icon(Icons.account_circle_outlined, size: 22),
    );
  }

  Widget _buildActionableErrorBanner(BuildContext context) {
    return MaterialBanner(
      key: const ValueKey<String>('conversationErrorBanner'),
      content: SelectableText(contextMenuBuilder: jovTextContextMenu, _error!),
      leading: const Icon(Icons.error_outline),
      actions: <Widget>[
        TextButton(onPressed: _openBackendSettings, child: const Text('服务管理')),
        TextButton(
          onPressed: () => setState(() => _error = null),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildChatEmptyState(BuildContext context) {
    final hasSelectedSession = _selectedSession != null;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.chat_bubble_outline, size: 48),
              const SizedBox(height: 12),
              Text(
                hasSelectedSession
                    ? '当前会话暂无消息。发送第一条消息后会在这里展示对话。'
                    : '选择或创建会话后开始对话',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildComposer(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final cornerRadius = _settings.appearance.cornerRadius;
    final sendBlockers = _sendBlockersForCurrentSelection();
    final composerEnabled = !_conversationBusy && _selectedSession != null;
    final sendEnabled = composerEnabled && sendBlockers.isEmpty;
    final imageInputEnabled =
        composerEnabled &&
        (_externalRuntimeClient?.supportsMediaImageInput ?? false);
    final canCancelExternal =
        _effectiveConversationSnapshot.phase ==
            RuntimeConversationPhase.sending &&
        _conversationController != null;
    final blockerSummary = sendBlockers.isEmpty
        ? ''
        : _bindingCapabilityLossSummary(sendBlockers);
    return Material(
      color: colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_composerImage
                case final _ComposerImageAttachment image) ...<Widget>[
              Row(
                key: const ValueKey<String>('composerImageAttachment'),
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.memory(
                      image.bytes,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(image.name, overflow: TextOverflow.ellipsis),
                  ),
                  IconButton(
                    tooltip: '移除图片',
                    onPressed: _conversationBusy
                        ? null
                        : () => setState(() => _composerImage = null),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 6),
            ],
            Container(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh,
                border: Border.all(color: colorScheme.outlineVariant),
                borderRadius: BorderRadius.all(Radius.circular(cornerRadius)),
              ),
              // 裁剪掉发送区溢出的直角，让它和输入区共享同一个圆角矩形。
              clipBehavior: Clip.antiAlias,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        key: const ValueKey<String>('composerInput'),
                        contextMenuBuilder: jovTextContextMenu,
                        controller: _messageController,
                        focusNode: _messageFocusNode,
                        enabled: composerEnabled,
                        minLines: 1,
                        maxLines: 6,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.fromLTRB(
                            14,
                            12,
                            8,
                            12,
                          ),
                          hintText: composerEnabled
                              ? _settings.shortcuts.isEnabled(
                                      AppShortcutId.sendMessage,
                                    )
                                    ? '输入消息，按 Ctrl+Enter 发送'
                                    : _settings.shortcuts.isEnabled(
                                        AppShortcutId.sendMessageOnEnter,
                                      )
                                    ? '输入消息，按 Enter 发送'
                                    : '输入消息'
                              : _selectedSession == null
                              ? '请先选择会话'
                              : _sending
                              ? '正在发送消息'
                              : _effectiveConversationSnapshot.phase ==
                                    RuntimeConversationPhase.reconciling
                              ? '正在同步会话'
                              : '正在初始化会话',
                        ),
                      ),
                    ),
                    Tooltip(
                      message: canCancelExternal
                          ? '取消外部消息'
                          : blockerSummary.isEmpty
                          ? '发送消息'
                          : '当前无法发送：$blockerSummary',
                      child: Material(
                        color: sendEnabled || canCancelExternal
                            ? colorScheme.primary
                            : colorScheme.onSurface.withValues(alpha: 0.12),
                        // 自带右侧圆角，与外层圆角矩形贴合。
                        borderRadius: BorderRadius.horizontal(
                          right: Radius.circular(
                            (cornerRadius - 1)
                                .clamp(0, cornerRadius)
                                .toDouble(),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          key: const ValueKey<String>('composerSendButton'),
                          onTap: canCancelExternal
                              ? _cancelExternalMessage
                              : sendEnabled
                              ? _sendMessage
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Center(
                              child: Icon(
                                canCancelExternal ? Icons.stop : Icons.send,
                                size: 20,
                                color: sendEnabled || canCancelExternal
                                    ? colorScheme.onPrimary
                                    : colorScheme.onSurface.withValues(
                                        alpha: 0.38,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Scrollbar(
              controller: _composerActionsScrollController,
              thumbVisibility: true,
              child: ScrollConfiguration(
                // 桌面端默认不允许鼠标拖拽滚动，这里显式放开。
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: <PointerDeviceKind>{
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.stylus,
                  },
                ),
                child: SingleChildScrollView(
                  controller: _composerActionsScrollController,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: <Widget>[
                      _composerMenuButton(
                        key: const ValueKey<String>('composerModelMenu'),
                        icon: Icons.model_training_outlined,
                        label: '模型',
                        items: const <(IconData, String)>[
                          (Icons.smart_toy_outlined, '模型占位 A'),
                          (Icons.smart_toy_outlined, '模型占位 B'),
                        ],
                      ),
                      const SizedBox(width: 4),
                      _composerMenuButton(
                        key: const ValueKey<String>('composerInsertMenu'),
                        icon: Icons.attach_file_outlined,
                        label: '插入',
                        onSelected: (value) {
                          if (value == '插入媒体') {
                            if (imageInputEnabled) {
                              unawaited(_pickComposerImage());
                            } else {
                              showTopNotice(context, '当前 Runtime 未声明图片输入能力');
                            }
                          } else {
                            showTopNotice(context, '“$value”当前仅为界面预览。');
                          }
                        },
                        items: const <(IconData, String)>[
                          (Icons.photo_camera_outlined, '拍照'),
                          (Icons.videocam_outlined, '录像'),
                          (Icons.image_outlined, '插入媒体'),
                          (Icons.description_outlined, '插入文件'),
                        ],
                      ),
                      const SizedBox(width: 4),
                      _composerMenuButton(
                        key: const ValueKey<String>('composerSearchMenu'),
                        icon: Icons.travel_explore_outlined,
                        label: '搜索',
                        items: const <(IconData, String)>[
                          (Icons.search_outlined, '搜索占位 A'),
                          (Icons.search_outlined, '搜索占位 B'),
                        ],
                      ),
                      const SizedBox(width: 4),
                      _composerMenuButton(
                        key: const ValueKey<String>('composerThinkingMenu'),
                        icon: Icons.psychology_outlined,
                        label: '思考',
                        items: const <(IconData, String)>[
                          (Icons.psychology_outlined, '思考'),
                          (Icons.psychology_alt_outlined, '不思考'),
                        ],
                      ),
                      const SizedBox(width: 4),
                      _composerActionButton(
                        icon: Icons.hub_outlined,
                        label: 'MCP',
                      ),
                      const SizedBox(width: 4),
                      _composerActionButton(
                        icon: Icons.map_outlined,
                        label: '小地图',
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (blockerSummary.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '当前无法发送：$blockerSummary',
                key: const ValueKey<String>('sendBlockerMessage'),
                style: TextStyle(color: colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // 输入框下方的功能入口，目前只做界面占位，点击提示即将支持。
  Widget _composerActionButton({
    required IconData icon,
    required String label,
  }) {
    return TextButton.icon(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onPressed: () {
        showTopNotice(context, '“$label”功能即将支持，当前仅为界面预览。');
      },
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }

  Widget _composerMenuButton({
    Key? key,
    required IconData icon,
    required String label,
    required List<(IconData, String)> items,
    ValueChanged<String>? onSelected,
  }) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return PopupMenuButton<String>(
      key: key,
      tooltip: label,
      position: PopupMenuPosition.under,
      onSelected: (value) {
        final handler = onSelected;
        if (handler != null) {
          handler(value);
        } else {
          showTopNotice(context, '“$value”当前仅为界面预览。');
        }
      },
      itemBuilder: (context) => items
          .map(
            (item) => PopupMenuItem<String>(
              value: item.$2,
              child: Row(
                children: <Widget>[
                  Icon(item.$1, size: 18),
                  const SizedBox(width: 10),
                  Text(item.$2),
                ],
              ),
            ),
          )
          .toList(growable: false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: color)),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 18, color: color),
          ],
        ),
      ),
    );
  }

  Widget _buildContextPane(BuildContext context) {
    final session = _selectedSession;
    final assistant = _selectedAssistant;

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ListView(
        key: const ValueKey<String>('contextPaneListView'),
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        children: <Widget>[
          Card(
            elevation: 0,
            margin: const EdgeInsets.all(4),
            child: Padding(
              // Card 默认外边距为 4px；配合这里的 4px 内顶部距，
              // 让标题行距离面板上边缘正好为 8px。
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    key: const ValueKey<String>('contextPaneHeader'),
                    children: <Widget>[
                      IconButton.filledTonal(
                        key: const ValueKey<String>('contextPaneCloseButton'),
                        tooltip: '收起会话选项',
                        onPressed: () => _toggleContextPane(context),
                        icon: const Icon(Icons.vertical_split_outlined),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '会话选项',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text('会话与角色由 GensokyoAI Runtime 管理；本页只保存客户端显示偏好。'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _ContextDetailCard(
            title: '会话头像',
            icon: Icons.account_circle_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  height: 112,
                  child: Center(child: _sessionAvatarPreview(context, session)),
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.tonalIcon(
                        key: const ValueKey<String>('sessionAvatarPicker'),
                        onPressed: session == null || _sessionAvatarBusy
                            ? null
                            : () => _pickSessionAvatar(session),
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: Text(
                          session?.avatarImagePath.isEmpty ?? true
                              ? '选择头像'
                              : '更换头像',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: '移除会话头像',
                      child: IconButton.outlined(
                        key: const ValueKey<String>('sessionAvatarRemove'),
                        onPressed:
                            session == null ||
                                session.avatarImagePath.isEmpty ||
                                _sessionAvatarBusy
                            ? null
                            : () => _removeSessionAvatar(session),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                  ],
                ),
                if (_sessionAvatarBusy) ...<Widget>[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _ContextDetailCard(
            title: '会话背景',
            icon: Icons.image_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.all(
                      Radius.circular(_settings.appearance.cornerRadius),
                    ),
                    child: _sessionBackgroundPreview(context, session),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.tonalIcon(
                        key: const ValueKey<String>('sessionBackgroundPicker'),
                        onPressed: session == null || _sessionBackgroundBusy
                            ? null
                            : () => _pickSessionBackground(session),
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: Text(
                          session?.backgroundImagePath.isEmpty ?? true
                              ? '选择图片'
                              : '更换图片',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: '移除会话背景',
                      child: IconButton.outlined(
                        key: const ValueKey<String>('sessionBackgroundRemove'),
                        onPressed:
                            session == null ||
                                session.backgroundImagePath.isEmpty ||
                                _sessionBackgroundBusy
                            ? null
                            : () => _removeSessionBackground(session),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                  ],
                ),
                if (_sessionBackgroundBusy) ...<Widget>[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _ContextDetailCard(
            title: '远程会话',
            icon: Icons.cloud_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('会话: ${session?.title ?? '未选择'}'),
                const SizedBox(height: 8),
                Text('角色: ${assistant?.name ?? '由 Runtime 管理'}'),
                const SizedBox(height: 8),
                const Text('执行配置、上下文、记忆与生成状态均由 GensokyoAI 管理。'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sessionBackgroundPreview(BuildContext context, ChatSession? session) {
    final file = resolveSessionBackgroundFile(
      session,
      _conversationArchiveRepository.paths,
    );
    if (file == null) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: Text(
            '全局',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return Image.file(
      file,
      key: ValueKey<String>('sessionBackgroundPreview:${file.path}'),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    );
  }

  Widget _sessionAvatarPreview(BuildContext context, ChatSession? session) {
    if (session == null) {
      return const AvatarImage(radius: 48);
    }
    return _sessionAvatarWidget(session, radius: 48);
  }

  List<CapabilityLoss> _sendBlockersForCurrentSelection() {
    final session = _selectedSession;
    if (session == null) {
      return const <CapabilityLoss>[];
    }
    if (_conversationController == null || !_externalBackendAvailable) {
      return const <CapabilityLoss>[
        CapabilityLoss(
          code: 'connection_required',
          severity: 'blocked',
          title: '需要连接 GensokyoAI',
          description: 'HakureiTerminal 不提供本地聊天回退。',
          affectedFeatures: <String>['send_message', 'create_session'],
          recoverAction: '在服务管理中显式连接 GensokyoAI Runtime。',
        ),
      ];
    }
    if (session.externalMappingStatus != ExternalMappingStatus.verified) {
      return <CapabilityLoss>[
        CapabilityLoss(
          code: 'mapping_${session.externalMappingStatus.name}',
          severity: 'blocked',
          title: '远程会话映射尚未验证',
          description:
              '当前映射状态：${_externalMappingStatusLabel(session.externalMappingStatus)}。',
          affectedFeatures: const <String>['send_message'],
          recoverAction:
              session.externalMappingStatus == ExternalMappingStatus.stale
              ? '加载该角色的历史会话重新验证，或选择其他会话。'
              : '重新选择该会话以显式激活并验证。',
        ),
      ];
    }
    final assistant = _selectedAssistant;
    if (assistant == null ||
        assistant.providerId != AssistantProviderId.gensokyoAi ||
        session.externalSessionId.isEmpty ||
        session.externalCharacterId.isEmpty) {
      return const <CapabilityLoss>[
        CapabilityLoss(
          code: 'remote_mapping_required',
          severity: 'blocked',
          title: '远程会话映射不完整',
          description: '发送需要 Runtime 会话和 Runtime 角色的明确映射。',
          affectedFeatures: <String>['send_message'],
          recoverAction: '刷新远程会话，或使用远程角色创建新会话。',
        ),
      ];
    }
    if (_conversationController!.snapshot.sessionId !=
            session.externalSessionId ||
        _conversationController!.snapshot.characterId !=
            session.externalCharacterId) {
      return const <CapabilityLoss>[
        CapabilityLoss(
          code: 'active_session_required',
          severity: 'blocked',
          title: '需要激活所选会话',
          description: '所选会话不是 Runtime 当前活动会话。',
          affectedFeatures: <String>['send_message'],
          recoverAction: '重新选择该会话并等待激活完成。',
        ),
      ];
    }
    return const <CapabilityLoss>[];
  }

  String _assistantDisplayName(String assistantId) {
    for (final assistant in _assistants) {
      if (assistant.id == assistantId) {
        return assistant.name;
      }
    }
    return assistantId;
  }
}

class _ComposerImageAttachment {
  const _ComposerImageAttachment({
    required this.name,
    required this.bytes,
    required this.contentType,
  });

  final String name;
  final Uint8List bytes;
  final String contentType;
}

String _externalMappingStatusLabel(ExternalMappingStatus status) =>
    switch (status) {
      ExternalMappingStatus.verified => '已验证',
      ExternalMappingStatus.unverified => '未验证',
      ExternalMappingStatus.stale => '已失效',
      ExternalMappingStatus.inaccessible => '暂不可访问',
    };

class _PaneResizeHandle extends StatefulWidget {
  const _PaneResizeHandle({super.key, required this.onDrag});

  /// 拖动时回调水平位移增量（向右为正），返回实际应用的位移。
  final double Function(double delta) onDrag;

  @override
  State<_PaneResizeHandle> createState() => _PaneResizeHandleState();
}

class _PaneResizeHandleState extends State<_PaneResizeHandle> {
  bool _hovered = false;
  double _unappliedDelta = 0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => _unappliedDelta = 0,
        onHorizontalDragUpdate: (details) {
          final requested = _unappliedDelta + details.delta.dx;
          final applied = widget.onDrag(requested);
          _unappliedDelta = requested - applied;
        },
        onHorizontalDragEnd: (_) => _unappliedDelta = 0,
        onHorizontalDragCancel: () => _unappliedDelta = 0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          width: 7,
          decoration: BoxDecoration(
            color: _hovered
                ? colorScheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
          ),
          child: Center(
            child: AnimatedContainer(
              key: const ValueKey<String>('paneResizeHandleIndicator'),
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              width: _hovered ? 3 : 1,
              decoration: BoxDecoration(
                color: _hovered
                    ? colorScheme.primary
                    : colorScheme.outlineVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _bindingCapabilityLossSummary(List<CapabilityLoss> losses) {
  if (losses.isEmpty) {
    return '无';
  }
  return losses
      .map((loss) => loss.title.trim().isEmpty ? loss.code : loss.title)
      .join('、');
}

class _ContextDetailCard extends StatelessWidget {
  const _ContextDetailCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

@visibleForTesting
class MessageSnapshotTestHost extends StatelessWidget {
  const MessageSnapshotTestHost({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return _MessageSnapshotChips(message: message);
  }
}

@visibleForTesting
class MessageBubbleTestHost extends StatelessWidget {
  const MessageBubbleTestHost({
    super.key,
    required this.message,
    required this.assistantName,
    this.bubbleStyle = AppearanceSettings.defaultBubbleStyle,
    this.cornerRadius = AppearanceSettings.defaultCornerRadius,
    this.avatarProvider,
  });

  final ChatMessage message;
  final String assistantName;
  final String bubbleStyle;
  final double cornerRadius;
  final ImageProvider? avatarProvider;

  @override
  Widget build(BuildContext context) {
    return _MessageBubble(
      message: message,
      assistantName: assistantName,
      avatarProvider: avatarProvider,
      bubbleStyle: bubbleStyle,
      cornerRadius: cornerRadius,
    );
  }
}

class _MessageSnapshotChips extends StatelessWidget {
  const _MessageSnapshotChips({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        if (message.assistantId.isNotEmpty)
          _SnapshotChip(
            label: '角色: ${message.assistantId}',
            tooltip: '本条回复使用的角色 ID：${message.assistantId}',
          ),
        if (message.assistantProviderId.isNotEmpty)
          _SnapshotChip(
            label: '来源: ${message.assistantProviderId}',
            tooltip: '角色来源 Provider：${message.assistantProviderId}',
          ),
        if (message.backendId.isNotEmpty)
          _SnapshotChip(
            label: '来源: ${message.backendId}',
            tooltip: '本条消息来自 ${message.backendId}。',
          ),
      ],
    );
  }
}

class _SnapshotChip extends StatelessWidget {
  const _SnapshotChip({required this.label, required this.tooltip});

  final String label;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Chip(label: Text(label)),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.assistantName,
    this.avatarProvider,
    required this.bubbleStyle,
    required this.cornerRadius,
    this.excludedFromContext = false,
    this.ttsConfigured = false,
    this.ttsActive = false,
    this.ttsPaused = false,
    this.ttsBusy = false,
    this.onSpeak,
    this.onToggleTts,
    this.onStopTts,
  });

  final ChatMessage message;
  final String assistantName;
  final ImageProvider? avatarProvider;
  final String bubbleStyle;
  final double cornerRadius;
  final bool excludedFromContext;
  final bool ttsConfigured;
  final bool ttsActive;
  final bool ttsPaused;
  final bool ttsBusy;
  final VoidCallback? onSpeak;
  final VoidCallback? onToggleTts;
  final VoidCallback? onStopTts;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatMessageRole.user;
    final colorScheme = Theme.of(context).colorScheme;
    final bubbleColor = isUser
        ? colorScheme.primaryContainer
        : colorScheme.secondaryContainer;
    final messageBody = Padding(
      key: const ValueKey<String>('messageBubbleBody'),
      padding: const EdgeInsets.all(10),
      child: _StructuredMessageBody(message: message),
    );
    final bubble = switch (bubbleStyle) {
      'flat' => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.all(Radius.circular(cornerRadius)),
          ),
          child: messageBody,
        ),
      ),
      'plain' => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: messageBody,
      ),
      _ => Card(color: bubbleColor, child: messageBody),
    };
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: isUser
                  ? <Widget>[
                      Text(
                        _senderLabel(isUser),
                        style: Theme.of(context).textTheme.labelMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(width: 6),
                      _messageAvatar(isUser: true),
                    ]
                  : <Widget>[
                      _messageAvatar(isUser: false),
                      const SizedBox(width: 6),
                      Text(
                        _senderLabel(isUser),
                        style: Theme.of(context).textTheme.labelMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
            ),
          ),
          if (excludedFromContext)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Chip(
                avatar: Icon(Icons.visibility_off_outlined, size: 18),
                label: Text('已从请求上下文排除'),
              ),
            ),
          bubble,
          if (message.role == ChatMessageRole.assistant &&
              ttsConfigured &&
              _hasSpeechText)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (!ttsActive)
                    IconButton(
                      tooltip: '朗读消息',
                      onPressed: ttsBusy ? null : onSpeak,
                      icon: const Icon(Icons.volume_up_outlined, size: 18),
                    )
                  else ...<Widget>[
                    IconButton(
                      tooltip: ttsPaused ? '继续朗读' : '暂停朗读',
                      onPressed: ttsBusy ? null : onToggleTts,
                      icon: Icon(
                        ttsPaused ? Icons.play_arrow : Icons.pause,
                        size: 18,
                      ),
                    ),
                    IconButton(
                      tooltip: '停止朗读',
                      onPressed: onStopTts,
                      icon: const Icon(Icons.stop, size: 18),
                    ),
                    if (ttsBusy)
                      const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ],
              ),
            ),
          if (!isUser) ...<Widget>[
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _MessageSnapshotChips(message: message),
            ),
          ],
        ],
      ),
    );
  }

  Widget _messageAvatar({required bool isUser}) {
    return CircleAvatar(
      key: ValueKey<String>('messageAvatar_${message.id}'),
      radius: 16,
      foregroundImage: avatarProvider,
      onForegroundImageError: avatarProvider == null ? null : (_, _) {},
      child: Icon(
        isUser
            ? Icons.person_outline
            : message.role == ChatMessageRole.tool
            ? Icons.build_outlined
            : message.role == ChatMessageRole.system
            ? Icons.info_outline
            : Icons.smart_toy_outlined,
        size: 18,
      ),
    );
  }

  String _senderLabel(bool isUser) {
    if (isUser) return assistantName;
    return switch (message.role) {
      ChatMessageRole.tool => '工具结果',
      ChatMessageRole.system => '系统',
      ChatMessageRole.unknown =>
        message.rawRole.isEmpty ? 'Runtime 消息' : 'Runtime · ${message.rawRole}',
      _ => assistantName,
    };
  }

  bool get _hasSpeechText =>
      message.content.trim().isNotEmpty ||
      message.contentParts.any(
        (part) => part.type == 'text' && part.text.trim().isNotEmpty,
      );
}

class _StructuredMessageBody extends StatelessWidget {
  const _StructuredMessageBody({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      if (message.reasoningContent.isNotEmpty)
        _ReasoningSection(
          content: message.reasoningContent,
          streaming: message.status == 'streaming',
        ),
      if (message.reasoningContent.isNotEmpty &&
          (message.content.isNotEmpty ||
              message.contentParts.isNotEmpty ||
              message.toolCalls.isNotEmpty ||
              message.toolEvents.isNotEmpty))
        const SizedBox(height: 8),
      if (message.contentParts.isEmpty && message.content.isNotEmpty)
        MarkdownMessage(data: message.content),
      if (message.contentParts.isNotEmpty)
        for (final (index, part) in message.contentParts.indexed) ...<Widget>[
          if (index > 0) const SizedBox(height: 8),
          _ContentPartView(part: part),
        ],
      if (message.toolCalls.isNotEmpty)
        for (final call in message.toolCalls) ...<Widget>[
          if (childrenNeedGap(message)) const SizedBox(height: 8),
          _ToolCallView(call: call),
        ],
      if (message.toolEvents.isNotEmpty)
        for (final event in message.toolEvents) ...<Widget>[
          const SizedBox(height: 8),
          _ToolEventView(event: event),
        ],
      if (message.role == ChatMessageRole.tool && message.toolCallId.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '调用 ID: ${message.toolCallId}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      if (!message.hasDisplayContent)
        Text('Runtime 返回了空消息', style: Theme.of(context).textTheme.bodySmall),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  bool childrenNeedGap(ChatMessage message) =>
      message.content.isNotEmpty ||
      message.contentParts.isNotEmpty ||
      message.reasoningContent.isNotEmpty;
}

class _ReasoningSection extends StatelessWidget {
  const _ReasoningSection({required this.content, required this.streaming});

  final String content;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: const BorderRadius.all(Radius.circular(4)),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const ValueKey<String>('messageReasoningSection'),
        initiallyExpanded: false,
        leading: const Icon(Icons.psychology_outlined, size: 18),
        title: Text(streaming ? '正在思考' : '思考过程'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 10),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              contextMenuBuilder: jovTextContextMenu,
              content,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ContentPartView extends StatelessWidget {
  const _ContentPartView({required this.part});

  final ChatContentPart part;

  @override
  Widget build(BuildContext context) {
    if (part.type == 'text' && part.text.isNotEmpty) {
      return MarkdownMessage(data: part.text);
    }
    if (part.type == 'image') {
      return _RuntimeImage(image: part.image);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.insert_drive_file_outlined, size: 18),
        const SizedBox(width: 6),
        Flexible(child: Text('暂不支持的内容类型: ${part.type}')),
      ],
    );
  }
}

class _RuntimeImage extends StatelessWidget {
  const _RuntimeImage({required this.image});

  final Map<String, dynamic> image;

  @override
  Widget build(BuildContext context) {
    final provider = _imageProvider();
    if (provider == null) return const Text('图片数据不可用');
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480, maxHeight: 480),
      child: Image(
        key: const ValueKey<String>('runtimeMessageImage'),
        image: provider,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const Text('图片加载失败'),
      ),
    );
  }

  ImageProvider? _imageProvider() {
    final url = image['url'];
    if (url is String) {
      final uri = Uri.tryParse(url);
      if (uri != null &&
          uri.hasScheme &&
          (uri.scheme == 'http' || uri.scheme == 'https')) {
        final rawHeaders = image['headers'];
        final headers = rawHeaders is Map
            ? rawHeaders.map(
                (key, value) => MapEntry(key.toString(), value.toString()),
              )
            : null;
        return NetworkImage(url, headers: headers);
      }
    }
    final data = image['data'];
    if (data is! String || data.isEmpty || data.length > 28 * 1024 * 1024) {
      return null;
    }
    try {
      final encoded = data.startsWith('data:')
          ? data.substring(data.indexOf(',') + 1)
          : data;
      return MemoryImage(base64Decode(encoded));
    } on FormatException {
      return null;
    }
  }
}

class _ToolCallView extends StatelessWidget {
  const _ToolCallView({required this.call});

  final Map<String, dynamic> call;

  @override
  Widget build(BuildContext context) {
    final function = call['function'] is Map
        ? Map<String, dynamic>.from(call['function'] as Map)
        : const <String, dynamic>{};
    final name = function['name']?.toString() ?? '未知工具';
    final arguments = _formatStructuredValue(function['arguments']);
    return _ToolPanel(
      icon: Icons.build_outlined,
      title: name,
      subtitle: call['id']?.toString() ?? '',
      body: arguments,
    );
  }
}

class _ToolEventView extends StatelessWidget {
  const _ToolEventView({required this.event});

  final Map<String, dynamic> event;

  @override
  Widget build(BuildContext context) {
    final info = event['tool_info'] is Map
        ? Map<String, dynamic>.from(event['tool_info'] as Map)
        : const <String, dynamic>{};
    final name =
        info['name']?.toString() ?? info['tool_name']?.toString() ?? '工具调用';
    final status = event['status']?.toString() ?? '执行中';
    return _ToolPanel(
      icon: Icons.sync_outlined,
      title: name,
      subtitle: status,
      body: info.isEmpty ? '' : _formatStructuredValue(info),
    );
  }
}

class _ToolPanel extends StatelessWidget {
  const _ToolPanel({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String body;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('messageToolPanel'),
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: const BorderRadius.all(Radius.circular(4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 18),
              const SizedBox(width: 6),
              Expanded(child: Text(title)),
              if (subtitle.isNotEmpty)
                Text(subtitle, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
          if (body.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            SelectableText(
              contextMenuBuilder: jovTextContextMenu,
              body,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ],
        ],
      ),
    );
  }
}

String _formatStructuredValue(Object? value) {
  if (value == null) return '';
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } on FormatException {
      return value;
    }
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } on JsonUnsupportedObjectError {
    return value.toString();
  }
}

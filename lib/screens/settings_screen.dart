import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, TextInputFormatter, rootBundle;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import '../models/runtime_identity.dart';
import '../models/assistant.dart';
import '../models/chat_session.dart';
import '../repositories/archive_repositories.dart';
import '../repositories/media_repository.dart';
import '../services/runtime/external_agent_runtime.dart';
import '../services/runtime/http_runtime_client.dart';
import '../services/runtime/runtime_connection.dart';
import '../services/provider_model_catalog.dart';
import '../theme/app_theme.dart';
import '../widgets/color_picker.dart';
import '../widgets/app_background.dart';
import '../widgets/text_context_menu.dart';
import '../widgets/top_notice.dart';

enum SettingsInitialPage {
  language,
  display,
  modelProvider,
  tts,
  sessionDefaults,
  userProfile,
  assistantManagement,
  gensokyoAi,
  shortcuts,
  storage,
  backend,
  developerOptions,
  about,
}

@visibleForTesting
Future<({int deleted, int failed})> deleteLegacyRuntimeData(
  ArchivePaths paths,
) async {
  var deleted = 0;
  var failed = 0;
  for (final name in <String>[
    'backends',
    'runtime_data',
    'character_deployments',
  ]) {
    final directory = Directory(
      '${paths.root.path}${Platform.pathSeparator}$name',
    );
    if (!await directory.exists()) {
      continue;
    }
    try {
      await directory.delete(recursive: true);
      deleted++;
    } on FileSystemException {
      failed++;
    }
  }
  return (deleted: deleted, failed: failed);
}

class SettingsOperation {
  const SettingsOperation({
    this.settings,
    this.reloadAssistants = false,
    this.reloadSessions = false,
    this.activateExternalRuntime = false,
    this.deactivateExternalRuntime = false,
  });

  const SettingsOperation.archiveImport({this.settings})
    : reloadAssistants = false,
      reloadSessions = false,
      activateExternalRuntime = false,
      deactivateExternalRuntime = false;

  final AppSettings? settings;
  final bool reloadAssistants;
  final bool reloadSessions;
  final bool activateExternalRuntime;
  final bool deactivateExternalRuntime;
}

@visibleForTesting
Future<void> applyArchiveImportOperation({
  required AppSettings? settings,
  required bool disconnectLiveRuntime,
  required Future<void> Function(SettingsOperation operation) dispatch,
  Future<void> Function()? disconnect,
}) async {
  await dispatch(SettingsOperation.archiveImport(settings: settings));
  if (disconnectLiveRuntime) {
    await disconnect?.call();
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initialSettings,
    this.initialPage,
    this.externalBackendAvailable = false,
    this.activeExternalRuntimeConnectionId,
    this.externalAgentRuntime,
    this.assistantRepository,
    this.conversationRepository,
    this.mediaRepository,
    this.providerModelCatalog,
    this.onSettingsChanged,
    this.onOperation,
    this.onActivateExternalRuntime,
    this.onDeactivateExternalRuntime,
  });

  final AppSettings initialSettings;

  /// 显式指定时直接进入该分类（compact 下直接推详情页）；
  /// 为 null 时桌面默认选中委托档案，compact 先显示导航列表。
  final SettingsInitialPage? initialPage;
  final bool externalBackendAvailable;
  final String? activeExternalRuntimeConnectionId;
  final ExternalAgentRuntime? externalAgentRuntime;
  final AssistantArchiveRepository? assistantRepository;
  final ConversationArchiveRepository? conversationRepository;
  final MediaRepository? mediaRepository;
  final ProviderModelCatalog? providerModelCatalog;
  final ValueChanged<AppSettings>? onSettingsChanged;
  final Future<void> Function(SettingsOperation operation)? onOperation;
  final Future<ExternalAgentRuntime> Function(
    AppSettings settings,
    String connectionId,
  )?
  onActivateExternalRuntime;
  final Future<void> Function()? onDeactivateExternalRuntime;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _providers = <String>[
    'openai',
    'openai_responses',
    'openrouter',
    'deepseek',
    'ollama',
    'claude',
    'gemini',
  ];
  static const _embeddingProviders = <String>[
    'openai',
    'openrouter',
    'ollama',
    'gemini',
  ];
  static const _providerLabels = <String, String>{
    'openai': 'OpenAI Compatible',
    'openai_responses': 'OpenAI Responses',
    'openrouter': 'OpenRouter',
    'deepseek': 'DeepSeek',
    'ollama': 'Ollama',
    'claude': 'Claude',
    'gemini': 'Gemini',
  };
  static const _modelCapabilityLabels = <String, String>{
    'multimodal': '多模态',
    'reasoning': '推理',
    'tool_calling': '工具调用',
  };

  _SettingsPage _selectedPage = _SettingsPage.modelProvider;

  late AppSettings _settings;
  late ModelProfile _editingProfile;
  late final AssistantArchiveRepository _assistantRepository;
  late final ConversationArchiveRepository _conversationRepository;
  late final MediaRepository _mediaRepository;
  late final ProviderModelCatalog _providerModelCatalog;
  List<Assistant> _localAssistants = const <Assistant>[];
  List<ChatSession> _archivedConversations = const <ChatSession>[];
  List<File> _logFiles = const <File>[];
  List<ManagedMediaFile> _mediaFiles = const <ManagedMediaFile>[];
  bool _loadingMedia = false;
  int _logBytes = 0;
  bool _loadingArchiveData = false;
  bool _loadingLogs = false;
  bool _clearingLogs = false;
  bool _clearingLegacyRuntimeData = false;
  Map<String, ModelCapabilityProfile> _modelCapabilities =
      const <String, ModelCapabilityProfile>{};
  List<ProviderModelCatalogEntry> _providerModels =
      const <ProviderModelCatalogEntry>[];
  bool _providerModelsLoading = false;
  String? _providerModelsError;
  int _providerModelRequestGeneration = 0;

  late final TextEditingController _profileNameController;
  late final TextEditingController _modelController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _temperatureController;
  late final TextEditingController _topPController;
  late final TextEditingController _maxTokensController;
  late final TextEditingController _timeoutController;
  late final TextEditingController _reasoningEffortController;
  late final TextEditingController _embeddingModelController;
  late final TextEditingController _embeddingBaseUrlController;
  late final TextEditingController _embeddingApiKeyController;
  late final TextEditingController _embeddingDimensionsController;
  late final TextEditingController _embeddingTimeoutController;
  late final TextEditingController _ttsBaseUrlController;
  late final TextEditingController _ttsApiKeyController;
  late final TextEditingController _ttsModelController;
  late final TextEditingController _ttsVoiceController;
  late final TextEditingController _userNicknameController;
  late final TextEditingController _userBioController;
  late final TextEditingController _backgroundImageOpacityController;
  final List<_UserRoleDraft> _userRoles = <_UserRoleDraft>[];
  String? _selectedUserRoleId;
  int _userRoleCounter = 0;
  bool _userRoleEditing = false;

  ExternalAgentRuntime? _externalAgentRuntime;
  String? _activeExternalRuntimeConnectionId;
  Map<String, dynamic> _gensokyoRuntimeInfo = const <String, dynamic>{};
  Map<String, dynamic> _gensokyoHealth = const <String, dynamic>{};
  Map<String, dynamic> _gensokyoCurrentSession = const <String, dynamic>{};
  List<Map<String, dynamic>> _gensokyoSessions = const <Map<String, dynamic>>[];
  Map<String, dynamic> _gensokyoCurrentScene = const <String, dynamic>{};
  Map<String, dynamic> _gensokyoCurrentTimer = const <String, dynamic>{};
  bool? _gensokyoInitiativeEnabled;
  Map<String, dynamic> _gensokyoToolStatus = const <String, dynamic>{};
  List<Map<String, dynamic>> _gensokyoMemories = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _gensokyoScenes = const <Map<String, dynamic>>[];
  Map<String, dynamic> _gensokyoWorldState = const <String, dynamic>{};
  List<Map<String, dynamic>> _gensokyoWorldRoster =
      const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _gensokyoWorldTranscript =
      const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _gensokyoWorldSessions =
      const <Map<String, dynamic>>[];
  bool _gensokyoSettingsLoading = false;
  bool _gensokyoSettingsBusy = false;
  String? _gensokyoSettingsError;
  late final TextEditingController _gensokyoMemorySearchController;
  late final TextEditingController _gensokyoTimerDelayController;
  late final TextEditingController _gensokyoTimerSummaryController;

  late String _provider;
  late String _embeddingProvider;
  late bool _stream;
  late bool _think;
  late bool _useProxy;
  late bool _embeddingUseProxy;
  bool _obscureApiKey = true;
  bool _obscureEmbeddingApiKey = true;
  bool _obscureTtsApiKey = true;
  late bool _ttsEnabled;
  late double _ttsSpeed;
  late String _ttsResponseFormat;
  late bool _externalBackendAvailable;
  String? _runtimeConnectionOperationId;
  String _previewLanguage = '简体中文';
  final List<AppThemePalette> _customPreviewThemes = <AppThemePalette>[];
  String _selectedPreviewThemeId = AppearanceSettings.defaultThemeId;
  String _backgroundImagePath = '';
  double _backgroundImageOpacity = 1.0;
  bool _backgroundImageBusy = false;
  Uint8List? _userAvatarBytes;
  String _userAvatarPath = '';
  bool _userAvatarBusy = false;
  int _customPreviewThemeCounter = 0;
  // 显示设置预览状态：仅界面演示，不影响实际外观。
  String _previewFontFamily = AppearanceSettings.defaultFontFamilyId;
  double _previewFontSize = AppearanceSettings.defaultFontSize;
  double _previewUiScale = 1.0;
  String _previewDensity = AppearanceSettings.defaultUiDensity;
  double _previewCornerRadius = AppearanceSettings.defaultCornerRadius;
  String _previewBubbleStyle = AppearanceSettings.defaultBubbleStyle;
  String _previewTransparencyType = '不透明';
  double _previewTransparencyAmount = 0;
  int _displayFormRevision = 0;
  // 会话默认值由客户端持久化，并在创建远程会话后应用。
  String _previewDefaultAssistant = '不自动挂载';
  late SessionTitleMode _previewDefaultTitleMode;
  // 开发者选项预览状态：仅界面演示，不影响运行行为。
  bool _previewDevVerboseLog = false;
  bool _previewDevShowRequestPayload = false;
  bool _previewDevExperimental = false;
  // compact（<600 逻辑像素）档采用“列表-详情”两级导航：
  // false 时整屏显示导航列表，true 时整屏显示当前分类详情。
  // 未显式指定 initialPage 时先停在列表，避免手机上一进设置就落进某个详情页。
  late bool _compactDetailOpen;
  bool _archiveTransferBusy = false;
  String? _lastArchiveExportPath;
  Timer? _settingsNotifyDebounce;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    _previewDefaultTitleMode = _settings.newSessionTitleMode;
    _externalAgentRuntime = widget.externalAgentRuntime;
    _activeExternalRuntimeConnectionId =
        widget.activeExternalRuntimeConnectionId;
    _customPreviewThemes.addAll(customThemePalettes(_settings.appearance));
    _selectedPreviewThemeId = resolveAppTheme(_settings.appearance).id;
    _backgroundImagePath = _settings.appearance.backgroundImagePath;
    _backgroundImageOpacity = _settings.appearance.backgroundImageOpacity;
    _backgroundImageOpacityController = TextEditingController(
      text: '${(_backgroundImageOpacity * 100).round()}',
    );
    _previewFontFamily = _settings.appearance.fontFamilyId;
    _previewFontSize = _settings.appearance.fontSize;
    _previewDensity = _settings.appearance.uiDensity;
    _previewCornerRadius = _settings.appearance.cornerRadius;
    _previewBubbleStyle = _settings.appearance.bubbleStyle;
    _customPreviewThemeCounter = _customPreviewThemes.length;
    _externalBackendAvailable = widget.externalBackendAvailable;
    _assistantRepository =
        widget.assistantRepository ?? AssistantArchiveRepository();
    _conversationRepository =
        widget.conversationRepository ?? ConversationArchiveRepository();
    _mediaRepository =
        widget.mediaRepository ??
        MediaRepository(paths: _assistantRepository.paths);
    _providerModelCatalog =
        widget.providerModelCatalog ?? HttpProviderModelCatalog();
    _selectedPage = _settingsPageFromInitialPage(
      widget.initialPage ?? SettingsInitialPage.modelProvider,
    );
    if (_selectedPage == _SettingsPage.gensokyoAi && !_gensokyoAiInstalled) {
      _selectedPage = _SettingsPage.backend;
    }
    if (_selectedPage == _SettingsPage.gensokyoAi) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadGensokyoAiSettings());
      });
    }
    _compactDetailOpen = widget.initialPage != null;
    _editingProfile = _settings.activeProfile;
    _profileNameController = TextEditingController();
    _modelController = TextEditingController();
    _baseUrlController = TextEditingController();
    _apiKeyController = TextEditingController();
    _temperatureController = TextEditingController();
    _topPController = TextEditingController();
    _maxTokensController = TextEditingController();
    _timeoutController = TextEditingController();
    _reasoningEffortController = TextEditingController();
    _embeddingModelController = TextEditingController();
    _embeddingBaseUrlController = TextEditingController();
    _embeddingApiKeyController = TextEditingController();
    _embeddingDimensionsController = TextEditingController();
    _embeddingTimeoutController = TextEditingController();
    _ttsBaseUrlController = TextEditingController(text: _settings.tts.baseUrl);
    _ttsApiKeyController = TextEditingController(text: _settings.tts.apiKey);
    _ttsModelController = TextEditingController(text: _settings.tts.model);
    _ttsVoiceController = TextEditingController(text: _settings.tts.voice);
    _ttsEnabled = _settings.tts.enabled;
    _ttsSpeed = _settings.tts.speed;
    _ttsResponseFormat = _settings.tts.responseFormat;
    _userNicknameController = TextEditingController();
    _userBioController = TextEditingController();
    _gensokyoMemorySearchController = TextEditingController();
    _gensokyoTimerDelayController = TextEditingController();
    _gensokyoTimerSummaryController = TextEditingController();
    _userRoleCounter = _settings.userRoles.length;
    _userRoles.addAll(
      _settings.userRoles.map(
        (role) => _UserRoleDraft(
          id: role.id,
          nickname: role.nickname,
          bio: role.bio,
          avatarPath: role.avatarImagePath,
        ),
      ),
    );
    _selectedUserRoleId = _settings.activeUserRoleId;
    final initialUserRole = _selectedUserRole;
    if (initialUserRole != null) {
      _loadUserRoleIntoForm(initialUserRole);
    }
    _loadProfileIntoForm(_editingProfile);
    for (final controller in <TextEditingController>[
      _profileNameController,
      _modelController,
      _baseUrlController,
      _apiKeyController,
      _temperatureController,
      _topPController,
      _maxTokensController,
      _timeoutController,
      _reasoningEffortController,
      _embeddingModelController,
      _embeddingBaseUrlController,
      _embeddingApiKeyController,
      _embeddingDimensionsController,
      _embeddingTimeoutController,
      _ttsBaseUrlController,
      _ttsApiKeyController,
      _ttsModelController,
      _ttsVoiceController,
    ]) {
      controller.addListener(_scheduleSettingsChanged);
    }
    _loadArchiveData();
    _loadLogData();
    if (_selectedPage == _SettingsPage.storage) {
      unawaited(_loadMediaData());
    }
  }

  @override
  void dispose() {
    _settingsNotifyDebounce?.cancel();
    _profileNameController.dispose();
    _modelController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _temperatureController.dispose();
    _topPController.dispose();
    _maxTokensController.dispose();
    _timeoutController.dispose();
    _reasoningEffortController.dispose();
    _embeddingModelController.dispose();
    _embeddingBaseUrlController.dispose();
    _embeddingApiKeyController.dispose();
    _embeddingDimensionsController.dispose();
    _embeddingTimeoutController.dispose();
    _ttsBaseUrlController.dispose();
    _ttsApiKeyController.dispose();
    _ttsModelController.dispose();
    _ttsVoiceController.dispose();
    _userNicknameController.dispose();
    _userBioController.dispose();
    _gensokyoMemorySearchController.dispose();
    _gensokyoTimerDelayController.dispose();
    _gensokyoTimerSummaryController.dispose();
    _backgroundImageOpacityController.dispose();
    super.dispose();
  }

  void _setBackgroundImageOpacity(double value) {
    final normalized = value.clamp(0.0, 1.0);
    setState(() => _backgroundImageOpacity = normalized);
    final percentage = '${(normalized * 100).round()}';
    if (_backgroundImageOpacityController.text != percentage) {
      _backgroundImageOpacityController.value = TextEditingValue(
        text: percentage,
        selection: TextSelection.collapsed(offset: percentage.length),
      );
    }
    _notifySettingsChanged();
  }

  void _updateBackgroundImageOpacityFromText(String text) {
    final percentage = int.tryParse(text);
    if (percentage == null || percentage < 0 || percentage > 100) {
      return;
    }
    setState(() => _backgroundImageOpacity = percentage / 100);
    _notifySettingsChanged();
  }

  void _normalizeBackgroundImageOpacityText() {
    _setBackgroundImageOpacity(_backgroundImageOpacity);
  }

  bool get _gensokyoAiInstalled => _externalAgentRuntime != null;

  Future<void> _restoreDisplayDefaults() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('还原外观默认值'),
        content: const Text(
          '字体、字号、界面密度、圆角、气泡样式和透明效果会恢复默认。当前主题和全局背景不会改变。确定继续吗？',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.tonalIcon(
            key: const ValueKey<String>('confirmRestoreDisplayDefaults'),
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.restore),
            label: const Text('还原默认值'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    const defaults = AppearanceSettings();
    setState(() {
      _previewFontFamily = defaults.fontFamilyId;
      _previewFontSize = defaults.fontSize;
      _previewDensity = defaults.uiDensity;
      _previewCornerRadius = defaults.cornerRadius;
      _previewBubbleStyle = defaults.bubbleStyle;
      _previewUiScale = 1.0;
      _previewTransparencyType = '不透明';
      _previewTransparencyAmount = 0;
      _displayFormRevision += 1;
    });
    _notifySettingsChanged();
  }

  Future<void> _dispatchOperation(SettingsOperation operation) async {
    final settings = operation.settings;
    if (settings != null) {
      widget.onSettingsChanged?.call(settings);
    }
    await widget.onOperation?.call(operation);
  }

  void _notifySettingsChanged() {
    _settingsNotifyDebounce?.cancel();
    final nextSettings = _settingsWithCurrentForm();
    _settings = nextSettings;
    unawaited(_dispatchOperation(SettingsOperation(settings: nextSettings)));
  }

  void _scheduleSettingsChanged() {
    _settingsNotifyDebounce?.cancel();
    _settingsNotifyDebounce = Timer(
      const Duration(milliseconds: 180),
      _notifySettingsChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isModelProviderPage = _selectedPage == _SettingsPage.modelProvider;
    final previewPalette = _findPreviewTheme(_selectedPreviewThemeId);
    final backgroundFile = resolveAppBackgroundFile(
      AppearanceSettings(
        backgroundImagePath: _backgroundImagePath,
        backgroundImageOpacity: _backgroundImageOpacity,
      ),
      _assistantRepository.paths,
    );
    final basePreviewTheme = buildAppTheme(
      previewPalette,
      fontFamilyId: _previewFontFamily,
      fontSize: _previewFontSize,
      uiDensity: _previewDensity,
      cornerRadius: _previewCornerRadius,
    );
    final previewTheme = backgroundFile == null
        ? basePreviewTheme
        : basePreviewTheme.copyWith(
            scaffoldBackgroundColor: Colors.transparent,
          );
    return Theme(
      data: previewTheme,
      child: AppBackground(
        file: backgroundFile,
        color: previewPalette.background,
        imageOpacity: _backgroundImageOpacity,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 600;
            final showCompactDetail = compact && _compactDetailOpen;
            return PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (didPop) {
                  return;
                }
                // compact 详情页的返回先回到导航列表，再次返回才退出设置。
                if (showCompactDetail) {
                  _notifySettingsChanged();
                  setState(() => _compactDetailOpen = false);
                  return;
                }
                unawaited(_closeWithCurrentSettings());
              },
              child: Scaffold(
                appBar: AppBar(
                  leading: showCompactDetail
                      ? BackButton(
                          key: const ValueKey<String>('settingsCompactBack'),
                          onPressed: () =>
                              setState(() => _compactDetailOpen = false),
                        )
                      : null,
                  title: Text(
                    showCompactDetail || !compact
                        ? _settingsPageTitle(_selectedPage)
                        : '控制中心',
                  ),
                  actions: <Widget>[
                    if (isModelProviderPage &&
                        (!compact || showCompactDetail)) ...<Widget>[
                      TextButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.save),
                        label: const Text('保存并生效'),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
                body: compact
                    ? (showCompactDetail
                          ? _buildSelectedPage()
                          : _buildSettingsList(context, fullWidth: true))
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          _buildSettingsList(context),
                          const VerticalDivider(width: 1),
                          Expanded(child: _buildSelectedPage()),
                        ],
                      ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSettingsList(
    BuildContext themedContext, {
    bool fullWidth = false,
  }) {
    return Material(
      color: Theme.of(themedContext).colorScheme.surfaceContainerLow,
      child: SizedBox(
        width: fullWidth ? double.infinity : 300,
        child: ListView(
          key: const ValueKey<String>('settings-navigation'),
          padding: const EdgeInsets.all(10),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '控制中心',
                    style: Theme.of(themedContext).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  const Text('管理语言、显示、委托档案、角色草稿、存储、运行服务和应用信息。'),
                ],
              ),
            ),
            _buildSettingsListTile(
              themedContext,
              page: _SettingsPage.language,
              icon: Icons.language_outlined,
              title: '语言',
              subtitle: '界面语言与区域格式',
              showSelection: !fullWidth,
            ),
            _buildSettingsListTile(
              themedContext,
              page: _SettingsPage.display,
              icon: Icons.display_settings_outlined,
              title: '显示设置',
              subtitle: '主题、界面密度与文字显示',
              showSelection: !fullWidth,
            ),
            _buildSettingsListTile(
              themedContext,
              page: _SettingsPage.modelProvider,
              icon: Icons.smart_toy_outlined,
              title: 'Provider 委托档案',
              subtitle: '仅在明确授权后发送给 GensokyoAI',
              showSelection: !fullWidth,
            ),
            _buildSettingsListTile(
              themedContext,
              page: _SettingsPage.tts,
              icon: Icons.record_voice_over_outlined,
              title: 'TTS 语音',
              subtitle: '专用语音 Provider 与播放设置',
              showSelection: !fullWidth,
            ),
            _buildSettingsListTile(
              themedContext,
              page: _SettingsPage.sessionDefaults,
              icon: Icons.playlist_add_check_outlined,
              title: '会话默认值',
              subtitle: '客户端显示偏好',
              showSelection: !fullWidth,
            ),
            _buildSettingsListTile(
              themedContext,
              page: _SettingsPage.backend,
              icon: Icons.storage_outlined,
              title: '服务管理',
              subtitle: '运行服务、来源和许可',
              showSelection: !fullWidth,
            ),
            if (_gensokyoAiInstalled)
              _buildSettingsListTile(
                themedContext,
                page: _SettingsPage.gensokyoAi,
                icon: Icons.auto_awesome_outlined,
                title: 'GensokyoAI 设置',
                subtitle: '记忆、场景、工具与主动消息',
                showSelection: !fullWidth,
              ),
            _buildSettingsListTile(
              themedContext,
              page: _SettingsPage.userProfile,
              icon: Icons.account_circle_outlined,
              title: '用户角色',
              subtitle: '头像、昵称与角色信息',
              showSelection: !fullWidth,
            ),
            _buildSettingsListTile(
              themedContext,
              page: _SettingsPage.assistantManagement,
              icon: Icons.groups_2_outlined,
              title: '角色管理',
              subtitle: '不可执行的本地角色草稿',
              showSelection: !fullWidth,
            ),
            _buildSettingsListTile(
              themedContext,
              page: _SettingsPage.shortcuts,
              icon: Icons.keyboard_outlined,
              title: '快捷键',
              subtitle: '键盘快捷键一览与自定义',
              showSelection: !fullWidth,
            ),
            _buildSettingsListTile(
              themedContext,
              page: _SettingsPage.storage,
              icon: Icons.storage_outlined,
              title: '数据管理',
              subtitle: '存档导入导出、日志与本地空间',
              showSelection: !fullWidth,
            ),
            _buildSettingsListTile(
              themedContext,
              page: _SettingsPage.developerOptions,
              icon: Icons.code_outlined,
              title: '开发者选项',
              subtitle: '调试、日志与实验性功能',
              showSelection: !fullWidth,
            ),
            _buildSettingsListTile(
              themedContext,
              page: _SettingsPage.about,
              icon: Icons.info_outline,
              title: '关于',
              subtitle: '版本、作者、许可证和依赖',
              showSelection: !fullWidth,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsListTile(
    BuildContext themedContext, {
    required _SettingsPage page,
    required IconData icon,
    required String title,
    required String subtitle,
    bool showSelection = true,
  }) {
    final selected = showSelection && _selectedPage == page;
    return Card(
      elevation: selected ? 2 : 0,
      color: selected
          ? Theme.of(themedContext).colorScheme.secondaryContainer
          : null,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        selected: selected,
        selectedColor: Theme.of(themedContext).colorScheme.onSecondaryContainer,
        onTap: () {
          setState(() {
            _selectedPage = page;
            _compactDetailOpen = true;
          });
          if (page == _SettingsPage.storage) {
            unawaited(_loadMediaData());
          } else if (page == _SettingsPage.gensokyoAi) {
            unawaited(_loadGensokyoAiSettings());
          }
        },
      ),
    );
  }

  Widget _buildSelectedPage() {
    switch (_selectedPage) {
      case _SettingsPage.language:
        return _buildLanguagePage();
      case _SettingsPage.display:
        return _buildDisplayPage();
      case _SettingsPage.modelProvider:
        return _buildModelProviderPage();
      case _SettingsPage.tts:
        return _buildTtsPage();
      case _SettingsPage.sessionDefaults:
        return _buildSessionDefaultsPage();
      case _SettingsPage.userProfile:
        return _buildUserProfilePage();
      case _SettingsPage.shortcuts:
        return _buildShortcutsPage();
      case _SettingsPage.developerOptions:
        return _buildDeveloperOptionsPage();
      case _SettingsPage.assistantManagement:
        return _buildAssistantManagementPage();
      case _SettingsPage.gensokyoAi:
        return _buildGensokyoAiSettingsPage();
      case _SettingsPage.storage:
        return _buildStoragePage();
      case _SettingsPage.backend:
        return _buildBackendPage();
      case _SettingsPage.about:
        return _buildAboutPage();
    }
  }

  Widget _buildLanguagePage() {
    return ListView(
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        _SettingsSection(
          icon: Icons.language_outlined,
          title: '语言',
          description: '选择 HakureiTerminal 的界面语言。当前仅提供设置界面，选择不会改变应用语言。',
          children: <Widget>[
            DropdownButtonFormField<String>(
              initialValue: _previewLanguage,
              decoration: const InputDecoration(
                labelText: '界面语言',
                border: OutlineInputBorder(),
                helperText: '多语言支持将在后续版本接入。',
              ),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: '简体中文', child: Text('简体中文')),
                DropdownMenuItem(value: '繁體中文', child: Text('繁體中文')),
                DropdownMenuItem(value: 'English', child: Text('English')),
                DropdownMenuItem(value: '日本語', child: Text('日本語')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _previewLanguage = value);
                }
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTtsPage() {
    return ListView(
      key: const ValueKey<String>('ttsSettingsPage'),
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        _SettingsSection(
          icon: Icons.record_voice_over_outlined,
          title: 'TTS Provider',
          description: '使用兼容 OpenAI /audio/speech 的专用语音服务。仅在点击消息朗读时请求，不参与聊天生成。',
          children: <Widget>[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用消息朗读'),
              subtitle: const Text('关闭时聊天页不显示朗读按钮'),
              value: _ttsEnabled,
              onChanged: (value) {
                setState(() => _ttsEnabled = value);
                _notifySettingsChanged();
              },
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey<String>('ttsBaseUrlField'),
              controller: _ttsBaseUrlController,
              enabled: _ttsEnabled,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://example.com/v1',
                helperText: '也可直接填写以 /audio/speech 结尾的地址',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('ttsApiKeyField'),
              controller: _ttsApiKeyController,
              enabled: _ttsEnabled,
              obscureText: _obscureTtsApiKey,
              decoration: InputDecoration(
                labelText: 'API Key（可选）',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _obscureTtsApiKey ? '显示 API Key' : '隐藏 API Key',
                  onPressed: () =>
                      setState(() => _obscureTtsApiKey = !_obscureTtsApiKey),
                  icon: Icon(
                    _obscureTtsApiKey ? Icons.visibility : Icons.visibility_off,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('ttsModelField'),
                    controller: _ttsModelController,
                    enabled: _ttsEnabled,
                    decoration: const InputDecoration(
                      labelText: '模型',
                      hintText: 'tts-1',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('ttsVoiceField'),
                    controller: _ttsVoiceController,
                    enabled: _ttsEnabled,
                    decoration: const InputDecoration(
                      labelText: '音色',
                      hintText: 'alloy',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('语速 ${_ttsSpeed.toStringAsFixed(2)}x'),
            Slider(
              value: _ttsSpeed.clamp(0.25, 4.0),
              min: 0.25,
              max: 4,
              divisions: 15,
              onChanged: _ttsEnabled
                  ? (value) {
                      setState(() => _ttsSpeed = value);
                      _notifySettingsChanged();
                    }
                  : null,
            ),
            DropdownButtonFormField<String>(
              initialValue: _ttsResponseFormat,
              decoration: const InputDecoration(
                labelText: '音频格式',
                border: OutlineInputBorder(),
              ),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'mp3', child: Text('MP3')),
                DropdownMenuItem(value: 'wav', child: Text('WAV')),
                DropdownMenuItem(value: 'opus', child: Text('Opus')),
                DropdownMenuItem(value: 'aac', child: Text('AAC')),
                DropdownMenuItem(value: 'flac', child: Text('FLAC')),
              ],
              onChanged: _ttsEnabled
                  ? (value) {
                      if (value == null) return;
                      setState(() => _ttsResponseFormat = value);
                      _notifySettingsChanged();
                    }
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDisplayPage() {
    final selectedTheme = _findPreviewTheme(_selectedPreviewThemeId);
    return ListView(
      key: const ValueKey<String>('displaySettingsList'),
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        _SettingsSection(
          key: ValueKey<String>('displayControls:$_displayFormRevision'),
          icon: Icons.display_settings_outlined,
          title: '外观',
          description: '文字、缩放、密度、圆角、气泡与透明效果。已实装的显示设置会即时生效并自动保存。',
          children: <Widget>[
            DropdownButtonFormField<String>(
              key: const ValueKey<String>('displayFontFamilySelector'),
              initialValue: _previewFontFamily,
              decoration: const InputDecoration(
                labelText: '字体',
                prefixIcon: Icon(Icons.font_download_outlined),
                border: OutlineInputBorder(),
              ),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(
                  value: 'source_han_sans_sc',
                  child: Text('思源黑体（内置）'),
                ),
                DropdownMenuItem(value: 'system', child: Text('系统默认')),
                DropdownMenuItem(
                  value: 'source_han_serif_sc',
                  child: Text('思源宋体'),
                ),
                DropdownMenuItem(value: 'lxgw_wenkai', child: Text('霞鹜文楷')),
                DropdownMenuItem(
                  value: 'jetbrains_mono',
                  child: Text('JetBrains Mono'),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _previewFontFamily = value);
                  _notifySettingsChanged();
                }
              },
            ),
            const SizedBox(height: 12),
            _DisplaySliderRow(
              key: const ValueKey<String>('displayFontSizeSlider'),
              label: '字号',
              valueText: '${_previewFontSize.round()} pt',
              value: _previewFontSize,
              min: 10,
              max: 22,
              divisions: 12,
              inputKey: const ValueKey<String>('displayFontSizeInput'),
              inputScale: 1,
              onChanged: (value) {
                setState(() => _previewFontSize = value);
                _notifySettingsChanged();
              },
            ),
            _DisplaySliderRow(
              key: const ValueKey<String>('displayUiScaleSlider'),
              label: '界面缩放',
              valueText: '${(_previewUiScale * 100).round()}%',
              value: _previewUiScale,
              min: 0.75,
              max: 1.75,
              divisions: 8,
              inputKey: const ValueKey<String>('displayUiScaleInput'),
              inputScale: 100,
              onChanged: (value) => setState(() => _previewUiScale = value),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              key: const ValueKey<String>('displayDensitySelector'),
              initialValue: _previewDensity,
              decoration: const InputDecoration(
                labelText: '界面密度',
                prefixIcon: Icon(Icons.density_medium_outlined),
                border: OutlineInputBorder(),
              ),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'comfortable', child: Text('宽松')),
                DropdownMenuItem(value: 'standard', child: Text('标准')),
                DropdownMenuItem(value: 'compact', child: Text('紧凑')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _previewDensity = value);
                  _notifySettingsChanged();
                }
              },
            ),
            const SizedBox(height: 12),
            _DisplaySliderRow(
              key: const ValueKey<String>('displayCornerRadiusSlider'),
              label: '边框圆角',
              valueText: '${_previewCornerRadius.round()} px',
              value: _previewCornerRadius,
              min: 0,
              max: 12,
              divisions: 12,
              inputKey: const ValueKey<String>('displayCornerRadiusInput'),
              inputScale: 1,
              onChanged: (value) {
                setState(() => _previewCornerRadius = value);
                _notifySettingsChanged();
              },
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              key: const ValueKey<String>('displayBubbleStyleSelector'),
              initialValue: _previewBubbleStyle,
              decoration: const InputDecoration(
                labelText: '气泡样式',
                prefixIcon: Icon(Icons.chat_bubble_outline),
                border: OutlineInputBorder(),
              ),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'classic', child: Text('经典气泡')),
                DropdownMenuItem(value: 'flat', child: Text('扁平块')),
                DropdownMenuItem(value: 'plain', child: Text('无背景纯文本')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _previewBubbleStyle = value);
                  _notifySettingsChanged();
                }
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey<String>('displayTransparencySelector'),
              initialValue: _previewTransparencyType,
              decoration: const InputDecoration(
                labelText: '透明效果',
                prefixIcon: Icon(Icons.blur_on_outlined),
                border: OutlineInputBorder(),
              ),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: '不透明', child: Text('不透明')),
                DropdownMenuItem(value: '纯透明', child: Text('纯透明')),
                DropdownMenuItem(value: '模糊', child: Text('模糊')),
                DropdownMenuItem(value: '亚克力', child: Text('亚克力')),
                DropdownMenuItem(value: '云母', child: Text('云母')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _previewTransparencyType = value);
                }
              },
            ),
            if (_previewTransparencyType != '不透明')
              _DisplaySliderRow(
                key: const ValueKey<String>('displayTransparencyAmountSlider'),
                label: '透明度',
                valueText: '${(_previewTransparencyAmount * 100).round()}%',
                value: _previewTransparencyAmount,
                min: 0,
                max: 0.9,
                divisions: 18,
                inputKey: const ValueKey<String>(
                  'displayTransparencyAmountInput',
                ),
                inputScale: 100,
                onChanged: (value) =>
                    setState(() => _previewTransparencyAmount = value),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                key: const ValueKey<String>('restoreDisplayDefaultsButton'),
                style: FilledButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                ),
                onPressed: _restoreDisplayDefaults,
                icon: const Icon(Icons.restore),
                label: const Text('还原默认值'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _SettingsSection(
          key: ValueKey<String>('themeManager:$_displayFormRevision'),
          icon: Icons.palette_outlined,
          title: '主题',
          description: '选择亮色或暗色预设，也可以复制色板并维护自己的主题。',
          children: <Widget>[
            DropdownButtonFormField<String>(
              key: const ValueKey<String>('themeManagerSelector'),
              initialValue: _selectedPreviewThemeId,
              decoration: const InputDecoration(
                labelText: '当前主题',
                prefixIcon: Icon(Icons.palette_outlined),
                border: OutlineInputBorder(),
              ),
              isExpanded: true,
              items: <DropdownMenuItem<String>>[
                _ThemeGroupHeaderItem(label: '预设主题·亮'),
                for (final theme in appPresetLightThemes)
                  DropdownMenuItem(
                    value: theme.id,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text(theme.name),
                    ),
                  ),
                _ThemeGroupHeaderItem(label: '预设主题·暗'),
                for (final theme in appPresetDarkThemes)
                  DropdownMenuItem(
                    value: theme.id,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text(theme.name),
                    ),
                  ),
                if (_customPreviewThemes
                    .isNotEmpty) ...<DropdownMenuItem<String>>[
                  _ThemeGroupHeaderItem(label: '自定义主题'),
                  for (final theme in _customPreviewThemes)
                    DropdownMenuItem(
                      value: theme.id,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Text(theme.name),
                      ),
                    ),
                ],
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selectedPreviewThemeId = value);
                  _notifySettingsChanged();
                }
              },
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  key: const ValueKey<String>('themeCreateButton'),
                  onPressed: _createCustomPreviewTheme,
                  icon: const Icon(Icons.add),
                  label: const Text('新建主题'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('themeDuplicateButton'),
                  onPressed: () => _duplicatePreviewTheme(selectedTheme),
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('复制'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('themeRenameButton'),
                  onPressed: selectedTheme.isPreset
                      ? null
                      : () => _renameCustomPreviewTheme(selectedTheme),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('重命名'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('themeDeleteButton'),
                  onPressed: selectedTheme.isPreset
                      ? null
                      : () => _deleteCustomPreviewTheme(selectedTheme),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        _SettingsSection(
          key: const ValueKey<String>('themeParametersSection'),
          icon: Icons.tune_outlined,
          title: selectedTheme.name,
          description: '展示当前主题的颜色参数。',
          children: <Widget>[
            for (final entry in selectedTheme.colors.entries) ...<Widget>[
              _ThemeColorRow(
                label: entry.key,
                color: entry.value,
                readOnly: selectedTheme.isPreset,
                onEdit: selectedTheme.isPreset
                    ? null
                    : () => _editCustomPreviewThemeColor(
                        selectedTheme,
                        entry.key,
                        entry.value,
                      ),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Semantics(
          key: const ValueKey<String>('globalBackgroundControls'),
          container: true,
          label: '全局默认背景',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: selectedTheme.background,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.all(
                        Radius.circular(_previewCornerRadius),
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.all(
                        Radius.circular(
                          (_previewCornerRadius - 1)
                              .clamp(0, _previewCornerRadius)
                              .toDouble(),
                        ),
                      ),
                      child: _backgroundPreview(selectedTheme.background),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    FilledButton.tonalIcon(
                      key: const ValueKey<String>('backgroundImagePicker'),
                      onPressed: _backgroundImageBusy
                          ? null
                          : _pickGlobalBackgroundImage,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: Text(
                        _backgroundImagePath.isEmpty ? '选择全局默认背景' : '更换全局默认背景',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: '移除背景图片',
                      child: IconButton.outlined(
                        key: const ValueKey<String>('backgroundImageRemove'),
                        onPressed:
                            _backgroundImageBusy || _backgroundImagePath.isEmpty
                            ? null
                            : _removeGlobalBackgroundImage,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                    if (_backgroundImageBusy) ...<Widget>[
                      const SizedBox(width: 12),
                      const SizedBox(
                        width: 72,
                        child: LinearProgressIndicator(),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    const Text('透明度'),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Slider(
                        key: const ValueKey<String>('backgroundImageOpacity'),
                        value: _backgroundImageOpacity,
                        min: 0,
                        max: 1,
                        label: '${(_backgroundImageOpacity * 100).round()}%',
                        onChanged: _setBackgroundImageOpacity,
                      ),
                    ),
                    SizedBox(
                      width: 84,
                      child: TextField(
                        key: const ValueKey<String>(
                          'backgroundImageOpacityInput',
                        ),
                        controller: _backgroundImageOpacityController,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.end,
                        maxLength: 3,
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          counterText: '',
                          suffixText: '%',
                          isDense: true,
                        ),
                        onChanged: _updateBackgroundImageOpacityFromText,
                        onSubmitted: (_) =>
                            _normalizeBackgroundImageOpacityText(),
                        onTapOutside: (_) {
                          _normalizeBackgroundImageOpacityText();
                          FocusManager.instance.primaryFocus?.unfocus();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _backgroundPreview(Color fallbackColor) {
    final file = _assistantRepository.paths.managedAppearanceResourceFile(
      _backgroundImagePath,
    );
    if (file == null || !file.existsSync()) {
      return ColoredBox(
        color: fallbackColor,
        child: Center(
          child: Icon(
            Icons.image_not_supported_outlined,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Opacity(
      opacity: _backgroundImageOpacity,
      child: Image.file(
        file,
        key: ValueKey<String>('backgroundPreview:${file.path}'),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => ColoredBox(color: fallbackColor),
      ),
    );
  }

  Future<void> _pickGlobalBackgroundImage() async {
    final picked = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: '背景图片',
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
    setState(() => _backgroundImageBusy = true);
    try {
      final bytes = await picked.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      codec.dispose();

      final relativePath = await _mediaRepository.storeBytes(bytes);
      final previous = _assistantRepository.paths.managedAppearanceFile(
        _backgroundImagePath,
      );
      if (!mounted) {
        return;
      }
      setState(() => _backgroundImagePath = relativePath);
      _notifySettingsChanged();
      if (previous != null && await previous.exists()) {
        await previous.delete();
      }
    } catch (error) {
      if (mounted) {
        showTopNotice(context, '背景图片读取失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _backgroundImageBusy = false);
      }
    }
  }

  Future<void> _removeGlobalBackgroundImage() async {
    final file = _assistantRepository.paths.managedAppearanceFile(
      _backgroundImagePath,
    );
    setState(() => _backgroundImagePath = '');
    _notifySettingsChanged();
    if (file != null && await file.exists()) {
      try {
        await file.delete();
      } on FileSystemException catch (error) {
        if (mounted) {
          showTopNotice(context, '背景设置已移除，但旧图片清理失败：$error');
        }
      }
    }
  }

  AppThemePalette _findPreviewTheme(String id) {
    for (final theme in appPresetThemes) {
      if (theme.id == id) {
        return theme;
      }
    }
    for (final theme in _customPreviewThemes) {
      if (theme.id == id) {
        return theme;
      }
    }
    return appPresetLightThemes.first;
  }

  String _nextCustomPreviewThemeId() {
    _customPreviewThemeCounter += 1;
    return 'custom_$_customPreviewThemeCounter';
  }

  void _createCustomPreviewTheme() {
    final base = appPresetLightThemes.first;
    final theme = AppThemePalette(
      id: _nextCustomPreviewThemeId(),
      name: '新自定义主题 $_customPreviewThemeCounter',
      brightness: base.brightness,
      isPreset: false,
      colors: Map<String, Color>.from(base.colors),
    );
    setState(() {
      _customPreviewThemes.add(theme);
      _selectedPreviewThemeId = theme.id;
    });
    _notifySettingsChanged();
  }

  void _duplicatePreviewTheme(AppThemePalette source) {
    final theme = AppThemePalette(
      id: _nextCustomPreviewThemeId(),
      name: '${source.name} 副本',
      brightness: source.brightness,
      isPreset: false,
      colors: Map<String, Color>.from(source.colors),
    );
    setState(() {
      _customPreviewThemes.add(theme);
      _selectedPreviewThemeId = theme.id;
    });
    _notifySettingsChanged();
  }

  Future<void> _editCustomPreviewThemeColor(
    AppThemePalette theme,
    String colorKey,
    Color currentColor,
  ) async {
    final nextColor = await showColorPickerDialog(
      context: context,
      title: '编辑颜色：$colorKey',
      initialColor: currentColor,
    );
    if (nextColor == null || !mounted) {
      return;
    }
    setState(() {
      final index = _customPreviewThemes.indexWhere(
        (item) => item.id == theme.id,
      );
      if (index >= 0) {
        final colors = Map<String, Color>.from(theme.colors);
        colors[colorKey] = nextColor;
        _customPreviewThemes[index] = theme.copyWith(colors: colors);
      }
    });
    _notifySettingsChanged();
  }

  Future<void> _renameCustomPreviewTheme(AppThemePalette theme) async {
    final controller = TextEditingController(text: theme.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名主题'),
        content: TextField(
          contextMenuBuilder: jovTextContextMenu,
          key: const ValueKey<String>('themeRenameField'),
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: '主题名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) {
      return;
    }
    setState(() {
      final index = _customPreviewThemes.indexWhere(
        (item) => item.id == theme.id,
      );
      if (index >= 0) {
        _customPreviewThemes[index] = theme.copyWith(name: name);
      }
    });
    _notifySettingsChanged();
  }

  Future<void> _deleteCustomPreviewTheme(AppThemePalette theme) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除主题'),
        content: Text('确定删除自定义主题“${theme.name}”吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('confirmThemeDelete'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _customPreviewThemes.removeWhere((item) => item.id == theme.id);
      if (_selectedPreviewThemeId == theme.id) {
        _selectedPreviewThemeId = appPresetLightThemes.first.id;
      }
    });
    _notifySettingsChanged();
  }

  Widget _buildModelProviderPage() {
    return ListView(
      key: const ValueKey<String>('modelSettingsList'),
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        _buildHeader(context),
        const SizedBox(height: 24),
        _buildProfileSection(),
        const SizedBox(height: 20),
        _buildModelSection(),
        const SizedBox(height: 20),
        _buildEmbeddingSection(),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('保存并生效'),
          ),
        ),
      ],
    );
  }

  Widget _buildAssistantManagementPage() {
    return ListView(
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        _SettingsSection(
          icon: Icons.groups_2_outlined,
          title: '角色管理',
          description: '管理仅保存在本机、不可执行的角色草稿。GensokyoAI 角色由 Runtime 管理。',
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                Chip(label: Text('本地草稿: ${_localAssistants.length}')),
                if (_loadingArchiveData) const Chip(label: Text('正在刷新')),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _createLocalAssistant,
                  icon: const Icon(Icons.add),
                  label: const Text('新建角色草稿'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _loadArchiveData,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新角色列表'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('本地角色草稿', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (_localAssistants.isEmpty)
              const _SettingsInfoTile(
                icon: Icons.folder_outlined,
                title: '暂无本地角色草稿',
                description: '角色草稿不会出现在可执行角色选择器中，也不会联系 Runtime。',
              )
            else
              for (final assistant in _localAssistants) ...<Widget>[
                _AssistantManagementTile(
                  assistant: assistant,
                  onEdit: () => _editLocalAssistant(assistant),
                  onDelete: () => _deleteLocalAssistant(assistant),
                ),
                const SizedBox(height: 8),
              ],
            const _SettingsInfoTile(
              icon: Icons.hub_outlined,
              title: '角色来源边界',
              description: '独立部署的 GensokyoAI 角色通过已连接 Runtime 获取，不复制到本地角色存档。',
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cloud_upload_outlined),
              title: const Text('上传 GensokyoAI 角色包'),
              subtitle: Text(
                _externalAgentRuntime == null
                    ? '连接 Runtime 后可选择现成的 .gensokyo-character 包'
                    : '仅通过公开管理员端点上传；不会上传或转换本地草稿',
              ),
              trailing: FilledButton.tonalIcon(
                key: const ValueKey<String>('uploadCharacterPackageButton'),
                onPressed:
                    _externalAgentRuntime != null && !_gensokyoSettingsBusy
                    ? _uploadCharacterPackage
                    : null,
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('选择包'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGensokyoAiSettingsPage() {
    final initialized = _gensokyoHealth['initialized'] == true;
    final timerAvailable = _gensokyoCurrentTimer.isNotEmpty;
    final currentSceneId = _gensokyoCurrentScene['id']?.toString() ?? '';
    final capabilities =
        (_gensokyoRuntimeInfo['capabilities'] as List?)
            ?.map((item) => item.toString())
            .where((item) => item.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    return ListView(
      key: const ValueKey<String>('gensokyoAiSettingsPage'),
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        _SettingsSection(
          icon: Icons.monitor_heart_outlined,
          title: '运行状态',
          description: 'GensokyoAI Runtime 的版本、协议和当前 Agent 状态。',
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                const Chip(
                  avatar: Icon(Icons.check_circle_outline, size: 18),
                  label: Text('已连接'),
                ),
                Chip(
                  avatar: Icon(
                    _externalBackendAvailable
                        ? Icons.link
                        : Icons.link_off_outlined,
                    size: 18,
                  ),
                  label: Text(
                    _externalBackendAvailable ? 'Runtime 可用' : 'Runtime 未连接',
                  ),
                ),
                Chip(
                  avatar: Icon(
                    initialized
                        ? Icons.play_circle_outline
                        : Icons.pause_circle_outline,
                    size: 18,
                  ),
                  label: Text(initialized ? 'Agent 已初始化' : 'Agent 未初始化'),
                ),
                IconButton(
                  tooltip: '刷新 GensokyoAI 状态',
                  onPressed: _gensokyoSettingsLoading
                      ? null
                      : _loadGensokyoAiSettings,
                  icon: _gensokyoSettingsLoading
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            if (_gensokyoSettingsError != null) ...<Widget>[
              const SizedBox(height: 12),
              _SettingsInfoTile(
                icon: Icons.warning_amber_outlined,
                title: '部分状态不可用',
                description: _gensokyoSettingsError!,
              ),
            ],
            const SizedBox(height: 12),
            _buildBackendInfoTile(
              '运行版本',
              _gensokyoRuntimeInfo['package_version']?.toString() ?? '未读取',
            ),
            _buildBackendInfoTile(
              'Runtime 协议',
              _gensokyoRuntimeInfo['protocol_version']?.toString() ?? '未读取',
            ),
            _buildBackendInfoTile(
              '能力',
              capabilities.isEmpty ? '未读取' : capabilities.join('、'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.forum_outlined,
          title: '外部会话',
          description: '当前角色的会话与消息由 GensokyoAI 管理；此处仅供查看。',
          children: <Widget>[
            const _SettingsInfoTile(
              key: ValueKey<String>('gensokyoAiSessionActivationGuidance'),
              icon: Icons.open_in_new_outlined,
              title: '请从聊天页激活会话',
              description: '设置页不会恢复或切换会话。请返回聊天页，通过明确的会话选择流程激活远端会话。',
            ),
            const SizedBox(height: 12),
            if (!initialized)
              const _SettingsInfoTile(
                icon: Icons.pause_circle_outline,
                title: '暂无活动 Agent',
                description: '会话级 Runtime 状态暂不可用。',
              )
            else ...<Widget>[
              _buildBackendInfoTile(
                '会话 ID',
                _gensokyoCurrentSession['session_id']?.toString() ?? '未读取',
                selectable: true,
              ),
              _buildBackendInfoTile(
                '标题',
                _gensokyoCurrentSession['title']?.toString() ?? '未命名会话',
              ),
              _buildBackendInfoTile(
                '消息轮次',
                _gensokyoCurrentSession['total_turns']?.toString() ?? '0',
              ),
            ],
            if (_gensokyoSessions.isNotEmpty) ...<Widget>[
              const Divider(height: 28),
              for (final session in _gensokyoSessions)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_outlined),
                  title: Text(
                    session['title']?.toString().trim().isNotEmpty == true
                        ? session['title'].toString()
                        : session['session_id']?.toString() ?? '未命名会话',
                  ),
                  subtitle: Text(
                    '远端 ID：${session['session_id'] ?? ''} · ${session['total_turns'] ?? 0} 轮',
                  ),
                ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.schedule_send_outlined,
          title: '主动消息',
          description: '管理当前 Agent 的主动消息开关和待触发定时器。',
          children: <Widget>[
            CheckboxListTile(
              key: const ValueKey<String>('gensokyoAiInitiativeToggle'),
              contentPadding: EdgeInsets.zero,
              tristate: true,
              title: const Text('允许主动消息'),
              subtitle: Text(
                !initialized
                    ? '当前 Agent 尚未初始化'
                    : _gensokyoInitiativeEnabled == null
                    ? 'Runtime 不提供只读状态；选择后以本次服务端回显为准'
                    : _gensokyoInitiativeEnabled!
                    ? '本次 Runtime 操作已启用主动消息'
                    : '本次 Runtime 操作已停用主动消息',
              ),
              value: _gensokyoInitiativeEnabled,
              onChanged: initialized && !_gensokyoSettingsBusy
                  ? (value) => _setGensokyoInitiative(value ?? true)
                  : null,
            ),
            const Divider(height: 24),
            if (!timerAvailable)
              const _SettingsInfoTile(
                icon: Icons.timer_off_outlined,
                title: '当前没有待触发的主动消息',
                description: '定时器创建后会在这里显示并允许调整。',
              )
            else ...<Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  Chip(
                    label: Text(
                      '状态: ${_gensokyoCurrentTimer['status'] ?? 'unknown'}',
                    ),
                  ),
                  Chip(
                    label: Text(
                      '剩余 ${_gensokyoCurrentTimer['remaining_seconds'] ?? 0} 秒',
                    ),
                  ),
                  if (_gensokyoCurrentTimer['is_fallback'] == true)
                    const Chip(label: Text('兜底定时器')),
                  if (_gensokyoCurrentTimer['user_modified'] == true)
                    const Chip(label: Text('已手动调整')),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey<String>('gensokyoAiTimerDelayField'),
                controller: _gensokyoTimerDelayController,
                enabled: !_gensokyoSettingsBusy,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: const InputDecoration(
                  labelText: '延迟秒数',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey<String>('gensokyoAiTimerSummaryField'),
                controller: _gensokyoTimerSummaryController,
                enabled: !_gensokyoSettingsBusy,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '待发送摘要',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton.tonalIcon(
                    onPressed: _gensokyoSettingsBusy
                        ? null
                        : _updateGensokyoTimer,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('应用调整'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _gensokyoSettingsBusy
                        ? null
                        : _triggerGensokyoTimer,
                    icon: const Icon(Icons.send_outlined),
                    label: const Text('立即触发'),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: _gensokyoSettingsBusy
                        ? null
                        : _cancelGensokyoTimer,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('取消定时器'),
                  ),
                ],
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.psychology_alt_outlined,
          title: '语义记忆',
          description: '添加、查看、搜索、编辑和删除当前 GensokyoAI 会话的语义记忆。',
          children: <Widget>[
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                key: const ValueKey<String>('gensokyoAiAddMemoryButton'),
                onPressed: initialized && !_gensokyoSettingsBusy
                    ? _addGensokyoMemory
                    : null,
                icon: const Icon(Icons.add),
                label: const Text('添加记忆'),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('gensokyoAiMemorySearchField'),
                    controller: _gensokyoMemorySearchController,
                    enabled: initialized && !_gensokyoSettingsBusy,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _searchGensokyoMemory(),
                    decoration: const InputDecoration(
                      labelText: '搜索记忆',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: '搜索记忆',
                  onPressed: initialized && !_gensokyoSettingsBusy
                      ? _searchGensokyoMemory
                      : null,
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_gensokyoMemories.isEmpty)
              const _SettingsInfoTile(
                icon: Icons.inbox_outlined,
                title: '暂无语义记忆',
                description: '当前会话没有可显示的语义记忆。',
              )
            else
              for (
                var index = 0;
                index < _gensokyoMemories.length;
                index += 1
              ) ...<Widget>[
                _buildGensokyoMemoryTile(_gensokyoMemories[index]),
                if (index < _gensokyoMemories.length - 1)
                  const Divider(height: 1),
              ],
          ],
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.map_outlined,
          title: '场景',
          description: '查看场景库并切换当前 GensokyoAI 会话的场景。',
          children: <Widget>[
            if (_gensokyoScenes.isEmpty)
              const _SettingsInfoTile(
                icon: Icons.map_outlined,
                title: '场景系统当前不可用',
                description:
                    '场景是可选功能。如需启用，请在 GensokyoAI Runtime 配置中设置 scene.enabled: true，并准备 scenes/ 场景库后重启 Runtime。scene.enabled: false 不影响聊天、主动消息或语义记忆。',
              )
            else
              for (
                var index = 0;
                index < _gensokyoScenes.length;
                index += 1
              ) ...<Widget>[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _gensokyoScenes[index]['id']?.toString() == currentSceneId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(
                    _gensokyoScenes[index]['name']?.toString() ??
                        _gensokyoScenes[index]['id']?.toString() ??
                        '未命名场景',
                  ),
                  subtitle: Text(
                    _gensokyoScenes[index]['description']?.toString() ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing:
                      _gensokyoScenes[index]['id']?.toString() == currentSceneId
                      ? const Chip(label: Text('当前'))
                      : const Icon(Icons.chevron_right),
                  onTap: _gensokyoSettingsBusy
                      ? null
                      : () => _switchGensokyoScene(
                          _gensokyoScenes[index]['id']?.toString() ?? '',
                        ),
                ),
                if (index < _gensokyoScenes.length - 1)
                  const Divider(height: 1),
              ],
          ],
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.extension_outlined,
          title: '工具与资源控制',
          description: '显示 GensokyoAI 的外部工具来源和 Runtime 并发限制。',
          children: <Widget>[
            _buildBackendInfoTile(
              '外部工具',
              _formatGensokyoRuntimeValue(_gensokyoToolStatus),
            ),
            _buildBackendInfoTile(
              '资源控制',
              _formatGensokyoRuntimeValue(
                _gensokyoRuntimeInfo['resource_control'],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildWorldSection(capabilities),
      ],
    );
  }

  Widget _buildWorldSection(List<String> capabilities) {
    final available = capabilities.contains('world.orchestration');
    if (!available) {
      return const _SettingsSection(
        icon: Icons.public_outlined,
        title: 'GensokyoWorld',
        description: '多角色 World 编排的只读状态。',
        children: <Widget>[
          _SettingsInfoTile(
            icon: Icons.extension_off_outlined,
            title: 'Runtime 未提供 World 能力',
            description: '当前服务没有声明 world.orchestration；普通 Agent 聊天不受影响。',
          ),
        ],
      );
    }
    final worldId = _gensokyoWorldState['world_id']?.toString() ?? '';
    final sessionId = _gensokyoWorldState['session_id']?.toString() ?? '';
    return _SettingsSection(
      icon: Icons.public_outlined,
      title: 'GensokyoWorld',
      description: '查看 Runtime 权威的 World、花名册、共享剧本和存档；客户端不在此执行写操作。',
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            const Chip(
              avatar: Icon(Icons.visibility_outlined, size: 18),
              label: Text('只读'),
            ),
            Chip(label: Text(worldId.isEmpty ? 'World 未装配' : worldId)),
            if (_gensokyoWorldState['started'] == true)
              const Chip(label: Text('已开始')),
            if (_gensokyoWorldState['waiting_for_user'] == true)
              const Chip(label: Text('等待用户')),
          ],
        ),
        if (sessionId.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          _buildBackendInfoTile('World 会话', sessionId, selectable: true),
        ],
        const Divider(height: 28),
        Text('花名册', style: Theme.of(context).textTheme.titleMedium),
        if (_gensokyoWorldRoster.isEmpty)
          const _SettingsInfoTile(
            icon: Icons.groups_outlined,
            title: '暂无在场角色',
            description: 'Runtime 当前没有返回 World 花名册。',
          )
        else
          for (final actor in _gensokyoWorldRoster)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                actor['is_current'] == true
                    ? Icons.record_voice_over_outlined
                    : Icons.person_outline,
              ),
              title: Text(
                actor['name']?.toString() ??
                    actor['actor_id']?.toString() ??
                    '未命名角色',
              ),
              subtitle: Text('场景：${actor['scene_id'] ?? '未指定'}'),
            ),
        const Divider(height: 28),
        Text('共享剧本', style: Theme.of(context).textTheme.titleMedium),
        if (_gensokyoWorldTranscript.isEmpty)
          const _SettingsInfoTile(
            icon: Icons.article_outlined,
            title: '暂无公开剧本',
            description: '当前场景没有可显示的共享剧本条目。',
          )
        else
          for (final entry in _gensokyoWorldTranscript)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text(
                entry['speaker_name']?.toString() ??
                    entry['actor_name']?.toString() ??
                    entry['speaker_id']?.toString() ??
                    entry['speaker_kind']?.toString() ??
                    'World',
              ),
              subtitle: SelectableText(
                contextMenuBuilder: jovTextContextMenu,
                entry['content']?.toString() ?? '',
              ),
            ),
        const Divider(height: 28),
        Text('World 存档', style: Theme.of(context).textTheme.titleMedium),
        if (_gensokyoWorldSessions.isEmpty)
          const Text('暂无可显示的 World 存档')
        else
          for (final session in _gensokyoWorldSessions)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(
                session['title']?.toString() ??
                    session['session_id']?.toString() ??
                    '未命名存档',
              ),
              subtitle: Text(
                '会话 ${session['session_id'] ?? ''}${session['updated_at'] == null ? '' : ' · ${session['updated_at']}'}',
              ),
            ),
      ],
    );
  }

  Widget _buildGensokyoMemoryTile(Map<String, dynamic> memory) {
    final id = memory['id']?.toString() ?? '';
    final tags = memory['tags'] is List
        ? (memory['tags'] as List).map((item) => item.toString()).join('、')
        : '';
    final topic =
        memory['topic_name']?.toString() ?? memory['topic']?.toString() ?? '';
    return ListTile(
      key: ValueKey<String>('gensokyoAiMemory-$id'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.memory_outlined),
      title: Text(
        memory['content']?.toString() ?? '空记忆',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        <String>[
          if (topic.isNotEmpty) topic,
          if (memory['importance'] != null) '重要度 ${memory['importance']}',
          if (tags.isNotEmpty) tags,
        ].join(' · '),
      ),
      trailing: PopupMenuButton<String>(
        enabled: !_gensokyoSettingsBusy && id.isNotEmpty,
        tooltip: '记忆操作',
        onSelected: (action) {
          if (action == 'edit') {
            unawaited(_editGensokyoMemory(memory));
          } else if (action == 'delete') {
            unawaited(_deleteGensokyoMemory(memory));
          }
        },
        itemBuilder: (context) => const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: 'edit',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_outlined),
              title: Text('编辑'),
            ),
          ),
          PopupMenuItem<String>(
            value: 'delete',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline),
              title: Text('删除'),
            ),
          ),
        ],
      ),
    );
  }

  Future<T?> _readGensokyoRuntime<T>(
    String label,
    Future<T> Function() reader,
    List<String> errors, {
    bool optional = false,
  }) async {
    try {
      return await reader();
    } catch (error) {
      if (!optional) {
        errors.add('$label：$error');
      }
      return null;
    }
  }

  Future<void> _loadGensokyoAiSettings() async {
    if (!_gensokyoAiInstalled || _gensokyoSettingsLoading) {
      return;
    }
    final runtime = _externalAgentRuntime;
    if (runtime == null) {
      setState(() {
        _gensokyoSettingsError = '当前应用实例没有连接外部 Runtime 管理接口。';
      });
      return;
    }
    setState(() {
      _gensokyoSettingsLoading = true;
      _gensokyoSettingsError = null;
    });
    final errors = <String>[];
    final info = await _readGensokyoRuntime(
      '运行信息',
      runtime.runtimeInfo,
      errors,
    );
    final health = await _readGensokyoRuntime('健康状态', runtime.health, errors);
    final tools = await _readGensokyoRuntime(
      '外部工具',
      runtime.externalToolStatus,
      errors,
    );
    final sessions = await _readGensokyoRuntime(
      '会话列表',
      runtime.listSessions,
      errors,
    );
    final worldAvailable =
        (info?['capabilities'] as List?)?.any(
          (item) => item.toString() == 'world.orchestration',
        ) ==
        true;
    Map<String, dynamic>? worldState;
    List<Map<String, dynamic>>? worldRoster;
    List<Map<String, dynamic>>? worldTranscript;
    List<Map<String, dynamic>>? worldSessions;
    if (worldAvailable) {
      worldState = await _readGensokyoRuntime(
        'World 状态',
        runtime.worldState,
        errors,
        optional: true,
      );
      if (worldState != null && worldState.isNotEmpty) {
        worldRoster = await _readGensokyoRuntime(
          'World 花名册',
          runtime.worldRoster,
          errors,
          optional: true,
        );
        worldTranscript = await _readGensokyoRuntime(
          'World 共享剧本',
          runtime.worldTranscript,
          errors,
          optional: true,
        );
        worldSessions = await _readGensokyoRuntime(
          'World 存档',
          runtime.listWorldSessions,
          errors,
          optional: true,
        );
      }
    }
    Map<String, dynamic>? session;
    Map<String, dynamic>? timer;
    Map<String, dynamic>? currentScene;
    List<Map<String, dynamic>>? memories;
    List<Map<String, dynamic>>? scenes;
    if (health?['initialized'] == true) {
      final sessionFuture = _readGensokyoRuntime(
        '当前会话',
        runtime.currentSession,
        errors,
      );
      final timerFuture = _readGensokyoRuntime(
        '主动定时器',
        runtime.currentInitiativeTimer,
        errors,
      );
      final memoryFuture = _readGensokyoRuntime(
        '语义记忆',
        runtime.listMemory,
        errors,
      );
      final sceneFuture = _readGensokyoRuntime(
        '场景列表',
        runtime.listScenes,
        errors,
        optional: true,
      );
      final currentSceneFuture = _readGensokyoRuntime(
        '当前场景',
        runtime.currentScene,
        errors,
        optional: true,
      );
      session = await sessionFuture;
      timer = await timerFuture;
      memories = await memoryFuture;
      scenes = await sceneFuture;
      currentScene = await currentSceneFuture;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _gensokyoRuntimeInfo = info ?? const <String, dynamic>{};
      _gensokyoHealth = health ?? const <String, dynamic>{};
      _gensokyoToolStatus = tools ?? const <String, dynamic>{};
      _gensokyoCurrentSession = session ?? const <String, dynamic>{};
      _gensokyoSessions = sessions ?? const <Map<String, dynamic>>[];
      _gensokyoCurrentTimer = timer ?? const <String, dynamic>{};
      _gensokyoMemories = memories ?? const <Map<String, dynamic>>[];
      _gensokyoScenes = scenes ?? const <Map<String, dynamic>>[];
      _gensokyoCurrentScene = currentScene ?? const <String, dynamic>{};
      _gensokyoWorldState = worldState ?? const <String, dynamic>{};
      _gensokyoWorldRoster = worldRoster ?? const <Map<String, dynamic>>[];
      _gensokyoWorldTranscript =
          worldTranscript ?? const <Map<String, dynamic>>[];
      _gensokyoWorldSessions = worldSessions ?? const <Map<String, dynamic>>[];
      _gensokyoSettingsError = errors.isEmpty ? null : errors.join('\n');
      _gensokyoSettingsLoading = false;
    });
    _syncGensokyoTimerEditors();
  }

  void _syncGensokyoTimerEditors() {
    final delay = _gensokyoCurrentTimer['delay_seconds']?.toString() ?? '';
    final summary = _gensokyoCurrentTimer['pending_summary']?.toString() ?? '';
    _gensokyoTimerDelayController.text = delay;
    _gensokyoTimerSummaryController.text = summary;
  }

  Future<void> _runGensokyoMutation(
    String successMessage,
    Future<void> Function(ExternalAgentRuntime runtime) action,
  ) async {
    final runtime = _externalAgentRuntime;
    if (runtime == null || _gensokyoSettingsBusy) {
      return;
    }
    setState(() {
      _gensokyoSettingsBusy = true;
      _gensokyoSettingsError = null;
    });
    try {
      await action(runtime);
      if (!mounted) {
        return;
      }
      showTopNotice(context, successMessage);
    } catch (error) {
      if (mounted) {
        setState(() => _gensokyoSettingsError = error.toString());
      }
      return;
    } finally {
      if (mounted) {
        setState(() => _gensokyoSettingsBusy = false);
      }
    }
    await _loadGensokyoAiSettings();
  }

  Future<void> _setGensokyoInitiative(bool enabled) =>
      _runGensokyoMutation(enabled ? '已启用主动消息' : '已停用主动消息', (runtime) async {
        final result = await runtime.updateInitiativeTimer(enabled: enabled);
        if (mounted) {
          setState(() {
            _gensokyoInitiativeEnabled = result['enabled'] is bool
                ? result['enabled'] as bool
                : enabled;
          });
        }
      });

  Future<void> _updateGensokyoTimer() async {
    final delay = int.tryParse(_gensokyoTimerDelayController.text.trim());
    if (delay == null || delay < 1) {
      setState(() => _gensokyoSettingsError = '延迟秒数必须是大于 0 的整数。');
      return;
    }
    final summary = _gensokyoTimerSummaryController.text.trim();
    await _runGensokyoMutation('主动定时器已更新', (runtime) async {
      await runtime.updateInitiativeTimer(
        timerId: _gensokyoCurrentTimer['timer_id']?.toString(),
        delaySeconds: delay,
        pendingSummary: summary.isEmpty ? null : summary,
      );
    });
  }

  Future<void> _triggerGensokyoTimer() =>
      _runGensokyoMutation('主动定时器已触发', (runtime) async {
        await runtime.triggerInitiativeTimer(
          timerId: _gensokyoCurrentTimer['timer_id']?.toString(),
        );
      });

  Future<void> _cancelGensokyoTimer() =>
      _runGensokyoMutation('主动定时器已取消', (runtime) async {
        await runtime.cancelInitiativeTimer(
          timerId: _gensokyoCurrentTimer['timer_id']?.toString(),
        );
      });

  Future<void> _searchGensokyoMemory() async {
    final runtime = _externalAgentRuntime;
    if (runtime == null || _gensokyoSettingsBusy) {
      return;
    }
    final query = _gensokyoMemorySearchController.text.trim();
    setState(() {
      _gensokyoSettingsBusy = true;
      _gensokyoSettingsError = null;
    });
    try {
      final memories = query.isEmpty
          ? await runtime.listMemory()
          : ((await runtime.searchMemory(query))['items'] as List?)
                    ?.whereType<Map>()
                    .map((item) => Map<String, dynamic>.from(item))
                    .toList(growable: false) ??
                const <Map<String, dynamic>>[];
      if (mounted) {
        setState(() => _gensokyoMemories = memories);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _gensokyoSettingsError = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _gensokyoSettingsBusy = false);
      }
    }
  }

  Future<void> _addGensokyoMemory() async {
    var content = '';
    var topic = '';
    var importanceText = '0';
    var valenceText = '0';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加语义记忆'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextFormField(
                  key: const ValueKey<String>('gensokyoAiMemoryContentField'),
                  onChanged: (value) => content = value,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: '内容',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  onChanged: (value) => topic = value,
                  decoration: const InputDecoration(
                    labelText: '话题名称（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextFormField(
                        initialValue: importanceText,
                        onChanged: (value) => importanceText = value,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: '重要度',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        initialValue: valenceText,
                        onChanged: (value) => valenceText = value,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: '情感效价',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    content = content.trim();
    topic = topic.trim();
    final importance = double.tryParse(importanceText.trim());
    final valence = double.tryParse(valenceText.trim());
    if (confirmed != true || !mounted) return;
    if (content.isEmpty || importance == null || valence == null) {
      setState(() {
        _gensokyoSettingsError = '记忆内容不能为空，重要度和情感效价必须是数字。';
      });
      return;
    }
    await _runGensokyoMutation('语义记忆已添加', (runtime) async {
      await runtime.addMemory(
        content,
        topicName: topic.isEmpty ? null : topic,
        importance: importance,
        emotionalValence: valence,
      );
    });
  }

  Future<void> _uploadCharacterPackage() async {
    final runtime = _externalAgentRuntime;
    final connection = runtime is GensokyoAiHttpRuntimeFacade
        ? runtime.client.connection
        : _settings.selectedExternalRuntimeConnection;
    if (runtime == null || connection == null) return;
    final picked = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'GensokyoAI 角色包',
          extensions: <String>['gensokyo-character'],
        ),
      ],
    );
    if (picked == null || !mounted) return;
    if (!picked.name.toLowerCase().endsWith('.gensokyo-character')) {
      setState(() => _gensokyoSettingsError = '请选择 .gensokyo-character 角色包。');
      return;
    }
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    var locale = '';
    var overwrite = false;
    var allowUntrusted = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('确认上传角色包'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _SettingsInfoTile(
                    icon: Icons.dns_outlined,
                    title: '目标连接：${connection.displayName}',
                    description:
                        '${connection.baseUrl}\nAgent：${connection.agentId}',
                  ),
                  _SettingsInfoTile(
                    icon: Icons.inventory_2_outlined,
                    title: picked.name,
                    description: '载荷大小：${_formatByteCount(bytes.length)}',
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    onChanged: (value) => locale = value,
                    decoration: const InputDecoration(
                      labelText: 'Locale（可选）',
                      hintText: '例如 zh_cn',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: overwrite,
                    onChanged: (value) =>
                        setDialogState(() => overwrite = value ?? false),
                    title: const Text('覆盖同名角色'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: allowUntrusted,
                    onChanged: (value) =>
                        setDialogState(() => allowUntrusted = value ?? false),
                    title: const Text('允许导入未受信任的包'),
                    subtitle: const Text('上游当前只校验签名格式；启用前应确认包来源'),
                  ),
                  const Text('此操作需要 admin 角色，且 Runtime 必须启用远程管理。'),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('上传到此连接'),
            ),
          ],
        ),
      ),
    );
    locale = locale.trim();
    if (confirmed != true || !mounted) return;
    setState(() {
      _gensokyoSettingsBusy = true;
      _gensokyoSettingsError = null;
    });
    try {
      await runtime.uploadCharacterPackage(
        filename: picked.name,
        bytes: bytes,
        locale: locale.isEmpty ? null : locale,
        overwrite: overwrite,
        allowUntrusted: allowUntrusted,
      );
      await _dispatchOperation(const SettingsOperation(reloadAssistants: true));
      if (mounted) showTopNotice(context, '角色包已上传到 ${connection.displayName}');
    } catch (error) {
      if (mounted) {
        setState(() => _gensokyoSettingsError = '角色包上传失败：$error');
      }
    } finally {
      if (mounted) setState(() => _gensokyoSettingsBusy = false);
    }
  }

  String _formatByteCount(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  Future<void> _editGensokyoMemory(Map<String, dynamic> memory) async {
    final contentController = TextEditingController(
      text: memory['content']?.toString() ?? '',
    );
    final importanceController = TextEditingController(
      text: memory['importance']?.toString() ?? '',
    );
    final tagsController = TextEditingController(
      text: memory['tags'] is List
          ? (memory['tags'] as List).map((item) => item.toString()).join(', ')
          : '',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑语义记忆'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: contentController,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: '内容',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: importanceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: '重要度',
                  hintText: '0.0 - 1.0',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tagsController,
                decoration: const InputDecoration(
                  labelText: '标签',
                  hintText: '使用逗号分隔',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      contentController.dispose();
      importanceController.dispose();
      tagsController.dispose();
      return;
    }
    final content = contentController.text.trim();
    final importance = double.tryParse(importanceController.text.trim());
    final tags = tagsController.text
        .split(RegExp(r'[,，]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    contentController.dispose();
    importanceController.dispose();
    tagsController.dispose();
    if (content.isEmpty ||
        (importance != null && (importance < 0 || importance > 1))) {
      setState(() {
        _gensokyoSettingsError = '记忆内容不能为空，重要度必须在 0.0 到 1.0 之间。';
      });
      return;
    }
    await _runGensokyoMutation('语义记忆已更新', (runtime) async {
      await runtime.updateMemory(
        memory['id']?.toString() ?? '',
        content: content,
        importance: importance,
        tags: tags,
      );
    });
  }

  Future<void> _deleteGensokyoMemory(Map<String, dynamic> memory) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除语义记忆'),
        content: const Text('这条记忆将从 GensokyoAI 当前会话中删除。确定继续吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _runGensokyoMutation('语义记忆已删除', (runtime) async {
      await runtime.deleteMemory(memory['id']?.toString() ?? '');
    });
  }

  Future<void> _switchGensokyoScene(String sceneId) async {
    if (sceneId.isEmpty || sceneId == _gensokyoCurrentScene['id']?.toString()) {
      return;
    }
    await _runGensokyoMutation('GensokyoAI 场景已切换', (runtime) async {
      await runtime.switchScene(sceneId);
    });
  }

  String _formatGensokyoRuntimeValue(Object? value) {
    if (value == null) {
      return '未读取';
    }
    if (value is Map) {
      if (value.isEmpty) {
        return '无';
      }
      return value.entries
          .map(
            (entry) =>
                '${entry.key}: ${_formatGensokyoRuntimeValue(entry.value)}',
          )
          .join(' · ');
    }
    if (value is List) {
      return value.isEmpty
          ? '无'
          : value.map(_formatGensokyoRuntimeValue).join('、');
    }
    if (value is bool) {
      return value ? '是' : '否';
    }
    return value.toString();
  }

  Widget _buildStoragePage() {
    final messagesFiles = _archivedConversations.length;
    final mediaBytes = _mediaFiles.fold<int>(
      0,
      (total, media) => total + media.byteLength,
    );
    return ListView(
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        _SettingsSection(
          icon: Icons.import_export_outlined,
          title: '存档导入导出',
          description: '把角色、会话和外观资源打包为 .jovarchive 文件，或从存档包恢复。导入会覆盖同名数据。',
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  key: const ValueKey<String>('archiveExportButton'),
                  onPressed: _archiveTransferBusy ? null : _exportAllArchives,
                  icon: const Icon(Icons.upload_outlined),
                  label: const Text('导出全部存档'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('archiveImportButton'),
                  onPressed: _archiveTransferBusy ? null : _importAllArchives,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('导入存档包'),
                ),
                if (_archiveTransferBusy)
                  const SizedBox(width: 80, child: LinearProgressIndicator()),
              ],
            ),
            if (_lastArchiveExportPath != null) ...<Widget>[
              const SizedBox(height: 8),
              SelectableText(
                contextMenuBuilder: jovTextContextMenu,
                '最近导出：$_lastArchiveExportPath',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.perm_media_outlined,
          title: '存储空间',
          description:
              '查看 HakureiTerminal 复制到程序数据目录中的所有媒体文件、占用空间和当前引用。相同内容只在媒体库中保存一份。',
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                Chip(label: Text('媒体文件: ${_mediaFiles.length}')),
                Chip(label: Text('占用空间: ${_formatFileSize(mediaBytes)}')),
                if (_loadingMedia) const Chip(label: Text('正在统计')),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              contextMenuBuilder: jovTextContextMenu,
              _mediaRepository.paths.mediaDir.path,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey<String>('refreshMediaStorage'),
              onPressed: _loadingMedia ? null : _loadMediaData,
              icon: const Icon(Icons.refresh),
              label: const Text('刷新媒体清单'),
            ),
            const SizedBox(height: 12),
            if (!_loadingMedia && _mediaFiles.isEmpty)
              const Text('暂无由 HakureiTerminal 管理的媒体文件。'),
            for (final media in _mediaFiles) _buildMediaStorageTile(media),
          ],
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.inventory_2_outlined,
          title: '存档管理',
          description: '本页展示客户端草稿、远程会话显示缓存和媒体存档清单。远程状态仍以 GensokyoAI 为准。',
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                Chip(label: Text('角色文件: ${_localAssistants.length}')),
                Chip(label: Text('会话目录: ${_archivedConversations.length}')),
                Chip(label: Text('消息文件: $messagesFiles')),
                if (_loadingArchiveData) const Chip(label: Text('正在刷新')),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _loadArchiveData,
              icon: const Icon(Icons.refresh),
              label: const Text('刷新存档清单'),
            ),
            const SizedBox(height: 16),
            _SettingsInfoTile(
              icon: Icons.smart_toy_outlined,
              title: 'assistants/*.json',
              description:
                  '当前 ${_localAssistants.length} 个不可执行角色草稿，保存用户创作内容和惰性元数据。',
            ),
            _SettingsInfoTile(
              icon: Icons.description_outlined,
              title: 'conversations/<id>/conversation.json',
              description: '当前 ${_archivedConversations.length} 个远程会话显示缓存目录。',
            ),
            _SettingsInfoTile(
              icon: Icons.notes_outlined,
              title: 'conversations/<id>/messages.jsonl',
              description: '当前 $messagesFiles 个消息文件入口，追加保存用户消息和 assistant 回复。',
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.delete_forever_outlined,
          title: '旧本地 Runtime 数据',
          description:
              '旧版本创建的本地 Runtime 文件不会被当前版本读取、上传或自动迁移。请先使用旧 Runtime 自带工具备份仍需保留的数据。',
          children: <Widget>[
            SelectableText(
              contextMenuBuilder: jovTextContextMenu,
              _assistantRepository.paths.root.path,
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              key: const ValueKey<String>('clearLegacyRuntimeData'),
              onPressed: _clearingLegacyRuntimeData
                  ? null
                  : _clearLegacyRuntimeData,
              icon: const Icon(Icons.delete_forever_outlined),
              label: Text(
                _clearingLegacyRuntimeData ? '正在删除...' : '删除旧本地 Runtime 数据',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '仅删除数据根目录中的 backends/、runtime_data/ 和 character_deployments/；不会删除设置、角色、会话、消息、媒体、日志或远端服务数据。',
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.article_outlined,
          title: '日志管理',
          description: '管理 HakureiTerminal 与可选运行服务写入的本地诊断日志，不会删除存档或配置。',
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                Chip(label: Text('日志文件: ${_logFiles.length}')),
                Chip(label: Text('占用空间: ${_formatFileSize(_logBytes)}')),
                if (_loadingLogs) const Chip(label: Text('正在统计')),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              contextMenuBuilder: jovTextContextMenu,
              _assistantRepository.paths.logsDir.path,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _loadingLogs ? null : _loadLogData,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新日志统计'),
                ),
                OutlinedButton.icon(
                  onPressed: _openLogsDirectory,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('打开日志目录'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _logFiles.isEmpty || _clearingLogs
                      ? null
                      : _clearLogFiles,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: Text(_clearingLogs ? '正在清除...' : '清除日志文件'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('仅处理日志目录内的 .log 文件；被其他进程占用的文件会保留并在结果中说明。'),
          ],
        ),
      ],
    );
  }

  Widget _buildMediaStorageTile(ManagedMediaFile media) {
    final references = <String>[];
    if (_backgroundImagePath == media.relativePath) {
      references.add('全局默认背景');
    }
    for (final conversation in _archivedConversations) {
      final title = conversation.title.trim().isEmpty
          ? conversation.sessionId
          : conversation.title;
      if (conversation.backgroundImagePath == media.relativePath) {
        references.add('会话背景：$title');
      }
      if (conversation.avatarImagePath == media.relativePath) {
        references.add('会话头像：$title');
      }
    }
    for (final role in _userRoles) {
      if (role.avatarPath == media.relativePath) {
        references.add('用户角色：${role.nickname}');
      }
    }
    final referenceText = references.isEmpty ? '当前未引用' : references.join('、');
    return ListTile(
      key: ValueKey<String>('managedMedia:${media.relativePath}'),
      contentPadding: EdgeInsets.zero,
      leading: SizedBox.square(
        dimension: 52,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(
            media.mediaType == '未知媒体'
                ? Icons.insert_drive_file_outlined
                : Icons.image_outlined,
          ),
        ),
      ),
      title: Text(
        '${media.mediaType} · ${_formatFileSize(media.byteLength)}${media.contentAddressed ? '' : ' · 旧格式'}',
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('引用：$referenceText'),
          SelectableText(
            contextMenuBuilder: jovTextContextMenu,
            media.relativePath,
          ),
          SelectableText(
            contextMenuBuilder: jovTextContextMenu,
            'SHA-256: ${media.sha256}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _loadMediaData() async {
    if (mounted) {
      setState(() => _loadingMedia = true);
    }
    try {
      final mediaFiles = await _mediaRepository.listManagedFiles();
      if (!mounted) {
        return;
      }
      setState(() => _mediaFiles = mediaFiles);
    } catch (error) {
      if (mounted) {
        showTopNotice(context, '媒体存储统计失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _loadingMedia = false);
      }
    }
  }

  Future<void> _loadLogData() async {
    if (mounted) {
      setState(() => _loadingLogs = true);
    }
    final files = <File>[];
    var bytes = 0;
    final directory = _assistantRepository.paths.logsDir;
    if (directory.existsSync()) {
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.log')) {
          files.add(entity);
          try {
            bytes += entity.lengthSync();
          } on FileSystemException {
            // A writer may rotate a log while the directory is being scanned.
          }
        }
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _logFiles = files;
      _logBytes = bytes;
      _loadingLogs = false;
    });
  }

  Future<void> _openLogsDirectory() async {
    final directory = _assistantRepository.paths.logsDir;
    await directory.create(recursive: true);
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', <String>[directory.path]);
      } else if (Platform.isMacOS) {
        await Process.start('open', <String>[directory.path]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', <String>[directory.path]);
      } else {
        throw UnsupportedError('当前平台不支持打开目录');
      }
    } catch (error) {
      if (mounted) {
        showTopNotice(context, '无法打开日志目录：$error');
      }
    }
  }

  Future<void> _clearLogFiles() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除日志文件'),
        content: Text('将删除 ${_logFiles.length} 个日志文件，不会影响存档和设置。是否继续？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _clearingLogs = true);
    var deleted = 0;
    var failed = 0;
    for (final file in List<File>.from(_logFiles)) {
      try {
        if (file.existsSync()) {
          file.deleteSync();
          deleted++;
        }
      } on FileSystemException {
        failed++;
      }
    }
    await _loadLogData();
    if (!mounted) {
      return;
    }
    setState(() => _clearingLogs = false);
    final result = failed == 0
        ? '已清除 $deleted 个日志文件'
        : '已清除 $deleted 个日志文件，$failed 个文件因正在使用或无权限而保留';
    showTopNotice(context, result);
  }

  Future<void> _clearLegacyRuntimeData() async {
    final root = _assistantRepository.paths.root.path;
    final directories = <Directory>[
      for (final name in <String>[
        'backends',
        'runtime_data',
        'character_deployments',
      ])
        Directory('$root${Platform.pathSeparator}$name'),
    ];
    final existing = directories
        .where((directory) => directory.existsSync())
        .toList(growable: false);
    if (existing.isEmpty) {
      showTopNotice(context, '没有找到旧本地 Runtime 数据');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除旧本地 Runtime 数据'),
        content: Text(
          '将永久删除以下 ${existing.length} 个目录及其全部内容：\n\n'
          '${existing.map((directory) => directory.path).join('\n')}\n\n'
          '此操作无法撤销。请先确认旧 Runtime 的角色、会话、记忆和配置已按需备份。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('confirmClearLegacyRuntimeData'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _clearingLegacyRuntimeData = true);
    final result = await deleteLegacyRuntimeData(_assistantRepository.paths);
    if (!mounted) {
      return;
    }
    setState(() => _clearingLegacyRuntimeData = false);
    showTopNotice(
      context,
      result.failed == 0
          ? '已删除 ${result.deleted} 个旧 Runtime 目录'
          : '已删除 ${result.deleted} 个目录，${result.failed} 个删除失败',
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final kib = bytes / 1024;
    if (kib < 1024) {
      return '${kib.toStringAsFixed(1)} KiB';
    }
    return '${(kib / 1024).toStringAsFixed(1)} MiB';
  }

  Future<void> _loadArchiveData() async {
    setState(() => _loadingArchiveData = true);
    try {
      final assistants = await _assistantRepository.listAssistants();
      final conversations = await _conversationRepository.listConversations();
      if (!mounted) {
        return;
      }
      setState(() {
        _localAssistants = assistants;
        _archivedConversations = conversations;
      });
    } finally {
      if (mounted) {
        setState(() => _loadingArchiveData = false);
      }
    }
  }

  /// 导出全部存档：桌面用系统“另存为”对话框；安卓桌面对话框不可用，
  /// 落到应用外部目录（`Android/data/<pkg>/files/exports`，
  /// 用户可通过文件管理器访问），未来可换 SAF 创建文档。
  Future<void> _exportAllArchives() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出完整存档'),
        content: const Text(
          '完整 .jovarchive 会包含模型 Provider Key、外部 Runtime URL 和访问令牌。'
          '该文件等同于敏感凭据备份，不应公开分享。确定继续吗？',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认并导出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _archiveTransferBusy = true);
    try {
      final exporter = JovArchiveExportRepository(
        paths: _assistantRepository.paths,
      );
      final fileName =
          'hakurei_terminal_archive_${DateTime.now().toUtc().millisecondsSinceEpoch}.jovarchive';
      File output;
      if (Platform.isAndroid) {
        final externalDir = await getExternalStorageDirectory();
        final baseDir = externalDir ?? await getApplicationDocumentsDirectory();
        output = File(
          '${baseDir.path}${Platform.pathSeparator}exports${Platform.pathSeparator}$fileName',
        );
      } else {
        final location = await getSaveLocation(
          suggestedName: fileName,
          acceptedTypeGroups: const <XTypeGroup>[
            XTypeGroup(
              label: 'HakureiTerminal 存档',
              extensions: <String>['jovarchive'],
            ),
          ],
        );
        if (location == null) {
          return;
        }
        output = File(location.path);
      }
      final currentSettings = _settingsWithCurrentForm();
      final written = await exporter.exportAllToFile(
        output,
        appearance: currentSettings.appearance,
        userRoles: currentSettings.userRoles,
        activeUserRoleId: currentSettings.activeUserRoleId,
        settings: currentSettings,
      );
      if (!mounted) {
        return;
      }
      setState(() => _lastArchiveExportPath = written.path);
      showTopNotice(context, '存档已导出：${written.path}');
    } catch (error) {
      if (mounted) {
        showTopNotice(context, '存档导出失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _archiveTransferBusy = false);
      }
    }
  }

  Future<void> _importAllArchives() async {
    final picked = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'HakureiTerminal 存档',
          extensions: <String>['jovarchive'],
        ),
      ],
    );
    if (picked == null || !mounted) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入存档包'),
        content: const Text(
          '导入会把存档包中的角色、会话和设置写入本地，同名数据将被覆盖。'
          '存档可能包含 Provider Key 和 Runtime 令牌；恢复的外部连接和委托授权会保持禁用，'
          '导入期间不会联网。确定继续吗？',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('confirmArchiveImport'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('导入并覆盖'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final hadLiveExternalRuntime =
        _externalBackendAvailable || _externalAgentRuntime != null;
    setState(() => _archiveTransferBusy = true);
    try {
      final bytes = await picked.readAsBytes();
      final importer = JovArchiveExportRepository(
        paths: _assistantRepository.paths,
      );
      final summary = await importer.importAllFromBytes(bytes);
      final importedSettings = summary.settings;
      if (importedSettings != null) {
        setState(() {
          _settings = importedSettings;
          _loadProfileIntoForm(importedSettings.activeProfile);
        });
      }
      final importedAppearance = summary.appearance;
      if (importedAppearance != null) {
        final importedBackground = _assistantRepository.paths
            .managedAppearanceResourceFile(
              importedAppearance.backgroundImagePath,
            );
        if (importedBackground != null && await importedBackground.exists()) {
          await FileImage(importedBackground).evict();
        }
        setState(() {
          _settings = _settingsWithCurrentForm().copyWith(
            appearance: importedAppearance,
          );
          _customPreviewThemes
            ..clear()
            ..addAll(customThemePalettes(importedAppearance));
          _selectedPreviewThemeId = resolveAppTheme(importedAppearance).id;
          _customPreviewThemeCounter = _customPreviewThemes.length;
          _backgroundImagePath = importedAppearance.backgroundImagePath;
          _backgroundImageOpacity = importedAppearance.backgroundImageOpacity;
          _backgroundImageOpacityController.text =
              '${(importedAppearance.backgroundImageOpacity * 100).round()}';
          _previewFontFamily = importedAppearance.fontFamilyId;
          _previewFontSize = importedAppearance.fontSize;
          _previewDensity = importedAppearance.uiDensity;
          _previewCornerRadius = importedAppearance.cornerRadius;
          _previewBubbleStyle = importedAppearance.bubbleStyle;
        });
      }
      final importedUserRoles = summary.userRoles;
      if (importedUserRoles != null) {
        setState(() {
          _settings = _settingsWithCurrentForm().copyWith(
            activeUserRoleId: summary.activeUserRoleId,
            userRoles: importedUserRoles,
          );
          _userRoles
            ..clear()
            ..addAll(
              importedUserRoles.map(
                (role) => _UserRoleDraft(
                  id: role.id,
                  nickname: role.nickname,
                  bio: role.bio,
                  avatarPath: role.avatarImagePath,
                ),
              ),
            );
          _selectedUserRoleId = summary.activeUserRoleId;
          _userRoleCounter = _userRoles.length;
          final selectedRole = _selectedUserRole;
          if (selectedRole != null) {
            _loadUserRoleIntoForm(selectedRole);
          } else {
            _userNicknameController.clear();
            _userBioController.clear();
            _userAvatarBytes = null;
            _userAvatarPath = '';
          }
          _userRoleEditing = false;
        });
      }
      await _loadArchiveData();
      await _loadMediaData();
      if (!mounted) {
        return;
      }
      final settingsChanged =
          importedSettings != null ||
          importedAppearance != null ||
          importedUserRoles != null;
      await applyArchiveImportOperation(
        settings: settingsChanged ? _settingsWithCurrentForm() : null,
        disconnectLiveRuntime:
            importedSettings != null && hadLiveExternalRuntime,
        dispatch: _dispatchOperation,
        disconnect: widget.onDeactivateExternalRuntime,
      );
      if (importedSettings != null && hadLiveExternalRuntime) {
        if (mounted) {
          setState(() {
            _externalAgentRuntime = null;
            _activeExternalRuntimeConnectionId = null;
            _externalBackendAvailable = false;
          });
        }
      }
      if (!mounted) {
        return;
      }
      if (!settingsChanged &&
          summary.assistantCount == 0 &&
          summary.conversationCount == 0) {
        showTopNotice(context, '导入完成，存档包中没有可更新的数据');
      }
    } catch (error) {
      if (mounted) {
        showTopNotice(context, '存档导入失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _archiveTransferBusy = false);
      }
    }
  }

  Future<void> _createLocalAssistant() async {
    final now = DateTime.now().toUtc();
    final assistant = Assistant(
      id: 'assistant_local_${now.microsecondsSinceEpoch}',
      name: '新角色草稿',
      description: '仅保存在本机的不可执行角色草稿。',
      createdAt: now,
      updatedAt: now,
      metadata: const <String, dynamic>{
        'origin': 'local_draft',
        'owner': 'hakurei_terminal',
        'executable': false,
      },
    );
    await _assistantRepository.saveAssistant(assistant);
    await _loadArchiveData();
  }

  Future<void> _editLocalAssistant(Assistant assistant) async {
    final nameController = TextEditingController(text: assistant.name);
    final descriptionController = TextEditingController(
      text: assistant.description,
    );
    final promptController = TextEditingController(
      text: assistant.systemPrompt,
    );
    final updated = await showDialog<Assistant>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑角色草稿'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                contextMenuBuilder: jovTextContextMenu,
                controller: nameController,
                decoration: const InputDecoration(labelText: '角色名称'),
              ),
              TextField(
                contextMenuBuilder: jovTextContextMenu,
                controller: descriptionController,
                decoration: const InputDecoration(labelText: '描述'),
              ),
              TextField(
                contextMenuBuilder: jovTextContextMenu,
                controller: promptController,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(labelText: '系统提示词'),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              Assistant(
                id: assistant.id,
                name: nameController.text.trim().isEmpty
                    ? assistant.name
                    : nameController.text.trim(),
                description: descriptionController.text.trim(),
                avatar: assistant.avatar,
                systemPrompt: promptController.text,
                createdAt: assistant.createdAt,
                updatedAt: DateTime.now().toUtc(),
                metadata: <String, dynamic>{
                  ...assistant.metadata,
                  'origin': 'local_draft',
                  'owner': 'hakurei_terminal',
                  'executable': false,
                },
              ),
            ),
            child: const Text('保存草稿'),
          ),
        ],
      ),
    );
    nameController.dispose();
    descriptionController.dispose();
    promptController.dispose();
    if (updated != null) {
      await _assistantRepository.saveAssistant(updated);
      await _loadArchiveData();
    }
  }

  Future<void> _deleteLocalAssistant(Assistant assistant) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本地角色'),
        content: Text(
          '确定要删除“${assistant.name}”吗？该操作会移除 assistants/${assistant.id}.json。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _assistantRepository.deleteAssistant(assistant.id);
    await _loadArchiveData();
  }

  Widget _buildSessionDefaultsPage() {
    return ListView(
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        _SettingsSection(
          icon: Icons.playlist_add_check_outlined,
          title: '会话默认值',
          description: '远程会话由 GensokyoAI 管理；标题策略会在创建后通过公开会话接口写入。',
          children: <Widget>[
            DropdownButtonFormField<String>(
              key: const ValueKey<String>('sessionDefaultAssistantSelector'),
              initialValue: _previewDefaultAssistant,
              decoration: const InputDecoration(
                labelText: '新会话默认角色',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
                helperText: '默认角色将在后续版本接入，当前仅为界面预览。',
              ),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: '不自动挂载', child: Text('不自动挂载')),
                DropdownMenuItem(value: '默认角色', child: Text('默认角色')),
                DropdownMenuItem(value: '最近使用的角色', child: Text('最近使用的角色')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _previewDefaultAssistant = value);
                }
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SessionTitleMode>(
              key: const ValueKey<String>('sessionDefaultTitleSelector'),
              initialValue: _previewDefaultTitleMode,
              decoration: const InputDecoration(
                labelText: '新会话标题',
                prefixIcon: Icon(Icons.title_outlined),
                border: OutlineInputBorder(),
                helperText: '创建会话后应用；首条消息模式使用首条用户消息的截断文本。',
              ),
              items: const <DropdownMenuItem<SessionTitleMode>>[
                DropdownMenuItem(
                  value: SessionTitleMode.fixed,
                  child: Text('固定为“新会话”'),
                ),
                DropdownMenuItem(
                  value: SessionTitleMode.createdAt,
                  child: Text('创建时间'),
                ),
                DropdownMenuItem(
                  value: SessionTitleMode.firstMessage,
                  child: Text('首条消息作为标题'),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _previewDefaultTitleMode = value);
                  _notifySettingsChanged();
                }
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildUserProfilePage() {
    final selectedRole = _selectedUserRole;
    return ListView(
      key: const ValueKey<String>('userRoleManagerList'),
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        _SettingsSection(
          icon: Icons.manage_accounts_outlined,
          title: '用户角色管理',
          description: '新建、选择、编辑或删除用户角色。角色资料和头像会随设置保存。',
          children: <Widget>[
            if (_userRoles.isNotEmpty)
              DropdownButtonFormField<String>(
                key: ValueKey<String>(
                  'userRoleSelector_${_selectedUserRoleId ?? 'none'}',
                ),
                initialValue: _selectedUserRoleId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '当前用户角色',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                items: _userRoles
                    .map(
                      (role) => DropdownMenuItem<String>(
                        value: role.id,
                        child: Row(
                          children: <Widget>[
                            CircleAvatar(
                              radius: 14,
                              foregroundImage: _userRoleAvatarProvider(role),
                              child: _userRoleAvatarProvider(role) == null
                                  ? const Icon(Icons.person_outline, size: 16)
                                  : null,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                role.nickname,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _userRoleEditing ? null : _selectUserRole,
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  key: const ValueKey<String>('userRoleCreateButton'),
                  onPressed: _userRoleEditing ? null : _createUserRole,
                  icon: const Icon(Icons.add),
                  label: const Text('新建角色'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('userRoleEditButton'),
                  onPressed: selectedRole == null || _userRoleEditing
                      ? null
                      : () => setState(() => _userRoleEditing = true),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('编辑'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey<String>('userRoleDeleteButton'),
                  onPressed: selectedRole == null || _userRoleEditing
                      ? null
                      : () => _deleteUserRole(selectedRole),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                ),
              ],
            ),
            if (_userRoles.isEmpty) ...<Widget>[
              const SizedBox(height: 12),
              const _SettingsInfoTile(
                icon: Icons.person_off_outlined,
                title: '暂无用户角色',
                description: '点击“新建角色”创建一个用户角色。',
              ),
            ],
          ],
        ),
        if (selectedRole != null) ...<Widget>[
          const SizedBox(height: 12),
          _SettingsSection(
            icon: Icons.account_circle_outlined,
            title: '角色资料：${selectedRole.nickname}',
            description: _userRoleEditing
                ? '正在编辑角色资料。'
                : '选择“编辑”后修改头像、昵称和自我介绍。',
            children: <Widget>[
              Row(
                children: <Widget>[
                  CircleAvatar(
                    key: const ValueKey<String>('userAvatarPreview'),
                    radius: 44,
                    foregroundImage: _currentUserAvatarProvider(),
                    child: _currentUserAvatarProvider() == null
                        ? const Icon(Icons.person_outline, size: 42)
                        : null,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        FilledButton.tonalIcon(
                          key: const ValueKey<String>('userAvatarPicker'),
                          onPressed: !_userRoleEditing || _userAvatarBusy
                              ? null
                              : _pickUserAvatar,
                          icon: const Icon(Icons.upload_outlined),
                          label: const Text('上传头像'),
                        ),
                        Tooltip(
                          message: '移除头像',
                          child: IconButton.outlined(
                            key: const ValueKey<String>('userAvatarRemove'),
                            onPressed:
                                !_userRoleEditing ||
                                    _userAvatarBusy ||
                                    (_userAvatarBytes == null &&
                                        _userAvatarPath.isEmpty)
                                ? null
                                : () => setState(() {
                                    _userAvatarBytes = null;
                                    _userAvatarPath = '';
                                  }),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ),
                        if (_userAvatarBusy)
                          const SizedBox(
                            width: 72,
                            child: LinearProgressIndicator(),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                contextMenuBuilder: jovTextContextMenu,
                key: const ValueKey<String>('userNicknameField'),
                controller: _userNicknameController,
                enabled: _userRoleEditing,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: '用户昵称',
                  hintText: '对话中展示的你的名字',
                  prefixIcon: Icon(Icons.badge_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                contextMenuBuilder: jovTextContextMenu,
                key: const ValueKey<String>('userBioField'),
                controller: _userBioController,
                enabled: _userRoleEditing,
                minLines: 3,
                maxLines: 6,
                maxLength: 600,
                decoration: const InputDecoration(
                  labelText: '自我介绍',
                  hintText: '可选。角色可以参考这里的信息了解你。',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              if (_userRoleEditing) ...<Widget>[
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    TextButton(
                      key: const ValueKey<String>('userRoleCancelButton'),
                      onPressed: _cancelUserRoleEditing,
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      key: const ValueKey<String>('userRoleSaveButton'),
                      onPressed: _saveUserRole,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('保存编辑'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              const _SettingsInfoTile(
                icon: Icons.psychology_alt_outlined,
                title: '用户记忆',
                description: '跨会话的用户级记忆管理将在后续版本提供。',
              ),
            ],
          ),
        ],
      ],
    );
  }

  String _nextUserRoleId() {
    String id;
    do {
      _userRoleCounter += 1;
      id = 'user_role_$_userRoleCounter';
    } while (_userRoles.any((role) => role.id == id));
    return id;
  }

  _UserRoleDraft? get _selectedUserRole {
    for (final role in _userRoles) {
      if (role.id == _selectedUserRoleId) {
        return role;
      }
    }
    return null;
  }

  void _loadUserRoleIntoForm(_UserRoleDraft role) {
    _userNicknameController.text = role.nickname;
    _userBioController.text = role.bio;
    _userAvatarBytes = null;
    _userAvatarPath = role.avatarPath;
  }

  ImageProvider? _userRoleAvatarProvider(_UserRoleDraft role) {
    final file = _assistantRepository.paths.managedMediaFile(role.avatarPath);
    return file != null && file.existsSync() ? FileImage(file) : null;
  }

  ImageProvider? _currentUserAvatarProvider() {
    if (_userAvatarBytes != null) {
      return MemoryImage(_userAvatarBytes!);
    }
    final file = _assistantRepository.paths.managedMediaFile(_userAvatarPath);
    return file != null && file.existsSync() ? FileImage(file) : null;
  }

  void _selectUserRole(String? id) {
    if (id == null || _userRoleEditing) {
      return;
    }
    _UserRoleDraft? role;
    for (final item in _userRoles) {
      if (item.id == id) {
        role = item;
        break;
      }
    }
    if (role == null) {
      return;
    }
    final selectedRole = role;
    setState(() {
      _selectedUserRoleId = id;
      _loadUserRoleIntoForm(selectedRole);
    });
    _notifySettingsChanged();
  }

  void _createUserRole() {
    final id = _nextUserRoleId();
    final role = _UserRoleDraft(
      id: id,
      nickname: '新用户角色 $_userRoleCounter',
      bio: '',
    );
    setState(() {
      _userRoles.add(role);
      _selectedUserRoleId = id;
      _loadUserRoleIntoForm(role);
      _userRoleEditing = true;
    });
  }

  Future<void> _saveUserRole() async {
    final nickname = _userNicknameController.text.trim();
    if (nickname.isEmpty) {
      showTopNotice(context, '用户昵称不能为空');
      return;
    }
    final index = _userRoles.indexWhere(
      (role) => role.id == _selectedUserRoleId,
    );
    if (index < 0) {
      return;
    }
    var avatarPath = _userAvatarPath;
    if (_userAvatarBytes != null) {
      try {
        avatarPath = await _mediaRepository.storeBytes(_userAvatarBytes!);
      } catch (error) {
        if (mounted) {
          showTopNotice(context, '用户头像保存失败：$error');
        }
        return;
      }
      if (!mounted) {
        return;
      }
    }
    setState(() {
      _userRoles[index] = _UserRoleDraft(
        id: _userRoles[index].id,
        nickname: nickname,
        bio: _userBioController.text.trim(),
        avatarPath: avatarPath,
      );
      _userAvatarBytes = null;
      _userAvatarPath = avatarPath;
      _userRoleEditing = false;
    });
    _notifySettingsChanged();
  }

  void _cancelUserRoleEditing() {
    final role = _selectedUserRole;
    if (role == null) {
      return;
    }
    setState(() {
      _loadUserRoleIntoForm(role);
      _userRoleEditing = false;
    });
  }

  Future<void> _deleteUserRole(_UserRoleDraft role) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除用户角色'),
        content: Text('确定删除用户角色“${role.nickname}”吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('confirmUserRoleDelete'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _userRoles.removeWhere((item) => item.id == role.id);
      _userRoleEditing = false;
      final nextRole = _userRoles.isEmpty ? null : _userRoles.first;
      _selectedUserRoleId = nextRole?.id;
      if (nextRole == null) {
        _userNicknameController.clear();
        _userBioController.clear();
        _userAvatarBytes = null;
        _userAvatarPath = '';
      } else {
        _loadUserRoleIntoForm(nextRole);
      }
    });
    _notifySettingsChanged();
  }

  Future<void> _pickUserAvatar() async {
    final picked = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: '头像图片',
          extensions: <String>['png', 'jpg', 'jpeg', 'webp'],
        ),
      ],
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() => _userAvatarBusy = true);
    try {
      final bytes = await picked.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 128);
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      codec.dispose();
      if (mounted) {
        setState(() => _userAvatarBytes = bytes);
      }
    } catch (error) {
      if (mounted) {
        showTopNotice(context, '头像图片读取失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _userAvatarBusy = false);
      }
    }
  }

  Widget _buildShortcutsPage() {
    const shortcuts = <(String, String, String)>[
      (AppShortcutId.sendMessage, 'Ctrl+Enter 发送，Enter 换行', 'Ctrl + Enter'),
      (AppShortcutId.sendMessageOnEnter, 'Enter 发送，Ctrl+Enter 换行', 'Enter'),
      (AppShortcutId.newSession, '新建会话', 'Ctrl + N'),
      (AppShortcutId.openSettings, '打开设置', 'Ctrl + ,'),
      (AppShortcutId.previousSession, '切换到上一个会话', 'Ctrl + Shift + Tab'),
      (AppShortcutId.nextSession, '切换到下一个会话', 'Ctrl + Tab'),
      (AppShortcutId.focusComposer, '聚焦消息输入框', 'Ctrl + L'),
    ];
    return ListView(
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        _SettingsSection(
          icon: Icons.keyboard_outlined,
          title: '快捷键',
          description: '控制全局键盘快捷键。两种发送方式互斥，其他快捷键默认开启。',
          children: <Widget>[
            for (final shortcut in shortcuts)
              SwitchListTile(
                key: ValueKey<String>('shortcutToggle_${shortcut.$1}'),
                contentPadding: EdgeInsets.zero,
                title: Text(shortcut.$2),
                secondary: _ShortcutKeyLabel(text: shortcut.$3),
                value: _settings.shortcuts.isEnabled(shortcut.$1),
                onChanged: (value) {
                  setState(() {
                    _settings = _settingsWithCurrentForm().copyWith(
                      shortcuts: _settings.shortcuts.setEnabled(
                        shortcut.$1,
                        value,
                      ),
                    );
                  });
                  _notifySettingsChanged();
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildDeveloperOptionsPage() {
    return ListView(
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        _SettingsSection(
          icon: Icons.code_outlined,
          title: '开发者选项',
          description: '调试与诊断相关的开关。除“显示调试信息”外，其余仅为界面预览。',
          children: <Widget>[
            CheckboxListTile(
              key: const ValueKey<String>('devShowDebugInfoToggle'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('显示调试信息'),
              subtitle: const Text('在会话列表和会话头部显示会话 ID 等内部标识。'),
              value: _settings.developer.showDebugInfo,
              onChanged: (value) {
                setState(() {
                  _settings = _settingsWithCurrentForm().copyWith(
                    developer: _settings.developer.copyWith(
                      showDebugInfo: value ?? false,
                    ),
                  );
                });
                _notifySettingsChanged();
              },
            ),
            CheckboxListTile(
              key: const ValueKey<String>('devVerboseLogToggle'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('详细日志'),
              subtitle: const Text('输出更详细的运行日志，用于排查问题。'),
              value: _previewDevVerboseLog,
              onChanged: (value) =>
                  setState(() => _previewDevVerboseLog = value ?? false),
            ),
            CheckboxListTile(
              key: const ValueKey<String>('devShowRequestPayloadToggle'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('显示请求载荷'),
              subtitle: const Text('在调试视图中展示客户端发往 Runtime 的请求体。'),
              value: _previewDevShowRequestPayload,
              onChanged: (value) => setState(
                () => _previewDevShowRequestPayload = value ?? false,
              ),
            ),
            CheckboxListTile(
              key: const ValueKey<String>('devExperimentalToggle'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('实验性功能'),
              subtitle: const Text('启用尚未稳定的实验性能力。'),
              value: _previewDevExperimental,
              onChanged: (value) =>
                  setState(() => _previewDevExperimental = value ?? false),
            ),
            const SizedBox(height: 8),
            const _SettingsInfoTile(
              icon: Icons.bug_report_outlined,
              title: '诊断工具',
              description: 'Runtime 连接追踪、性能面板等诊断工具将在后续版本提供。',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBackendPage() {
    return ListView(
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        _buildExternalRuntimeConnectionsSection(),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.dashboard_customize_outlined,
          title: '运行服务总览',
          description: 'HakureiTerminal 只连接独立部署的 GensokyoAI，不提供内置运行服务。',
          children: <Widget>[
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                Chip(
                  label: Text(
                    _externalBackendAvailable
                        ? 'GensokyoAI：已连接'
                        : 'GensokyoAI：未连接',
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildExternalRuntimeConnectionsSection() {
    final connections = _settings.externalRuntimeConnections;
    final activeConnection = _settings.externalRuntimeConnectionById(
      _activeExternalRuntimeConnectionId ?? '',
    );
    return _SettingsSection(
      icon: Icons.hub_outlined,
      title: 'Runtime 连接',
      description: '管理独立的 GensokyoAI Runtime。选择或保存档案不会发起网络请求。',
      children: <Widget>[
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            activeConnection == null
                ? Icons.cloud_off_outlined
                : Icons.cloud_done_outlined,
          ),
          title: Text(
            activeConnection == null
                ? '当前未连接'
                : '已连接：${_runtimeConnectionName(activeConnection)}',
          ),
          subtitle: Text(
            activeConnection == null
                ? '选择一个档案后，点击其连接按钮。'
                : activeConnection.baseUrl,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Divider(),
        if (connections.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text('尚未保存 Runtime 连接档案。'),
          ),
        for (var index = 0; index < connections.length; index++)
          _buildExternalRuntimeConnectionRow(connections[index], index),
        OutlinedButton.icon(
          key: const ValueKey<String>('addExternalRuntimeConnection'),
          onPressed: _showExternalRuntimeConnectionDialog,
          icon: const Icon(Icons.add_link),
          label: const Text('添加 GensokyoAI 连接'),
        ),
      ],
    );
  }

  Widget _buildExternalRuntimeConnectionRow(
    ExternalRuntimeConnectionSettings connection,
    int index,
  ) {
    final selected =
        _settings.selectedExternalRuntimeConnectionId == connection.id;
    final active = _activeExternalRuntimeConnectionId == connection.id;
    final busy = _runtimeConnectionOperationId != null;
    return Column(
      key: ValueKey<String>('externalRuntimeConnection:${connection.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ListTile(
          key: ValueKey<String>('selectExternalRuntime:${connection.id}'),
          contentPadding: EdgeInsets.zero,
          selected: selected,
          onTap: busy
              ? null
              : () => _selectExternalRuntimeConnection(connection.id),
          leading: Icon(
            active
                ? Icons.cloud_done_outlined
                : selected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
          ),
          title: Row(
            children: <Widget>[
              Expanded(child: Text(_runtimeConnectionName(connection))),
              if (active)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Chip(label: Text('已连接')),
                )
              else if (selected)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Chip(label: Text('已选择')),
                ),
            ],
          ),
          subtitle: Column(
            key: ValueKey<String>(
              'externalRuntimeAgentSummary:${connection.id}',
            ),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                connection.baseUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                'Agent v2 · Agent ID ${_shortRuntimeAgentId(connection.agentId)} · '
                '${connection.lastVerifiedAt == null ? '未验证' : '已验证'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            spacing: 2,
            children: <Widget>[
              IconButton(
                key: ValueKey<String>('testExternalRuntime:${connection.id}'),
                tooltip: '测试连接',
                onPressed: busy
                    ? null
                    : () => _testExternalRuntimeConnection(connection),
                icon: const Icon(Icons.network_check_outlined),
              ),
              IconButton(
                key: ValueKey<String>('editExternalRuntime:${connection.id}'),
                tooltip: active ? '请先断开再编辑' : '编辑连接',
                onPressed: busy || active
                    ? null
                    : () => _showExternalRuntimeConnectionDialog(
                        connection: connection,
                      ),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: connection.delegatedProfileId.isEmpty
                    ? '委托当前模型配置'
                    : '撤销模型配置委托',
                onPressed: busy
                    ? null
                    : () => _toggleExternalRuntimeDelegation(connection),
                icon: Icon(
                  connection.delegatedProfileId.isEmpty
                      ? Icons.key_outlined
                      : Icons.key_off_outlined,
                ),
              ),
              IconButton(
                key: ValueKey<String>(
                  '${active ? 'disconnect' : 'connect'}ExternalRuntime:${connection.id}',
                ),
                tooltip: active ? '断开 Runtime' : '连接 Runtime',
                onPressed: busy
                    ? null
                    : active
                    ? () => _disconnectExternalRuntime(connection)
                    : () => _connectExternalRuntime(connection),
                icon: Icon(
                  active ? Icons.logout_outlined : Icons.login_outlined,
                ),
              ),
              IconButton(
                key: ValueKey<String>('removeExternalRuntime:${connection.id}'),
                tooltip: '删除连接',
                onPressed: busy
                    ? null
                    : () => _removeExternalRuntimeConnection(connection),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
        if (index < _settings.externalRuntimeConnections.length - 1)
          const Divider(),
      ],
    );
  }

  String _runtimeConnectionName(ExternalRuntimeConnectionSettings connection) {
    final name = connection.displayName.trim();
    return name.isEmpty ? 'GensokyoAI Runtime' : name;
  }

  String _shortRuntimeAgentId(String agentId) {
    final normalized = agentId.trim();
    if (normalized.length <= 8) {
      return normalized;
    }
    return '${normalized.substring(0, 8)}…';
  }

  Future<void> _showExternalRuntimeConnectionDialog({
    ExternalRuntimeConnectionSettings? connection,
  }) async {
    final result = await showDialog<ExternalRuntimeConnectionSettings>(
      context: context,
      builder: (context) =>
          _ExternalRuntimeConnectionDialog(connection: connection),
    );
    if (result == null || !mounted) {
      return;
    }
    final settings = _settings.upsertExternalRuntimeConnection(
      result,
      select: connection == null,
    );
    setState(() => _settings = settings);
    await _dispatchOperation(SettingsOperation(settings: settings));
  }

  Future<void> _testExternalRuntimeConnection(
    ExternalRuntimeConnectionSettings connection,
  ) async {
    if (_runtimeConnectionOperationId != null) {
      return;
    }
    setState(() => _runtimeConnectionOperationId = connection.id);
    final client = GensokyoAiHttpRuntimeClient(connection: connection);
    try {
      final info = await client.negotiate();
      await client.health();
      await client.readiness();
      if (!mounted) {
        return;
      }
      final updated = connection.copyWith(
        lastVerifiedAt: DateTime.now().toUtc(),
        lastRuntimeInfo: _runtimeInfoSummary(info),
      );
      final settings = _settings.upsertExternalRuntimeConnection(
        updated,
        select: false,
      );
      setState(() => _settings = settings);
      await _dispatchOperation(SettingsOperation(settings: settings));
      if (mounted) {
        showTopNotice(context, '服务连接验证成功');
      }
    } on RuntimeConnectionException catch (error) {
      if (mounted) {
        showTopNotice(context, error.kind);
      }
    } on FormatException {
      if (mounted) {
        showTopNotice(context, '服务响应格式无效');
      }
    } finally {
      await client.dispose();
      if (mounted) {
        setState(() => _runtimeConnectionOperationId = null);
      }
    }
  }

  Map<String, dynamic> _runtimeInfoSummary(Map<String, dynamic> info) {
    const fields = <String>{
      'name',
      'package_version',
      'protocol_version',
      'protocol_major_version',
      'capabilities',
      'methods',
    };
    return <String, dynamic>{
      for (final entry in info.entries)
        if (fields.contains(entry.key)) entry.key: entry.value,
    };
  }

  Future<void> _selectExternalRuntimeConnection(String connectionId) async {
    if (_settings.selectedExternalRuntimeConnectionId == connectionId) {
      return;
    }
    final settings = _settings.selectExternalRuntimeConnection(connectionId);
    setState(() => _settings = settings);
    await _dispatchOperation(SettingsOperation(settings: settings));
  }

  Future<void> _connectExternalRuntime(
    ExternalRuntimeConnectionSettings connection,
  ) async {
    if (_runtimeConnectionOperationId != null) {
      return;
    }
    var settings = _settings;
    if (settings.selectedExternalRuntimeConnectionId != connection.id) {
      settings = settings.selectExternalRuntimeConnection(connection.id);
      setState(() => _settings = settings);
      await _dispatchOperation(SettingsOperation(settings: settings));
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _runtimeConnectionOperationId = connection.id;
      _activeExternalRuntimeConnectionId = null;
      _externalAgentRuntime = null;
      _externalBackendAvailable = false;
    });
    try {
      final runtime = await widget.onActivateExternalRuntime?.call(
        settings,
        connection.id,
      );
      if (runtime != null && mounted) {
        setState(() {
          _externalAgentRuntime = runtime;
          _activeExternalRuntimeConnectionId = connection.id;
          _externalBackendAvailable = true;
        });
        showTopNotice(context, '已连接 ${_runtimeConnectionName(connection)}');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _externalAgentRuntime = null;
          _activeExternalRuntimeConnectionId = null;
          _externalBackendAvailable = false;
        });
        showTopNotice(
          context,
          '${_runtimeConnectionName(connection)} 连接失败：$error',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _runtimeConnectionOperationId = null);
      }
    }
  }

  Future<bool> _disconnectExternalRuntime(
    ExternalRuntimeConnectionSettings connection,
  ) async {
    if (_runtimeConnectionOperationId != null) {
      return false;
    }
    setState(() => _runtimeConnectionOperationId = connection.id);
    try {
      await widget.onDeactivateExternalRuntime?.call();
      if (mounted) {
        setState(() {
          _externalAgentRuntime = null;
          _activeExternalRuntimeConnectionId = null;
          _externalBackendAvailable = false;
        });
        showTopNotice(context, '已断开 ${_runtimeConnectionName(connection)}');
      }
      return true;
    } catch (error) {
      if (mounted) {
        showTopNotice(context, '断开 Runtime 失败：$error');
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _runtimeConnectionOperationId = null);
      }
    }
  }

  Future<void> _toggleExternalRuntimeDelegation(
    ExternalRuntimeConnectionSettings connection,
  ) async {
    final delegated = connection.delegatedProfileId.isNotEmpty;
    if (!delegated) {
      final profile = _settings.activeProfile;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('委托模型配置'),
          content: Text(
            '将把模型配置“${profile.name}”的 Provider、模型、Base URL 和 Key '
            '在发送外部消息时交给 ${connection.displayName}。授权范围是当前 Runtime '
            '实例，直到服务重启、再次初始化或你撤销委托。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认委托'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
    }
    final updated = connection.copyWith(
      delegatedProfileId: delegated ? '' : _settings.activeProfile.id,
    );
    final settings = _settings.upsertExternalRuntimeConnection(
      updated,
      select: false,
    );
    setState(() => _settings = settings);
    await _dispatchOperation(SettingsOperation(settings: settings));
  }

  Future<void> _removeExternalRuntimeConnection(
    ExternalRuntimeConnectionSettings connection,
  ) async {
    final active = _activeExternalRuntimeConnectionId == connection.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 Runtime 连接'),
        content: Text(
          active
              ? '“${_runtimeConnectionName(connection)}”当前已连接。删除会先断开连接，但不会删除 Runtime 中的角色、会话或记忆。'
              : '删除“${_runtimeConnectionName(connection)}”的本地连接档案？这不会删除 Runtime 中的任何数据。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    if (active && !await _disconnectExternalRuntime(connection)) {
      return;
    }
    final settings = _settings.removeExternalRuntimeConnection(connection.id);
    setState(() => _settings = settings);
    await _dispatchOperation(SettingsOperation(settings: settings));
    if (mounted) {
      showTopNotice(context, '已删除本地连接档案');
    }
  }

  Widget _buildBackendInfoTile(
    String label,
    String value, {
    bool selectable = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          selectable
              ? SelectableText(contextMenuBuilder: jovTextContextMenu, value)
              : Text(value),
        ],
      ),
    );
  }

  Widget _buildAboutPage() {
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      key: const ValueKey<String>('aboutSettingsList'),
      padding: const EdgeInsets.all(10),
      children: <Widget>[
        _SettingsSection(
          icon: Icons.info_outline,
          title: '版本',
          description: '当前客户端 Release 版本号。',
          children: <Widget>[
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                final packageInfo = snapshot.data;
                final versionText = packageInfo == null
                    ? '读取中...'
                    : _formatFullVersion(packageInfo);
                return SelectableText(
                  contextMenuBuilder: jovTextContextMenu,
                  'Release 版本号：$versionText',
                  style: textTheme.bodyLarge,
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.verified_user_outlined,
          title: '许可证',
          description: '项目许可证信息。',
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: _openLicenseFile,
              icon: const Icon(Icons.open_in_new),
              label: const Text('打开主项目许可证 LICENSE'),
            ),
            const SizedBox(height: 8),
            SelectableText(
              contextMenuBuilder: jovTextContextMenu,
              '第三方依赖许可证：见仓库根目录 THIRD_PARTY_LICENSES.md。',
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _showSourceHanSansLicense,
              icon: const Icon(Icons.font_download_outlined),
              label: const Text('查看思源黑体许可证（SIL OFL 1.1）'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.badge_outlined,
          title: '作者信息',
          description: '项目作者与维护信息。',
          children: const <Widget>[
            SelectableText(
              contextMenuBuilder: jovTextContextMenu,
              '作者：JO-Beacon',
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.bug_report_outlined,
          title: 'BUG 反馈',
          description: '提交使用过程中发现的问题。',
          children: <Widget>[
            OutlinedButton.icon(
              key: const ValueKey<String>('bugReportButton'),
              onPressed: () {
                showTopNotice(context, 'BUG 反馈入口即将开放。');
              },
              icon: const Icon(Icons.feedback_outlined),
              label: const Text('提交 BUG 反馈'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          icon: Icons.extension_outlined,
          title: '第三方依赖与运行服务声明',
          description: '客户端依赖和外部运行服务边界说明。',
          children: const <Widget>[
            SelectableText(
              contextMenuBuilder: jovTextContextMenu,
              'Dart 依赖：package_info_plus、archive、crypto、cupertino_icons、flutter_markdown_plus、audioplayers、url_launcher。',
            ),
            SizedBox(height: 8),
            SelectableText(
              contextMenuBuilder: jovTextContextMenu,
              'HakureiTerminal 不内置或分发运行服务；GensokyoAI 由用户独立部署并显式连接。',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.settings, size: 36),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Provider 设置', style: textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  const Text(
                    '前端保存可选的委托档案。模型执行始终由 GensokyoAI 负责；模型列表仅在你明确请求时从 Provider 读取。',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileSection() {
    return _SettingsSection(
      icon: Icons.manage_accounts_outlined,
      title: 'Provider 配置档案',
      description: '可保存多套委托配置。配置只会在你对目标 GensokyoAI 明确授权委托后发送。',
      children: <Widget>[
        DropdownButtonFormField<String>(
          initialValue: _editingProfile.id,
          items: _settings.profiles
              .map(
                (profile) => DropdownMenuItem<String>(
                  value: profile.id,
                  child: Text(profile.name),
                ),
              )
              .toList(growable: false),
          decoration: const InputDecoration(
            labelText: '当前配置',
            border: OutlineInputBorder(),
          ),
          onChanged: (value) {
            if (value != null) {
              _selectProfile(value);
            }
          },
        ),
        const SizedBox(height: 16),
        TextField(
          contextMenuBuilder: jovTextContextMenu,
          controller: _profileNameController,
          decoration: const InputDecoration(
            labelText: '配置名称',
            hintText: '例如 OpenAI 正式环境 / DeepSeek 日常 / 本地 Ollama',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: _createProfile,
              icon: const Icon(Icons.add),
              label: const Text('新建'),
            ),
            OutlinedButton.icon(
              onPressed: _duplicateProfile,
              icon: const Icon(Icons.copy),
              label: const Text('复制当前'),
            ),
            OutlinedButton.icon(
              onPressed: _settings.profiles.length <= 1 ? null : _deleteProfile,
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除当前'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildModelSection() {
    return _SettingsSection(
      icon: Icons.smart_toy_outlined,
      title: 'Runtime 委托配置',
      description:
          '这些客户端自有字段不会被 HakureiTerminal 执行。仅在目标连接上明确开启委托后随 agent.init 发送给 GensokyoAI。',
      children: <Widget>[
        _buildProviderDropdown(
          label: 'Provider',
          value: _provider,
          onChanged: (value) {
            setState(() {
              _provider = value;
              _clearProviderModels();
            });
            _notifySettingsChanged();
          },
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey<String>('providerBaseUrlField'),
          contextMenuBuilder: jovTextContextMenu,
          controller: _baseUrlController,
          onChanged: (_) => _invalidateProviderModels(),
          decoration: const InputDecoration(
            labelText: 'Base URL（可选）',
            hintText: '兼容 OpenAI 的第三方服务可在这里填写 endpoint',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey<String>('providerApiKeyField'),
          contextMenuBuilder: jovTextContextMenu,
          controller: _apiKeyController,
          onChanged: (_) => _invalidateProviderModels(),
          obscureText: _obscureApiKey,
          decoration: InputDecoration(
            labelText: 'API Key',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _obscureApiKey ? '显示 API Key' : '隐藏 API Key',
              onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
              icon: Icon(
                _obscureApiKey ? Icons.visibility : Icons.visibility_off,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildModelSelector(),
        const SizedBox(height: 12),
        _buildModelCapabilitySummary(),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                contextMenuBuilder: jovTextContextMenu,
                controller: _temperatureController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Temperature（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                contextMenuBuilder: jovTextContextMenu,
                controller: _topPController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Top P（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                contextMenuBuilder: jovTextContextMenu,
                controller: _maxTokensController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Max Tokens（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                contextMenuBuilder: jovTextContextMenu,
                controller: _timeoutController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Timeout 秒（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          contextMenuBuilder: jovTextContextMenu,
          controller: _reasoningEffortController,
          decoration: const InputDecoration(
            labelText: 'Reasoning Effort（可选）',
            hintText: '例如 low / medium / high，按 Provider 支持情况填写',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('启用流式配置'),
          subtitle: const Text('是否向运行服务传递 stream=true。当前 UI 仍按非流式结果展示。'),
          value: _stream,
          onChanged: (value) {
            setState(() => _stream = value ?? false);
            _notifySettingsChanged();
          },
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('启用 Think 参数'),
          subtitle: const Text('用于支持 think/reasoning 的 Provider。'),
          value: _think,
          onChanged: (value) {
            setState(() => _think = value ?? false);
            _notifySettingsChanged();
          },
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('使用代理'),
          value: _useProxy,
          onChanged: (value) {
            setState(() {
              _useProxy = value ?? false;
              _clearProviderModels();
            });
            _notifySettingsChanged();
          },
        ),
        const SizedBox(height: 12),
        const _SettingsInfoTile(
          icon: Icons.hub_outlined,
          title: '模型执行仍由 Runtime 负责',
          description:
              '获取模型列表只读取 Provider 元数据。生成、Embedding、工具调用和上下文处理仍全部由 GensokyoAI 执行。',
        ),
      ],
    );
  }

  Widget _buildModelSelector() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final field = _providerModels.isEmpty
            ? TextField(
                key: const ValueKey<String>('providerModelManualField'),
                contextMenuBuilder: jovTextContextMenu,
                controller: _modelController,
                decoration: const InputDecoration(
                  labelText: '模型名',
                  hintText: '例如 gpt-4o / claude-3-5-sonnet-latest',
                  border: OutlineInputBorder(),
                ),
              )
            : DropdownMenu<ProviderModelCatalogEntry>(
                key: const ValueKey<String>('providerModelDropdown'),
                controller: _modelController,
                width: constraints.maxWidth - 56,
                enableFilter: true,
                enableSearch: true,
                requestFocusOnTap: true,
                label: const Text('模型名'),
                hintText: '搜索或手动输入模型名',
                dropdownMenuEntries: _providerModels
                    .map(
                      (model) => DropdownMenuEntry<ProviderModelCatalogEntry>(
                        value: model,
                        label: model.name == model.id
                            ? model.id
                            : '${model.id} · ${model.name}',
                      ),
                    )
                    .toList(growable: false),
                onSelected: (model) {
                  if (model != null) {
                    _modelController.text = model.id;
                  }
                },
              );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: field),
                const SizedBox(width: 8),
                SizedBox(
                  width: 48,
                  height: 56,
                  child: IconButton.filledTonal(
                    key: const ValueKey<String>('fetchProviderModels'),
                    tooltip: '获取模型列表',
                    onPressed: _providerModelsLoading
                        ? null
                        : _fetchProviderModels,
                    icon: _providerModelsLoading
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ),
              ],
            ),
            if (_providerModelsError != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _providerModelsError!,
                key: const ValueKey<String>('providerModelsError'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ] else if (_providerModels.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '已获取 ${_providerModels.length} 个模型',
                key: const ValueKey<String>('providerModelsCount'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _fetchProviderModels() async {
    final provider = _provider.trim();
    final baseUrl = _baseUrlController.text.trim();
    final apiKey = _apiKeyController.text.trim();
    if (baseUrl.isEmpty) {
      setState(() => _providerModelsError = '请先填写 Provider Base URL');
      return;
    }
    final timeoutSeconds = int.tryParse(_timeoutController.text.trim());
    final timeout = Duration(
      seconds: timeoutSeconds != null && timeoutSeconds > 0
          ? timeoutSeconds
          : 30,
    );
    final sourceKey = _providerModelSourceKey(
      provider: provider,
      baseUrl: baseUrl,
      apiKey: apiKey,
      useProxy: _useProxy,
    );
    final generation = ++_providerModelRequestGeneration;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _providerModelsLoading = true;
      _providerModelsError = null;
      _providerModels = const <ProviderModelCatalogEntry>[];
    });
    try {
      final models = await _providerModelCatalog.listModels(
        provider: provider,
        baseUrl: baseUrl,
        apiKey: apiKey,
        timeout: timeout,
        useProxy: _useProxy,
      );
      if (!mounted ||
          generation != _providerModelRequestGeneration ||
          sourceKey != _currentProviderModelSourceKey) {
        return;
      }
      setState(() => _providerModels = models);
      showTopNotice(context, '已获取 ${models.length} 个模型');
    } on ProviderModelCatalogException catch (error) {
      if (!mounted || generation != _providerModelRequestGeneration) {
        return;
      }
      setState(() => _providerModelsError = error.message);
    } catch (_) {
      if (!mounted || generation != _providerModelRequestGeneration) {
        return;
      }
      setState(() => _providerModelsError = '获取模型列表失败');
    } finally {
      if (mounted && generation == _providerModelRequestGeneration) {
        setState(() => _providerModelsLoading = false);
      }
    }
  }

  String get _currentProviderModelSourceKey => _providerModelSourceKey(
    provider: _provider,
    baseUrl: _baseUrlController.text,
    apiKey: _apiKeyController.text,
    useProxy: _useProxy,
  );

  String _providerModelSourceKey({
    required String provider,
    required String baseUrl,
    required String apiKey,
    required bool useProxy,
  }) =>
      '${provider.trim()}\u0000${baseUrl.trim()}\u0000${apiKey.trim()}\u0000$useProxy';

  void _invalidateProviderModels() {
    if (_providerModels.isEmpty &&
        _providerModelsError == null &&
        !_providerModelsLoading) {
      return;
    }
    setState(_clearProviderModels);
  }

  void _clearProviderModels() {
    _providerModelRequestGeneration++;
    _providerModels = const <ProviderModelCatalogEntry>[];
    _providerModelsLoading = false;
    _providerModelsError = null;
  }

  ModelCapabilityProfile get _currentModelCapabilityProfile {
    final key = _modelCapabilityKey(
      provider: _provider,
      model: _modelController.text,
    );
    return _modelCapabilities[key] ?? const ModelCapabilityProfile();
  }

  String _modelCapabilityKey({
    required String provider,
    required String model,
  }) {
    return '${provider.trim()}\u0000${model.trim()}';
  }

  Widget _buildModelCapabilitySummary() {
    final enabled = _currentModelCapabilityProfile.effective.entries
        .where((entry) => entry.value)
        .map((entry) => _modelCapabilityLabels[entry.key])
        .whereType<String>()
        .toList(growable: false);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: enabled.isEmpty
              ? const SizedBox.shrink()
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: enabled
                      .map((label) => Chip(label: Text(label)))
                      .toList(growable: false),
                ),
        ),
        TextButton.icon(
          onPressed: _editModelCapabilities,
          icon: const Icon(Icons.tune_outlined),
          label: const Text('编辑能力'),
        ),
      ],
    );
  }

  Future<void> _editModelCapabilities() async {
    final profile = _currentModelCapabilityProfile;
    final values = <String, bool>{
      for (final key in _modelCapabilityLabels.keys)
        key: profile.effective[key] == true,
    };
    final result = await showDialog<Map<String, bool>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('编辑模型能力'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: _modelCapabilityLabels.entries
                .map(
                  (entry) => CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.value),
                    value: values[entry.key],
                    onChanged: (value) => setDialogState(
                      () => values[entry.key] = value ?? false,
                    ),
                  ),
                )
                .toList(growable: false),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                for (final key in _modelCapabilityLabels.keys) {
                  values[key] = profile.declared[key] == true;
                }
                setDialogState(() {});
              },
              child: const Text('恢复服务端声明'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(values),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) {
      return;
    }
    final overrides = <String, bool>{};
    for (final key in _modelCapabilityLabels.keys) {
      final effective = result[key] == true;
      final declared = profile.declared[key] == true;
      if (effective != declared) {
        overrides[key] = effective;
      }
    }
    final modelKey = _modelCapabilityKey(
      provider: _provider,
      model: _modelController.text,
    );
    setState(() {
      _modelCapabilities[modelKey] = profile.copyWith(overrides: overrides);
    });
    _notifySettingsChanged();
  }

  Widget _buildEmbeddingSection() {
    return _SettingsSection(
      icon: Icons.hub_outlined,
      title: 'Embedding 模型',
      description:
          '可选的 GensokyoAI 委托字段。HakureiTerminal 不会直接测试或执行该配置，只在明确授权委托后发送。',
      children: <Widget>[
        _buildProviderDropdown(
          label: 'Embedding Provider',
          value: _embeddingProvider,
          includeDefault: true,
          providers: _embeddingProviders,
          onChanged: (value) {
            setState(() => _embeddingProvider = value);
            _notifySettingsChanged();
          },
        ),
        const SizedBox(height: 16),
        TextField(
          contextMenuBuilder: jovTextContextMenu,
          controller: _embeddingModelController,
          decoration: const InputDecoration(
            labelText: 'Embedding 模型名',
            hintText:
                '例如 text-embedding-3-small / BAAI/bge-m3 / gemini-embedding-001',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          contextMenuBuilder: jovTextContextMenu,
          controller: _embeddingBaseUrlController,
          decoration: const InputDecoration(
            labelText: 'Embedding Base URL（可选）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          contextMenuBuilder: jovTextContextMenu,
          controller: _embeddingApiKeyController,
          obscureText: _obscureEmbeddingApiKey,
          decoration: InputDecoration(
            labelText: 'Embedding API Key（可选）',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _obscureEmbeddingApiKey ? '显示 API Key' : '隐藏 API Key',
              onPressed: () => setState(() {
                _obscureEmbeddingApiKey = !_obscureEmbeddingApiKey;
              }),
              icon: Icon(
                _obscureEmbeddingApiKey
                    ? Icons.visibility
                    : Icons.visibility_off,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                contextMenuBuilder: jovTextContextMenu,
                controller: _embeddingDimensionsController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Embedding 维度（可选）',
                  hintText: 'OpenAI text-embedding-3 系列可填写缩短维度',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                contextMenuBuilder: jovTextContextMenu,
                controller: _embeddingTimeoutController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Embedding Timeout 秒（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Embedding 使用代理'),
          value: _embeddingUseProxy,
          onChanged: (value) {
            setState(() => _embeddingUseProxy = value ?? false);
            _notifySettingsChanged();
          },
        ),
      ],
    );
  }

  Widget _buildProviderDropdown({
    required String label,
    required String value,
    required ValueChanged<String> onChanged,
    bool includeDefault = false,
    List<String> providers = _providers,
  }) {
    final values = <String>[if (includeDefault) '', ...providers];
    final selected = values.contains(value) ? value : values.first;
    return DropdownButtonFormField<String>(
      initialValue: selected,
      items: values
          .map(
            (provider) => DropdownMenuItem<String>(
              value: provider,
              child: Text(
                provider.isEmpty
                    ? '沿用主模型 / 运行服务默认'
                    : _providerLabels[provider] ?? provider,
              ),
            ),
          )
          .toList(growable: false),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      onChanged: (value) {
        if (value != null) {
          onChanged(value);
        }
      },
    );
  }

  void _loadProfileIntoForm(ModelProfile profile) {
    _clearProviderModels();
    _editingProfile = profile;
    _profileNameController.text = profile.name;
    _provider = _normalizeProvider(
      profile.model.provider,
      fallback: 'deepseek',
    );
    _modelController.text = profile.model.model;
    _modelCapabilities = Map<String, ModelCapabilityProfile>.from(
      profile.model.modelCapabilities,
    );
    _baseUrlController.text = profile.model.baseUrl;
    _apiKeyController.text = profile.model.apiKey;
    _temperatureController.text = profile.model.temperature;
    _topPController.text = profile.model.topP;
    _maxTokensController.text = profile.model.maxTokens;
    _timeoutController.text = profile.model.timeout;
    _reasoningEffortController.text = profile.model.reasoningEffort;
    _stream = profile.model.stream;
    _think = profile.model.think;
    _useProxy = profile.model.useProxy;
    _embeddingProvider = _normalizeProvider(
      profile.embedding.provider,
      fallback: 'openai',
      allowDefault: true,
      providers: _embeddingProviders,
    );
    _embeddingModelController.text = profile.embedding.model;
    _embeddingBaseUrlController.text = profile.embedding.baseUrl;
    _embeddingApiKeyController.text = profile.embedding.apiKey;
    _embeddingDimensionsController.text = profile.embedding.dimensions;
    _embeddingTimeoutController.text = profile.embedding.timeout;
    _embeddingUseProxy = profile.embedding.useProxy;
  }

  ModelProfile _profileFromForm() {
    return _editingProfile.copyWith(
      name: _profileNameController.text.trim(),
      model: ModelServiceSettings(
        provider: _provider,
        model: _modelController.text.trim(),
        baseUrl: _baseUrlController.text.trim(),
        apiKey: _apiKeyController.text.trim(),
        temperature: _temperatureController.text.trim(),
        topP: _topPController.text.trim(),
        maxTokens: _maxTokensController.text.trim(),
        timeout: _timeoutController.text.trim(),
        stream: _stream,
        think: _think,
        reasoningEffort: _reasoningEffortController.text.trim(),
        useProxy: _useProxy,
        modelCapabilities: Map<String, ModelCapabilityProfile>.from(
          _modelCapabilities,
        ),
      ),
      embedding: EmbeddingServiceSettings(
        provider: _embeddingProvider,
        model: _embeddingModelController.text.trim(),
        baseUrl: _embeddingBaseUrlController.text.trim(),
        apiKey: _embeddingApiKeyController.text.trim(),
        dimensions: _embeddingDimensionsController.text.trim(),
        timeout: _embeddingTimeoutController.text.trim(),
        useProxy: _embeddingUseProxy,
      ),
      updatedAt: DateTime.now(),
    );
  }

  AppSettings _settingsWithCurrentForm() {
    final appearance = AppearanceSettings(
      themeId: _selectedPreviewThemeId,
      customThemes: _customPreviewThemes
          .map((theme) => theme.toSettings())
          .toList(growable: false),
      backgroundImagePath: _backgroundImagePath,
      backgroundImageOpacity: _backgroundImageOpacity,
      fontFamilyId: _previewFontFamily,
      fontSize: _previewFontSize,
      uiDensity: _previewDensity,
      cornerRadius: _previewCornerRadius,
      bubbleStyle: _previewBubbleStyle,
    );
    return _settings
        .copyWith(
          appearance: appearance,
          tts: TtsSettings(
            enabled: _ttsEnabled,
            baseUrl: _ttsBaseUrlController.text.trim(),
            apiKey: _ttsApiKeyController.text.trim(),
            model: _ttsModelController.text.trim(),
            voice: _ttsVoiceController.text.trim(),
            speed: _ttsSpeed,
            responseFormat: _ttsResponseFormat,
          ),
          activeUserRoleId: _selectedUserRoleId,
          newSessionTitleMode: _previewDefaultTitleMode,
          userRoles: _userRoles
              .map(
                (role) => UserRoleSettings(
                  id: role.id,
                  nickname: role.nickname,
                  bio: role.bio,
                  avatarImagePath: role.avatarPath,
                ),
              )
              .toList(growable: false),
        )
        .upsertProfile(_profileFromForm(), activate: true);
  }

  void _selectProfile(String id) {
    final current = _profileFromForm();
    final updatedSettings = _settings.upsertProfile(current, activate: false);
    final nextProfile = updatedSettings.profiles.firstWhere(
      (profile) => profile.id == id,
      orElse: () => updatedSettings.activeProfile,
    );
    setState(() {
      _settings = updatedSettings.copyWith(activeProfileId: id);
      _loadProfileIntoForm(nextProfile);
    });
    _notifySettingsChanged();
  }

  void _createProfile() {
    final now = DateTime.now();
    final currentSettings = _settingsWithCurrentForm();
    final profile = ModelProfile(
      id: 'profile_${now.microsecondsSinceEpoch}',
      name: '新配置 ${currentSettings.profiles.length + 1}',
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
    setState(() {
      _settings = currentSettings.upsertProfile(profile);
      _loadProfileIntoForm(profile);
    });
    _notifySettingsChanged();
  }

  void _duplicateProfile() {
    final currentSettings = _settingsWithCurrentForm();
    final current = currentSettings.activeProfile;
    final duplicate = current.duplicate(
      id: 'profile_${DateTime.now().microsecondsSinceEpoch}',
      name: '${current.name} 副本',
    );
    setState(() {
      _settings = currentSettings.upsertProfile(duplicate);
      _loadProfileIntoForm(duplicate);
    });
    _notifySettingsChanged();
  }

  void _deleteProfile() {
    final currentSettings = _settingsWithCurrentForm();
    if (currentSettings.profiles.length <= 1) {
      return;
    }
    final nextSettings = currentSettings.removeProfile(_editingProfile.id);
    setState(() {
      _settings = nextSettings;
      _loadProfileIntoForm(nextSettings.activeProfile);
    });
    _notifySettingsChanged();
  }

  Future<void> _save() async {
    final nextSettings = _settingsWithCurrentForm();
    final errors = nextSettings.activeProfile.validate();
    if (errors.isNotEmpty) {
      showTopNotice(context, errors.first);
      return;
    }

    _settingsNotifyDebounce?.cancel();
    _settings = nextSettings;
    await _dispatchOperation(SettingsOperation(settings: nextSettings));
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(nextSettings);
  }

  Future<void> _closeWithCurrentSettings() async {
    _settingsNotifyDebounce?.cancel();
    final nextSettings = _settingsWithCurrentForm();
    _settings = nextSettings;
    await _dispatchOperation(SettingsOperation(settings: nextSettings));
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(nextSettings);
  }

  String _formatFullVersion(PackageInfo packageInfo) {
    final buildNumber = packageInfo.buildNumber.trim();
    if (buildNumber.isEmpty) {
      return packageInfo.version;
    }
    return '${packageInfo.version}+$buildNumber';
  }

  String _normalizeProvider(
    String value, {
    required String fallback,
    bool allowDefault = false,
    List<String> providers = _providers,
  }) {
    final raw = value.trim();
    final trimmed = raw == 'anthropic' ? 'claude' : raw;
    if (allowDefault && trimmed.isEmpty) {
      return '';
    }
    if (providers.contains(trimmed)) {
      return trimmed;
    }
    return fallback;
  }

  Future<void> _openLicenseFile() async {
    final license = File('LICENSE').absolute;
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', <String>[license.path]);
      } else if (Platform.isMacOS) {
        await Process.start('open', <String>[license.path]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', <String>[license.path]);
      } else if (mounted) {
        showTopNotice(context, '当前平台不支持直接打开文件：${license.path}');
      }
    } catch (error) {
      if (mounted) {
        showTopNotice(context, '无法打开 LICENSE：$error');
      }
    }
  }

  Future<void> _showSourceHanSansLicense() async {
    final license = await rootBundle.loadString(
      'assets/licenses/SourceHanSans-OFL-1.1.txt',
    );
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('思源黑体许可证'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: SelectableText(
              contextMenuBuilder: jovTextContextMenu,
              license,
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String _settingsPageTitle(_SettingsPage page) {
    switch (page) {
      case _SettingsPage.language:
        return '语言';
      case _SettingsPage.display:
        return '显示设置';
      case _SettingsPage.modelProvider:
        return 'Provider 委托档案';
      case _SettingsPage.tts:
        return 'TTS 语音';
      case _SettingsPage.sessionDefaults:
        return '会话默认值';
      case _SettingsPage.userProfile:
        return '用户角色';
      case _SettingsPage.shortcuts:
        return '快捷键';
      case _SettingsPage.developerOptions:
        return '开发者选项';
      case _SettingsPage.assistantManagement:
        return '角色管理';
      case _SettingsPage.gensokyoAi:
        return 'GensokyoAI 设置';
      case _SettingsPage.storage:
        return '数据管理';
      case _SettingsPage.backend:
        return '服务管理';
      case _SettingsPage.about:
        return '关于';
    }
  }

  _SettingsPage _settingsPageFromInitialPage(SettingsInitialPage page) {
    switch (page) {
      case SettingsInitialPage.language:
        return _SettingsPage.language;
      case SettingsInitialPage.display:
        return _SettingsPage.display;
      case SettingsInitialPage.modelProvider:
        return _SettingsPage.modelProvider;
      case SettingsInitialPage.tts:
        return _SettingsPage.tts;
      case SettingsInitialPage.sessionDefaults:
        return _SettingsPage.sessionDefaults;
      case SettingsInitialPage.userProfile:
        return _SettingsPage.userProfile;
      case SettingsInitialPage.shortcuts:
        return _SettingsPage.shortcuts;
      case SettingsInitialPage.developerOptions:
        return _SettingsPage.developerOptions;
      case SettingsInitialPage.assistantManagement:
        return _SettingsPage.assistantManagement;
      case SettingsInitialPage.gensokyoAi:
        return _SettingsPage.gensokyoAi;
      case SettingsInitialPage.storage:
        return _SettingsPage.storage;
      case SettingsInitialPage.backend:
        return _SettingsPage.backend;
      case SettingsInitialPage.about:
        return _SettingsPage.about;
    }
  }
}

enum _SettingsPage {
  language,
  display,
  modelProvider,
  tts,
  sessionDefaults,
  userProfile,
  assistantManagement,
  gensokyoAi,
  shortcuts,
  storage,
  backend,
  developerOptions,
  about,
}

class _AssistantManagementTile extends StatelessWidget {
  const _AssistantManagementTile({
    required this.assistant,
    this.onEdit,
    this.onDelete,
  });

  final Assistant assistant;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final description = assistant.description.trim().isEmpty
        ? '未填写描述'
        : assistant.description.trim();
    final promptSummary = assistant.systemPrompt.trim().isEmpty
        ? '未设置系统提示词'
        : '系统提示词 ${assistant.systemPrompt.trim().length} 字符';
    final updatedAt = assistant.updatedAt ?? assistant.createdAt;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _AssistantAvatar(name: assistant.name),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        assistant.name.trim().isEmpty
                            ? assistant.id
                            : assistant.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(description),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    if (onEdit != null)
                      OutlinedButton.icon(
                        onPressed: onEdit,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('编辑'),
                      ),
                    if (onDelete != null)
                      OutlinedButton.icon(
                        onPressed: onDelete,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('删除'),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                const Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(Icons.edit_note_outlined, size: 18),
                  label: Text('不可执行草稿'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '$promptSummary${updatedAt == null ? '' : ' · 更新于 ${updatedAt.toLocal()}'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

String _assistantInitial(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '?';
  }
  final firstRune = trimmed.runes.first;
  return String.fromCharCode(firstRune);
}

class _AssistantAvatar extends StatelessWidget {
  const _AssistantAvatar({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: const BorderRadius.all(Radius.circular(4)),
      ),
      child: Text(
        _assistantInitial(name),
        style: TextStyle(color: colorScheme.onPrimaryContainer),
      ),
    );
  }
}

class _ExternalRuntimeConnectionDialog extends StatefulWidget {
  const _ExternalRuntimeConnectionDialog({this.connection});

  final ExternalRuntimeConnectionSettings? connection;

  @override
  State<_ExternalRuntimeConnectionDialog> createState() =>
      _ExternalRuntimeConnectionDialogState();
}

class _ExternalRuntimeConnectionDialogState
    extends State<_ExternalRuntimeConnectionDialog> {
  late String _name;
  late String _url;
  late String _token;

  @override
  void initState() {
    super.initState();
    final connection = widget.connection;
    _name = connection?.displayName ?? '';
    _url = connection?.baseUrl ?? 'https://';
    _token = connection?.authToken ?? '';
  }

  void _cancel() {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.pop(context);
  }

  void _save() {
    try {
      final normalized = const RuntimeEndpointPolicy().normalize(_url);
      final existing = widget.connection;
      final endpointChanged =
          existing != null &&
          (existing.baseUrl != normalized.toString() ||
              existing.authToken != _token.trim());
      Navigator.pop(
        context,
        ExternalRuntimeConnectionSettings(
          id:
              existing?.id ??
              'runtime_${DateTime.now().toUtc().microsecondsSinceEpoch}',
          agentId: existing?.agentId ?? generateRuntimeUuidV4(),
          displayName: _name.trim(),
          baseUrl: normalized.toString(),
          authToken: _token.trim(),
          runtimeKind: existing?.runtimeKind ?? 'gensokyoai',
          expectedProtocolMajor: 2,
          lastVerifiedAt: endpointChanged ? null : existing?.lastVerifiedAt,
          lastRuntimeInfo: endpointChanged
              ? const <String, dynamic>{}
              : existing?.lastRuntimeInfo ?? const <String, dynamic>{},
          delegatedProfileId: existing?.delegatedProfileId ?? '',
        ),
      );
    } on FormatException {
      showTopNotice(context, '请输入 HTTPS URL，或明确的 localhost HTTP URL。');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.connection == null ? '添加 GensokyoAI 连接' : '编辑 GensokyoAI 连接',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextFormField(
              key: const ValueKey<String>('externalRuntimeNameField'),
              initialValue: _name,
              onChanged: (value) => _name = value,
              decoration: const InputDecoration(labelText: '显示名称'),
            ),
            TextFormField(
              key: const ValueKey<String>('externalRuntimeUrlField'),
              initialValue: _url,
              onChanged: (value) => _url = value,
              decoration: const InputDecoration(labelText: '服务 URL'),
            ),
            TextFormField(
              key: const ValueKey<String>('externalRuntimeTokenField'),
              initialValue: _token,
              onChanged: (value) => _token = value,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Runtime 令牌'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: _cancel, child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

/// 显示设置里的滑杆行：左侧标签、右侧可编辑值，下面是滑杆。
class _DisplaySliderRow extends StatefulWidget {
  const _DisplaySliderRow({
    super.key,
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.inputKey,
    required this.inputScale,
    required this.onChanged,
  });

  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final Key inputKey;
  final double inputScale;
  final ValueChanged<double> onChanged;

  @override
  State<_DisplaySliderRow> createState() => _DisplaySliderRowState();
}

class _DisplaySliderRowState extends State<_DisplaySliderRow> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _inputText(widget.value));
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _DisplaySliderRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus &&
        (oldWidget.value != widget.value ||
            oldWidget.inputScale != widget.inputScale)) {
      _setInputText(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  String _inputText(double value) {
    final scaled = value * widget.inputScale;
    return scaled == scaled.roundToDouble()
        ? scaled.round().toString()
        : scaled.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  }

  void _setInputText(double value) {
    final text = _inputText(value);
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _onInputChanged(String text) {
    final parsed = double.tryParse(text.trim());
    if (parsed == null) {
      return;
    }
    final value = (parsed / widget.inputScale).clamp(widget.min, widget.max);
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(widget.label, style: textTheme.bodyMedium)),
            SizedBox(
              width: 82,
              child: TextField(
                key: widget.inputKey,
                controller: _controller,
                focusNode: _focusNode,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textAlign: TextAlign.right,
                onChanged: _onInputChanged,
                onSubmitted: (_) => _setInputText(widget.value),
                onTapOutside: (_) {
                  _setInputText(widget.value);
                  _focusNode.unfocus();
                },
                decoration: InputDecoration(
                  suffixText: widget.valueText.replaceFirst(
                    RegExp(r'^[-0-9.]+'),
                    '',
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        Slider(
          value: widget.value,
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          onChanged: widget.onChanged,
        ),
      ],
    );
  }
}

/// 快捷键组合的按键标签，样式类似键帽。
class _ShortcutKeyLabel extends StatelessWidget {
  const _ShortcutKeyLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          fontFamily: 'monospace',
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 下拉列表里的分类标题项：不可选中，仅用于给主题分组。
class _ThemeGroupHeaderItem extends DropdownMenuItem<String> {
  _ThemeGroupHeaderItem({required String label})
    : super(
        enabled: false,
        child: Builder(
          builder: (context) => Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
}

class _ThemeColorRow extends StatelessWidget {
  const _ThemeColorRow({
    required this.label,
    required this.color,
    required this.readOnly,
    this.onEdit,
  });

  final String label;
  final Color color;
  final bool readOnly;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final row = Row(
      children: <Widget>[
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color,
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        Text(
          '#${colorToHex(color)}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        if (readOnly)
          Icon(Icons.lock_outline, size: 14, color: colorScheme.outline)
        else
          Icon(Icons.edit_outlined, size: 14, color: colorScheme.outline),
      ],
    );
    if (onEdit == null) {
      return row;
    }
    return InkWell(
      key: ValueKey<String>('themeColorRow_$label'),
      onTap: onEdit,
      borderRadius: const BorderRadius.all(Radius.circular(4)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: row,
      ),
    );
  }
}

class _UserRoleDraft {
  const _UserRoleDraft({
    required this.id,
    required this.nickname,
    required this.bio,
    this.avatarPath = '',
  });

  final String id;
  final String nickname;
  final String bio;
  final String avatarPath;
}

class _SettingsInfoTile extends StatelessWidget {
  const _SettingsInfoTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(description),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        tileColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon),
                const SizedBox(width: 12),
                Text(title, style: textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 8),
            Text(description),
            const SizedBox(height: 20),
            ...children,
          ],
        ),
      ),
    );
  }
}

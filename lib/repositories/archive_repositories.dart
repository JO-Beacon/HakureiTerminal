import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../models/assistant.dart';
import '../models/app_settings.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';

class ArchivePaths {
  ArchivePaths({Directory? root}) : root = root ?? _defaultRoot();

  /// Resolves the platform application directory before repositories are
  /// created. Android's current directory is `/`, which is read-only.
  static Future<ArchivePaths> createDefault({
    bool? isWindows,
    Future<Directory> Function()? applicationSupportDirectoryProvider,
  }) async {
    if (isWindows ?? Platform.isWindows) {
      return ArchivePaths();
    }
    try {
      final directory =
          await (applicationSupportDirectoryProvider ??
              getApplicationSupportDirectory)();
      return ArchivePaths(root: directory);
    } catch (_) {
      // Keep a failed platform lookup away from Android's read-only `/`.
      return ArchivePaths(
        root: Directory(_join(Directory.systemTemp.path, 'HakureiTerminal')),
      );
    }
  }

  final Directory root;

  Directory get assistantsDir => Directory(_join(root.path, 'assistants'));

  Directory get conversationsDir =>
      Directory(_join(root.path, 'conversations'));

  Directory get archivesDir => Directory(_join(root.path, 'archives'));

  Directory get logsDir => Directory(_join(root.path, 'logs'));

  Directory get appearanceDir => Directory(_join(root.path, 'appearance'));

  Directory get backgroundsDir =>
      Directory(_join(appearanceDir.path, 'backgrounds'));

  Directory get mediaDir => Directory(_join(root.path, 'media'));

  File? managedMediaFile(String relativePath) {
    final normalized = relativePath.trim().replaceAll('\\', '/');
    if (!RegExp(r'^media/[a-f0-9]{64}$').hasMatch(normalized)) {
      return null;
    }
    return File(
      _join(root.path, normalized.replaceAll('/', Platform.pathSeparator)),
    );
  }

  File? managedAppearanceResourceFile(String relativePath) {
    return managedMediaFile(relativePath) ??
        managedAppearanceFile(relativePath);
  }

  File? managedConversationResourceFile(
    String conversationId,
    String relativePath,
  ) {
    return managedMediaFile(relativePath) ??
        managedConversationBackgroundFile(conversationId, relativePath);
  }

  File? managedAppearanceFile(String relativePath) {
    final normalized = relativePath.trim().replaceAll('\\', '/');
    if (!normalized.startsWith('appearance/') ||
        normalized.contains('..') ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      return null;
    }
    return File(
      _join(root.path, normalized.replaceAll('/', Platform.pathSeparator)),
    );
  }

  File assistantFile(String assistantId) {
    return File(_join(assistantsDir.path, '$assistantId.json'));
  }

  Directory conversationDir(String conversationId) {
    return Directory(
      _join(conversationsDir.path, _canonicalConversationId(conversationId)),
    );
  }

  Directory conversationBackgroundsDir(String conversationId) {
    return Directory(
      _join(conversationDir(conversationId).path, 'backgrounds'),
    );
  }

  File? managedConversationBackgroundFile(
    String conversationId,
    String relativePath,
  ) {
    final backgroundsDir = conversationBackgroundsDir(conversationId);
    final normalized = relativePath.trim().replaceAll('\\', '/');
    final prefix = 'conversations/$conversationId/backgrounds/';
    if (!normalized.startsWith(prefix) ||
        normalized.contains('..') ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      return null;
    }
    return File(
      _join(
        backgroundsDir.path,
        normalized
            .substring(prefix.length)
            .replaceAll('/', Platform.pathSeparator),
      ),
    );
  }

  File conversationFile(String conversationId) {
    return File(
      _join(conversationDir(conversationId).path, 'conversation.json'),
    );
  }

  File messagesFile(String conversationId) {
    return File(_join(conversationDir(conversationId).path, 'messages.jsonl'));
  }

  File contextFile(String conversationId) {
    return File(_join(conversationDir(conversationId).path, 'context.json'));
  }

  File archiveFile(String archiveId) {
    return File(_join(archivesDir.path, '$archiveId.jovarchive'));
  }

  static Directory _defaultRoot() {
    final appData = Platform.environment['APPDATA'];
    if (Platform.isWindows && appData != null && appData.isNotEmpty) {
      return Directory(_join(appData, 'HakureiTerminal'));
    }
    return Directory(_join(Directory.current.path, '.hakurei_terminal'));
  }

  static String _canonicalConversationId(String conversationId) {
    final isAbsolute =
        conversationId.startsWith('/') ||
        conversationId.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(conversationId);
    final hasForbiddenCharacter = RegExp(
      r'[<>:"/\\|?*\x00-\x1F]',
    ).hasMatch(conversationId);
    final isReservedDeviceName = RegExp(
      r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(conversationId);
    if (conversationId.isEmpty ||
        isAbsolute ||
        conversationId == '..' ||
        hasForbiddenCharacter ||
        conversationId.endsWith('.') ||
        conversationId.endsWith(' ') ||
        isReservedDeviceName) {
      throw ArgumentError.value(
        conversationId,
        'conversationId',
        'Must be a valid directory name',
      );
    }
    return conversationId;
  }
}

class ConversationContextState {
  const ConversationContextState({
    this.summary = '',
    this.includedMessageCount = 0,
    this.truncatedBeforeMessageId = '',
    this.excludedMessageIds = const <String>{},
    this.estimatedTokens = 0,
    this.estimatedBudgetTokens = 0,
    this.estimatedMessageCount = 0,
    this.excludedMessageCount = 0,
    this.overBudget = false,
    this.metadata = const <String, dynamic>{},
    this.updatedAt,
  });

  final String summary;
  final int includedMessageCount;
  final String truncatedBeforeMessageId;
  final Set<String> excludedMessageIds;
  final int estimatedTokens;
  final int estimatedBudgetTokens;
  final int estimatedMessageCount;
  final int excludedMessageCount;
  final bool overBudget;
  final Map<String, dynamic> metadata;
  final DateTime? updatedAt;

  ConversationContextState copyWith({
    String? summary,
    int? includedMessageCount,
    String? truncatedBeforeMessageId,
    Set<String>? excludedMessageIds,
    int? estimatedTokens,
    int? estimatedBudgetTokens,
    int? estimatedMessageCount,
    int? excludedMessageCount,
    bool? overBudget,
    Map<String, dynamic>? metadata,
    DateTime? updatedAt,
  }) {
    return ConversationContextState(
      summary: summary ?? this.summary,
      includedMessageCount: includedMessageCount ?? this.includedMessageCount,
      truncatedBeforeMessageId:
          truncatedBeforeMessageId ?? this.truncatedBeforeMessageId,
      excludedMessageIds: excludedMessageIds ?? this.excludedMessageIds,
      estimatedTokens: estimatedTokens ?? this.estimatedTokens,
      estimatedBudgetTokens:
          estimatedBudgetTokens ?? this.estimatedBudgetTokens,
      estimatedMessageCount:
          estimatedMessageCount ?? this.estimatedMessageCount,
      excludedMessageCount: excludedMessageCount ?? this.excludedMessageCount,
      overBudget: overBudget ?? this.overBudget,
      metadata: metadata ?? this.metadata,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'summary': summary,
      'included_message_count': includedMessageCount,
      'truncated_before_message_id': truncatedBeforeMessageId,
      'excluded_message_ids': excludedMessageIds.toList()..sort(),
      'estimated_tokens': estimatedTokens,
      'estimated_budget_tokens': estimatedBudgetTokens,
      'estimated_message_count': estimatedMessageCount,
      'excluded_message_count': excludedMessageCount,
      'over_budget': overBudget,
      'metadata': metadata,
      'updated_at': updatedAt?.toIso8601String(),
    }..removeWhere((_, value) => value == null || value == '');
  }

  factory ConversationContextState.fromJson(Map<String, dynamic> json) {
    return ConversationContextState(
      summary: json['summary']?.toString() ?? '',
      includedMessageCount:
          int.tryParse(json['included_message_count']?.toString() ?? '') ?? 0,
      truncatedBeforeMessageId:
          json['truncated_before_message_id']?.toString() ?? '',
      excludedMessageIds: _stringSetFromJson(json['excluded_message_ids']),
      estimatedTokens:
          int.tryParse(json['estimated_tokens']?.toString() ?? '') ?? 0,
      estimatedBudgetTokens:
          int.tryParse(json['estimated_budget_tokens']?.toString() ?? '') ?? 0,
      estimatedMessageCount:
          int.tryParse(json['estimated_message_count']?.toString() ?? '') ?? 0,
      excludedMessageCount:
          int.tryParse(json['excluded_message_count']?.toString() ?? '') ?? 0,
      overBudget: _boolFromJson(json['over_budget']),
      metadata: _mapFromJson(json['metadata']),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
    );
  }
}

class AssistantArchiveRepository {
  AssistantArchiveRepository({ArchivePaths? paths})
    : paths = paths ?? ArchivePaths();

  final ArchivePaths paths;

  Future<List<Assistant>> listAssistants() async {
    final dir = paths.assistantsDir;
    if (!await dir.exists()) {
      return const <Assistant>[];
    }
    final assistants = <Assistant>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      final decoded = jsonDecode(await entity.readAsString());
      if (decoded is Map) {
        assistants.add(Assistant.fromJson(Map<String, dynamic>.from(decoded)));
      }
    }
    assistants.sort((a, b) => a.name.compareTo(b.name));
    return assistants;
  }

  Future<Assistant?> getAssistant(String assistantId) async {
    final file = paths.assistantFile(assistantId);
    if (!await file.exists()) {
      return null;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      return null;
    }
    return Assistant.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<void> saveAssistant(Assistant assistant) async {
    final file = paths.assistantFile(assistant.id);
    await file.parent.create(recursive: true);
    await file.writeAsString(_prettyJson(assistant.toJson()));
  }

  Future<void> deleteAssistant(String assistantId) async {
    final file = paths.assistantFile(assistantId);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class ConversationArchiveRepository {
  ConversationArchiveRepository({ArchivePaths? paths})
    : paths = paths ?? ArchivePaths();

  final ArchivePaths paths;

  Future<void> createConversation(ChatSession conversation) async {
    await saveConversation(conversation);
  }

  Future<void> saveConversation(ChatSession conversation) async {
    final file = paths.conversationFile(conversation.sessionId);
    await file.parent.create(recursive: true);
    await file.writeAsString(_prettyJson(conversation.toJson()));
  }

  Future<ChatSession?> getConversation(String conversationId) async {
    final file = paths.conversationFile(conversationId);
    if (!await file.exists()) {
      return null;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      return null;
    }
    return ChatSession.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<List<ChatSession>> listConversations() async {
    final dir = paths.conversationsDir;
    if (!await dir.exists()) {
      return const <ChatSession>[];
    }
    final conversations = <ChatSession>[];
    await for (final entity in dir.list()) {
      if (entity is! Directory) {
        continue;
      }
      final file = File(_join(entity.path, 'conversation.json'));
      if (!await file.exists()) {
        continue;
      }
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          conversations.add(
            ChatSession.fromJson(Map<String, dynamic>.from(decoded)),
          );
        }
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    conversations.sort((a, b) {
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
      return bTime.compareTo(aTime);
    });
    return conversations;
  }

  Future<void> duplicateConversation(
    String sourceConversationId,
    ChatSession duplicate,
  ) async {
    final source = await getConversation(sourceConversationId);
    if (source == null) {
      throw StateError('Source conversation not found: $sourceConversationId');
    }
    if (await getConversation(duplicate.sessionId) != null) {
      throw StateError(
        'Duplicate conversation already exists: ${duplicate.sessionId}',
      );
    }

    final sourceMessages = await listMessages(sourceConversationId);
    final messageIds = <String, String>{};
    for (var index = 0; index < sourceMessages.length; index += 1) {
      final sourceId = sourceMessages[index].id;
      if (sourceId.isNotEmpty) {
        messageIds[sourceId] = '${duplicate.sessionId}_message_${index + 1}';
      }
    }
    final sourceContext = await getContext(sourceConversationId);

    try {
      await createConversation(duplicate);
      for (var index = 0; index < sourceMessages.length; index += 1) {
        final message = sourceMessages[index];
        await appendMessage(
          duplicate.sessionId,
          ChatMessage(
            id:
                messageIds[message.id] ??
                '${duplicate.sessionId}_message_${index + 1}',
            role: message.role,
            content: message.content,
            createdAt: message.createdAt,
            conversationId: duplicate.sessionId,
            assistantId: message.assistantId,
            thinkingEngineId: message.thinkingEngineId,
            backendId: message.backendId,
            assistantProviderId: message.assistantProviderId,
            compatibility: message.compatibility,
            capabilityLosses: message.capabilityLosses,
            modelResolved: message.modelResolved,
            status: message.status,
            parentMessageId:
                messageIds[message.parentMessageId] ?? message.parentMessageId,
            metadata: message.metadata,
          ),
        );
      }
      if (sourceContext != null) {
        await saveContext(
          duplicate.sessionId,
          sourceContext.copyWith(
            truncatedBeforeMessageId:
                messageIds[sourceContext.truncatedBeforeMessageId] ??
                sourceContext.truncatedBeforeMessageId,
            excludedMessageIds: sourceContext.excludedMessageIds
                .map((id) => messageIds[id] ?? id)
                .toSet(),
          ),
        );
      }
    } catch (_) {
      await deleteConversation(duplicate.sessionId);
      rethrow;
    }
  }

  Future<void> appendMessage(String conversationId, ChatMessage message) async {
    final file = paths.messagesFile(conversationId);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode(message.toJson())}\n',
      mode: FileMode.append,
    );
  }

  Future<List<ChatMessage>> listMessages(String conversationId) async {
    final file = paths.messagesFile(conversationId);
    if (!await file.exists()) {
      return const <ChatMessage>[];
    }
    final messages = <ChatMessage>[];
    final lines = await file.readAsLines();
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        messages.add(ChatMessage.fromJson(Map<String, dynamic>.from(decoded)));
      }
    }
    return messages;
  }

  Future<void> saveContext(
    String conversationId,
    ConversationContextState context,
  ) async {
    final file = paths.contextFile(conversationId);
    await file.parent.create(recursive: true);
    await file.writeAsString(_prettyJson(context.toJson()));
  }

  Future<ConversationContextState?> getContext(String conversationId) async {
    final file = paths.contextFile(conversationId);
    if (!await file.exists()) {
      return null;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      return null;
    }
    return ConversationContextState.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  Future<void> deleteConversation(String conversationId) async {
    final dir = paths.conversationDir(conversationId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}

class JovArchiveImportSummary {
  const JovArchiveImportSummary({
    required this.assistantCount,
    required this.conversationCount,
    required this.entryCount,
    this.appearance,
    this.userRoles,
    this.activeUserRoleId,
    this.settings,
  });

  final int assistantCount;
  final int conversationCount;
  final int entryCount;
  final AppearanceSettings? appearance;
  final List<UserRoleSettings>? userRoles;
  final String? activeUserRoleId;
  final AppSettings? settings;
}

class JovArchiveExportRepository {
  JovArchiveExportRepository({ArchivePaths? paths})
    : paths = paths ?? ArchivePaths();

  final ArchivePaths paths;

  /// 允许进入/离开存档包的顶层前缀；用于全量导出与导入安全校验。
  static const List<String> _fullArchivePrefixes = <String>[
    'assistants/',
    'conversations/',
    'appearance/',
    'user_roles/',
    'settings/',
    'media/',
  ];

  /// 导出全部本地存档（角色和会话）为一个 .jovarchive 包。
  Future<File> exportAllToFile(
    File output, {
    AppearanceSettings? appearance,
    List<UserRoleSettings>? userRoles,
    String? activeUserRoleId,
    AppSettings? settings,
  }) async {
    final archive = Archive();
    final entries = <String>['manifest.json'];

    Future<void> addDirectory(Directory dir, String prefix) async {
      if (!await dir.exists()) {
        return;
      }
      await for (final item in dir.list(recursive: true)) {
        if (item is! File) {
          continue;
        }
        final relative = item.path
            .substring(dir.path.length)
            .replaceAll('\\', '/')
            .replaceFirst(RegExp('^/'), '');
        final entryPath = '$prefix$relative';
        await _addFile(archive, item, entryPath);
        entries.add(entryPath);
      }
    }

    await addDirectory(paths.assistantsDir, 'assistants/');
    await addDirectory(paths.conversationsDir, 'conversations/');
    await addDirectory(paths.mediaDir, 'media/');
    if (appearance != null) {
      var exportedAppearance = appearance;
      final backgroundPath = appearance.backgroundImagePath;
      if (backgroundPath.isNotEmpty) {
        final backgroundFile = paths.managedAppearanceResourceFile(
          backgroundPath,
        );
        if (backgroundFile != null && await backgroundFile.exists()) {
          if (paths.managedMediaFile(backgroundPath) == null) {
            await _addFile(archive, backgroundFile, backgroundPath);
            entries.add(backgroundPath);
          }
        } else {
          exportedAppearance = AppearanceSettings(
            themeId: appearance.themeId,
            customThemes: appearance.customThemes,
            backgroundImageOpacity: appearance.backgroundImageOpacity,
            fontFamilyId: appearance.fontFamilyId,
            fontSize: appearance.fontSize,
            uiDensity: appearance.uiDensity,
            cornerRadius: appearance.cornerRadius,
            bubbleStyle: appearance.bubbleStyle,
          );
        }
      }
      final appearanceBytes = utf8.encode(
        _prettyJson(exportedAppearance.toJson()),
      );
      const appearanceEntry = 'appearance/settings.json';
      archive.addFile(
        ArchiveFile(appearanceEntry, appearanceBytes.length, appearanceBytes),
      );
      entries.add(appearanceEntry);
    }
    if (userRoles != null) {
      final userRoleBytes = utf8.encode(
        _prettyJson(<String, dynamic>{
          'active_user_role_id': activeUserRoleId ?? '',
          'user_roles': userRoles.map((role) => role.toJson()).toList(),
        }),
      );
      const userRoleEntry = 'user_roles/settings.json';
      archive.addFile(
        ArchiveFile(userRoleEntry, userRoleBytes.length, userRoleBytes),
      );
      entries.add(userRoleEntry);
    }
    if (settings != null) {
      final settingsBytes = utf8.encode(_prettyJson(settings.toJson()));
      const settingsEntry = 'settings/settings.json';
      archive.addFile(
        ArchiveFile(settingsEntry, settingsBytes.length, settingsBytes),
      );
      entries.add(settingsEntry);
    }

    final manifest = <String, dynamic>{
      'format': 'jovarchive',
      'format_version': 1,
      'scope': 'full',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'entries': entries,
    };
    final manifestBytes = utf8.encode(_prettyJson(manifest));
    archive.addFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );

    await output.parent.create(recursive: true);
    await output.writeAsBytes(ZipEncoder().encode(archive));
    return output;
  }

  /// 导入 .jovarchive 包，覆盖同名文件，返回导入统计。
  /// 只解出白名单前缀内的条目，并拒绝路径穿越，防止 zip-slip。
  Future<JovArchiveImportSummary> importAllFromBytes(List<int> bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final manifestEntry = archive.files
        .where((file) => file.name == 'manifest.json')
        .toList(growable: false);
    if (manifestEntry.isEmpty) {
      throw const FormatException('存档包缺少 manifest.json');
    }
    final manifest = jsonDecode(
      utf8.decode(manifestEntry.first.content as List<int>),
    );
    if (manifest is! Map || manifest['format'] != 'jovarchive') {
      throw const FormatException('不是有效的 HakureiTerminal 存档包');
    }

    final assistants = <String>{};
    final conversations = <String>{};
    AppearanceSettings? importedAppearance;
    List<UserRoleSettings>? importedUserRoles;
    String? importedActiveUserRoleId;
    AppSettings? importedSettings;
    final appearanceEntry = archive.files
        .where((file) => file.isFile && file.name == 'appearance/settings.json')
        .firstOrNull;
    if (appearanceEntry != null) {
      final decoded = jsonDecode(
        utf8.decode(appearanceEntry.content as List<int>),
      );
      if (decoded is! Map) {
        throw const FormatException('存档包中的外观设置无效');
      }
      importedAppearance = AppearanceSettings.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      final backgroundPath = importedAppearance.backgroundImagePath;
      if (backgroundPath.isNotEmpty) {
        final managedFile = paths.managedAppearanceResourceFile(backgroundPath);
        final containsBackground = archive.files.any(
          (file) => file.isFile && file.name == backgroundPath,
        );
        if (managedFile == null || !containsBackground) {
          throw const FormatException('存档包中的背景图片路径无效或图片缺失');
        }
      }
    }
    final userRoleEntry = archive.files
        .where((file) => file.isFile && file.name == 'user_roles/settings.json')
        .firstOrNull;
    if (userRoleEntry != null) {
      final decoded = jsonDecode(
        utf8.decode(userRoleEntry.content as List<int>),
      );
      if (decoded is! Map || decoded['user_roles'] is! List) {
        throw const FormatException('存档包中的用户角色设置无效');
      }
      final roles = <UserRoleSettings>[];
      for (final item in decoded['user_roles'] as List) {
        if (item is! Map) {
          throw const FormatException('存档包中的用户角色条目无效');
        }
        final role = UserRoleSettings.fromJson(Map<String, dynamic>.from(item));
        if (role.id.isEmpty || role.nickname.isEmpty) {
          throw const FormatException('存档包中的用户角色缺少 ID 或昵称');
        }
        if (role.avatarImagePath.isNotEmpty) {
          final managedAvatar = paths.managedMediaFile(role.avatarImagePath);
          final containsAvatar = archive.files.any(
            (file) => file.isFile && file.name == role.avatarImagePath,
          );
          if (managedAvatar == null || !containsAvatar) {
            throw const FormatException('存档包中的用户头像路径无效或图片缺失');
          }
        }
        roles.add(role);
      }
      importedUserRoles = roles;
      final requestedActiveId =
          decoded['active_user_role_id']?.toString() ?? '';
      importedActiveUserRoleId =
          roles.any((role) => role.id == requestedActiveId)
          ? requestedActiveId
          : roles.isEmpty
          ? ''
          : roles.first.id;
    }
    final settingsEntry = archive.files
        .where((file) => file.isFile && file.name == 'settings/settings.json')
        .firstOrNull;
    if (settingsEntry != null) {
      final decoded = jsonDecode(
        utf8.decode(settingsEntry.content as List<int>),
      );
      if (decoded is! Map) {
        throw const FormatException('存档包中的应用设置无效');
      }
      final restored = AppSettings.fromJson(Map<String, dynamic>.from(decoded));
      importedSettings = restored.copyWith(
        externalRuntimeConnections: restored.externalRuntimeConnections
            .map((connection) => connection.copyWith(delegatedProfileId: ''))
            .toList(growable: false),
      );
    }
    var entryCount = 0;
    for (final file in archive.files) {
      if (!file.isFile || file.name == 'manifest.json') {
        continue;
      }
      final name = file.name.replaceAll('\\', '/');
      if (name.contains('..')) {
        throw FormatException('存档包内含非法路径：$name');
      }
      final allowed = _fullArchivePrefixes.any(name.startsWith);
      if (!allowed) {
        continue;
      }
      if (name == 'appearance/settings.json' ||
          name == 'user_roles/settings.json' ||
          name == 'settings/settings.json') {
        entryCount += 1;
        continue;
      }
      if (name.startsWith('media/')) {
        final managedMedia = paths.managedMediaFile(name);
        final content = file.content as List<int>;
        if (managedMedia == null ||
            sha256.convert(content).toString() !=
                name.substring('media/'.length)) {
          throw FormatException('存档包中的媒体文件路径或内容哈希无效：$name');
        }
      }
      final target = File(
        '${paths.root.path}${Platform.pathSeparator}${name.replaceAll('/', Platform.pathSeparator)}',
      );
      await target.parent.create(recursive: true);
      await target.writeAsBytes(file.content as List<int>);
      entryCount += 1;
      final segments = name.split('/');
      if (name.startsWith('assistants/')) {
        assistants.add(segments.last);
      } else if (name.startsWith('conversations/') && segments.length > 1) {
        conversations.add(segments[1]);
      }
    }
    return JovArchiveImportSummary(
      assistantCount: assistants.length,
      conversationCount: conversations.length,
      entryCount: entryCount,
      appearance: importedAppearance,
      userRoles: importedUserRoles,
      activeUserRoleId: importedActiveUserRoleId,
      settings: importedSettings,
    );
  }

  Future<File> exportConversation(
    String conversationId, {
    String? archiveId,
  }) async {
    final conversationFile = paths.conversationFile(conversationId);
    if (!await conversationFile.exists()) {
      throw FileSystemException(
        'Conversation metadata not found',
        conversationFile.path,
      );
    }

    final id =
        archiveId ??
        'conversation_${conversationId}_${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final output = paths.archiveFile(id);
    await output.parent.create(recursive: true);

    final archive = Archive();
    final manifest = <String, dynamic>{
      'format': 'jovarchive',
      'format_version': 1,
      'scope': 'conversation',
      'conversation_id': conversationId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'entries': <String>[
        'manifest.json',
        'conversations/$conversationId/conversation.json',
      ],
    };

    await _addFile(
      archive,
      conversationFile,
      'conversations/$conversationId/conversation.json',
    );
    final messagesFile = paths.messagesFile(conversationId);
    if (await messagesFile.exists()) {
      await _addFile(
        archive,
        messagesFile,
        'conversations/$conversationId/messages.jsonl',
      );
      (manifest['entries'] as List<String>).add(
        'conversations/$conversationId/messages.jsonl',
      );
    }
    final contextFile = paths.contextFile(conversationId);
    if (await contextFile.exists()) {
      await _addFile(
        archive,
        contextFile,
        'conversations/$conversationId/context.json',
      );
      (manifest['entries'] as List<String>).add(
        'conversations/$conversationId/context.json',
      );
    }
    final backgroundsDir = paths.conversationBackgroundsDir(conversationId);
    if (await backgroundsDir.exists()) {
      await for (final item in backgroundsDir.list(recursive: true)) {
        if (item is! File) {
          continue;
        }
        final relative = item.path
            .substring(backgroundsDir.path.length)
            .replaceAll('\\', '/')
            .replaceFirst(RegExp('^/'), '');
        final archivePath =
            'conversations/$conversationId/backgrounds/$relative';
        await _addFile(archive, item, archivePath);
        (manifest['entries'] as List<String>).add(archivePath);
      }
    }
    final conversation = await ConversationArchiveRepository(
      paths: paths,
    ).getConversation(conversationId);
    final mediaPaths = <String>{
      conversation?.backgroundImagePath ?? '',
      conversation?.avatarImagePath ?? '',
    }..removeWhere((path) => path.isEmpty);
    for (final mediaPath in mediaPaths) {
      final mediaFile = paths.managedMediaFile(mediaPath);
      if (mediaFile != null && await mediaFile.exists()) {
        await _addFile(archive, mediaFile, mediaPath);
        (manifest['entries'] as List<String>).add(mediaPath);
      }
    }
    final manifestBytes = utf8.encode(_prettyJson(manifest));
    archive.addFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );

    final encoded = ZipEncoder().encode(archive);
    await output.writeAsBytes(encoded);
    return output;
  }

  Future<void> _addFile(
    Archive archive,
    File source,
    String archivePath,
  ) async {
    final bytes = await source.readAsBytes();
    archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
  }
}

Set<String> _stringSetFromJson(Object? value) {
  if (value is! List) {
    return const <String>{};
  }
  return value
      .map((item) => item.toString())
      .where((item) => item.trim().isNotEmpty)
      .toSet();
}

bool _boolFromJson(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value == null) {
    return false;
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

String _prettyJson(Map<String, dynamic> json) {
  return const JsonEncoder.withIndent('  ').convert(json);
}

String _join(String first, String second) {
  if (first.endsWith(Platform.pathSeparator)) {
    return '$first$second';
  }
  return '$first${Platform.pathSeparator}$second';
}

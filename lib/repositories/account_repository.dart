import 'dart:convert';
import 'dart:io';

import '../models/local_account.dart';
import '../models/runtime_identity.dart';
import '../services/app_logger.dart';
import 'archive_repositories.dart';

/// Persists the local account registry (`accounts.json`) at the shared
/// application root and manages the per-account data directories.
///
/// Accounts are identity shells: the registry stores only identity metadata
/// (id, display name, avatar, creation time). Business data lives in each
/// account's own directory, addressed through
/// [ArchivePaths.forAccount]. Accounts themselves are never exported into a
/// `.jovarchive`; the registry file is excluded from archive export/import.
class AccountRepository {
  AccountRepository({ArchivePaths? globalPaths, AppLogger? logger})
    : globalPaths = globalPaths ?? ArchivePaths(),
      _logger = logger ?? AppLogger.instance;

  final ArchivePaths globalPaths;
  final AppLogger _logger;

  static const String defaultDisplayName = '默认账户';

  Future<List<LocalAccount>> listAccounts() =>
      _logger.trace<List<LocalAccount>>(
        'accounts.list',
        component: 'accounts',
        operation: _listAccounts,
      );

  Future<List<LocalAccount>> _listAccounts() async {
    final registry = await _readRegistry();
    final raw = registry['accounts'];
    if (raw is! List) {
      return const <LocalAccount>[];
    }
    final accounts = <LocalAccount>[];
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final account = LocalAccount.fromJson(Map<String, dynamic>.from(item));
      if (account.id.isNotEmpty) {
        accounts.add(account);
      }
    }
    return accounts;
  }

  Future<String?> activeAccountId() async {
    final registry = await _readRegistry();
    final accounts = await _listAccounts();
    final requested = registry['active_account_id']?.toString().trim() ?? '';
    for (final account in accounts) {
      if (account.id == requested) {
        return account.id;
      }
    }
    return accounts.isEmpty ? null : accounts.first.id;
  }

  Future<LocalAccount?> activeAccount() async {
    final id = await activeAccountId();
    if (id == null) {
      return null;
    }
    for (final account in await _listAccounts()) {
      if (account.id == id) {
        return account;
      }
    }
    return null;
  }

  /// Ensures exactly one active account exists, migrating legacy single-user
  /// data from the shared root into a default account on first run.
  Future<LocalAccount> ensureActiveAccount() async {
    final existing = await activeAccount();
    if (existing != null) {
      return existing;
    }
    final account = LocalAccount(
      id: generateRuntimeUuidV4(),
      displayName: defaultDisplayName,
      createdAt: DateTime.now().toUtc(),
    );
    await _migrateLegacyData(account.id);
    await _writeRegistry(accounts: <LocalAccount>[account], activeId: account.id);
    _logger.info(
      'accounts.migrated',
      component: 'accounts',
      data: <String, Object?>{'account_ref': _logger.reference(account.id)},
    );
    return account;
  }

  Future<LocalAccount> createAccount(String displayName) async {
    final name = displayName.trim().isEmpty
        ? defaultDisplayName
        : displayName.trim();
    final account = LocalAccount(
      id: generateRuntimeUuidV4(),
      displayName: name,
      createdAt: DateTime.now().toUtc(),
    );
    final accounts = <LocalAccount>[...await _listAccounts(), account];
    final activeId = await activeAccountId() ?? account.id;
    await globalPaths.forAccount(account.id).root.create(recursive: true);
    await _writeRegistry(accounts: accounts, activeId: activeId);
    _logger.info(
      'accounts.created',
      component: 'accounts',
      data: <String, Object?>{'account_ref': _logger.reference(account.id)},
    );
    return account;
  }

  Future<LocalAccount> renameAccount(String id, String displayName) async {
    final name = displayName.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(displayName, 'displayName', '账户名称不能为空');
    }
    final accounts = await _listAccounts();
    LocalAccount? updated;
    final next = <LocalAccount>[];
    for (final account in accounts) {
      if (account.id == id) {
        updated = account.copyWith(displayName: name);
        next.add(updated);
      } else {
        next.add(account);
      }
    }
    if (updated == null) {
      throw ArgumentError.value(id, 'id', '账户不存在');
    }
    await _writeRegistry(
      accounts: next,
      activeId: await activeAccountId() ?? updated.id,
    );
    _logger.info(
      'accounts.renamed',
      component: 'accounts',
      data: <String, Object?>{'account_ref': _logger.reference(id)},
    );
    return updated;
  }

  Future<void> deleteAccount(String id) async {
    final accounts = await _listAccounts();
    if (accounts.length <= 1) {
      throw StateError('至少需要保留一个账户');
    }
    var found = false;
    final next = <LocalAccount>[];
    for (final account in accounts) {
      if (account.id == id) {
        found = true;
      } else {
        next.add(account);
      }
    }
    if (!found) {
      throw ArgumentError.value(id, 'id', '账户不存在');
    }
    final activeId = await activeAccountId();
    if (activeId == id) {
      throw StateError('请先切换到其他账户再删除当前账户');
    }
    await _writeRegistry(accounts: next, activeId: activeId ?? next.first.id);
    await _deleteAccountDirectory(id);
    _logger.info(
      'accounts.deleted',
      component: 'accounts',
      data: <String, Object?>{'account_ref': _logger.reference(id)},
    );
  }

  Future<void> setActiveAccount(String id) async {
    final accounts = await _listAccounts();
    var found = false;
    for (final account in accounts) {
      if (account.id == id) {
        found = true;
        break;
      }
    }
    if (!found) {
      throw ArgumentError.value(id, 'id', '账户不存在');
    }
    await _writeRegistry(accounts: accounts, activeId: id);
    _logger.info(
      'accounts.activated',
      component: 'accounts',
      data: <String, Object?>{'account_ref': _logger.reference(id)},
    );
  }

  Future<void> _migrateLegacyData(String accountId) async {
    final accountRoot = globalPaths.forAccount(accountId).root;
    await accountRoot.create(recursive: true);
    final source = globalPaths.root;
    for (final name in const <String>[
      'assistants',
      'conversations',
      'media',
      'appearance',
      'archives',
    ]) {
      final from = Directory(_join(source.path, name));
      final to = Directory(_join(accountRoot.path, name));
      if (await from.exists() && !await to.exists()) {
        await from.rename(to.path);
      }
    }
    final settingsFile = globalPaths.settingsFile;
    final targetSettings = File(_join(accountRoot.path, 'settings.json'));
    if (await settingsFile.exists() && !await targetSettings.exists()) {
      await settingsFile.rename(targetSettings.path);
    } else if (await targetSettings.exists() == false) {
      final legacyFallback = File(
        '${Directory.current.path}${Platform.pathSeparator}.hakurei_terminal_settings.json',
      );
      if (await legacyFallback.exists()) {
        await legacyFallback.rename(targetSettings.path);
      }
    }
  }

  Future<void> _deleteAccountDirectory(String id) async {
    final directory = globalPaths.forAccount(id).root;
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<Map<String, dynamic>> _readRegistry() async {
    final file = globalPaths.accountsFile;
    if (!await file.exists()) {
      return const <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      _logger.warning(
        'accounts.registry_invalid',
        component: 'accounts',
      );
    }
    return const <String, dynamic>{};
  }

  Future<void> _writeRegistry({
    required List<LocalAccount> accounts,
    required String activeId,
  }) async {
    final file = globalPaths.accountsFile;
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      encoder.convert(<String, dynamic>{
        'format_version': 1,
        'active_account_id': activeId,
        'accounts': accounts.map((account) => account.toJson()).toList(
          growable: false,
        ),
      }),
    );
  }
}

String _join(String first, String second) {
  if (first.endsWith(Platform.pathSeparator)) {
    return '$first$second';
  }
  return '$first${Platform.pathSeparator}$second';
}

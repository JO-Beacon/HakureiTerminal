import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/repositories/account_repository.dart';
import 'package:hakurei_terminal/repositories/archive_repositories.dart';
import 'package:hakurei_terminal/services/app_logger.dart';

void main() {
  group('AccountRepository', () {
    test('migrates legacy single-user data into the first account', () async {
      final global = await Directory.systemTemp.createTemp(
        'jov_account_migrate_',
      );
      addTearDown(() => global.delete(recursive: true));
      final globalPaths = ArchivePaths(root: global);
      await globalPaths.settingsFile.parent.create(recursive: true);
      await globalPaths.settingsFile.writeAsString(
        '{"active_user_role_id":"user_work"}',
      );
      final legacyDraft = globalPaths.assistantFile('draft_legacy');
      await legacyDraft.parent.create(recursive: true);
      await legacyDraft.writeAsString('{"id":"draft_legacy","name":"Legacy"}');

      final repository = AccountRepository(globalPaths: globalPaths);
      final account = await repository.ensureActiveAccount();

      final accountPaths = globalPaths.forAccount(account.id);
      expect(await accountPaths.settingsFile.exists(), isTrue);
      expect(await accountPaths.assistantFile('draft_legacy').exists(), isTrue);
      expect(await globalPaths.settingsFile.exists(), isFalse);
      expect(await globalPaths.accountsFile.exists(), isTrue);
      expect(await repository.activeAccountId(), account.id);

      // A second ensure keeps the migrated account and data intact.
      final again = await repository.ensureActiveAccount();
      expect(again.id, account.id);
      expect(await accountPaths.assistantFile('draft_legacy').exists(), isTrue);
    });

    test('creates, renames, switches, and deletes accounts', () async {
      final global = await Directory.systemTemp.createTemp('jov_account_crud_');
      addTearDown(() => global.delete(recursive: true));
      final repository = AccountRepository(
        globalPaths: ArchivePaths(root: global),
      );

      final first = await repository.ensureActiveAccount();
      final second = await repository.createAccount('工作');
      expect(await repository.activeAccountId(), first.id);

      await repository.setActiveAccount(second.id);
      expect(await repository.activeAccountId(), second.id);

      final renamed = await repository.renameAccount(second.id, '工作 2');
      expect(renamed.displayName, '工作 2');

      await repository.setActiveAccount(first.id);
      await repository.deleteAccount(second.id);
      final remaining = await repository.listAccounts();
      expect(remaining, hasLength(1));
      expect(remaining.single.id, first.id);
    });

    test('refuses to delete the active or last account', () async {
      final global = await Directory.systemTemp.createTemp('jov_account_guard_');
      addTearDown(() => global.delete(recursive: true));
      final repository = AccountRepository(
        globalPaths: ArchivePaths(root: global),
      );
      final account = await repository.ensureActiveAccount();
      expect(() => repository.deleteAccount(account.id), throwsStateError);
    });

    test('rejects unsafe account ids when building account paths', () {
      final globalPaths = ArchivePaths(root: Directory.systemTemp);
      const unsafeIds = <String>['', '..', '../escape', 'a/b', r'a\b', 'CON'];
      for (final id in unsafeIds) {
        expect(() => globalPaths.forAccount(id), throwsArgumentError, reason: id);
      }
    });

    test('accounts are excluded from full archive export', () async {
      final global = await Directory.systemTemp.createTemp(
        'jov_account_archive_',
      );
      addTearDown(() => global.delete(recursive: true));
      final globalPaths = ArchivePaths(root: global);
      final repository = AccountRepository(globalPaths: globalPaths);
      final account = await repository.ensureActiveAccount();
      final accountPaths = globalPaths.forAccount(account.id);
      final output = File(
        '${global.path}${Platform.pathSeparator}full.jovarchive',
      );

      await JovArchiveExportRepository(
        paths: accountPaths,
      ).exportAllToFile(output);

      final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
      final entries = archive.files.map((file) => file.name).toSet();
      expect(entries, contains('manifest.json'));
      expect(entries, isNot(contains('accounts.json')));
      expect(
        entries.where((name) => name.startsWith('accounts/')),
        isEmpty,
      );
    });

    test('logs account lifecycle with hashed references only', () async {
      final global = await Directory.systemTemp.createTemp(
        'jov_account_logging_',
      );
      final logs = await Directory.systemTemp.createTemp('jov_account_logs_');
      addTearDown(() => global.delete(recursive: true));
      addTearDown(() => logs.delete(recursive: true));
      final logger = AppLogger();
      await logger.initialize(logs);
      final repository = AccountRepository(
        globalPaths: ArchivePaths(root: global),
        logger: logger,
      );

      final account = await repository.ensureActiveAccount();
      await repository.createAccount('公开账户名');
      await logger.flush();

      final logFile = logger.activeFile!;
      final lines = await logFile.readAsLines();
      final events = lines
          .map((line) => jsonDecode(line))
          .whereType<Map>()
          .map((entry) => entry['event']?.toString())
          .toList();
      expect(events, contains('accounts.migrated'));
      expect(events, contains('accounts.created'));

      final raw = lines.join('\n');
      // Account ids and display names must never appear in diagnostics.
      expect(raw, isNot(contains(account.id)));
      expect(raw, isNot(contains('公开账户名')));
    });
  });
}

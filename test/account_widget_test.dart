import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/models/app_settings.dart';
import 'package:hakurei_terminal/repositories/account_repository.dart';
import 'package:hakurei_terminal/repositories/archive_repositories.dart';
import 'package:hakurei_terminal/screens/settings_screen.dart';

void main() {
  testWidgets('account management page surfaces local account controls', (
    tester,
  ) async {
    final global = Directory.systemTemp.createTempSync('jov_account_page_');
    addTearDown(() => global.deleteSync(recursive: true));
    final globalPaths = ArchivePaths(root: global);
    final repository = AccountRepository(globalPaths: globalPaths);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaultSettings,
          initialPage: SettingsInitialPage.accounts,
          accountRepository: repository,
          assistantRepository: AssistantArchiveRepository(paths: globalPaths),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('账户管理'), findsWidgets);
    expect(find.text('本地账户'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('accountCreateButton')),
      findsOneWidget,
    );
    expect(find.text('新建账户'), findsOneWidget);
    expect(find.textContaining('账户本身不会进入存档'), findsOneWidget);
  });

  testWidgets('account navigation is listed in the settings index', (
    tester,
  ) async {
    final global = Directory.systemTemp.createTempSync('jov_account_nav_');
    addTearDown(() => global.deleteSync(recursive: true));
    final globalPaths = ArchivePaths(root: global);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaultSettings,
          initialPage: null,
          accountRepository: AccountRepository(globalPaths: globalPaths),
          assistantRepository: AssistantArchiveRepository(paths: globalPaths),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final nav = find.byKey(const ValueKey<String>('settings-navigation'));
    final navScrollable = find
        .descendant(of: nav, matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(
      find.text('账户管理'),
      100,
      scrollable: navScrollable,
    );
    expect(find.text('账户管理'), findsOneWidget);
    expect(find.text('本地账户与切换'), findsOneWidget);
  });
}

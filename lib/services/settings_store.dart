import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';

class SettingsStore {
  SettingsStore({File? file, AppSettings? defaultSettings})
    : _file = file,
      _defaultSettings = defaultSettings ?? AppSettings.defaultSettings;

  final File? _file;
  final AppSettings _defaultSettings;

  Future<AppSettings> load() async {
    final file = await _settingsFileAsync();
    if (!await file.exists()) {
      return _defaultSettings;
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        final settings = _settingsFromJson(decoded);
        await _persistRuntimeIdentityMigration(file, decoded, settings);
        return settings;
      }
      if (decoded is Map) {
        final json = Map<String, dynamic>.from(decoded);
        final settings = _settingsFromJson(json);
        await _persistRuntimeIdentityMigration(file, json, settings);
        return settings;
      }
    } catch (_) {
      return _defaultSettings;
    }
    return _defaultSettings;
  }

  AppSettings _settingsFromJson(Map<String, dynamic> json) {
    final settings = AppSettings.fromJson(json);
    final rawAppearance = json['appearance'];
    if (rawAppearance is! Map ||
        (rawAppearance['theme_id']?.toString().trim().isEmpty ?? true)) {
      return settings.copyWith(
        appearance: settings.appearance.copyWith(
          themeId: _defaultSettings.appearance.themeId,
        ),
      );
    }
    return settings;
  }

  Future<void> _persistRuntimeIdentityMigration(
    File file,
    Map<String, dynamic> raw,
    AppSettings settings,
  ) async {
    final connections = raw['external_runtime_connections'];
    if (connections is! List ||
        !connections.whereType<Map>().any(
          (item) => item['agent_id']?.toString().trim().isEmpty ?? true,
        )) {
      return;
    }
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(settings.toJson()));
  }

  Future<void> save(AppSettings settings) async {
    final file = await _settingsFileAsync();
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(settings.toJson()));
  }

  void saveSync(AppSettings settings) {
    final file = _settingsFile();
    file.parent.createSync(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    file.writeAsStringSync(encoder.convert(settings.toJson()));
  }

  File _settingsFile() {
    final configured = _file;
    if (configured != null) {
      return configured;
    }

    final appData = Platform.environment['APPDATA'];
    if (Platform.isWindows && appData != null && appData.isNotEmpty) {
      return File(
        '$appData${Platform.pathSeparator}HakureiTerminal${Platform.pathSeparator}settings.json',
      );
    }

    return File(
      '${Directory.current.path}${Platform.pathSeparator}.hakurei_terminal_settings.json',
    );
  }

  Future<File> _settingsFileAsync() async {
    final configured = _file;
    if (configured != null) {
      return configured;
    }
    if (Platform.isWindows) {
      return _settingsFile();
    }
    try {
      final directory = await getApplicationSupportDirectory();
      return File('${directory.path}${Platform.pathSeparator}settings.json');
    } catch (_) {
      return File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}HakureiTerminal'
        '${Platform.pathSeparator}settings.json',
      );
    }
  }
}

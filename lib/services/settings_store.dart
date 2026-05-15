import 'dart:convert';
import 'dart:io';

import '../models/app_settings.dart';

class SettingsStore {
  SettingsStore({File? file}) : _file = file;

  final File? _file;

  Future<AppSettings> load() async {
    final file = _settingsFile();
    if (!await file.exists()) {
      return AppSettings.defaultSettings;
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return AppSettings.fromJson(decoded);
      }
      if (decoded is Map) {
        return AppSettings.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      return AppSettings.defaultSettings;
    }
    return AppSettings.defaultSettings;
  }

  Future<void> save(AppSettings settings) async {
    final file = _settingsFile();
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(settings.toJson()));
  }

  File _settingsFile() {
    final configured = _file;
    if (configured != null) {
      return configured;
    }

    final appData = Platform.environment['APPDATA'];
    if (Platform.isWindows && appData != null && appData.isNotEmpty) {
      return File('$appData${Platform.pathSeparator}HakureiTerminal${Platform.pathSeparator}settings.json');
    }

    return File('${Directory.current.path}${Platform.pathSeparator}.hakurei_terminal_settings.json');
  }
}

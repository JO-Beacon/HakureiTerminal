import 'dart:io';

import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../models/chat_session.dart';
import '../repositories/archive_repositories.dart';

File? resolveAppBackgroundFile(
  AppearanceSettings appearance,
  ArchivePaths paths,
) {
  final relativePath = appearance.backgroundImagePath;
  if (relativePath.isEmpty) {
    return null;
  }
  final file = paths.managedAppearanceResourceFile(relativePath);
  return file != null && file.existsSync() ? file : null;
}

File? resolveSessionBackgroundFile(ChatSession? session, ArchivePaths paths) {
  if (session == null || session.backgroundImagePath.isEmpty) {
    return null;
  }
  final file = paths.managedConversationResourceFile(
    session.sessionId,
    session.backgroundImagePath,
  );
  return file != null && file.existsSync() ? file : null;
}

class AppBackground extends StatelessWidget {
  const AppBackground({
    super.key,
    required this.file,
    required this.color,
    required this.child,
    this.imageOpacity = 1.0,
  });

  final File? file;
  final Color color;
  final Widget child;
  final double imageOpacity;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color,
      child: file == null
          ? child
          : Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Opacity(
                  opacity: imageOpacity.clamp(0.0, 1.0),
                  child: Image.file(
                    file!,
                    key: ValueKey<String>('appBackground:${file!.path}'),
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    errorBuilder: (_, _, _) => ColoredBox(color: color),
                  ),
                ),
                child,
              ],
            ),
    );
  }
}

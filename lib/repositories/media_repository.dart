import 'dart:io';

import 'package:crypto/crypto.dart';

import 'archive_repositories.dart';

class ManagedMediaFile {
  const ManagedMediaFile({
    required this.relativePath,
    required this.file,
    required this.sha256,
    required this.byteLength,
    required this.modifiedAt,
    required this.mediaType,
    required this.contentAddressed,
  });

  final String relativePath;
  final File file;
  final String sha256;
  final int byteLength;
  final DateTime modifiedAt;
  final String mediaType;
  final bool contentAddressed;
}

class MediaRepository {
  MediaRepository({required this.paths});

  final ArchivePaths paths;

  static bool isContentAddressedPath(String relativePath) {
    return RegExp(
      r'^media/[a-f0-9]{64}$',
    ).hasMatch(relativePath.trim().replaceAll('\\', '/'));
  }

  Future<String> storeBytes(List<int> bytes) async {
    if (bytes.isEmpty) {
      throw const FormatException('不能存储空媒体文件');
    }
    final digest = sha256.convert(bytes).toString();
    final relativePath = 'media/$digest';
    final target = paths.managedMediaFile(relativePath)!;
    if (!await target.exists()) {
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes, flush: true);
    }
    return relativePath;
  }

  Future<String> storeFile(File source) async {
    return storeBytes(await source.readAsBytes());
  }

  Future<List<ManagedMediaFile>> listManagedFiles() async {
    final files = <String, File>{};

    Future<void> collect(
      Directory directory,
      bool Function(String) include,
    ) async {
      if (!await directory.exists()) {
        return;
      }
      await for (final entity in directory.list(recursive: true)) {
        if (entity is! File) {
          continue;
        }
        final relativePath = entity.path
            .substring(paths.root.path.length)
            .replaceAll('\\', '/')
            .replaceFirst(RegExp(r'^/'), '');
        if (include(relativePath)) {
          files[relativePath] = entity;
        }
      }
    }

    await collect(paths.mediaDir, isContentAddressedPath);
    await collect(
      paths.backgroundsDir,
      (path) => path.startsWith('appearance/backgrounds/'),
    );
    await collect(
      paths.conversationsDir,
      (path) => RegExp(r'^conversations/[^/]+/backgrounds/').hasMatch(path),
    );

    final result = <ManagedMediaFile>[];
    for (final entry in files.entries) {
      try {
        final bytes = await entry.value.readAsBytes();
        final stat = await entry.value.stat();
        result.add(
          ManagedMediaFile(
            relativePath: entry.key,
            file: entry.value,
            sha256: sha256.convert(bytes).toString(),
            byteLength: bytes.length,
            modifiedAt: stat.modified,
            mediaType: _detectMediaType(bytes),
            contentAddressed: isContentAddressedPath(entry.key),
          ),
        );
      } on FileSystemException {
        // The file may be replaced while the storage page is being refreshed.
      }
    }
    result.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return result;
  }

  String _detectMediaType(List<int> bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return 'PNG';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return 'JPEG';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'WebP';
    }
    return '未知媒体';
  }
}

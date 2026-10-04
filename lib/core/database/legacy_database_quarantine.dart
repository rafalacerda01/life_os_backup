import 'dart:io';

import 'package:path/path.dart' as p;

final class LegacyDatabaseQuarantineInfo {
  LegacyDatabaseQuarantineInfo(List<File> existingArtifacts)
    : existingArtifacts = List.unmodifiable(existingArtifacts);

  final List<File> existingArtifacts;
  bool get hasLegacyArtifacts => existingArtifacts.isNotEmpty;
}

/// Reports unowned legacy storage without opening, adopting or changing it.
class LegacyDatabaseQuarantineInspector {
  static const _artifactNames = [
    'life_os.sqlite',
    'life_os.sqlite-wal',
    'life_os.sqlite-shm',
    'life_os.sqlite-journal',
    'life_os.sqlite.encryption-candidate',
    'life_os.sqlite.plaintext-backup',
  ];

  Future<LegacyDatabaseQuarantineInfo> inspect(Directory directory) async {
    final existing = <File>[];
    for (final name in _artifactNames) {
      final file = File(p.join(directory.path, name));
      if (await file.exists()) existing.add(file);
    }
    return LegacyDatabaseQuarantineInfo(existing);
  }
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/legacy_database_quarantine.dart';
import 'package:life_os/core/database/local_database_identity.dart';

void main() {
  late Directory directory;
  setUp(
    () => directory = Directory.systemTemp.createTempSync('life_os_legacy_'),
  );
  tearDown(() => directory.deleteSync(recursive: true));

  test('absence is reported without creating any file', () async {
    final info = await LegacyDatabaseQuarantineInspector().inspect(directory);
    expect(info.hasLegacyArtifacts, isFalse);
    expect(directory.listSync(), isEmpty);
  });

  test(
    'all legacy artifacts are reported unchanged without adoption',
    () async {
      const names = [
        'life_os.sqlite',
        'life_os.sqlite-wal',
        'life_os.sqlite-shm',
        'life_os.sqlite-journal',
        'life_os.sqlite.encryption-candidate',
        'life_os.sqlite.plaintext-backup',
      ];
      for (final name in names) {
        File('${directory.path}/$name').writeAsStringSync('unowned:$name');
      }
      final info = await LegacyDatabaseQuarantineInspector().inspect(directory);
      expect(info.hasLegacyArtifacts, isTrue);
      expect(info.existingArtifacts, hasLength(names.length));
      expect(() => info.existingArtifacts.clear(), throwsUnsupportedError);
      expect(directory.listSync(), hasLength(names.length));
      for (final name in names) {
        expect(
          File('${directory.path}/$name').readAsStringSync(),
          'unowned:$name',
        );
      }
      for (final uid in ['user-a', 'user-b']) {
        expect(
          LocalDatabaseIdentity(uid).fileIn(directory).existsSync(),
          isFalse,
        );
      }
    },
  );

  test(
    'orphan legacy sidecar is recognized without creating the main DB',
    () async {
      File(
        '${directory.path}/life_os.sqlite-wal',
      ).writeAsStringSync('preserved');
      final info = await LegacyDatabaseQuarantineInspector().inspect(directory);
      expect(info.hasLegacyArtifacts, isTrue);
      expect(info.existingArtifacts, hasLength(1));
      expect(File('${directory.path}/life_os.sqlite').existsSync(), isFalse);
    },
  );
}

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/local_installation_storage_inspector.dart';
import 'package:life_os/core/services/native_notification_registry.dart';

void main() {
  late Directory root, documents, support;
  late LocalInstallationStorageInspector inspector;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lifeos-inspector-');
    documents = await Directory('${root.path}/app_flutter').create();
    support = await Directory('${root.path}/files').create();
    inspector = LocalInstallationStorageInspector(
      documentsDirectory: () async => documents,
      supportDirectory: () async => support,
    );
  });
  tearDown(() async => root.delete(recursive: true));

  test('fresh empty roots and engine artifacts remain untouched', () async {
    final assets = await Directory('${documents.path}/flutter_assets').create();
    final file = await File('${assets.path}/kernel').writeAsString('ENGINE');
    await File('${documents.path}/res_timestamp-1').writeAsString('');
    await inspector.assertFreshDirectories();
    expect(await file.readAsString(), 'ENGINE');
    expect(await support.list().isEmpty, true);
  });
  for (final suffix in ['', '-wal', '-shm', '-journal', '.plaintext-backup']) {
    test(
      'P1 native registry$suffix blocks even with an existing marker',
      () async {
        final file = await File(
          '${support.path}/life_os_native_ownership_v1.sqlite$suffix',
        ).writeAsString('SYNTHETIC-OWNERSHIP-MUST-SURVIVE');
        await expectLater(
          inspector.assertNoUnqualifiedSecondaryStores(),
          throwsStateError,
        );
        expect(await file.readAsString(), 'SYNTHETIC-OWNERSHIP-MUST-SURVIVE');
      },
    );
  }
  test(
    'SDK preference store is rejected before local identity can be published',
    () async {
      final prefs = await Directory('${root.path}/shared_prefs').create();
      final file = await File(
        '${prefs.path}/com.google.firebase.auth.api.Store.synthetic.xml',
      ).writeAsString('SYNTHETIC-SDK');
      await expectLater(
        inspector.assertNoUnqualifiedSecondaryStores(),
        throwsStateError,
      );
      expect(await file.readAsString(), 'SYNTHETIC-SDK');
    },
  );
  test(
    'known crypto metadata still cannot be treated as a fresh install',
    () async {
      final prefs = await Directory('${root.path}/shared_prefs').create();
      final file = await File(
        '${prefs.path}/FlutterSecureStorage.xml',
      ).writeAsString('SYNTHETIC');
      await inspector.assertNoUnqualifiedSecondaryStores();
      await expectLater(inspector.assertFreshDirectories(), throwsStateError);
      expect(await file.readAsString(), 'SYNTHETIC');
    },
  );
  test(
    'installation reminder host recognizes only its exact auxiliary files',
    () async {
      final allowed = LocalInstallationStorageInspector(
        documentsDirectory: () async => documents,
        supportDirectory: () async => support,
        allowInstallationReminders: true,
      );
      final prefs = await Directory('${root.path}/shared_prefs').create();
      final plugin = await File(
        '${prefs.path}/scheduled_notifications.xml',
      ).writeAsString('SYNTHETIC-ANDROID');
      final metadata = await File(
        '${support.path}/${NativeNotificationRegistry.installationFileName}',
      ).writeAsString('SYNTHETIC-REGISTRY');
      await allowed.assertNoUnqualifiedSecondaryStores();
      await expectLater(
        inspector.assertNoUnqualifiedSecondaryStores(),
        throwsStateError,
      );
      await expectLater(allowed.assertFreshDirectories(), throwsStateError);
      final legacy = await File(
        '${support.path}/life_os_native_ownership_v1.sqlite',
      ).writeAsString('SYNTHETIC-LEGACY');
      await expectLater(
        allowed.assertNoUnqualifiedSecondaryStores(),
        throwsStateError,
      );
      expect(await legacy.readAsString(), 'SYNTHETIC-LEGACY');
      expect(await metadata.readAsString(), 'SYNTHETIC-REGISTRY');
      expect(await plugin.readAsString(), 'SYNTHETIC-ANDROID');
    },
  );

  test(
    'only the known AndroidX profile verifier cache is safe on fresh boot',
    () async {
      final isolated = LocalInstallationStorageInspector(
        documentsDirectory: () async => documents,
        supportDirectory: () async => support,
        allowAndroidProfileVerifierCache: true,
      );
      final marker = File('${support.path}/profileInstalled');
      final cache = ByteData(24)
        ..setInt32(0, 1)
        ..setInt32(4, 327680)
        ..setInt64(8, 1234567890);
      final bytes = cache.buffer.asUint8List();
      await marker.writeAsBytes(bytes);
      await isolated.assertFreshDirectories();
      await expectLater(inspector.assertFreshDirectories(), throwsStateError);
      expect(await marker.readAsBytes(), bytes);

      cache.setInt32(0, 2);
      await marker.writeAsBytes(bytes);
      await expectLater(isolated.assertFreshDirectories(), throwsStateError);
      expect(await marker.readAsBytes(), bytes);
    },
  );

  for (final location in [
    'files/datastore/state.pb',
    'no_backup/sdk',
    'databases/sdk.sqlite',
    'app_flutter/export.json',
  ]) {
    test(
      'unqualified persistence $location prevents first provisioning',
      () async {
        final file = File('${root.path}/$location');
        await file.parent.create(recursive: true);
        await file.writeAsString('SYNTHETIC-RETAIN');
        await expectLater(inspector.assertFreshDirectories(), throwsStateError);
        expect(await file.readAsString(), 'SYNTHETIC-RETAIN');
      },
    );
  }
}

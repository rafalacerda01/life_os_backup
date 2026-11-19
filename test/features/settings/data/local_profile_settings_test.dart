import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/services/biometric_service.dart';
import 'package:life_os/features/settings/data/local_profile_settings.dart';
import 'package:life_os/features/settings/presentation/local_profile_screen.dart';
import 'package:local_auth/local_auth.dart';

import '../../../core/db/fake_secure_storage.dart';

class _DeviceAuth implements BiometricPlatform {
  bool allow = false;
  int requests = 0;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => [];

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required bool biometricOnly,
    required bool persistAcrossBackgrounding,
  }) async {
    requests++;
    expect(biometricOnly, false);
    expect(localizedReason, isNotEmpty);
    return allow;
  }
}

void main() {
  final identity = LocalDatabaseIdentity(
    'local-v1-123e4567-e89b-42d3-a456-426614174000',
  );
  late FakeSecureStorage storage;
  late LocalProfileSettingsStore store;
  late _DeviceAuth device;

  setUp(() {
    storage = FakeSecureStorage();
    store = LocalProfileSettingsStore(identity, storage: storage);
    device = _DeviceAuth();
  });

  test('optional installation settings are isolated and persisted', () async {
    final initial = await store.read();
    expect(initial.displayName, isEmpty);
    expect(initial.requireDeviceUnlock, false);
    await store.write(
      const LocalProfileSettings(
        displayName: 'Sintético',
        requireDeviceUnlock: true,
      ),
    );
    final sameProfile = LocalProfileSettingsStore(identity, storage: storage);
    expect((await sameProfile.read()).displayName, 'Sintético');
    expect((await sameProfile.read()).requireDeviceUnlock, true);
    final otherProfile = LocalProfileSettingsStore(
      LocalDatabaseIdentity('local-v1-123e4567-e89b-42d3-a456-426614174001'),
      storage: storage,
    );
    expect((await otherProfile.read()).requireDeviceUnlock, false);
    expect(storage.deletes, isEmpty);
  });

  test('malformed record is refused without being reset', () async {
    await store.write(const LocalProfileSettings(requireDeviceUnlock: true));
    final key = storage.values.keys.single;
    storage.values[key] =
        '{"v":1,"displayName":"","requireDeviceUnlock":"false"}';
    final original = Map.of(storage.values);
    await expectLater(store.read(), throwsFormatException);
    expect(storage.values, original);
    expect(storage.deletes, isEmpty);
  });

  test('name validation and storage verification fail closed', () async {
    await expectLater(
      store.write(const LocalProfileSettings(displayName: 'linha\nextra')),
      throwsArgumentError,
    );
    expect(storage.values, isEmpty);
    storage.discardWrites = true;
    await expectLater(
      store.write(const LocalProfileSettings(requireDeviceUnlock: true)),
      throwsStateError,
    );
    expect(storage.values, isEmpty);
  });

  testWidgets(
    'locked startup, cancellation and background require OS confirmation',
    (tester) async {
      await store.write(const LocalProfileSettings(requireDeviceUnlock: true));
      final binding = tester.binding;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localProfileSettingsStoreProvider.overrideWithValue(store),
            localProfileDeviceAuthProvider.overrideWithValue(
              BiometricService(platform: device),
            ),
          ],
          child: MaterialApp(
            builder: (context, child) => LocalProfileAppLock(child: child!),
            home: const Scaffold(body: Text('Conteúdo sintético')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Life OS bloqueado'), findsOneWidget);
      expect(find.text('Conteúdo sintético').hitTestable(), findsNothing);
      await tester.tap(find.text('Desbloquear'));
      await tester.pumpAndSettle();
      expect(device.requests, 1);
      expect(find.text('Conteúdo sintético').hitTestable(), findsNothing);

      device.allow = true;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.tap(find.text('Desbloquear'));
      await tester.pump();
      expect(find.text('Conteúdo sintético').hitTestable(), findsNothing);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Conteúdo sintético').hitTestable(), findsOneWidget);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Life OS bloqueado'), findsOneWidget);
      expect(find.text('Conteúdo sintético').hitTestable(), findsNothing);
      expect((await store.read()).requireDeviceUnlock, true);
    },
  );
}

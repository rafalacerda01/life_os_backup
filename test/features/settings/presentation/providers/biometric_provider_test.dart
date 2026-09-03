import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/biometric_service.dart';
import 'package:life_os/features/settings/presentation/providers/biometric_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeBiometricService extends BiometricService {
  bool enrolled = true;
  final List<bool> results = [];
  Completer<bool>? pendingAuthentication;
  int authenticationCalls = 0;

  @override
  Future<bool> hasEnrolledBiometrics() async => enrolled;

  @override
  Future<bool> authenticate({String reason = ''}) {
    authenticationCalls += 1;
    if (pendingAuthentication case final pending?) return pending.future;
    return Future.value(results.isEmpty ? false : results.removeAt(0));
  }
}

Future<void> _settleProvider() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

ProviderContainer _container(_FakeBiometricService service) {
  final container = ProviderContainer(
    overrides: [biometricServiceProvider.overrideWithValue(service)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('preference starts loading before it can release the app', () async {
    final preferences = Completer<SharedPreferences>();
    final container = ProviderContainer(
      overrides: [
        biometricPreferencesLoaderProvider.overrideWithValue(
          () => preferences.future,
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(biometricProvider).status,
      BiometricLockStatus.loading,
    );
    preferences.complete(await SharedPreferences.getInstance());
    await _settleProvider();
    expect(
      container.read(biometricProvider).status,
      BiometricLockStatus.disabled,
    );
  });

  test('persisted false becomes disabled and true becomes locked', () async {
    final service = _FakeBiometricService();
    final disabled = _container(service);
    disabled.read(biometricProvider);
    await _settleProvider();
    expect(
      disabled.read(biometricProvider).status,
      BiometricLockStatus.disabled,
    );

    SharedPreferences.setMockInitialValues({
      BiometricNotifier.storageKey: true,
    });
    final locked = _container(service);
    locked.read(biometricProvider);
    await _settleProvider();
    expect(locked.read(biometricProvider).status, BiometricLockStatus.locked);
  });

  test('enable requires enrollment and successful authentication', () async {
    final service = _FakeBiometricService()..enrolled = false;
    final container = _container(service);
    container.read(biometricProvider);
    await _settleProvider();

    expect(
      await container.read(biometricProvider.notifier).toggleBiometrics(true),
      isFalse,
    );
    expect(service.authenticationCalls, 0);

    service.enrolled = true;
    service.results.addAll([false, true]);
    expect(
      await container.read(biometricProvider.notifier).toggleBiometrics(true),
      isFalse,
    );
    expect(container.read(biometricProvider).isEnabled, isFalse);
    expect(
      await container.read(biometricProvider.notifier).toggleBiometrics(true),
      isTrue,
    );
    expect(
      container.read(biometricProvider).status,
      BiometricLockStatus.unlocked,
    );
    expect(
      (await SharedPreferences.getInstance()).getBool(
        BiometricNotifier.storageKey,
      ),
      isTrue,
    );
  });

  test(
    'disable requires authentication and preserves enabled on failure',
    () async {
      SharedPreferences.setMockInitialValues({
        BiometricNotifier.storageKey: true,
      });
      final service = _FakeBiometricService()
        ..results.addAll([true, false, true]);
      final container = _container(service);
      container.read(biometricProvider);
      await _settleProvider();
      expect(await container.read(biometricProvider.notifier).unlock(), isTrue);

      expect(
        await container
            .read(biometricProvider.notifier)
            .toggleBiometrics(false),
        isFalse,
      );
      expect(container.read(biometricProvider).isEnabled, isTrue);
      expect(
        await container
            .read(biometricProvider.notifier)
            .toggleBiometrics(false),
        isTrue,
      );
      expect(
        container.read(biometricProvider).status,
        BiometricLockStatus.disabled,
      );
    },
  );

  test('lock preserves preference and unlock success is memory-only', () async {
    SharedPreferences.setMockInitialValues({
      BiometricNotifier.storageKey: true,
    });
    final service = _FakeBiometricService()..results.addAll([true, false]);
    final container = _container(service);
    container.read(biometricProvider);
    await _settleProvider();

    expect(await container.read(biometricProvider.notifier).unlock(), isTrue);
    container.read(biometricProvider.notifier).lock();
    expect(
      container.read(biometricProvider).status,
      BiometricLockStatus.locked,
    );
    expect(await container.read(biometricProvider.notifier).unlock(), isFalse);
    expect(
      container.read(biometricProvider).status,
      BiometricLockStatus.locked,
    );
    expect(
      (await SharedPreferences.getInstance()).getBool(
        BiometricNotifier.storageKey,
      ),
      isTrue,
    );
  });

  test('concurrent unlock attempts start only one native prompt', () async {
    SharedPreferences.setMockInitialValues({
      BiometricNotifier.storageKey: true,
    });
    final pending = Completer<bool>();
    final service = _FakeBiometricService()..pendingAuthentication = pending;
    final container = _container(service);
    container.read(biometricProvider);
    await _settleProvider();

    final first = container.read(biometricProvider.notifier).unlock();
    final second = container.read(biometricProvider.notifier).unlock();
    expect(await second, isFalse);
    expect(service.authenticationCalls, 1);
    pending.complete(true);
    expect(await first, isTrue);
  });

  test('concurrent enable attempts start only one native prompt', () async {
    final pending = Completer<bool>();
    final service = _FakeBiometricService()..pendingAuthentication = pending;
    final container = _container(service);
    container.read(biometricProvider);
    await _settleProvider();

    final first = container
        .read(biometricProvider.notifier)
        .toggleBiometrics(true);
    final second = container
        .read(biometricProvider.notifier)
        .toggleBiometrics(true);
    expect(await second, isFalse);
    expect(service.authenticationCalls, 1);
    pending.complete(true);
    expect(await first, isTrue);
  });
}

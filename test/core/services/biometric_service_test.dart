import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:life_os/core/services/biometric_service.dart';

class _FakeBiometricPlatform implements BiometricPlatform {
  List<BiometricType> available = const [];
  bool authenticationResult = false;
  Object? availableError;
  Object? authenticationError;
  int authenticationCalls = 0;
  bool? receivedBiometricOnly;
  bool? receivedPersistAcrossBackgrounding;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async {
    if (availableError case final error?) throw error;
    return available;
  }

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required bool biometricOnly,
    required bool persistAcrossBackgrounding,
  }) async {
    authenticationCalls += 1;
    receivedBiometricOnly = biometricOnly;
    receivedPersistAcrossBackgrounding = persistAcrossBackgrounding;
    if (authenticationError case final error?) throw error;
    return authenticationResult;
  }
}

void main() {
  test('enrolled biometrics are available only for a non-empty list', () async {
    final authentication = _FakeBiometricPlatform()
      ..available = const [BiometricType.fingerprint];
    final service = BiometricService(platform: authentication);

    expect(await service.hasEnrolledBiometrics(), isTrue);
    authentication.available = const [];
    expect(await service.hasEnrolledBiometrics(), isFalse);
  });

  test('enrollment lookup exception fails closed', () async {
    final authentication = _FakeBiometricPlatform()
      ..availableError = StateError('private platform details');
    final service = BiometricService(platform: authentication);

    expect(await service.hasEnrolledBiometrics(), isFalse);
  });

  test(
    'authenticate preserves biometric-only persistent prompt options',
    () async {
      final authentication = _FakeBiometricPlatform()
        ..authenticationResult = true;
      final service = BiometricService(platform: authentication);

      expect(await service.authenticate(), isTrue);
      expect(authentication.receivedBiometricOnly, isTrue);
      expect(authentication.receivedPersistAcrossBackgrounding, isTrue);

      authentication.authenticationResult = false;
      expect(await service.authenticate(), isFalse);
    },
  );

  test(
    'authenticate exception returns false without exposing details',
    () async {
      final authentication = _FakeBiometricPlatform()
        ..authenticationError = StateError('private platform details');
      final service = BiometricService(platform: authentication);

      expect(await service.authenticate(), isFalse);
    },
  );
}

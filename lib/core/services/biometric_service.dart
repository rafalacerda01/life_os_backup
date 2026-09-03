import 'package:local_auth/local_auth.dart';

abstract interface class BiometricPlatform {
  Future<List<BiometricType>> getAvailableBiometrics();

  Future<bool> authenticate({
    required String localizedReason,
    required bool biometricOnly,
    required bool persistAcrossBackgrounding,
  });
}

class _LocalAuthBiometricPlatform implements BiometricPlatform {
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  Future<List<BiometricType>> getAvailableBiometrics() {
    return _auth.getAvailableBiometrics();
  }

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required bool biometricOnly,
    required bool persistAcrossBackgrounding,
  }) {
    return _auth.authenticate(
      localizedReason: localizedReason,
      biometricOnly: biometricOnly,
      persistAcrossBackgrounding: persistAcrossBackgrounding,
    );
  }
}

class BiometricService {
  BiometricService({BiometricPlatform? platform})
    : _platform = platform ?? _LocalAuthBiometricPlatform();

  final BiometricPlatform _platform;

  Future<bool> hasEnrolledBiometrics() async {
    try {
      final biometrics = await _platform.getAvailableBiometrics();
      return biometrics.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticate({
    String reason = 'Por favor, autentique-se para continuar',
  }) async {
    try {
      return await _platform.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}

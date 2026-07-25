import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

class BiometricService {
  final LocalAuthentication _auth = LocalAuthentication();

  /// Verifica se o dispositivo possui suporte físico e biometria cadastrada
  Future<bool> canCheckBiometrics() async {
    try {
      final bool canAuthenticateWithBiometrics = await _auth.canCheckBiometrics;
      final bool isSupported = await _auth.isDeviceSupported();
      return canAuthenticateWithBiometrics || isSupported;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Dispara o prompt nativo de autenticação (FaceID / Impressão Digital)
  Future<bool> authenticate({
    String reason = 'Por favor, autentique-se para continuar',
  }) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException catch (e) {
      // Usando as constantes corretas conforme a documentação da biblioteca
      if (e.code == LocalAuthExceptionCode.noBiometricHardware) {
        return false;
      } else if (e.code == LocalAuthExceptionCode.temporaryLockout ||
          e.code == LocalAuthExceptionCode.biometricLockout) {
        // Bloqueio temporário ou definitivo por excesso de tentativas
        return false;
      }
      return false;
    } on PlatformException catch (_) {
      // Fallback genérico para outros erros de plataforma
      return false;
    }
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:life_os/core/services/biometric_service.dart';

final biometricServiceProvider = Provider<BiometricService>((ref) {
  return BiometricService();
});

// Refatorado para o padrão moderno Notifier do Riverpod 2.x
class BiometricNotifier extends Notifier<bool> {
  static const String _storageKey = 'biometrics_enabled';

  @override
  bool build() {
    // Carrega a preferência de forma não bloqueante
    _loadPreference();
    return false; // Retorna o estado inicial
  }

  Future<void> _loadPreference() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_storageKey) ?? false;
  }

  Future<bool> toggleBiometrics(bool enable) async {
    if (enable) {
      final biometricService = ref.read(biometricServiceProvider);

      // Valida se o aparelho suporta e se o usuário passa na biometria antes de ativar
      final isSupported = await biometricService.canCheckBiometrics();
      if (!isSupported) return false;

      final authenticated = await biometricService.authenticate(
        reason: 'Confirme sua biometria para habilitar este recurso',
      );
      if (!authenticated) return false;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_storageKey, enable);
    state = enable;
    return true;
  }
}

// Utilizando NotifierProvider correspondente
final biometricProvider = NotifierProvider<BiometricNotifier, bool>(() {
  return BiometricNotifier();
});

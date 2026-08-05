import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AiConsentNotifier extends Notifier<bool> {
  static const String _storageKey = 'ai_consent_accepted';

  @override
  bool build() {
    // Carrega a preferência de forma assíncrona sem bloquear a thread principal
    _loadPreference();
    return false; // Por padrão, bloqueamos o acesso (Privacy by Default)
  }

  Future<void> _loadPreference() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_storageKey) ?? false;
  }

  Future<void> acceptConsent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_storageKey, true);
    state = true; // Atualiza a UI reativamente
  }
}

final aiConsentProvider = NotifierProvider<AiConsentNotifier, bool>(() {
  return AiConsentNotifier();
});

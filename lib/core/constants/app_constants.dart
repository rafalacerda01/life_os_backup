class AppConstants {
  AppConstants._(); // Construtor privado para evitar que a classe seja instanciada

  // ===========================================================================
  // 1. INFORMAÇÕES GERAIS DO APP
  // ===========================================================================
  static const String appName = 'Life OS';
  static const String defaultErrorMessage =
      'Ocorreu um erro inesperado. Tente novamente.';
  static const String noInternetMessage =
      'Verifique sua conexão com a internet.';

  // ===========================================================================
  // 2. LIMITES E NÚMEROS MÁGICOS
  // ===========================================================================
  static const int maxHabitsPerFreeUser = 5;
  static const int maxGoalTitleLength = 50;
  static const int syncTimeoutSeconds = 15;
}

class StorageKeys {
  StorageKeys._();

  // ===========================================================================
  // 3. CHAVES DE ARMAZENAMENTO LOCAL (SharedPreferences / Secure Storage)
  // ===========================================================================
  static const String hasCompletedOnboarding = 'HAS_COMPLETED_ONBOARDING';
  static const String userToken = 'USER_SECURE_TOKEN';
  static const String themeMode = 'APP_THEME_MODE';
}

class AppRoutes {
  AppRoutes._();

  // ===========================================================================
  // 4. NOMES DE ROTAS (Para usar com o GoRouter)
  // ===========================================================================
  static const String home = '/';
  static const String checkIn = '/check-in';
  static const String dashboard = '/dashboard';
}

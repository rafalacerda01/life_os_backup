import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

class AppLogger {
  AppLogger._(); // Construtor privado para evitar instanciamento

  static final Logger _logger = Logger(
    filter:
        null, // Usa o DevelopmentFilter padrão (só imprime no console em Debug)
    printer: PrettyPrinter(
      methodCount: 2, // Número de chamadas de método exibidas
      errorMethodCount: 8, // Stacktrace detalhado para erros
      lineLength: 120, // Largura da saída
      colors: true, // Cores no terminal
      printEmojis: true, // Emojis para facilitar a leitura visual
      dateTimeFormat: DateTimeFormat
          .onlyTimeAndSinceStart, // Formato de data conforme a doc
    ),
  );

  /// Log de Debug: Para informações úteis durante o desenvolvimento.
  static void d(dynamic message) {
    _logger.d(message);
  }

  /// Log de Info: Para destacar fluxos importantes (ex: "Usuário fez login").
  static void i(dynamic message) {
    _logger.i(message);
  }

  /// Log de Warning: Para comportamentos inesperados que não quebram o app.
  static void w(dynamic message) {
    _logger.w(message);
  }

  /// Log de Erro: Imprime no console (em debug) e envia para o Crashlytics (em release).
  static void e(String message, [dynamic error, StackTrace? stackTrace]) {
    // O pacote logger imprime no console apenas em Debug (DevelopmentFilter)
    _logger.e(message, error: error, stackTrace: stackTrace);

    // Em produção (Release), capturamos a falha e enviamos para a nuvem
    if (!kDebugMode) {
      FirebaseCrashlytics.instance.recordError(
        error ?? Exception(message),
        stackTrace,
        reason: message,
        fatal: false, // false porque o erro foi tratado por um try/catch seu
      );
    }
  }
}

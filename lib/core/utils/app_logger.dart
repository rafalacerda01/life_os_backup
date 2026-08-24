import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

@immutable
class SanitizedCrashReport {
  const SanitizedCrashReport({
    required this.error,
    required this.reason,
    required this.stackTrace,
    required this.fatal,
  });

  final Object error;
  final String reason;
  final StackTrace? stackTrace;
  final bool fatal;
}

class _SanitizedError implements Exception {
  const _SanitizedError(this.errorType);

  final String errorType;

  @override
  String toString() => 'HandledError:$errorType';
}

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
    _report(message, error, stackTrace, fatal: false);
  }

  /// Registra uma falha global sem enviar a mensagem bruta da exceção.
  static void fatal(String reason, Object error, StackTrace? stackTrace) {
    _report(reason, error, stackTrace, fatal: true);
  }

  @visibleForTesting
  static SanitizedCrashReport sanitizeForCrashlytics({
    required String reason,
    required Object? error,
    required StackTrace? stackTrace,
    required bool fatal,
  }) {
    return SanitizedCrashReport(
      error: _SanitizedError(error?.runtimeType.toString() ?? 'UnknownError'),
      reason: reason,
      stackTrace: stackTrace,
      fatal: fatal,
    );
  }

  static void _report(
    String reason,
    Object? error,
    StackTrace? stackTrace, {
    required bool fatal,
  }) {
    // DevelopmentFilter mantém erro e stack completos apenas no console local.
    _logger.e(reason, error: error, stackTrace: stackTrace);

    if (!kDebugMode) {
      final report = sanitizeForCrashlytics(
        reason: reason,
        error: error,
        stackTrace: stackTrace,
        fatal: fatal,
      );

      FirebaseCrashlytics.instance.recordError(
        report.error,
        report.stackTrace,
        reason: report.reason,
        fatal: report.fatal,
      );
    }
  }
}

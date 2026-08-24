import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/utils/app_logger.dart';

class SensitiveFailure implements Exception {
  const SensitiveFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

void main() {
  const secrets = <String>[
    'firebase-id-token-secret',
    'sensitive-uid',
    'user@example.com',
    'private-payload',
  ];

  test('sanitização não inclui conteúdo bruto da exceção', () {
    final report = AppLogger.sanitizeForCrashlytics(
      reason: 'Falha operacional fixa',
      error: const SensitiveFailure(
        'firebase-id-token-secret sensitive-uid '
        'user@example.com private-payload',
      ),
      stackTrace: StackTrace.fromString('stack seguro'),
      fatal: false,
    );

    final serialized = '${report.error} ${report.reason}';
    for (final secret in secrets) {
      expect(serialized, isNot(contains(secret)));
    }
    expect(report.error.toString(), 'HandledError:SensitiveFailure');
  });

  test('preserva razão fixa e stack sem concatenar o erro bruto', () {
    final stack = StackTrace.fromString('stack seguro');
    final report = AppLogger.sanitizeForCrashlytics(
      reason: 'Falha operacional fixa',
      error: const SensitiveFailure('private-payload'),
      stackTrace: stack,
      fatal: false,
    );

    expect(report.reason, 'Falha operacional fixa');
    expect(report.stackTrace, same(stack));
    expect(report.error.toString(), isNot(contains('private-payload')));
  });

  test('mantém fatal e nonfatal distintos', () {
    SanitizedCrashReport report(bool fatal) {
      return AppLogger.sanitizeForCrashlytics(
        reason: 'Falha operacional fixa',
        error: StateError('private-payload'),
        stackTrace: null,
        fatal: fatal,
      );
    }

    expect(report(false).fatal, isFalse);
    expect(report(true).fatal, isTrue);
  });

  test('erro ausente recebe categoria segura', () {
    final report = AppLogger.sanitizeForCrashlytics(
      reason: 'Falha operacional fixa',
      error: null,
      stackTrace: null,
      fatal: false,
    );

    expect(report.error.toString(), 'HandledError:UnknownError');
  });

  test('assinatura existente de AppLogger.e continua disponível', () {
    expect(AppLogger.e, isA<void Function(String, [dynamic, StackTrace?])>());
  });
}

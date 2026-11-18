import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/utils/app_logger.dart';

void main() {
  tearDown(() => AppLogger.configureCrashReporting(null));
  test(
    'domain logging works without initializing Firebase or a remote adapter',
    () {
      AppLogger.configureCrashReporting(null);
      expect(
        () => AppLogger.e('SYNTHETIC-LOCAL-ERROR', StateError('SYNTHETIC')),
        returnsNormally,
      );
      expect(
        () => AppLogger.fatal(
          'SYNTHETIC-FATAL',
          StateError('SYNTHETIC'),
          StackTrace.current,
        ),
        returnsNormally,
      );
    },
  );
  test('crash report keeps the sanitized contract for explicit adapters', () {
    final report = AppLogger.sanitizeForCrashlytics(
      reason: 'synthetic',
      error: StateError('SYNTHETIC-PRIVATE-PAYLOAD'),
      stackTrace: null,
      fatal: false,
    );
    expect(report.error.toString(), contains('StateError'));
    expect(
      report.error.toString(),
      isNot(contains('SYNTHETIC-PRIVATE-PAYLOAD')),
    );
  });
}

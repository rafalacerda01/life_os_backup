import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/features/auth/presentation/providers/auth_provider.dart',
    ).readAsStringSync();
  });

  test('restore é disparado somente no bloco de sessão preparada', () {
    final methodStart = source.indexOf(
      'Future<bool> _prepareAuthenticatedSession',
    );
    final methodEnd = source.indexOf(
      '// --- Métodos de Autenticação e Perfil ---',
      methodStart,
    );
    final method = source.substring(methodStart, methodEnd);
    final preparedBlock = RegExp(
      r'if \(isPrepared\) \{([\s\S]*?)\n    \}',
    ).firstMatch(method);

    expect(preparedBlock, isNotNull);
    final block = preparedBlock!.group(1)!;
    final ownerAssignment = block.indexOf('_activeLocalSessionUid = uid;');
    final restore = block.indexOf(
      '_restoreCycleReminderForPreparedSession(uid);',
    );
    expect(ownerAssignment, greaterThanOrEqualTo(0));
    expect(restore, greaterThan(ownerAssignment));
  });

  test('startup e listener usam o mesmo prepare central', () {
    final checkCurrentUserStart = source.indexOf(
      'Future<void> checkCurrentUser()',
    );
    final loginStart = source.indexOf(
      'Future<void> login(',
      checkCurrentUserStart,
    );
    final checkCurrentUser = source.substring(
      checkCurrentUserStart,
      loginStart,
    );
    final listenerStart = source.indexOf('void _initializeAuthListener()');
    final hydrationStart = source.indexOf(
      'void _scheduleHydration',
      listenerStart,
    );
    final listener = source.substring(listenerStart, hydrationStart);

    expect(checkCurrentUser, contains('_prepareAuthenticatedSession'));
    expect(listener, contains('_prepareAuthenticatedSession'));
    expect(source, isNot(contains('requestExactAlarmPermission')));
    expect(source, isNot(contains('requestPermissions')));
  });
}

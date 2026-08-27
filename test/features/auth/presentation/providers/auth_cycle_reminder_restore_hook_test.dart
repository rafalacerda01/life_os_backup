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
    final actionPrepared = block.indexOf(
      '_notifyCycleReminderActionSessionPrepared(uid);',
    );
    final restore = block.indexOf(
      '_restoreCycleReminderForPreparedSession(uid);',
    );
    expect(ownerAssignment, greaterThanOrEqualTo(0));
    expect(actionPrepared, greaterThan(ownerAssignment));
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

  test('cleanup invalida actions antes de qualquer limpeza crítica', () {
    final methodStart = source.indexOf('Future<void> _performLocalDataClear()');
    final methodEnd = source.indexOf(
      'void _invalidateSessionProviders()',
      methodStart,
    );
    final method = source.substring(methodStart, methodEnd);

    final ownerCapture = method.indexOf(
      'final previousLocalSessionUid = _activeLocalSessionUid;',
    );
    final actionClear = method.indexOf('_clearCycleReminderActionSession();');
    final generationInvalidation = method.indexOf('_sessionGeneration += 1;');
    final hydrationWait = method.indexOf('await hydration.timeout');
    final cycleCleanup = method.indexOf(
      '.cancelAfterCurrentMutations(previousLocalSessionUid);',
    );
    final tokenCleanup = method.indexOf('await secureStorage.deleteToken();');
    final driftCleanup = method.indexOf('await db.clearAllData();');
    final notificationCleanup = method.indexOf(
      'await NotificationService.instance.cancelAllNotifications();',
    );
    final ownerRelease = method.indexOf('_activeLocalSessionUid = null;');

    expect(ownerCapture, greaterThanOrEqualTo(0));
    expect(actionClear, greaterThan(ownerCapture));
    expect(generationInvalidation, greaterThan(actionClear));
    expect(hydrationWait, greaterThan(actionClear));
    expect(cycleCleanup, greaterThan(hydrationWait));
    expect(tokenCleanup, greaterThan(cycleCleanup));
    expect(tokenCleanup, greaterThan(actionClear));
    expect(driftCleanup, greaterThan(actionClear));
    expect(notificationCleanup, greaterThan(cycleCleanup));
    expect(ownerRelease, greaterThan(notificationCleanup));
  });

  test('troca A para B aguarda cleanup antes do novo ownership local', () {
    final methodStart = source.indexOf(
      'Future<bool> _prepareAuthenticatedSession',
    );
    final methodEnd = source.indexOf(
      'void _notifyCycleReminderActionSessionPrepared',
      methodStart,
    );
    final method = source.substring(methodStart, methodEnd);

    final localOwnerRead = method.indexOf(
      'final localSessionUid = _activeLocalSessionUid;',
    );
    final ownerMismatch = method.indexOf('localSessionUid != uid');
    final cleanupWait = method.indexOf('await _clearLocalData();');
    final ownerAssignment = method.indexOf('_activeLocalSessionUid = uid;');

    expect(localOwnerRead, greaterThanOrEqualTo(0));
    expect(ownerMismatch, greaterThan(localOwnerRead));
    expect(cleanupWait, greaterThan(ownerMismatch));
    expect(ownerAssignment, greaterThan(cleanupWait));
  });

  test('session clear usa o coordinator e prepare continua centralizado', () {
    final clearStart = source.indexOf(
      'void _clearCycleReminderActionSession()',
    );
    final restoreStart = source.indexOf(
      'void _restoreCycleReminderForPreparedSession',
      clearStart,
    );
    final clearMethod = source.substring(clearStart, restoreStart);

    expect(clearMethod, contains('.onSessionCleared();'));
    expect(source, contains('_notifyCycleReminderActionSessionPrepared(uid);'));
    expect(source, contains('_restoreCycleReminderForPreparedSession(uid);'));
  });
}

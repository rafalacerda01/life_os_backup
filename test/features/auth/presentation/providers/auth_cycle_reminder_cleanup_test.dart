import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/errors/failure.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/core/storage/secure_storage_service.dart';
import 'package:life_os/features/auth/data/local/auth_cleanup_barrier.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/domain/repositories/auth_repository.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/checkin/data/repositories/checkin_repository.dart';
import 'package:life_os/features/checkin/presentation/providers/check_in_provider.dart';
import 'package:life_os/features/finance/data/repositories/finance_repository.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/focus/data/repositories/focus_repository.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_coordinator.dart';
import 'package:life_os/features/health/services/cycle_reminder_mutation_gate.dart';
import 'package:life_os/features/health/services/cycle_reminder_notification_lifecycle.dart';
import 'package:life_os/features/health/services/cycle_reminder_operation_epoch.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_authority.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_cleanup.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_reconciler.dart';
import 'package:life_os/features/health/services/medication_reminder_lifecycle.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';
import 'package:life_os/features/premium/data/repositories/google_play_premium_repository.dart';
import 'package:life_os/features/premium/domain/entities/premium_plan_offer_entity.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';
import 'package:life_os/features/premium/domain/repositories/i_premium_repository.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/notifications/data/repositories/notifications_repository.dart';
import 'package:multiple_result/multiple_result.dart';

import '../../../../helpers/recording_analytics_platform.dart';
import '../../../../helpers/test_user_database_factory.dart';

class _FocusTimer implements Timer {
  _FocusTimer(this.callback);
  final void Function(Timer) callback;
  @override
  int tick = 0;
  @override
  bool isActive = true;
  @override
  void cancel() => isActive = false;
  void finish() {
    tick = 420;
    callback(this);
  }
}

const _userA = UserEntity(
  uid: 'user-a',
  email: 'a@example.invalid',
  displayName: 'A',
  isPremium: false,
  xp: 0,
  level: 1,
  streak: 0,
);

const _userB = UserEntity(
  uid: 'user-b',
  email: 'b@example.invalid',
  displayName: 'B',
  isPremium: false,
  xp: 0,
  level: 1,
  streak: 0,
);

class _FirebaseUser extends Fake implements User {
  _FirebaseUser(
    this.uid, {
    this.email,
    this.displayName,
    this.photoURL,
    this.tokenError,
    this.onGetIdToken,
  });

  @override
  final String uid;
  @override
  final String? email;
  @override
  final String? displayName;
  @override
  final String? photoURL;
  final Object? tokenError;
  final Future<void> Function()? onGetIdToken;
  int tokenCalls = 0;

  @override
  List<UserInfo> get providerData => const <UserInfo>[];

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    tokenCalls += 1;
    await onGetIdToken?.call();
    if (tokenError != null) throw tokenError!;
    return 'test-token';
  }
}

class _FirebaseAuth extends Fake implements FirebaseAuth {
  _FirebaseAuth(this.user);

  final StreamController<User?> _changes = StreamController<User?>.broadcast();
  User? user;
  int signOutCalls = 0;

  @override
  User? get currentUser => user;

  @override
  Stream<User?> authStateChanges() => _changes.stream;

  @override
  Future<void> signOut() async {
    signOutCalls += 1;
    user = null;
  }

  void emit(User? next) {
    user = next;
    _changes.add(next);
  }

  Future<void> close() => _changes.close();
}

class _ScriptedFirestore extends Fake implements FirebaseFirestore {
  _ScriptedFirestore({
    Iterable<Object?> clearResults = const <Object?>[null],
    Iterable<Object?> terminateResults = const <Object?>[null],
  }) : _clearResults = clearResults.toList(),
       _terminateResults = terminateResults.toList();

  final List<Object?> _clearResults;
  final List<Object?> _terminateResults;
  int clearPersistenceCalls = 0;
  int terminateCalls = 0;

  @override
  Future<void> clearPersistence() async {
    clearPersistenceCalls += 1;
    final result = _clearResults.isEmpty ? null : _clearResults.removeAt(0);
    if (result != null) throw result;
  }

  @override
  Future<void> terminate() async {
    terminateCalls += 1;
    final result = _terminateResults.isEmpty
        ? null
        : _terminateResults.removeAt(0);
    if (result != null) throw result;
  }
}

class _AuthRepository extends Fake implements AuthRepository {
  _AuthRepository(
    this.auth, {
    this.failSignOut = false,
    this.deleteStarted,
    this.allowDelete,
    this.completeDeletionBySigningOut = false,
    this.onGetCurrentUser,
    this.currentUserFailure,
  });

  final _FirebaseAuth auth;
  bool failSignOut;
  final Completer<void>? deleteStarted;
  final Completer<void>? allowDelete;
  final bool completeDeletionBySigningOut;
  final Future<void> Function(String userId)? onGetCurrentUser;
  final Failure? currentUserFailure;
  int signOutCalls = 0;
  final List<String> deletedExpectedUserIds = <String>[];

  @override
  Future<Result<UserEntity, Failure>> getCurrentUser() async {
    final userId = auth.currentUser?.uid;
    final failure = currentUserFailure;
    if (failure != null) {
      if (userId != null) await onGetCurrentUser?.call(userId);
      return Error(failure);
    }
    if (userId == null) {
      return const Error(AuthFailure('not authenticated'));
    }
    await onGetCurrentUser?.call(userId);
    return Success(userId == _userB.uid ? _userB : _userA);
  }

  @override
  Future<Result<void, Failure>> deleteAccount({
    required String expectedUid,
  }) async {
    deletedExpectedUserIds.add(expectedUid);
    deleteStarted?.complete();
    await allowDelete?.future;
    if (completeDeletionBySigningOut) auth.emit(null);
    return const Success(null);
  }

  @override
  Future<Result<void, Failure>> signOut() async {
    signOutCalls += 1;
    if (failSignOut) {
      return const Error(AuthFailure('private sign-out failure'));
    }
    auth.emit(null);
    return const Success(null);
  }
}

class _MemoryBarrierStorage
    implements AuthCleanupBarrierStorage, CycleReminderPreferencesStorage {
  _MemoryBarrierStorage([Map<String, String>? values])
    : values = values ?? <String, String>{};

  final Map<String, String> values;
  bool throwOnWrite = false;
  bool throwOnDelete = false;
  int writeCalls = 0;
  int deleteCalls = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writeCalls += 1;
    if (throwOnWrite) throw StateError('private barrier write failure');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleteCalls += 1;
    if (throwOnDelete) throw StateError('private barrier delete failure');
    values.remove(key);
  }
}

class _SecureStorage extends Fake implements FlutterSecureStorage {
  final values = <String, String>{};
  int writeCalls = 0;
  int deleteCalls = 0;
  Object? writeError;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writeCalls += 1;
    if (writeError != null) throw writeError!;
    if (value != null) values[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deleteCalls += 1;
    values.remove(key);
  }
}

class _SyncManager extends Fake implements SyncManager {
  bool shouldDrain = true;
  int calls = 0;
  Future<bool> Function()? onProcess;
  Future<bool> Function()? hasRejected;

  @override
  Future<bool> prepareForLocalDataDiscard() async {
    if (await hasRejected?.call() ?? false) return false;
    if (!await processPendingItems()) return false;
    return !(await hasRejected?.call() ?? false);
  }

  @override
  Future<bool> processPendingItems() {
    calls += 1;
    return onProcess?.call() ?? Future.value(shouldDrain);
  }
}

class _CheckInRepository extends Fake implements CheckInRepository {
  bool shouldDrain = true;
  int drainCalls = 0;
  int pullCalls = 0;
  Future<bool> Function()? onDrain;
  Future<void> Function()? onPull;

  @override
  Future<bool> syncPendingCheckIns() {
    drainCalls += 1;
    return onDrain?.call() ?? Future.value(shouldDrain);
  }

  @override
  Future<void> syncCheckinsFromFirebaseToLocal() {
    pullCalls += 1;
    return onPull?.call() ?? Future.value();
  }
}

class _FinanceRepository extends Fake implements FinanceRepository {
  _FinanceRepository(this.events);

  final List<String> events;
  final pulled = Completer<void>();

  @override
  Future<void> syncTransactionsFromFirestore() async {
    events.add('finance-pull');
    if (!pulled.isCompleted) pulled.complete();
  }
}

class _SessionCoordinator extends Fake
    implements CycleReminderActionSessionCoordinator {
  _SessionCoordinator(this.authority, this.epoch);

  final CycleReminderSessionAuthority authority;
  final CycleReminderOperationEpoch epoch;
  final List<String> preparedUserIds = <String>[];
  Completer<void>? sessionCleared;

  @override
  Future<void> onSessionPrepared(String userId) async {
    authority.prepare(userId);
    preparedUserIds.add(userId);
  }

  @override
  void onSessionCleared() {
    final previousUserId = authority.clear();
    if (previousUserId != null) epoch.invalidate(previousUserId);
    if (sessionCleared?.isCompleted == false) sessionCleared!.complete();
  }
}

class _SessionRestore extends Fake implements CycleReminderSessionRestore {
  _SessionRestore(this.store, {this.delegate});

  final CycleReminderPreferencesStore store;
  final CycleReminderSessionRestore? delegate;
  final List<String> restoredUserIds = [];
  final List<Map<String, Object>?> loadedPreferences = [];
  Future<void> lastRestore = Future<void>.value();

  @override
  Future<void> restoreForSession(String userId) {
    restoredUserIds.add(userId);
    return lastRestore = () async {
      loadedPreferences.add((await store.load(userId))?.toJson());
      await delegate?.restoreForSession(userId);
    }();
  }
}

class _ScriptedLifecycle extends Fake
    implements CycleReminderNotificationLifecycle {
  _ScriptedLifecycle(Iterable<int> cancellationResults, {this.events})
    : _cancellationResults = cancellationResults.toList();

  final List<int> _cancellationResults;
  final List<String>? events;
  int cancellationCalls = 0;
  final List<String> cancelledUserIds = <String>[];
  final List<String> rebuiltUserIds = [];
  final List<Map<String, Object>> rebuiltPreferences = [];

  @override
  Future<CycleReminderRebuildResult> rebuildCycleReminders(
    String userId,
    CycleReminderPreferences preferences, {
    CycleReminderRebuildGuard? shouldContinue,
  }) async {
    expect(shouldContinue!(), isTrue);
    rebuiltUserIds.add(userId);
    rebuiltPreferences.add(preferences.toJson());
    return const CycleReminderRebuildResult(
      eligible: 1,
      scheduled: 1,
      failed: 0,
      cancellationFailed: 0,
    );
  }

  @override
  Future<int> cancelAllCycleReminders(String userId) async {
    cancellationCalls += 1;
    cancelledUserIds.add(userId);
    events?.add('cleanup:$userId');
    return _cancellationResults.removeAt(0);
  }
}

class _ScriptedTokenRotation {
  _ScriptedTokenRotation({
    this.failuresRemaining = 0,
    this.events,
    this.callStarted,
    this.allowCall,
  });

  int failuresRemaining;
  final List<String>? events;
  final Completer<void>? callStarted;
  final Completer<void>? allowCall;
  int calls = 0;
  int tokenVersion = 1;
  final List<String> userIds = <String>[];

  Future<void> call(String userId) async {
    calls += 1;
    userIds.add(userId);
    events?.add('rotate:$userId');
    final started = callStarted;
    if (started != null && !started.isCompleted) started.complete();
    await allowCall?.future;
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw StateError('private token rotation failure');
    }
    tokenVersion += 1;
  }
}

class _ScriptedPreferencesDeletion {
  _ScriptedPreferencesDeletion(
    this.store, {
    this.failuresRemaining = 0,
    this.events,
  });

  final CycleReminderPreferencesStore store;
  int failuresRemaining;
  final List<String>? events;
  int calls = 0;
  final List<String> userIds = <String>[];

  Future<void> call(String userId) async {
    calls += 1;
    userIds.add(userId);
    events?.add('delete:$userId');
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw StateError('private preferences deletion failure');
    }
    await store.delete(userId);
  }
}

class _ScriptedNotificationCleanup {
  _ScriptedNotificationCleanup({this.failuresRemaining = 0});

  int failuresRemaining;
  int calls = 0;

  Future<void> call() async {
    calls += 1;
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw StateError('private notification cleanup failure');
    }
  }
}

class _ObservedNotificationEffects extends NotificationRemoteEffectsBarrier {
  final drainStarted = Completer<void>();

  @override
  Future<void> sealAndDrain() {
    if (!drainStarted.isCompleted) drainStarted.complete();
    return super.sealAndDrain();
  }
}

class _SettingsMedicationStore extends NotificationPreferencesStore {
  bool enabled = false;

  @override
  Future<NotificationPreferences> load() async => NotificationPreferences(
    allNotifications: true,
    studyReminders: true,
    habitReminders: true,
    medicationReminders: enabled,
  );

  @override
  Future<void> save(String key, bool value) async {
    if (key == NotificationPreferenceKeys.medicationReminders) enabled = value;
  }
}

class _SettingsNotifications extends NotificationService {
  int permissionCalls = 0;
  int exactCalls = 0;
  @override
  Future<bool> requestPermissions({String? preferenceKey}) async {
    permissionCalls++;
    return true;
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    exactCalls++;
    return false;
  }
}

class _SettingsMedicationLifecycle implements MedicationReminderLifecycle {
  final started = Completer<void>();
  final release = Completer<void>();
  bool active = false;
  int rebuildCalls = 0;
  int cancelCalls = 0;
  bool Function()? guard;

  @override
  Future<void> cancelAllMedicationReminders({
    bool Function()? shouldContinue,
  }) async {
    cancelCalls++;
    if (shouldContinue!()) active = false;
  }

  @override
  Future<MedicationReminderRebuildResult> rebuildMedicationReminders({
    bool Function()? shouldContinue,
  }) async {
    guard = shouldContinue;
    rebuildCalls++;
    if (!started.isCompleted) started.complete();
    await release.future;
    active = shouldContinue!();
    return MedicationReminderRebuildResult(
      eligible: 1,
      scheduled: active ? 1 : 0,
      failed: 0,
    );
  }
}

class _Harness {
  _Harness._({
    required this.auth,
    required this.repository,
    required this.firestore,
    required this.databaseFactory,
    required this.mutationGate,
    required this.authority,
    required this.epoch,
    required this.lifecycle,
    required this.rotation,
    required this.preferencesDeletion,
    required this.cycleStore,
    required this.cycleRestore,
    required this.settingsNotifications,
    required this.notificationCleanup,
    required this.coordinator,
    required this.barrierStorage,
    required this.syncManager,
    required this.container,
  });

  final _FirebaseAuth auth;
  final _AuthRepository repository;
  final _ScriptedFirestore firestore;
  final TestUserDatabaseFactory databaseFactory;
  AppDatabase get database {
    final last = databaseFactory.last;
    if (last == null) {
      return auth.currentUser == null
          ? databaseFactory.inspectClosed(_userA.uid, () => null)
          : databaseFactory.inspect(auth.currentUser!.uid);
    }
    if (!last.closed && auth.currentUser?.uid == last.identity!.uid)
      return last;
    return databaseFactory.inspectClosed(
      last.identity!.uid,
      () => auth.currentUser?.uid,
    );
  }

  final CycleReminderMutationGate mutationGate;
  final CycleReminderSessionAuthority authority;
  final CycleReminderOperationEpoch epoch;
  final _ScriptedLifecycle lifecycle;
  final _ScriptedTokenRotation rotation;
  final _ScriptedPreferencesDeletion preferencesDeletion;
  final CycleReminderPreferencesStore cycleStore;
  final _SessionRestore cycleRestore;
  final _SettingsNotifications settingsNotifications;
  final _ScriptedNotificationCleanup notificationCleanup;
  final _SessionCoordinator coordinator;
  final _MemoryBarrierStorage barrierStorage;
  final _SyncManager syncManager;
  final ProviderContainer container;

  AuthNotifier get notifier => container.read(authNotifierProvider.notifier);
  AuthState get state => container.read(authNotifierProvider);

  Future<T> waitForState<T extends AuthState>() async {
    final current = state;
    if (current is T) return current;

    final completer = Completer<T>();
    late final ProviderSubscription<AuthState> subscription;
    subscription = container.listen<AuthState>(authNotifierProvider, (_, next) {
      if (next is T && !completer.isCompleted) {
        completer.complete(next);
        subscription.close();
      }
    });
    return completer.future;
  }

  Future<PendingAuthCleanup?> readPendingCleanup() {
    return AuthCleanupBarrierStore(barrierStorage).readPending();
  }

  static Future<_Harness> create(
    Iterable<int> cancellationResults, {
    int rotationFailures = 0,
    int preferenceDeletionFailures = 0,
    int notificationCleanupFailures = 0,
    bool failSignOut = false,
    _MemoryBarrierStorage? barrierStorage,
    _ScriptedTokenRotation? tokenRotation,
    String? firebaseUserId = 'user-a',
    User? firebaseUser,
    Failure? currentUserFailure,
    FlutterSecureStorage? secureStorage,
    _SyncManager? syncManagerOverride,
    bool waitForAuthentication = true,
    Completer<void>? deleteStarted,
    Completer<void>? allowDelete,
    bool completeDeletionBySigningOut = false,
    NotificationRemoteEffectsBarrier? notificationEffects,
    _SettingsMedicationLifecycle? medicationLifecycle,
    _SettingsMedicationStore? medicationPreferences,
    _ScriptedFirestore? firestore,
    Future<void> Function(String userId, AppDatabase database)?
    onGetCurrentUser,
    CheckInRepository? checkInRepository,
    FinanceRepository? financeRepository,
    List<String>? lifecycleEvents,
    IPremiumRepository Function(String? uid)? createPremiumRepository,
    FocusPeriodicTimerFactory? focusTimerFactory,
    Future<void> Function(AppDatabase)? seedBeforeAuth,
    bool restoreCycleSchedules = false,
  }) async {
    final auth = _FirebaseAuth(
      firebaseUser ??
          (firebaseUserId == null ? null : _FirebaseUser(firebaseUserId)),
    );
    final databaseFactory = TestUserDatabaseFactory();
    final database = databaseFactory.inspect(firebaseUserId ?? _userA.uid);
    await seedBeforeAuth?.call(database);
    database.localMutations.bindSessionReader(() => auth.currentUser?.uid);
    final localFirestore = firestore ?? _ScriptedFirestore();
    final repository = _AuthRepository(
      auth,
      failSignOut: failSignOut,
      deleteStarted: deleteStarted,
      allowDelete: allowDelete,
      completeDeletionBySigningOut: completeDeletionBySigningOut,
      currentUserFailure: currentUserFailure,
      onGetCurrentUser: onGetCurrentUser == null
          ? null
          : (userId) =>
                onGetCurrentUser(userId, databaseFactory.inspect(userId)),
    );
    final authority = CycleReminderSessionAuthority();
    final epoch = CycleReminderOperationEpoch();
    final mutationGate = CycleReminderMutationGate(database.localMutations);
    final lifecycle = _ScriptedLifecycle(
      cancellationResults,
      events: lifecycleEvents,
    );
    final rotation =
        tokenRotation ??
        _ScriptedTokenRotation(failuresRemaining: rotationFailures);
    final cycleStore = CycleReminderPreferencesStore(_MemoryBarrierStorage());
    for (final uid in [_userA.uid, _userB.uid]) {
      await cycleStore.save(
        uid,
        CycleReminderPreferences(
          enabled: true,
          type: CycleReminderType.personal,
          hour: uid == _userA.uid ? 16 : 8,
          minute: 35,
          frequency: CycleReminderFrequency.specificWeekdays,
          weekdays: {1, 3, 5},
          privacyMode: CycleReminderPrivacyMode.custom,
          customTitle: 'Fixture title',
          customBody: 'Fixture body',
        ),
      );
    }
    final preferencesDeletion = _ScriptedPreferencesDeletion(
      cycleStore,
      failuresRemaining: preferenceDeletionFailures,
      events: lifecycleEvents,
    );
    final notificationCleanup = _ScriptedNotificationCleanup(
      failuresRemaining: notificationCleanupFailures,
    );
    final durableStorage = barrierStorage ?? _MemoryBarrierStorage();
    final syncManager = syncManagerOverride ?? _SyncManager();
    final coordinator = _SessionCoordinator(authority, epoch);
    final cycleRestore = _SessionRestore(
      cycleStore,
      delegate: restoreCycleSchedules
          ? CycleReminderSessionReconciler(
              loadCyclePreferences: cycleStore.load,
              loadGlobalNotifications: () async => true,
              currentUserId: () =>
                  authority.admittedUserId(auth.currentUser?.uid),
              lifecycle: lifecycle,
              operationEpoch: epoch,
            )
          : null,
    );
    final settingsNotifications = _SettingsNotifications();
    final cleanup = CycleReminderSessionCleanup(
      mutationGate,
      lifecycle,
      rotateActionToken: rotation.call,
      deletePreferences: preferencesDeletion.call,
    );
    final container = ProviderContainer(
      overrides: [
        if (focusTimerFactory != null) ...[
          focusPeriodicTimerFactoryProvider.overrideWithValue(
            focusTimerFactory,
          ),
          focusRepositoryProvider.overrideWithValue(
            FocusRepository(database, localFirestore, auth, syncManager),
          ),
          tasksRepositoryProvider.overrideWithValue(
            TasksRepository(database, localFirestore, auth),
          ),
          analyticsServiceProvider.overrideWithValue(
            AnalyticsService(platform: RecordingAnalyticsPlatform()),
          ),
        ],
        if (createPremiumRepository != null)
          premiumRepositoryProvider.overrideWith((ref) {
            final premium = createPremiumRepository(auth.currentUser?.uid);
            ref.onDispose(premium.dispose);
            return premium;
          }),
        firebaseAuthProvider.overrideWithValue(auth),
        firestoreProvider.overrideWithValue(localFirestore),
        authRepositoryProvider.overrideWithValue(repository),
        secureStorageProvider.overrideWithValue(
          secureStorage ?? _SecureStorage(),
        ),
        userDatabaseFactoryProvider.overrideWithValue(databaseFactory),
        if (medicationLifecycle != null) ...[
          medicationReminderLifecycleProvider.overrideWithValue(
            medicationLifecycle,
          ),
          notificationPreferencesStoreProvider.overrideWithValue(
            medicationPreferences!,
          ),
          notificationServiceProvider.overrideWithValue(settingsNotifications),
          notificationPreferencesChangedProvider.overrideWithValue(() {}),
        ],
        if (notificationEffects != null)
          notificationRemoteEffectsBarrierProvider.overrideWithValue(
            notificationEffects,
          ),
        syncManagerProvider.overrideWithValue(syncManager),
        checkInRepositoryProvider.overrideWithValue(
          checkInRepository ?? _CheckInRepository(),
        ),
        if (financeRepository != null)
          financeRepositoryProvider.overrideWithValue(financeRepository),
        cycleReminderSessionAuthorityProvider.overrideWithValue(authority),
        cycleReminderOperationEpochProvider.overrideWithValue(epoch),
        cycleReminderMutationGateProvider.overrideWithValue(mutationGate),
        cycleReminderActionCoordinatorProvider.overrideWithValue(coordinator),
        cycleReminderSessionReconcilerProvider.overrideWithValue(cycleRestore),
        cycleReminderSessionCleanupProvider.overrideWithValue(cleanup),
        authNotificationCleanupProvider.overrideWithValue(
          notificationCleanup.call,
        ),
        authCleanupBarrierProvider.overrideWithValue(
          AuthCleanupBarrierStore(durableStorage),
        ),
        cycleReminderFirebaseUserIdReaderProvider.overrideWithValue(
          () => auth.currentUser?.uid,
        ),
      ],
    );

    if (waitForAuthentication) {
      final authenticated = Completer<void>();
      container.listen<AuthState>(authNotifierProvider, (_, next) {
        if (next is AuthAuthenticated && !authenticated.isCompleted) {
          authenticated.complete();
        }
      }, fireImmediately: true);
      await authenticated.future;
    } else {
      container.read(authNotifierProvider);
    }

    return _Harness._(
      auth: auth,
      repository: repository,
      firestore: localFirestore,
      databaseFactory: databaseFactory,
      mutationGate: mutationGate,
      authority: authority,
      epoch: epoch,
      lifecycle: lifecycle,
      rotation: rotation,
      preferencesDeletion: preferencesDeletion,
      cycleStore: cycleStore,
      cycleRestore: cycleRestore,
      settingsNotifications: settingsNotifications,
      notificationCleanup: notificationCleanup,
      coordinator: coordinator,
      barrierStorage: durableStorage,
      syncManager: syncManager,
      container: container,
    );
  }

  Future<void> dispose() async {
    final databases = container.read(sessionDatabaseCoordinatorProvider);
    container.dispose();
    await databases.dispose();
    await databaseFactory.dispose();
    await auth.close();
  }
}

class _SessionPremiumRepository implements IPremiumRepository {
  _SessionPremiumRepository(this.uid);

  final String? uid;
  final statuses = StreamController<PremiumStatusEntity>.broadcast();
  Completer<bool>? activePurchase;
  bool disposed = false;

  @override
  Stream<PremiumStatusEntity> watchPremiumStatus() => statuses.stream;
  @override
  Future<List<PremiumPlanOfferEntity>> loadAvailablePlans() async => [];
  @override
  Future<bool> purchasePlan(PremiumTier tier) {
    activePurchase = Completer<bool>();
    return activePurchase!.future;
  }

  @override
  Future<bool> restorePurchases() async => false;
  @override
  void dispose() {
    disposed = true;
    final active = activePurchase;
    if (active != null && !active.isCompleted) {
      active.completeError(
        const PremiumPurchaseException(
          'PURCHASE_INTERRUPTED',
          'A operação de compra foi interrompida.',
        ),
      );
    }
    unawaited(statuses.close());
  }
}

Future<void> seedSessionRows(AppDatabase db, String uid) async {
  await db
      .into(db.taskTable)
      .insert(
        TaskTableCompanion.insert(
          id: '$uid-task',
          title: 'Fixture',
          priority: 'normal',
          date: DateTime(2026, 10, 2),
        ),
      );
  await db
      .into(db.notificationsTable)
      .insert(
        NotificationsTableCompanion.insert(
          id: '$uid-notification',
          title: 'Fixture',
          description: 'Fixture',
          priority: 'normal',
          moduleType: 'health',
          route: '/health',
          createdAt: DateTime(2026, 10, 2),
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Auth logout drains and invalidates the same medication job started by Settings',
    () async {
      final medication = _SettingsMedicationLifecycle();
      final harness = await _Harness.create(
        [0],
        medicationLifecycle: medication,
        medicationPreferences: _SettingsMedicationStore(),
      );
      addTearDown(harness.dispose);
      final reconciler = harness.container.read(
        medicationReminderSessionReconcilerProvider,
      );
      await reconciler.drain();
      harness.coordinator.sessionCleared = Completer<void>();
      await harness.database
          .into(harness.database.medications)
          .insert(
            MedicationsCompanion.insert(
              firestoreId: 'medication-a',
              name: 'Fixture',
              startDate: DateTime(2026, 10, 3, 21),
            ),
          );
      await harness.container.read(notificationsProvider.future);
      final toggle = harness.container
          .read(notificationsProvider.notifier)
          .toggleMedication(true);
      await medication.started.future;
      expect(medication.guard!(), isTrue);
      final logout = harness.notifier.logout();
      await harness.coordinator.sessionCleared!.future;
      expect(harness.auth.currentUser?.uid, 'user-a');
      expect(medication.guard!(), isFalse);
      expect(harness.repository.signOutCalls, 0);
      expect(harness.firestore.clearPersistenceCalls, 0);
      expect(
        await harness.database.select(harness.database.medications).get(),
        hasLength(1),
      );
      medication.release.complete();
      await toggle;
      await logout;
      expect(medication.active, isFalse);
      expect(harness.repository.signOutCalls, 1);
      expect(harness.state, isA<AuthUnauthenticated>());
      expect(
        await harness.database.select(harness.database.medications).get(),
        hasLength(1),
      );
    },
  );

  test(
    'logout drains notification effects before non-destructive isolation',
    () async {
      final effects = _ObservedNotificationEffects();
      final harness = await _Harness.create([0], notificationEffects: effects);
      addTearDown(harness.dispose);
      await harness.database
          .into(harness.database.taskTable)
          .insert(
            TaskTableCompanion.insert(
              id: 'local-a',
              title: 'Fixture',
              priority: 'normal',
              date: DateTime(2026, 10, 3),
            ),
          );
      final release = Completer<void>();
      final write = effects.track(() => release.future);
      final logout = harness.notifier.logout();
      await effects.drainStarted.future;
      expect(harness.repository.signOutCalls, 0);
      expect(harness.firestore.clearPersistenceCalls, 0);
      expect(
        await harness.database.select(harness.database.taskTable).get(),
        hasLength(1),
      );
      expect(effects.resume(), isFalse);
      release.complete();
      await write;
      await logout;
      expect(harness.repository.signOutCalls, 1);
      expect(harness.state, isA<AuthUnauthenticated>());
      expect(
        await harness.database.select(harness.database.taskTable).get(),
        hasLength(1),
      );
      expect(effects.isCurrent(effects.generation), isFalse);
    },
  );

  test(
    'account deletion drains notifications before invoking remote deletion',
    () async {
      final effects = _ObservedNotificationEffects();
      final harness = await _Harness.create(
        [0],
        notificationEffects: effects,
        completeDeletionBySigningOut: true,
      );
      addTearDown(harness.dispose);
      final release = Completer<void>();
      var remoteWriteCompleted = false;
      final write = effects.track(() async {
        await release.future;
        remoteWriteCompleted = true;
      });
      final deletion = harness.notifier.deleteAccount();
      await effects.drainStarted.future;
      expect(remoteWriteCompleted, isFalse);
      expect(harness.repository.deletedExpectedUserIds, isEmpty);
      expect(harness.firestore.clearPersistenceCalls, 0);
      release.complete();
      await write;
      await deletion;
      expect(remoteWriteCompleted, isTrue);
      expect(harness.repository.deletedExpectedUserIds, [_userA.uid]);
      expect(harness.state, isA<AuthUnauthenticated>());
      expect(effects.isCurrent(effects.generation), isFalse);
    },
  );

  test(
    'session B is prepared only after draining notification effects of A',
    () async {
      final effects = _ObservedNotificationEffects();
      final harness = await _Harness.create([0], notificationEffects: effects);
      addTearDown(harness.dispose);
      final release = Completer<void>();
      final write = effects.track(() => release.future);
      harness.auth.user = _FirebaseUser(_userB.uid);
      final preparation = harness.notifier.checkCurrentUser();
      await effects.drainStarted.future;
      expect((harness.state as AuthAuthenticated).user.uid, _userA.uid);
      expect(harness.firestore.clearPersistenceCalls, 0);
      release.complete();
      await write;
      await preparation;
      expect(harness.auth.currentUser?.uid, _userB.uid);
      expect((harness.state as AuthAuthenticated).user.uid, _userB.uid);
      expect(harness.firestore.clearPersistenceCalls, 1);
      expect(effects.isCurrent(effects.generation), isTrue);
    },
  );

  HealthRepository healthFor(_Harness harness) => HealthRepository(
    NotificationService.instance,
    harness.firestore,
    harness.auth,
    harness.database,
    harness.syncManager,
    now: () => DateTime(2026, 10, 2, 12),
  );

  test('sign-out failure preserves A and reopens domain writes', () async {
    final harness = await _Harness.create(
      [0],
      failSignOut: true,
      syncManagerOverride: _SyncManager()..shouldDrain = false,
    );
    addTearDown(harness.dispose);
    final health = healthFor(harness);
    expect(
      await health.updatePillStatus(true, expectedUid: _userA.uid),
      isTrue,
    );
    expect(
      await harness.database.getPendingSyncItems(_userA.uid),
      hasLength(1),
    );
    harness.syncManager.shouldDrain = true;
    await harness.notifier.logout();
    expect(harness.state, isA<AuthError>());
    expect(harness.auth.currentUser?.uid, _userA.uid);
    expect(harness.repository.signOutCalls, 1);
    final marker = await harness.readPendingCleanup();
    expect(marker, isNull);
    expect(
      await harness.database.select(harness.database.healthEntries).get(),
      hasLength(1),
    );
    expect(
      await harness.database.select(harness.database.syncQueueTable).get(),
      hasLength(1),
    );
    expect(
      await health.updatePillStatus(false, expectedUid: _userA.uid),
      isTrue,
    );
    expect(await harness.readPendingCleanup(), marker);
    expect(
      await harness.database.select(harness.database.healthEntries).get(),
      hasLength(1),
    );
    expect(
      await harness.database.select(harness.database.syncQueueTable).get(),
      hasLength(2),
    );
  });

  test('post-quiesce waiter resumes A after sign-out failure', () async {
    final checkIns = _CheckInRepository();
    final harness = await _Harness.create(
      [0],
      failSignOut: true,
      checkInRepository: checkIns,
      syncManagerOverride: _SyncManager()..shouldDrain = false,
    );
    addTearDown(harness.dispose);
    harness.syncManager.shouldDrain = true;
    final started = Completer<void>();
    final release = Completer<void>();
    checkIns.onDrain = () async {
      started.complete();
      await release.future;
      return true;
    };
    final logout = harness.notifier.logout();
    await started.future;
    var entered = false;
    final waiting = harness.database.localMutations.run(() async {
      entered = true;
      return healthFor(harness).updatePillStatus(true, expectedUid: _userA.uid);
    });

    expect(entered, isFalse);
    release.complete();
    await logout;
    expect(await waiting, isTrue);
    expect(entered, isTrue);
    expect(harness.state, isA<AuthError>());
    expect(await harness.readPendingCleanup(), isNull);
    expect(
      await harness.database.select(harness.database.healthEntries).get(),
      hasLength(1),
    );
    expect(
      await harness.database.select(harness.database.syncQueueTable).get(),
      hasLength(1),
    );
  });

  test(
    'failed sign-out restores cycle and medication hooks on the same A database',
    () async {
      final medication = _SettingsMedicationLifecycle()..release.complete();
      final preferences = _SettingsMedicationStore()..enabled = true;
      final effects = NotificationRemoteEffectsBarrier();
      final harness = await _Harness.create(
        [0],
        failSignOut: true,
        medicationLifecycle: medication,
        medicationPreferences: preferences,
        notificationEffects: effects,
        restoreCycleSchedules: true,
      );
      addTearDown(harness.dispose);
      final database = harness.container.read(databaseProvider);
      await seedSessionRows(database, _userA.uid);
      final reconciler = harness.container.read(
        medicationReminderSessionReconcilerProvider,
      );
      await reconciler.drain();
      await harness.cycleRestore.lastRestore;
      final oldSession = reconciler.captureSession();
      expect(reconciler.isCurrentSession(oldSession), isTrue);
      expect(medication.rebuildCalls, 1);

      await harness.notifier.logout();
      await reconciler.drain();
      await harness.cycleRestore.lastRestore;

      expect(harness.state, isA<AuthError>());
      expect(harness.auth.currentUser?.uid, _userA.uid);
      expect(await harness.readPendingCleanup(), isNull);
      expect(harness.container.read(databaseProvider), same(database));
      expect(harness.databaseFactory.openedUserIds, [_userA.uid]);
      expect(await database.localMutations.run(() async => true), isTrue);
      expect(await database.select(database.taskTable).get(), hasLength(1));
      expect(harness.authority.preparedUserId, _userA.uid);
      expect(harness.coordinator.preparedUserIds, [_userA.uid, _userA.uid]);
      expect(harness.lifecycle.rebuiltUserIds, [_userA.uid, _userA.uid]);
      expect(reconciler.isCurrentSession(oldSession), isFalse);
      expect(reconciler.isCurrentSession(reconciler.captureSession()), isTrue);
      expect(medication.rebuildCalls, 2);
      expect(medication.active, isTrue);
      expect(effects.isCurrent(effects.generation), isTrue);
      expect(harness.settingsNotifications.permissionCalls, 0);
      expect(harness.settingsNotifications.exactCalls, 0);
      expect(harness.preferencesDeletion.userIds, isEmpty);

      await harness.container.read(notificationsProvider.future);
      final settings = harness.container.read(notificationsProvider.notifier);
      await settings.toggleMedication(false);
      expect(medication.active, isFalse);
      await settings.toggleMedication(true);
      expect(medication.active, isTrue);
      expect(medication.rebuildCalls, 3);
      expect(harness.settingsNotifications.permissionCalls, 1);
      expect(harness.settingsNotifications.exactCalls, 1);
    },
  );

  test(
    'failed marker clear after sign-out failure restores no session hooks',
    () async {
      final medication = _SettingsMedicationLifecycle()..release.complete();
      final effects = NotificationRemoteEffectsBarrier();
      final harness = await _Harness.create(
        [0],
        failSignOut: true,
        barrierStorage: _MemoryBarrierStorage()..throwOnDelete = true,
        medicationLifecycle: medication,
        medicationPreferences: _SettingsMedicationStore()..enabled = true,
        notificationEffects: effects,
        restoreCycleSchedules: true,
      );
      addTearDown(harness.dispose);
      final reconciler = harness.container.read(
        medicationReminderSessionReconcilerProvider,
      );
      await reconciler.drain();
      await harness.cycleRestore.lastRestore;
      await harness.notifier.logout();
      await reconciler.drain();
      expect(harness.state, isA<AuthError>());
      expect(harness.auth.currentUser?.uid, _userA.uid);
      expect(await harness.readPendingCleanup(), isNotNull);
      await expectLater(
        harness.databaseFactory.last!.localMutations.run(
          () async => fail('Sealed session must not admit writes'),
          waitForReopen: false,
        ),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(harness.authority.preparedUserId, isNull);
      expect(harness.coordinator.preparedUserIds, [_userA.uid]);
      expect(harness.cycleRestore.restoredUserIds, [_userA.uid]);
      expect(harness.lifecycle.rebuiltUserIds, [_userA.uid]);
      expect(reconciler.captureSession(), isNull);
      expect(medication.rebuildCalls, 1);
      expect(effects.isCurrent(effects.generation), isFalse);
      expect(harness.settingsNotifications.permissionCalls, 0);
      expect(harness.settingsNotifications.exactCalls, 0);
    },
  );

  test('sign-out retry preserves data and relogin uses a new gate', () async {
    final harness = await _Harness.create(
      [0, 0, 0],
      failSignOut: true,
      syncManagerOverride: _SyncManager()..shouldDrain = false,
    );
    addTearDown(harness.dispose);
    harness.syncManager.shouldDrain = true;
    final gate = harness.database.localMutations;
    final old = gate.capture(expectedUid: _userA.uid);
    await harness.notifier.logout();
    final marker = await harness.readPendingCleanup();
    expect(marker, isNull);
    await harness.notifier.logout();
    expect(harness.state, isA<AuthError>());
    expect(harness.repository.signOutCalls, 2);
    expect(harness.auth.currentUser?.uid, _userA.uid);
    expect(await harness.readPendingCleanup(), marker);
    expect(
      await healthFor(harness).updatePillStatus(true, expectedUid: _userA.uid),
      isTrue,
    );
    harness.repository.failSignOut = false;
    await harness.notifier.logout();
    expect(harness.repository.signOutCalls, 3);
    expect(harness.auth.currentUser, isNull);
    expect(harness.state, isA<AuthUnauthenticated>());
    expect(await harness.readPendingCleanup(), isNull);
    expect(
      await harness.database.select(harness.database.healthEntries).get(),
      hasLength(1),
    );
    expect(
      await harness.database.select(harness.database.syncQueueTable).get(),
      hasLength(1),
    );
    await expectLater(
      gate.run(() async {}),
      throwsA(isA<LocalMutationUnavailable>()),
    );

    final started = Completer<void>();
    final release = Completer<void>();
    harness.auth.emit(
      _FirebaseUser(
        _userA.uid,
        onGetIdToken: () async {
          if (!started.isCompleted) started.complete();
          await release.future;
        },
      ),
    );
    await started.future;
    await expectLater(
      healthFor(harness).updatePillStatus(true, expectedUid: _userA.uid),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    release.complete();
    await harness.notifier.checkCurrentUser();
    expect(harness.state, isA<AuthAuthenticated>());
    await expectLater(
      gate.run(
        () =>
            healthFor(harness).updatePillStatus(true, expectedUid: _userA.uid),
        ticket: old,
      ),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    expect(
      await healthFor(harness).updatePillStatus(true, expectedUid: _userA.uid),
      isTrue,
    );
    expect(
      await harness.database.select(harness.database.healthEntries).get(),
      hasLength(1),
    );
    expect(
      await harness.database.getPendingSyncItems(_userA.uid),
      hasLength(1),
    );
  });

  test(
    'restored cold-start session rejects Health writes until prepared',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final harness = await _Harness.create(
        [0],
        firebaseUser: _FirebaseUser(
          _userA.uid,
          onGetIdToken: () async {
            if (!started.isCompleted) started.complete();
            await release.future;
          },
        ),
        syncManagerOverride: _SyncManager()..shouldDrain = false,
        waitForAuthentication: false,
      );
      addTearDown(harness.dispose);
      await started.future;
      expect(harness.auth.currentUser?.uid, _userA.uid);
      expect(harness.state, isNot(isA<AuthAuthenticated>()));
      await expectLater(
        healthFor(harness).updatePillStatus(true, expectedUid: _userA.uid),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(
        await harness.database.select(harness.database.healthEntries).get(),
        isEmpty,
      );
      expect(
        await harness.database.select(harness.database.syncQueueTable).get(),
        isEmpty,
      );
      release.complete();
      await harness.waitForState<AuthAuthenticated>();
      expect(
        await healthFor(
          harness,
        ).updatePillStatus(true, expectedUid: _userA.uid),
        isTrue,
      );
      expect(
        await harness.database.select(harness.database.healthEntries).get(),
        hasLength(1),
      );
      expect(
        await harness.database.getPendingSyncItems(_userA.uid),
        hasLength(1),
      );
    },
  );

  for (final intent in AuthCleanupIntent.values) {
    test(
      'cold-start durable ${intent.name} recovery never admits a domain write',
      () async {
        final storage = _MemoryBarrierStorage();
        final marker = await AuthCleanupBarrierStore(
          storage,
        ).setPending(_userA.uid, intent);
        final started = Completer<void>();
        final release = Completer<void>();
        final harness = await _Harness.create(
          [0],
          barrierStorage: storage,
          tokenRotation: _ScriptedTokenRotation(
            callStarted: started,
            allowCall: release,
          ),
          syncManagerOverride: _SyncManager()..shouldDrain = false,
          waitForAuthentication: false,
        );
        addTearDown(harness.dispose);
        await started.future;
        expect(await harness.readPendingCleanup(), marker);
        expect(
          harness.auth.currentUser?.uid,
          intent == AuthCleanupIntent.logout ? null : _userA.uid,
        );
        expect(harness.coordinator.preparedUserIds, isEmpty);
        if (intent == AuthCleanupIntent.logout) {
          expect(
            await healthFor(
              harness,
            ).updatePillStatus(true, expectedUid: _userA.uid),
            isFalse,
          );
          expect(harness.databaseFactory.openedUserIds, isEmpty);
        } else {
          await expectLater(
            healthFor(harness).updatePillStatus(true, expectedUid: _userA.uid),
            throwsA(isA<LocalMutationUnavailable>()),
          );
        }
        expect(
          await harness.database.select(harness.database.healthEntries).get(),
          isEmpty,
        );
        expect(
          await harness.database.select(harness.database.syncQueueTable).get(),
          isEmpty,
        );
        release.complete();
        await harness.notifier.checkCurrentUser();
        if (intent == AuthCleanupIntent.logout) {
          await harness.notifier.checkCurrentUser();
          expect(harness.auth.currentUser, isNull);
          expect(harness.state, isA<AuthUnauthenticated>());
          expect(harness.coordinator.preparedUserIds, isEmpty);
          await expectLater(
            harness.database.transaction(() async {}),
            throwsA(isA<LocalMutationUnavailable>()),
          );
        } else {
          expect(harness.state, isA<AuthAuthenticated>());
        }
        expect(await harness.readPendingCleanup(), isNull);
        expect(harness.notificationCleanup.calls, greaterThan(0));
        expect(
          await harness.database.select(harness.database.healthEntries).get(),
          isEmpty,
        );
        expect(
          await harness.database.select(harness.database.syncQueueTable).get(),
          isEmpty,
        );
        if (intent == AuthCleanupIntent.isolation) {
          expect(
            await healthFor(
              harness,
            ).updatePillStatus(true, expectedUid: _userA.uid),
            isTrue,
          );
          expect(
            await harness.database.getPendingSyncItems(_userA.uid),
            hasLength(1),
          );
        }
      },
    );
  }

  for (final logoutSucceeds in [true, false]) {
    test(
      'Cycle lease precedes feature gate and late action ${logoutSucceeds ? "is rejected after logout" : "resumes after abort"}',
      () async {
        final checkIns = _CheckInRepository();
        final harness = await _Harness.create(
          [0],
          checkInRepository: checkIns,
          syncManagerOverride: _SyncManager()..shouldDrain = false,
        );
        addTearDown(harness.dispose);
        harness.syncManager.shouldDrain = true;
        final health = healthFor(harness);
        final occupied = Completer<void>();
        final release = Completer<void>();
        final events = <String>[];
        final first = harness.mutationGate.run(_userA.uid, () async {
          occupied.complete();
          await release.future;
          events.add('first');
        });
        await occupied.future;
        final admitted = harness.mutationGate.run(_userA.uid, () async {
          expect(
            await health.updatePillStatus(true, expectedUid: _userA.uid),
            isTrue,
          );
          events.add('health');
        });
        checkIns.onDrain = () async {
          events.add('logout-drain');
          expect(events, ['first', 'health', 'logout-drain']);
          expect(
            (await harness.database
                    .select(harness.database.healthEntries)
                    .get())
                .single
                .hasTakenPillToday,
            isTrue,
          );
          expect(
            await harness.database.getPendingSyncItems(_userA.uid),
            hasLength(1),
          );
          return logoutSucceeds;
        };
        final logout = harness.notifier.logout();
        var lateEntered = false;
        final lateAction = harness.mutationGate.run(_userA.uid, () async {
          lateEntered = true;
          return health.updatePillStatus(false, expectedUid: _userA.uid);
        });
        final lateRejected = logoutSucceeds
            ? expectLater(lateAction, throwsA(isA<LocalMutationUnavailable>()))
            : null;
        release.complete();
        await first;
        await admitted;
        await logout;
        if (logoutSucceeds) {
          await lateRejected;
          expect(lateEntered, isFalse);
          expect(harness.state, isA<AuthUnauthenticated>());
          expect(
            await harness.database.select(harness.database.healthEntries).get(),
            hasLength(1),
          );
          expect(
            await harness.database
                .select(harness.database.syncQueueTable)
                .get(),
            hasLength(1),
          );
        } else {
          expect(await lateAction, isTrue);
          expect(lateEntered, isTrue);
          expect(harness.state, isA<AuthError>());
          expect(harness.repository.signOutCalls, 0);
          expect(
            await harness.database.getPendingSyncItems(_userA.uid),
            hasLength(2),
          );
        }
      },
    );
  }

  for (final newUid in [_userA.uid, _userB.uid]) {
    test(
      'external sign-out invalidates old ticket before login $newUid',
      () async {
        final harness = await _Harness.create([
          0,
        ], syncManagerOverride: _SyncManager()..shouldDrain = false);
        addTearDown(harness.dispose);
        final gate = harness.database.localMutations;
        final old = gate.capture(expectedUid: _userA.uid);
        harness.auth.emit(null);
        await harness.waitForState<AuthUnauthenticated>();
        expect(harness.notificationCleanup.calls, greaterThan(0));
        expect(await harness.readPendingCleanup(), isNull);
        final prepared = Completer<void>();
        final release = Completer<void>();
        harness.auth.emit(
          _FirebaseUser(
            newUid,
            onGetIdToken: () async {
              if (!prepared.isCompleted) prepared.complete();
              await release.future;
            },
          ),
        );
        await prepared.future;
        await expectLater(
          gate.run(
            () =>
                healthFor(harness).updatePillStatus(true, expectedUid: newUid),
          ),
          throwsA(isA<LocalMutationUnavailable>()),
        );
        release.complete();
        await harness.notifier.checkCurrentUser();
        expect((harness.state as AuthAuthenticated).user.uid, newUid);
        await expectLater(
          gate.run(
            () =>
                healthFor(harness).updatePillStatus(true, expectedUid: newUid),
            ticket: old,
          ),
          throwsA(isA<LocalMutationUnavailable>()),
        );
        expect(
          await harness.database.select(harness.database.healthEntries).get(),
          isEmpty,
        );
        expect(
          await harness.database.select(harness.database.syncQueueTable).get(),
          isEmpty,
        );
        final freshGate = harness.database.localMutations;
        final fresh = freshGate.capture(expectedUid: newUid);
        expect(
          await freshGate.run(
            () =>
                healthFor(harness).updatePillStatus(true, expectedUid: newUid),
            ticket: fresh,
          ),
          isTrue,
        );
        expect(
          await harness.database.select(harness.database.healthEntries).get(),
          hasLength(1),
        );
        expect(
          await harness.database.getPendingSyncItems(newUid),
          hasLength(1),
        );
      },
    );
  }

  test(
    'repeated same-session event preserves existing mutation ticket',
    () async {
      final harness = await _Harness.create([
        0,
      ], syncManagerOverride: _SyncManager()..shouldDrain = false);
      addTearDown(harness.dispose);
      final ticket = harness.database.localMutations.capture();
      harness.auth.emit(_FirebaseUser(_userA.uid));
      await harness.notifier.checkCurrentUser();
      expect(harness.databaseFactory.openedUserIds, [_userA.uid]);
      expect(
        await harness.database.localMutations.run(
          () => healthFor(
            harness,
          ).updatePillStatus(true, expectedUid: _userA.uid),
          ticket: ticket,
        ),
        isTrue,
      );
      expect(
        await harness.database.getPendingSyncItems(_userA.uid),
        hasLength(1),
      );
      expect(harness.notificationCleanup.calls, 0);
    },
  );

  for (final logoutSucceeds in [true, false]) {
    test(
      'Focus completion during CheckIn drain ${logoutSucceeds ? "cannot write after logout" : "resumes after logout abort"}',
      () async {
        final checkIns = _CheckInRepository();
        late _FocusTimer timer;
        final harness = await _Harness.create(
          [0],
          checkInRepository: checkIns,
          focusTimerFactory: (_, callback) => timer = _FocusTimer(callback),
        );
        addTearDown(harness.dispose);
        final focus = harness.container.read(focusProvider.notifier);
        focus.selectTarget('focus-task', 'Task', FocusTargetType.task);
        focus.setCustomDuration(7);
        focus.startTimer();
        expect(harness.container.read(focusProvider).isRunning, isTrue);
        final started = Completer<void>();
        final release = Completer<void>();
        checkIns.onDrain = () async {
          started.complete();
          await release.future;
          return logoutSucceeds;
        };
        final logout = harness.notifier.logout();
        await started.future;
        timer.finish();
        expect(
          await harness.database.select(harness.database.focusLogs).get(),
          isEmpty,
        );
        expect(await harness.database.getPendingSyncItems(_userA.uid), isEmpty);
        final completion = Completer<void>();
        final subscription = harness.container.listen(focusProvider, (_, next) {
          if (next.isBreak && !completion.isCompleted) completion.complete();
        });
        addTearDown(subscription.close);
        release.complete();
        await logout;
        if (logoutSucceeds) {
          expect(harness.state, isA<AuthUnauthenticated>());
          expect(harness.repository.signOutCalls, 1);
          expect(
            await harness.database.select(harness.database.focusLogs).get(),
            isEmpty,
          );
          expect(
            await harness.database.getPendingSyncItems(_userA.uid),
            isEmpty,
          );
        } else {
          await completion.future;
          expect(harness.state, isA<AuthError>());
          expect(harness.auth.currentUser?.uid, _userA.uid);
          expect(harness.repository.signOutCalls, 0);
          expect(
            await harness.database.select(harness.database.focusLogs).get(),
            hasLength(1),
          );
          final pending = await harness.database.getPendingSyncItems(
            _userA.uid,
          );
          expect(
            pending.map((row) => row.collection),
            containsAll(['focus_logs', 'tasks']),
          );
        }
      },
    );
  }

  Future<void> seedPendingLocalChange(AppDatabase db) async {
    await db
        .into(db.taskTable)
        .insert(
          TaskTableCompanion.insert(
            id: 'pending-task',
            title: 'Pending task',
            priority: 'normal',
            date: DateTime(2026, 9, 24),
          ),
        );
    await db.insertSyncItem(
      ownerUid: _userA.uid,
      collection: 'tasks',
      docId: 'pending-task',
      operationType: 'create',
      payloadJson: '{"title":"Pending task"}',
    );
  }

  Future<void> seedPendingCheckIn(AppDatabase db) async {
    await db.insertCheckIn(
      CheckInTableCompanion.insert(
        id: '2026-09-24',
        energy: 4,
        focus: 3,
        motivation: 2,
        createdAt: DateTime.utc(2026, 9, 24, 10),
      ),
    );
  }

  group('offline startup', () {
    test(
      'restores Firebase profile without clearing existing Drift data',
      () async {
        final firebaseUser = _FirebaseUser(
          _userA.uid,
          email: 'offline@example.invalid',
          displayName: '  Nome Firebase  ',
          photoURL: 'https://example.invalid/avatar.png',
        );
        final storage = _SecureStorage();
        final harness = await _Harness.create(
          <int>[0],
          firebaseUser: firebaseUser,
          currentUserFailure: ServerFailure.connection(),
          secureStorage: storage,
          syncManagerOverride: _SyncManager()..shouldDrain = false,
          seedBeforeAuth: seedPendingLocalChange,
        );
        addTearDown(harness.dispose);

        final user = (harness.state as AuthAuthenticated).user;
        expect(user.uid, _userA.uid);
        expect(user.email, 'offline@example.invalid');
        expect(user.displayName, 'Nome Firebase');
        expect(user.photoUrl, 'https://example.invalid/avatar.png');
        expect(user.isPremium, isFalse);
        expect(user.xp, 0);
        expect(user.level, 1);
        expect(user.streak, 0);
        expect(firebaseUser.tokenCalls, 1);
        expect(storage.values[SecureStorageService.tokenKey], 'test-token');
        expect(storage.deleteCalls, 0);
        final tasks = await harness.database
            .select(harness.database.taskTable)
            .get();
        expect(tasks.single.id, 'pending-task');
        expect(tasks.single.title, 'Pending task');
        final queue = await harness.database
            .select(harness.database.syncQueueTable)
            .get();
        expect(queue.single.status, SyncQueuePersistenceStatus.pending);
        expect(harness.auth.currentUser?.uid, _userA.uid);
        expect(harness.repository.signOutCalls, 0);
        expect(harness.auth.signOutCalls, 0);
        expect(harness.firestore.clearPersistenceCalls, 0);
        expect(harness.lifecycle.cancellationCalls, 0);
        expect(harness.notificationCleanup.calls, 0);
        expect(await harness.readPendingCleanup(), isNull);
        expect(harness.coordinator.preparedUserIds, [_userA.uid]);
      },
    );

    for (final name in <String?>[null, '   ']) {
      test('missing or blank displayName uses safe fallback ($name)', () async {
        final harness = await _Harness.create(
          <int>[0],
          firebaseUser: _FirebaseUser(_userA.uid, displayName: name),
          currentUserFailure: ServerFailure.connection(),
          syncManagerOverride: _SyncManager()..shouldDrain = false,
        );
        addTearDown(harness.dispose);
        expect(
          (harness.state as AuthAuthenticated).user.displayName,
          'Usuário',
        );
      });
    }

    test(
      'NETWORK_ERROR without a Firebase session does not authenticate',
      () async {
        final harness = await _Harness.create(
          <int>[0],
          firebaseUserId: null,
          currentUserFailure: ServerFailure.connection(),
          waitForAuthentication: false,
        );
        addTearDown(harness.dispose);
        await harness.waitForState<AuthUnauthenticated>();
        expect(harness.auth.currentUser, isNull);
        expect(harness.state, isNot(isA<AuthAuthenticated>()));
      },
    );

    for (final failure in <Failure>[
      const ServerFailure(
        'Não foi possível preparar seu perfil.',
        code: 'USER_PROFILE_PROVISION_FAILED',
      ),
      const SecurityFailure(
        'Acesso não autorizado.',
        code: 'permission-denied',
      ),
      const AuthFailure('Sua sessão não é válida.', code: 'UNAUTHENTICATED'),
    ]) {
      test('${failure.code} does not activate offline fallback', () async {
        final harness = await _Harness.create(
          <int>[0],
          currentUserFailure: failure,
          waitForAuthentication: false,
        );
        addTearDown(harness.dispose);
        await harness.waitForState<AuthError>();
        expect(harness.state, isNot(isA<AuthAuthenticated>()));
        expect(harness.auth.currentUser?.uid, _userA.uid);
        expect(harness.repository.signOutCalls, 0);
      });
    }

    test(
      'UID change during token preparation never publishes old offline user',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        final harness = await _Harness.create(
          <int>[0],
          firebaseUser: _FirebaseUser(
            _userA.uid,
            onGetIdToken: () async {
              started.complete();
              await release.future;
            },
          ),
          currentUserFailure: ServerFailure.connection(),
          waitForAuthentication: false,
        );
        addTearDown(harness.dispose);
        final published = <UserEntity>[];
        harness.container.listen<AuthState>(authNotifierProvider, (_, next) {
          if (next is AuthAuthenticated) published.add(next.user);
        });
        await started.future;
        harness.auth.user = _FirebaseUser(_userB.uid);
        release.complete();
        await harness.waitForState<AuthError>();
        expect(published, isEmpty);
        expect(harness.auth.currentUser?.uid, _userB.uid);
        expect(harness.repository.signOutCalls, 0);
      },
    );

    test(
      'token network failure preserves saved token and Firebase session',
      () async {
        final storage = _SecureStorage()
          ..values[SecureStorageService.tokenKey] = 'previous-test-token';
        final firebaseUser = _FirebaseUser(
          _userA.uid,
          tokenError: FirebaseAuthException(code: 'network-request-failed'),
        );
        final harness = await _Harness.create(
          <int>[0],
          firebaseUser: firebaseUser,
          currentUserFailure: ServerFailure.connection(),
          secureStorage: storage,
          syncManagerOverride: _SyncManager()..shouldDrain = false,
        );
        addTearDown(harness.dispose);
        expect(harness.state, isA<AuthAuthenticated>());
        expect(harness.auth.currentUser?.uid, _userA.uid);
        expect(harness.auth.signOutCalls, 0);
        expect(harness.repository.signOutCalls, 0);
        expect(
          storage.values[SecureStorageService.tokenKey],
          'previous-test-token',
        );
        expect(storage.writeCalls, 0);
        expect(storage.deleteCalls, 0);
      },
    );

    for (final code in [
      'user-token-expired',
      'user-disabled',
      'invalid-user-token',
      'user-not-found',
    ]) {
      test('token $code remains fail-closed', () async {
        final harness = await _Harness.create(
          <int>[0],
          firebaseUser: _FirebaseUser(
            _userA.uid,
            tokenError: FirebaseAuthException(code: code),
          ),
          currentUserFailure: ServerFailure.connection(),
          waitForAuthentication: false,
        );
        addTearDown(harness.dispose);
        final error = await harness.waitForState<AuthError>();
        expect(error.message, 'Não foi possível proteger a sessão local.');
        expect(harness.coordinator.preparedUserIds, isEmpty);
        expect(harness.syncManager.calls, 0);
      });
    }

    test('unknown token error remains fail-closed', () async {
      final harness = await _Harness.create(
        <int>[0],
        firebaseUser: _FirebaseUser(
          _userA.uid,
          tokenError: StateError('technical-token-marker'),
        ),
        currentUserFailure: ServerFailure.connection(),
        waitForAuthentication: false,
      );
      addTearDown(harness.dispose);
      final error = await harness.waitForState<AuthError>();
      expect(error.message, 'Não foi possível proteger a sessão local.');
      expect(error.message, isNot(contains('technical-token-marker')));
    });

    test('storage failure is not bypassed as token network failure', () async {
      final storage = _SecureStorage()
        ..writeError = FirebaseAuthException(code: 'network-request-failed');
      final harness = await _Harness.create(
        <int>[0],
        currentUserFailure: ServerFailure.connection(),
        secureStorage: storage,
        waitForAuthentication: false,
      );
      addTearDown(harness.dispose);
      await harness.waitForState<AuthError>();
      expect(harness.state, isNot(isA<AuthAuthenticated>()));
    });

    test('hydration failure leaves offline session authenticated', () async {
      final started = Completer<void>();
      final drain = Completer<bool>();
      final sync = _SyncManager()
        ..onProcess = () {
          started.complete();
          return drain.future;
        };
      final harness = await _Harness.create(
        <int>[0],
        currentUserFailure: ServerFailure.connection(),
        syncManagerOverride: sync,
      );
      addTearDown(harness.dispose);
      await started.future;
      drain.completeError(StateError('technical-hydration-marker'));
      await drain.future.then<void>((_) {}, onError: (Object _) {});
      expect(sync.calls, 1);
      expect(harness.state, isA<AuthAuthenticated>());
      expect(harness.auth.currentUser?.uid, _userA.uid);
      expect(harness.auth.signOutCalls, 0);
    });
  });

  test('logout bloqueia cleanup quando Check-in permanece pendente', () async {
    final checkIns = _CheckInRepository();
    final harness = await _Harness.create(<int>[
      0,
    ], checkInRepository: checkIns);
    addTearDown(harness.dispose);
    await seedPendingCheckIn(harness.database);
    checkIns.shouldDrain = false;

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(
      (harness.state as AuthError).message,
      contains('alterações pendentes'),
    );
    expect(harness.auth.currentUser?.uid, _userA.uid);
    expect(harness.repository.signOutCalls, 0);
    expect(harness.auth.signOutCalls, 0);
    expect(harness.firestore.clearPersistenceCalls, 0);
    expect(harness.lifecycle.cancellationCalls, 0);
    final local = await harness.database
        .select(harness.database.checkInTable)
        .getSingle();
    expect(local.energy, 4);
    expect(local.isSynced, isFalse);
    expect(await harness.readPendingCleanup(), isNull);
  });

  test('logout preserves confirmed Check-ins after replay', () async {
    final events = <String>[];
    final checkIns = _CheckInRepository();
    final harness = await _Harness.create(
      <int>[0],
      checkInRepository: checkIns,
      lifecycleEvents: events,
    );
    addTearDown(harness.dispose);
    await seedPendingCheckIn(harness.database);
    events.clear();
    checkIns.onDrain = () async {
      events.add('checkin-drain');
      final local = await harness.database
          .select(harness.database.checkInTable)
          .getSingle();
      expect(local.isSynced, isFalse);
      await harness.database.markCheckInAsSynced(
        local.id,
        ownerUid: _userA.uid,
      );
      return true;
    };

    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(events.first, 'checkin-drain');
    expect(events, contains('cleanup:${_userA.uid}'));
    expect(harness.repository.signOutCalls, 1);
    expect(
      await harness.database.select(harness.database.checkInTable).get(),
      hasLength(1),
    );
  });

  test('troca de UID durante replay Check-in impede cleanup', () async {
    final checkIns = _CheckInRepository();
    final harness = await _Harness.create(<int>[
      0,
    ], checkInRepository: checkIns);
    addTearDown(harness.dispose);
    await seedPendingCheckIn(harness.database);
    checkIns.onDrain = () async {
      harness.auth.user = _FirebaseUser(_userB.uid);
      return true;
    };

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.repository.signOutCalls, 0);
    expect(harness.lifecycle.cancellationCalls, 0);
    expect(
      (await harness.database.select(harness.database.checkInTable).getSingle())
          .isSynced,
      isFalse,
    );
  });

  test('hidratação drena Check-ins antes de aplicar snapshot', () async {
    final events = <String>[];
    final checkIns = _CheckInRepository()
      ..onDrain = (() async {
        events.add('checkin-drain');
        return true;
      })
      ..onPull = (() async => events.add('checkin-pull'));
    final finance = _FinanceRepository(events);
    final harness = await _Harness.create(
      <int>[0],
      checkInRepository: checkIns,
      financeRepository: finance,
    );
    addTearDown(harness.dispose);

    await finance.pulled.future;
    expect(events, ['checkin-drain', 'checkin-pull', 'finance-pull']);
    expect(checkIns.pullCalls, 1);
  });

  test(
    'falha do replay Check-in pula pull próprio sem bloquear Finance',
    () async {
      final events = <String>[];
      final checkIns = _CheckInRepository()
        ..onDrain = (() async {
          events.add('checkin-drain');
          return false;
        });
      final finance = _FinanceRepository(events);
      final harness = await _Harness.create(
        <int>[0],
        checkInRepository: checkIns,
        financeRepository: finance,
      );
      addTearDown(harness.dispose);

      await finance.pulled.future;
      expect(checkIns.pullCalls, 0);
      expect(events, ['checkin-drain', 'finance-pull']);
    },
  );

  test('logout com fila pendente preserva sessão, dados e operação', () async {
    final harness = await _Harness.create(<int>[0]);
    addTearDown(harness.dispose);
    await seedPendingLocalChange(harness.database);
    harness.syncManager.shouldDrain = false;

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(
      (harness.state as AuthError).message,
      contains('alterações pendentes'),
    );
    expect(harness.auth.currentUser?.uid, _userA.uid);
    expect(harness.repository.signOutCalls, 0);
    expect(harness.auth.signOutCalls, 0);
    expect(
      await harness.database.select(harness.database.taskTable).get(),
      hasLength(1),
    );
    final queue = await harness.database
        .select(harness.database.syncQueueTable)
        .get();
    expect(queue, hasLength(1));
    expect(queue.single.ownerUid, _userA.uid);
    expect(queue.single.status, SyncQueuePersistenceStatus.pending);
    expect(harness.lifecycle.cancellationCalls, 0);
    expect(harness.firestore.clearPersistenceCalls, 0);
    expect(await harness.readPendingCleanup(), isNull);

    harness.syncManager.shouldDrain = true;
    await harness.notifier.logout();
    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.repository.signOutCalls, 1);
  });

  test('rejected persistido bloqueia logout e segunda tentativa', () async {
    final harness = await _Harness.create(<int>[0]);
    addTearDown(harness.dispose);
    await seedPendingLocalChange(harness.database);
    final queue = await harness.database
        .select(harness.database.syncQueueTable)
        .get();
    await harness.database.markSyncItemRejected(
      queue.single.id,
      _userA.uid,
      'INVALID_PAYLOAD',
    );
    harness.syncManager.hasRejected = () =>
        harness.database.hasRejectedSyncItems(_userA.uid);

    for (var attempt = 0; attempt < 2; attempt++) {
      await harness.notifier.logout();

      expect(harness.state, isA<AuthError>());
      expect(
        (harness.state as AuthError).message,
        'Há alterações pendentes que ainda não foram sincronizadas. '
        'Verifique sua conexão e tente sair novamente.',
      );
      expect(harness.auth.currentUser?.uid, _userA.uid);
      expect(harness.repository.signOutCalls, 0);
      expect(harness.auth.signOutCalls, 0);
      expect(
        await harness.database.select(harness.database.taskTable).get(),
        hasLength(1),
      );
      final retained = await harness.database
          .select(harness.database.syncQueueTable)
          .get();
      expect(retained, hasLength(1));
      expect(retained.single.id, queue.single.id);
      expect(retained.single.status, SyncQueuePersistenceStatus.rejected);
      expect(harness.lifecycle.cancellationCalls, 0);
      expect(harness.firestore.clearPersistenceCalls, 0);
      expect(harness.notificationCleanup.calls, 0);
      expect(harness.rotation.calls, 0);
      expect(harness.preferencesDeletion.calls, 0);
      expect(await harness.readPendingCleanup(), isNull);
    }
  });

  test('logout drains before non-destructive isolation', () async {
    final events = <String>[];
    final harness = await _Harness.create(<int>[0], lifecycleEvents: events);
    addTearDown(harness.dispose);
    await seedPendingLocalChange(harness.database);
    events.clear();
    harness.syncManager.onProcess = () async {
      events.add('drain');
      expect(harness.auth.currentUser?.uid, _userA.uid);
      expect(
        await harness.database.select(harness.database.taskTable).get(),
        hasLength(1),
      );
      final queue = await harness.database
          .select(harness.database.syncQueueTable)
          .get();
      expect(queue.single.status, SyncQueuePersistenceStatus.pending);
      await harness.database.markSyncItemAsSucceeded(
        queue.single.id,
        _userA.uid,
      );
      return true;
    };

    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(events.first, 'drain');
    expect(events, contains('cleanup:${_userA.uid}'));
    expect(harness.repository.signOutCalls, 1);
    expect(
      await harness.database.select(harness.database.taskTable).get(),
      hasLength(1),
    );
    expect(
      await harness.database.select(harness.database.syncQueueTable).get(),
      hasLength(1),
    );
  });

  test('UID divergente não drena nem limpa dados de outro usuário', () async {
    final harness = await _Harness.create(<int>[0]);
    addTearDown(harness.dispose);
    await seedPendingLocalChange(harness.database);
    final callsBefore = harness.syncManager.calls;
    harness.auth.user = _FirebaseUser(_userB.uid);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.syncManager.calls, callsBefore);
    expect(harness.repository.signOutCalls, 0);
    expect(
      await harness.database.select(harness.database.taskTable).get(),
      hasLength(1),
    );
    expect(
      await harness.database.select(harness.database.syncQueueTable).get(),
      hasLength(1),
    );
  });

  test('troca de UID durante drain impede cleanup e sign-out', () async {
    final harness = await _Harness.create(<int>[0]);
    addTearDown(harness.dispose);
    await seedPendingLocalChange(harness.database);
    harness.syncManager.onProcess = () async {
      harness.auth.user = _FirebaseUser(_userB.uid);
      return true;
    };

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.repository.signOutCalls, 0);
    expect(
      await harness.database.select(harness.database.taskTable).get(),
      hasLength(1),
    );
    expect(
      await harness.database.select(harness.database.syncQueueTable).get(),
      hasLength(1),
    );
  });

  test(
    'logout disposes Billing A before preparing a fresh Billing B',
    () async {
      final repositories = <_SessionPremiumRepository>[];
      final harness = await _Harness.create(
        <int>[0, 0],
        createPremiumRepository: (uid) {
          if (uid == _userB.uid) expect(repositories.first.disposed, isTrue);
          final repository = _SessionPremiumRepository(uid);
          repositories.add(repository);
          return repository;
        },
      );
      addTearDown(harness.dispose);
      final first = repositories.single;
      expect(first.uid, _userA.uid);
      expect(first.statuses.hasListener, isTrue);
      await harness.container.read(premiumCatalogProvider.future);
      final purchaseA = harness.container
          .read(premiumProvider.notifier)
          .processSecureCheckout(PremiumTier.monthly);
      final interrupted = expectLater(
        purchaseA,
        throwsA(
          isA<PremiumPurchaseException>().having(
            (error) => error.code,
            'code',
            'PURCHASE_INTERRUPTED',
          ),
        ),
      );
      await harness.notifier.logout();
      await interrupted;
      expect(first.disposed, isTrue);
      expect(first.statuses.hasListener, isFalse);
      harness.auth.emit(_FirebaseUser(_userB.uid));
      await harness.notifier.checkCurrentUser();
      await harness.waitForState<AuthAuthenticated>();
      final second =
          harness.container.read(premiumRepositoryProvider)
              as _SessionPremiumRepository;
      expect(second, isNot(same(first)));
      expect(second.uid, _userB.uid);
      expect(second.statuses.hasListener, isTrue);
      final purchaseB = harness.container
          .read(premiumProvider.notifier)
          .processSecureCheckout(PremiumTier.annual);
      second.activePurchase!.complete(false);
      expect(await purchaseB, isFalse);
    },
  );

  test(
    'logout never deletes rows even when a DELETE trigger would fail',
    () async {
      final harness = await _Harness.create(<int>[0, 0]);
      addTearDown(harness.dispose);
      final db = harness.database;
      await db
          .into(db.taskTable)
          .insert(
            TaskTableCompanion.insert(
              id: 'cleanup-test',
              title: 'Test task',
              priority: 'normal',
              date: DateTime(2026, 9, 2),
            ),
          );
      await db.customStatement('''
      CREATE TEMP TRIGGER fail_cleanup BEFORE DELETE ON task_table
      BEGIN SELECT RAISE(ABORT, 'TEST_CLEANUP_FAILURE'); END
    ''');

      await harness.notifier.logout();

      expect(harness.state, isA<AuthUnauthenticated>());
      expect(harness.repository.signOutCalls, 1);
      expect(harness.auth.currentUser, isNull);
      expect(harness.authority.preparedUserId, isNull);
      expect(await harness.readPendingCleanup(), isNull);
      expect(harness.databaseFactory.last!.closed, isTrue);
      final preserved = harness.database;
      expect(await preserved.select(preserved.taskTable).get(), hasLength(1));
      await expectLater(
        db.localMutations.run(() async {}),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(await preserved.select(preserved.healthEntries).get(), isEmpty);
      expect(await preserved.select(preserved.syncQueueTable).get(), isEmpty);
    },
  );

  test(
    'logout termina Firestore após failed-precondition e repete clear',
    () async {
      final firestore = _ScriptedFirestore(
        clearResults: <Object?>[
          FirebaseException(
            plugin: 'cloud_firestore',
            code: 'failed-precondition',
          ),
          null,
        ],
      );
      final harness = await _Harness.create(<int>[0], firestore: firestore);
      addTearDown(harness.dispose);

      await harness.notifier.logout();

      expect(harness.state, isA<AuthUnauthenticated>());
      expect(harness.repository.signOutCalls, 1);
      expect(firestore.clearPersistenceCalls, 2);
      expect(firestore.terminateCalls, 1);
    },
  );

  test('segunda passagem do logout não repete limpeza Firestore', () async {
    final firestore = _ScriptedFirestore();
    final harness = await _Harness.create(<int>[0], firestore: firestore);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(firestore.clearPersistenceCalls, 1);
    expect(firestore.terminateCalls, 0);
  });

  test('falha ao terminar Firestore bloqueia sign-out', () async {
    final firestore = _ScriptedFirestore(
      clearResults: <Object?>[
        FirebaseException(
          plugin: 'cloud_firestore',
          code: 'failed-precondition',
        ),
      ],
      terminateResults: <Object?>[
        StateError('private Firestore terminate failure'),
      ],
    );
    final harness = await _Harness.create(<int>[0], firestore: firestore);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.repository.signOutCalls, 1);
    expect(firestore.clearPersistenceCalls, 1);
    expect(firestore.terminateCalls, 1);
  });

  test('falha no segundo clear não conclui guard e retry limpa', () async {
    final firestore = _ScriptedFirestore(
      clearResults: <Object?>[
        FirebaseException(
          plugin: 'cloud_firestore',
          code: 'failed-precondition',
        ),
        StateError('private second clear failure'),
        null,
      ],
    );
    final harness = await _Harness.create(<int>[0, 0], firestore: firestore);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.repository.signOutCalls, 1);
    expect(firestore.clearPersistenceCalls, 2);
    expect(firestore.terminateCalls, 1);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.repository.signOutCalls, 1);
    expect(firestore.clearPersistenceCalls, 3);
    expect(firestore.terminateCalls, 1);
  });

  test('nova sessão rearma limpeza Firestore para logout posterior', () async {
    final firestore = _ScriptedFirestore();
    final harness = await _Harness.create(<int>[0, 0], firestore: firestore);
    addTearDown(harness.dispose);

    await harness.notifier.logout();
    expect(harness.state, isA<AuthUnauthenticated>());
    expect(firestore.clearPersistenceCalls, 1);

    harness.auth.user = _FirebaseUser(_userB.uid);
    await harness.notifier.checkCurrentUser();
    expect(harness.state, isA<AuthAuthenticated>());

    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.repository.signOutCalls, 2);
    expect(firestore.clearPersistenceCalls, 2);
    expect(firestore.terminateCalls, 0);
  });

  test(
    'cancelamento final parcial falha fechado e retry posterior pode concluir',
    () async {
      final harness = await _Harness.create(<int>[1, 0]);
      addTearDown(harness.dispose);
      final oldGeneration = harness.epoch.snapshot(_userA.uid);

      await harness.notifier.logout();

      expect(harness.state, isA<AuthError>());
      expect(harness.repository.signOutCalls, 1);
      expect(harness.authority.preparedUserId, isNull);
      expect(harness.epoch.isCurrent(_userA.uid, oldGeneration), isFalse);
      expect(harness.coordinator.preparedUserIds, <String>[_userA.uid]);
      expect(harness.lifecycle.cancellationCalls, 1);
      expect(harness.rotation.calls, 1);

      await harness.notifier.logout();

      expect(harness.state, isA<AuthUnauthenticated>());
      expect(harness.repository.signOutCalls, 1);
      expect(harness.lifecycle.cancellationCalls, 2);
      expect(harness.rotation.calls, 2);
      expect(harness.authority.preparedUserId, isNull);
    },
  );

  test('troca A para B não prepara B quando cleanup de A falha', () async {
    final harness = await _Harness.create(<int>[1]);
    addTearDown(harness.dispose);
    final failed = Completer<void>();
    harness.container.listen<AuthState>(authNotifierProvider, (_, next) {
      if (next is AuthError && !failed.isCompleted) failed.complete();
    });

    harness.auth.emit(_FirebaseUser('user-b'));
    await failed.future;

    expect(harness.lifecycle.cancellationCalls, 1);
    expect(harness.coordinator.preparedUserIds, <String>[_userA.uid]);
    expect(harness.authority.preparedUserId, isNull);
    expect(harness.auth.currentUser, isNull);
    expect(harness.auth.signOutCalls, 1);
    expect(harness.repository.signOutCalls, 0);
  });

  test('zero falhas preserva logout normal', () async {
    final harness = await _Harness.create(<int>[0]);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.lifecycle.cancellationCalls, 1);
    expect(harness.rotation.calls, 1);
    expect(harness.preferencesDeletion.userIds, isEmpty);
    expect(harness.notificationCleanup.calls, 1);
    expect(harness.repository.signOutCalls, 1);
    expect(harness.authority.preparedUserId, isNull);
    expect(await harness.readPendingCleanup(), isNull);
  });

  test(
    'falha no cancelamento global bloqueia sign-out e retry faz duas passagens',
    () async {
      final harness = await _Harness.create(<int>[
        0,
        0,
      ], notificationCleanupFailures: 1);
      addTearDown(harness.dispose);

      await harness.notifier.logout();

      expect(harness.state, isA<AuthError>());
      expect(harness.notificationCleanup.calls, 1);
      expect(harness.repository.signOutCalls, 1);

      await harness.notifier.logout();

      expect(harness.state, isA<AuthUnauthenticated>());
      expect(harness.notificationCleanup.calls, 2);
      expect(harness.repository.signOutCalls, 1);
    },
  );

  test(
    'logout never invokes preference deletion even when storage deletion fails',
    () async {
      final harness = await _Harness.create(<int>[
        0,
        0,
      ], preferenceDeletionFailures: 1);
      addTearDown(harness.dispose);

      await harness.notifier.logout();

      expect(harness.state, isA<AuthUnauthenticated>());
      expect(harness.preferencesDeletion.userIds, isEmpty);
      expect(harness.repository.signOutCalls, 1);

      harness.auth.user = _FirebaseUser(_userA.uid);
      await harness.notifier.checkCurrentUser();
      await harness.notifier.logout();

      expect(harness.state, isA<AuthUnauthenticated>());
      expect(harness.preferencesDeletion.userIds, isEmpty);
      expect(harness.repository.signOutCalls, 2);
      expect(await harness.cycleStore.load(_userA.uid), isNotNull);
    },
  );

  test('falha de rotação bloqueia logout e retry posterior conclui', () async {
    final harness = await _Harness.create(<int>[0], rotationFailures: 1);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.authority.preparedUserId, isNull);
    expect(harness.rotation.calls, 1);
    expect(harness.rotation.tokenVersion, 1);
    expect(harness.lifecycle.cancellationCalls, 0);
    expect(harness.repository.signOutCalls, 1);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.rotation.calls, 2);
    expect(harness.rotation.tokenVersion, 2);
    expect(harness.lifecycle.cancellationCalls, 1);
    expect(harness.repository.signOutCalls, 1);
  });

  test('falha de rotação impede preparar B após troca de sessão', () async {
    final harness = await _Harness.create(<int>[0], rotationFailures: 1);
    addTearDown(harness.dispose);
    final failed = Completer<void>();
    harness.container.listen<AuthState>(authNotifierProvider, (_, next) {
      if (next is AuthError && !failed.isCompleted) failed.complete();
    });

    harness.auth.emit(_FirebaseUser('user-b'));
    await failed.future;

    expect(harness.rotation.calls, 1);
    expect(harness.lifecycle.cancellationCalls, 0);
    expect(harness.coordinator.preparedUserIds, <String>[_userA.uid]);
    expect(harness.authority.preparedUserId, isNull);
    expect(harness.auth.signOutCalls, 1);
  });

  test('falha de sign-out não restaura credencial anterior', () async {
    final harness = await _Harness.create(<int>[0], failSignOut: true);
    addTearDown(harness.dispose);
    final barrier = AuthCleanupBarrierStore(harness.barrierStorage);
    final isolation = await barrier.setPending(
      _userA.uid,
      AuthCleanupIntent.isolation,
    );

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.rotation.calls, 1);
    expect(harness.rotation.tokenVersion, 2);
    expect(harness.lifecycle.cancellationCalls, 1);
    expect(harness.repository.signOutCalls, 1);
    expect(harness.authority.preparedUserId, _userA.uid);
    final logout = await harness.readPendingCleanup();
    expect(logout, isNull);
    expect(logout, isNot(isolation));
    expect(await barrier.clearIfCurrent(isolation), isFalse);
    expect(await harness.readPendingCleanup(), logout);
  });

  test(
    'restart após rotação falhar recupera logout antes de qualquer prepare',
    () async {
      final barrierStorage = _MemoryBarrierStorage();
      final rotation = _ScriptedTokenRotation(failuresRemaining: 1);
      final first = await _Harness.create(
        <int>[0],
        barrierStorage: barrierStorage,
        tokenRotation: rotation,
      );

      await first.notifier.logout();

      expect(first.state, isA<AuthError>());
      expect(rotation.tokenVersion, 1);
      expect((await first.readPendingCleanup())?.requiresSignOut, isTrue);
      await first.dispose();

      final second = await _Harness.create(
        <int>[0],
        barrierStorage: barrierStorage,
        tokenRotation: rotation,
        waitForAuthentication: false,
      );
      addTearDown(second.dispose);
      await second.notifier.checkCurrentUser();

      expect(rotation.tokenVersion, 2);
      expect(rotation.userIds, <String>[_userA.uid, _userA.uid]);
      expect(second.coordinator.preparedUserIds, isEmpty);
      expect(second.auth.currentUser, isNull);
      expect(await second.readPendingCleanup(), isNull);
    },
  );

  test('restart mantém barrier quando rotação falha novamente', () async {
    final barrierStorage = _MemoryBarrierStorage();
    final barrier = AuthCleanupBarrierStore(barrierStorage);
    await barrier.setPending(_userA.uid, AuthCleanupIntent.logout);
    final rotation = _ScriptedTokenRotation(failuresRemaining: 1);

    final harness = await _Harness.create(
      <int>[0],
      barrierStorage: barrierStorage,
      tokenRotation: rotation,
      waitForAuthentication: false,
    );
    addTearDown(harness.dispose);
    await harness.waitForState<AuthError>();

    expect(rotation.calls, 1);
    expect(rotation.tokenVersion, 1);
    expect(harness.coordinator.preparedUserIds, isEmpty);
    expect((await harness.readPendingCleanup())?.userId, _userA.uid);
  });

  test(
    'recovery stale preserva logout mais novo e restart resolve antes do prepare',
    () async {
      final barrierStorage = _MemoryBarrierStorage();
      final barrier = AuthCleanupBarrierStore(barrierStorage);
      final isolation = await barrier.setPending(
        _userA.uid,
        AuthCleanupIntent.isolation,
      );
      final rotationStarted = Completer<void>();
      final allowRotation = Completer<void>();
      final rotation = _ScriptedTokenRotation(
        callStarted: rotationStarted,
        allowCall: allowRotation,
      );
      final first = await _Harness.create(
        <int>[0],
        barrierStorage: barrierStorage,
        tokenRotation: rotation,
        waitForAuthentication: false,
      );

      await rotationStarted.future;
      final logout = await barrier.setPending(
        _userA.uid,
        AuthCleanupIntent.logout,
      );
      expect(logout.revision, isNot(isolation.revision));
      allowRotation.complete();
      await first.waitForState<AuthError>();

      expect(first.coordinator.preparedUserIds, isEmpty);
      expect(await first.readPendingCleanup(), logout);
      await first.dispose();

      final second = await _Harness.create(
        <int>[0],
        barrierStorage: barrierStorage,
        tokenRotation: rotation,
        waitForAuthentication: false,
      );
      addTearDown(second.dispose);
      await second.notifier.checkCurrentUser();

      expect(second.coordinator.preparedUserIds, isEmpty);
      expect(second.auth.currentUser, isNull);
      expect(await second.readPendingCleanup(), isNull);
    },
  );

  test('restart com Firebase B isola A antes de preparar B', () async {
    final events = <String>[];
    final barrierStorage = _MemoryBarrierStorage();
    await AuthCleanupBarrierStore(
      barrierStorage,
    ).setPending(_userA.uid, AuthCleanupIntent.isolation);
    final rotation = _ScriptedTokenRotation(events: events);

    final harness = await _Harness.create(
      <int>[0],
      barrierStorage: barrierStorage,
      tokenRotation: rotation,
      firebaseUserId: 'user-b',
    );
    addTearDown(harness.dispose);
    events.addAll(
      harness.coordinator.preparedUserIds.map((uid) => 'prepare:$uid'),
    );

    expect(rotation.userIds, <String>[_userA.uid]);
    expect(harness.preferencesDeletion.userIds, isEmpty);
    expect(await harness.cycleStore.load(_userA.uid), isNotNull);
    expect(await harness.cycleStore.load(_userB.uid), isNotNull);
    expect(harness.coordinator.preparedUserIds, <String>['user-b']);
    expect(events, <String>['rotate:user-a', 'prepare:user-b']);
    expect(await harness.readPendingCleanup(), isNull);
  });

  test('restart com Firebase null conclui cleanup local de A', () async {
    final barrierStorage = _MemoryBarrierStorage();
    await AuthCleanupBarrierStore(
      barrierStorage,
    ).setPending(_userA.uid, AuthCleanupIntent.isolation);
    final rotation = _ScriptedTokenRotation();

    final harness = await _Harness.create(
      <int>[0],
      barrierStorage: barrierStorage,
      tokenRotation: rotation,
      firebaseUserId: null,
      waitForAuthentication: false,
    );
    addTearDown(harness.dispose);
    await harness.waitForState<AuthUnauthenticated>();

    expect(rotation.userIds, <String>[_userA.uid]);
    expect(harness.lifecycle.cancellationCalls, 1);
    expect(harness.preferencesDeletion.userIds, isEmpty);
    expect(await harness.cycleStore.load(_userA.uid), isNotNull);
    expect(harness.coordinator.preparedUserIds, isEmpty);
    expect(await harness.readPendingCleanup(), isNull);
  });

  test('crash após rotate repete recovery e só então prepara A', () async {
    final barrierStorage = _MemoryBarrierStorage()..throwOnDelete = true;
    await AuthCleanupBarrierStore(
      barrierStorage,
    ).setPending(_userA.uid, AuthCleanupIntent.isolation);
    final rotation = _ScriptedTokenRotation();
    final first = await _Harness.create(
      <int>[0],
      barrierStorage: barrierStorage,
      tokenRotation: rotation,
      waitForAuthentication: false,
    );
    await first.waitForState<AuthError>();

    expect(rotation.tokenVersion, 2);
    expect((await first.readPendingCleanup())?.userId, _userA.uid);
    await first.dispose();

    barrierStorage.throwOnDelete = false;
    final second = await _Harness.create(
      <int>[0],
      barrierStorage: barrierStorage,
      tokenRotation: rotation,
    );
    addTearDown(second.dispose);

    expect(rotation.tokenVersion, 3);
    expect(second.coordinator.preparedUserIds, <String>[_userA.uid]);
    expect(await second.readPendingCleanup(), isNull);
  });

  test('falha ao armar barrier não inicia cleanup crítico', () async {
    final barrierStorage = _MemoryBarrierStorage()..throwOnWrite = true;
    final harness = await _Harness.create(
      <int>[0],
      barrierStorage: barrierStorage,
      syncManagerOverride: _SyncManager()..shouldDrain = false,
    );
    addTearDown(harness.dispose);
    final health = healthFor(harness);
    final db = harness.database;
    expect(
      await health.updatePillStatus(true, expectedUid: _userA.uid),
      isTrue,
    );
    final originalHealth = await db.select(db.healthEntries).get();
    final originalQueue = await db.select(db.syncQueueTable).get();
    expect(originalHealth, hasLength(1));
    expect(originalQueue, hasLength(1));
    harness.syncManager.shouldDrain = true;

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.rotation.calls, 0);
    expect(harness.lifecycle.cancellationCalls, 0);
    expect(harness.repository.signOutCalls, 0);
    expect(harness.authority.preparedUserId, _userA.uid);
    expect(await harness.readPendingCleanup(), isNull);
    expect(harness.auth.currentUser?.uid, _userA.uid);
    expect(harness.firestore.clearPersistenceCalls, 0);
    expect(harness.notificationCleanup.calls, 0);
    expect(await db.select(db.healthEntries).get(), originalHealth);
    expect(await db.select(db.syncQueueTable).get(), originalQueue);
    expect(
      await health.updatePillStatus(false, expectedUid: _userA.uid),
      isTrue,
    );
    expect(
      (await db.select(db.healthEntries).getSingle()).hasTakenPillToday,
      isFalse,
    );
    expect(await db.select(db.syncQueueTable).get(), hasLength(2));

    barrierStorage.throwOnWrite = false;
    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.repository.signOutCalls, 1);
    expect(harness.auth.currentUser, isNull);
    expect(await harness.readPendingCleanup(), isNull);
    final preserved = harness.database;
    expect(await preserved.select(preserved.healthEntries).get(), hasLength(1));
    expect(
      await preserved.select(preserved.syncQueueTable).get(),
      hasLength(2),
    );
  });

  test('falha ao limpar barrier mantém logout fail-closed', () async {
    final barrierStorage = _MemoryBarrierStorage()..throwOnDelete = true;
    final harness = await _Harness.create(<int>[
      0,
    ], barrierStorage: barrierStorage);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.repository.signOutCalls, 1);
    expect(harness.coordinator.preparedUserIds, <String>[_userA.uid]);
    expect(harness.authority.preparedUserId, isNull);
    expect((await harness.readPendingCleanup())?.requiresSignOut, isTrue);
  });

  test(
    'delete A com troca para B limpa A antes de preparar e preserva B',
    () async {
      final deleteStarted = Completer<void>();
      final allowDelete = Completer<void>();
      final events = <String>[];
      final harness = await _Harness.create(
        <int>[0],
        deleteStarted: deleteStarted,
        allowDelete: allowDelete,
        lifecycleEvents: events,
        onGetCurrentUser: (userId, database) async {
          if (userId != _userB.uid) return;
          events.add('prepare:$userId');
          // Seed the repository fixture, not a domain mutation before preparation.
          await database.localMutations.cleanupWrite(
            () => database
                .into(database.taskTable)
                .insert(
                  TaskTableCompanion.insert(
                    id: 'user-b-local-data',
                    title: 'B local data',
                    priority: 'normal',
                    date: DateTime(2026, 9, 1),
                  ),
                ),
          );
        },
      );
      addTearDown(harness.dispose);

      final a = harness.databaseFactory.last!;
      await seedSessionRows(a, _userA.uid);
      final deletion = harness.notifier.deleteAccount();
      await deleteStarted.future;
      harness.auth.emit(_FirebaseUser(_userB.uid));
      allowDelete.complete();
      await deletion;

      expect(harness.repository.deletedExpectedUserIds, <String>[_userA.uid]);
      expect(await harness.cycleStore.load(_userA.uid), isNull);
      expect(await harness.cycleStore.load(_userB.uid), isNotNull);
      expect(harness.auth.signOutCalls, 0);
      expect(harness.auth.currentUser?.uid, _userB.uid);
      expect(harness.state, isA<AuthAuthenticated>());
      expect((harness.state as AuthAuthenticated).user.uid, _userB.uid);
      expect(events, <String>[
        'cleanup:${_userA.uid}',
        'delete:${_userA.uid}',
        'prepare:${_userB.uid}',
      ]);
      expect(
        await harness.database.select(harness.database.taskTable).get(),
        hasLength(1),
      );
      expect(a.closed, isTrue);
      final deletedA = harness.databaseFactory.inspectClosed(
        _userA.uid,
        () => _userA.uid,
      );
      expect(await deletedA.select(deletedA.taskTable).get(), isEmpty);
      expect(await deletedA.select(deletedA.notificationsTable).get(), isEmpty);
      expect(await harness.readPendingCleanup(), isNull);
    },
  );

  test(
    'normal logout closes A but preserves rows and relogin recovers A',
    () async {
      final harness = await _Harness.create(
        [0, 0],
        syncManagerOverride: _SyncManager()..shouldDrain = false,
        restoreCycleSchedules: true,
      );
      addTearDown(harness.dispose);
      final a = harness.databaseFactory.last!;
      await harness.cycleRestore.lastRestore;
      final preferences = (await harness.cycleStore.load(_userA.uid))!.toJson();
      expect(harness.lifecycle.rebuiltUserIds, [_userA.uid]);
      await seedSessionRows(a, _userA.uid);
      await healthFor(harness).updatePillStatus(true, expectedUid: _userA.uid);
      final beforeQueue = await a.select(a.syncQueueTable).get();
      harness.syncManager.shouldDrain = true;

      await harness.notifier.logout();
      expect(harness.state, isA<AuthUnauthenticated>());
      expect(a.closed, isTrue);
      expect(a.closeCalls, 1);
      expect(
        a.identity!.fileIn(harness.databaseFactory.directory).existsSync(),
        isTrue,
      );
      expect(harness.notificationCleanup.calls, 1);
      expect(harness.rotation.userIds, [_userA.uid]);
      expect(harness.lifecycle.cancelledUserIds, [_userA.uid]);
      expect(harness.preferencesDeletion.userIds, isEmpty);
      expect(
        (await harness.cycleStore.load(_userA.uid))!.toJson(),
        preferences,
      );
      expect(() => harness.container.read(databaseProvider), throwsA(anything));
      final persisted = harness.database;
      expect(await persisted.select(persisted.taskTable).get(), hasLength(1));
      expect(
        await persisted.select(persisted.notificationsTable).get(),
        hasLength(1),
      );
      expect(
        await persisted.select(persisted.syncQueueTable).get(),
        beforeQueue,
      );

      harness.syncManager.shouldDrain = false;
      harness.auth.user = _FirebaseUser(_userA.uid);
      await harness.notifier.checkCurrentUser();
      await harness.cycleRestore.lastRestore;
      expect(harness.lifecycle.rebuiltUserIds, [_userA.uid, _userA.uid]);
      expect(harness.lifecycle.rebuiltPreferences, [preferences, preferences]);
      final reopened = harness.container.read(databaseProvider);
      expect(reopened, isNot(same(a)));
      expect(reopened.identity, a.identity);
      expect(await reopened.select(reopened.taskTable).get(), hasLength(1));
      expect(
        await reopened.select(reopened.notificationsTable).get(),
        hasLength(1),
      );
      expect(await reopened.select(reopened.syncQueueTable).get(), beforeQueue);
    },
  );

  test(
    'spontaneous A to B closes A and relogin restores only each owner rows',
    () async {
      final harness = await _Harness.create([
        0,
        0,
      ], syncManagerOverride: _SyncManager()..shouldDrain = false);
      addTearDown(harness.dispose);
      final a = harness.databaseFactory.last!;
      await harness.cycleRestore.lastRestore;
      final preferencesA = (await harness.cycleStore.load(
        _userA.uid,
      ))!.toJson();
      final preferencesB = (await harness.cycleStore.load(
        _userB.uid,
      ))!.toJson();
      await seedSessionRows(a, _userA.uid);
      final preparedB = Completer<void>();
      harness.container.listen<AuthState>(authNotifierProvider, (_, next) {
        if (next is AuthAuthenticated &&
            next.user.uid == _userB.uid &&
            !preparedB.isCompleted) {
          preparedB.complete();
        }
      });
      harness.auth.emit(_FirebaseUser(_userB.uid));
      await preparedB.future;
      await harness.cycleRestore.lastRestore;
      expect(harness.cycleRestore.loadedPreferences.last, preferencesB);
      expect(harness.preferencesDeletion.userIds, isEmpty);
      expect(
        (await harness.cycleStore.load(_userA.uid))!.toJson(),
        preferencesA,
      );
      expect((harness.state as AuthAuthenticated).user.uid, _userB.uid);
      final b = harness.container.read(databaseProvider);
      expect(a.closed, isTrue);
      expect(b.identity!.uid, _userB.uid);
      expect(await b.select(b.taskTable).get(), isEmpty);
      expect(await b.select(b.notificationsTable).get(), isEmpty);
      await seedSessionRows(b, _userB.uid);
      harness.auth.emit(_FirebaseUser(_userA.uid));
      await harness.notifier.checkCurrentUser();
      await harness.cycleRestore.lastRestore;
      expect(harness.cycleRestore.loadedPreferences.last, preferencesA);
      expect(
        (await harness.cycleStore.load(_userB.uid))!.toJson(),
        preferencesB,
      );
      final reopenedA = harness.container.read(databaseProvider);
      expect(
        (await reopenedA.select(reopenedA.taskTable).get()).single.id,
        'user-a-task',
      );
      expect(
        (await reopenedA.select(reopenedA.notificationsTable).get()).single.id,
        'user-a-notification',
      );
      final persistedB = harness.databaseFactory.inspectClosed(
        _userB.uid,
        () => _userB.uid,
      );
      expect(
        (await persistedB.select(persistedB.taskTable).get()).single.id,
        'user-b-task',
      );
    },
  );

  test(
    'external sign-out preserves A rows while revoking database access',
    () async {
      final harness = await _Harness.create([
        0,
      ], syncManagerOverride: _SyncManager()..shouldDrain = false);
      addTearDown(harness.dispose);
      final a = harness.databaseFactory.last!;
      final preferences = (await harness.cycleStore.load(_userA.uid))!.toJson();
      await seedSessionRows(a, _userA.uid);
      harness.auth.emit(null);
      await harness.waitForState<AuthUnauthenticated>();
      expect(a.closed, isTrue);
      expect(harness.repository.signOutCalls, 0);
      expect(harness.rotation.userIds, [_userA.uid]);
      expect(harness.lifecycle.cancelledUserIds, [_userA.uid]);
      expect(harness.preferencesDeletion.userIds, isEmpty);
      expect(
        (await harness.cycleStore.load(_userA.uid))!.toJson(),
        preferences,
      );
      expect(() => harness.container.read(databaseProvider), throwsA(anything));
      final persisted = harness.database;
      expect(await persisted.select(persisted.taskTable).get(), hasLength(1));
      expect(
        await persisted.select(persisted.notificationsTable).get(),
        hasLength(1),
      );
    },
  );

  test(
    'pending logout with Firebase null preserves unopened A rows on recovery',
    () async {
      final storage = _MemoryBarrierStorage();
      await AuthCleanupBarrierStore(
        storage,
      ).setPending(_userA.uid, AuthCleanupIntent.logout);
      final harness = await _Harness.create(
        [0],
        firebaseUserId: null,
        barrierStorage: storage,
        waitForAuthentication: false,
        seedBeforeAuth: (db) => seedSessionRows(db, _userA.uid),
      );
      addTearDown(harness.dispose);
      await harness.waitForState<AuthUnauthenticated>();
      expect(harness.databaseFactory.openedUserIds, isEmpty);
      expect(harness.rotation.userIds, [_userA.uid]);
      expect(harness.lifecycle.cancelledUserIds, [_userA.uid]);
      expect(harness.preferencesDeletion.userIds, isEmpty);
      expect(await harness.cycleStore.load(_userA.uid), isNotNull);
      expect(harness.repository.signOutCalls, 0);
      expect(await harness.readPendingCleanup(), isNull);
      final preserved = harness.database;
      expect(await preserved.select(preserved.taskTable).get(), hasLength(1));
      expect(
        await preserved.select(preserved.notificationsTable).get(),
        hasLength(1),
      );
    },
  );

  test(
    'external null then B waits for A cleanup before publishing B',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final harness = await _Harness.create(
        [0],
        tokenRotation: _ScriptedTokenRotation(
          callStarted: started,
          allowCall: release,
        ),
        syncManagerOverride: _SyncManager()..shouldDrain = false,
      );
      addTearDown(harness.dispose);
      final a = harness.databaseFactory.last!;
      await seedSessionRows(a, _userA.uid);
      harness.auth.emit(null);
      await started.future;
      final preparedB = Completer<void>();
      harness.container.listen<AuthState>(authNotifierProvider, (_, next) {
        if (next is AuthAuthenticated &&
            next.user.uid == _userB.uid &&
            !preparedB.isCompleted) {
          preparedB.complete();
        }
      });
      harness.auth.emit(_FirebaseUser(_userB.uid));
      release.complete();
      await preparedB.future;
      expect(a.closed, isTrue);
      final b = harness.container.read(databaseProvider);
      expect(b.identity!.uid, _userB.uid);
      expect(await b.select(b.taskTable).get(), isEmpty);
      expect(await harness.readPendingCleanup(), isNull);
      final preservedA = harness.databaseFactory.inspectClosed(
        _userA.uid,
        () => _userA.uid,
      );
      expect(await preservedA.select(preservedA.taskTable).get(), hasLength(1));
    },
  );

  test(
    'cold Auth cannot publish authenticated before session DB and token are prepared',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final harness = await _Harness.create(
        [0],
        waitForAuthentication: false,
        firebaseUser: _FirebaseUser(
          _userA.uid,
          onGetIdToken: () async {
            started.complete();
            await release.future;
          },
        ),
        syncManagerOverride: _SyncManager()..shouldDrain = false,
      );
      addTearDown(harness.dispose);
      await started.future;
      expect(harness.state, isNot(isA<AuthAuthenticated>()));
      expect(() => harness.container.read(databaseProvider), throwsA(anything));
      final published = <String>[];
      harness.container.listen<AuthState>(authNotifierProvider, (_, next) {
        if (next is AuthAuthenticated) {
          published.add(harness.container.read(databaseProvider).identity!.uid);
        }
      });
      release.complete();
      await harness.waitForState<AuthAuthenticated>();
      expect(published, [_userA.uid]);
      expect(harness.databaseFactory.openedUserIds, [_userA.uid]);
    },
  );

  test('delete A no happy path limpa A e termina sem sessão', () async {
    final harness = await _Harness.create(<int>[
      0,
    ], completeDeletionBySigningOut: true);
    addTearDown(harness.dispose);

    final a = harness.databaseFactory.last!;
    await seedSessionRows(a, _userA.uid);
    await harness.notifier.deleteAccount();

    expect(harness.repository.deletedExpectedUserIds, <String>[_userA.uid]);
    expect(harness.lifecycle.cancelledUserIds, <String>[_userA.uid]);
    expect(harness.preferencesDeletion.userIds, <String>[_userA.uid]);
    expect(await harness.cycleStore.load(_userA.uid), isNull);
    expect(await harness.cycleStore.load(_userB.uid), isNotNull);
    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.auth.currentUser, isNull);
    expect(await harness.readPendingCleanup(), isNull);
    expect(a.closed, isTrue);
    final deleted = harness.database;
    expect(await deleted.select(deleted.taskTable).get(), isEmpty);
    expect(await deleted.select(deleted.notificationsTable).get(), isEmpty);
    expect(await deleted.select(deleted.syncQueueTable).get(), isEmpty);
  });
}

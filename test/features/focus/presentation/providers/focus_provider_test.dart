import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/focus/data/remote/focus_remote_data_source.dart';
import 'package:life_os/features/focus/data/repositories/focus_repository.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/study/data/study_repository.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';

import '../../../../helpers/recording_analytics_platform.dart';

// ignore: subtype_of_sealed_class
class _User extends Fake implements User {
  _User(this.uid);
  @override
  final String uid;
}

// ignore: subtype_of_sealed_class
class _Auth extends Fake implements FirebaseAuth {
  @override
  User? currentUser = _User('a');
}

typedef _StartOperation =
    Future<FocusStartResponse> Function({
      required String targetId,
      required FocusRemoteTargetType targetType,
      required int plannedDurationSeconds,
    });
typedef _SessionOperation =
    Future<Object> Function({required String sessionId});

class _FakeFocusRepository implements FocusRepository {
  int saveCalls = 0;
  String? lastTargetId;
  String? lastTargetType;
  int? lastDurationSeconds;
  Future<void> Function()? saveOperation;

  @override
  Future<void> saveFocusSession(
    String targetId,
    String targetType,
    int durationSeconds,
  ) {
    saveCalls++;
    lastTargetId = targetId;
    lastTargetType = targetType;
    lastDurationSeconds = durationSeconds;
    return saveOperation?.call() ?? Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTasksRepository implements TasksRepository {
  int toggleCalls = 0;
  String? lastTaskId;
  bool? lastCurrentStatus;
  Future<void> Function()? toggleOperation;

  @override
  Future<void> toggleTaskStatus(String taskId, bool currentStatus) async {
    toggleCalls++;
    lastTaskId = taskId;
    lastCurrentStatus = currentStatus;
    await toggleOperation?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingSyncManager implements SyncManager {
  int processCalls = 0;
  Future<bool> Function()? processOperation;

  @override
  Future<bool> processPendingItems() {
    processCalls++;
    return processOperation?.call() ?? Future.value(true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStudyRepository implements StudyRepository {
  int addStudyTimeCalls = 0;
  String? lastSubjectId;
  int? lastElapsedSeconds;

  @override
  Future<void> addStudyTime(String subjectId, int elapsedSeconds) async {
    addStudyTimeCalls++;
    lastSubjectId = subjectId;
    lastElapsedSeconds = elapsedSeconds;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFocusRemoteDataSource implements FocusRemoteDataSource {
  int startCalls = 0;
  int finishCalls = 0;
  int cancelCalls = 0;
  int closeCalls = 0;
  String? lastTargetId;
  FocusRemoteTargetType? lastTargetType;
  int? lastPlannedDurationSeconds;
  final List<String> startedSessionIds = [];
  final List<String> finishedSessionIds = [];
  final List<String> cancelledSessionIds = [];
  final Map<String, int> _plannedDurations = {};
  _StartOperation? startOperation;
  _SessionOperation? finishOperation;
  _SessionOperation? cancelOperation;

  @override
  Future<FocusStartResponse> startFocus({
    required String targetId,
    required FocusRemoteTargetType targetType,
    required int plannedDurationSeconds,
    RemoteSendPermit? admission,
  }) async {
    startCalls++;
    lastTargetId = targetId;
    lastTargetType = targetType;
    lastPlannedDurationSeconds = plannedDurationSeconds;

    final operation = startOperation;
    final response = operation == null
        ? FocusStartResponse(
            sessionId: 'verified-$startCalls',
            plannedDurationSeconds: plannedDurationSeconds,
            startedAt: DateTime.utc(2026, 8, 17, 12),
            expiresAt: DateTime.utc(2026, 8, 17, 13),
            reused: false,
          )
        : await operation(
            targetId: targetId,
            targetType: targetType,
            plannedDurationSeconds: plannedDurationSeconds,
          );

    startedSessionIds.add(response.sessionId);
    _plannedDurations[response.sessionId] = plannedDurationSeconds;
    return response;
  }

  @override
  Future<FocusFinishResponse> finishFocus({
    required String sessionId,
    RemoteSendPermit? admission,
  }) async {
    finishCalls++;
    finishedSessionIds.add(sessionId);

    final operation = finishOperation;
    if (operation != null) {
      return await operation(sessionId: sessionId) as FocusFinishResponse;
    }

    return FocusFinishResponse(
      sessionId: sessionId,
      verifiedDurationSeconds: _plannedDurations[sessionId] ?? 1500,
      completedAt: DateTime.utc(2026, 8, 17, 13),
      replayed: false,
    );
  }

  @override
  Future<FocusCancelResponse> cancelFocus({
    required String sessionId,
    RemoteSendPermit? admission,
  }) async {
    cancelCalls++;
    cancelledSessionIds.add(sessionId);

    final operation = cancelOperation;
    if (operation != null) {
      return await operation(sessionId: sessionId) as FocusCancelResponse;
    }

    return FocusCancelResponse(
      sessionId: sessionId,
      cancelledAt: DateTime.utc(2026, 8, 17, 12, 30),
      replayed: false,
    );
  }

  @override
  void close() {
    closeCalls++;
  }
}

class _ControlledPeriodicTimer implements Timer {
  _ControlledPeriodicTimer(this._callback);

  final void Function(Timer timer) _callback;

  bool _isActive = true;
  int _tick = 0;

  void fire({bool force = false}) {
    fireAtTick(_tick + 1, force: force);
  }

  void fireAtTick(int tick, {bool force = false}) {
    if (!_isActive && !force) return;
    if (tick <= _tick) {
      throw ArgumentError.value(tick, 'tick', 'must increase monotonically');
    }

    _tick = tick;
    _callback(this);
  }

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _tick;

  @override
  void cancel() {
    _isActive = false;
  }
}

void main() {
  late _FakeFocusRepository focusRepository;
  late _FakeTasksRepository tasksRepository;
  late _FakeStudyRepository studyRepository;
  late _FakeFocusRemoteDataSource remoteDataSource;
  late _RecordingSyncManager syncManager;
  late RecordingAnalyticsPlatform analytics;
  late ProviderContainer container;
  late _ControlledPeriodicTimer timer;
  late AppDatabase database;
  late _Auth auth;
  late FocusRemoteDataSource activeRemote;
  late int timersCreated;

  setUp(() {
    focusRepository = _FakeFocusRepository();
    tasksRepository = _FakeTasksRepository();
    studyRepository = _FakeStudyRepository();
    remoteDataSource = _FakeFocusRemoteDataSource();
    activeRemote = remoteDataSource;
    timersCreated = 0;
    syncManager = _RecordingSyncManager();
    analytics = RecordingAnalyticsPlatform();
    auth = _Auth();
    database = AppDatabase(executor: NativeDatabase.memory());
    database.localMutations.bindSessionReader(() => auth.currentUser?.uid);
    database.localMutations.openPreparedSession();
    addTearDown(database.close);

    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        firebaseAuthProvider.overrideWithValue(auth),
        focusRepositoryProvider.overrideWithValue(focusRepository),
        syncManagerProvider.overrideWithValue(syncManager),
        tasksRepositoryProvider.overrideWithValue(tasksRepository),
        studyRepositoryProvider.overrideWithValue(studyRepository),
        focusRemoteDataSourceProvider.overrideWith((ref) => activeRemote),
        focusPeriodicTimerFactoryProvider.overrideWithValue((
          duration,
          callback,
        ) {
          timersCreated++;
          timer = _ControlledPeriodicTimer(callback);
          return timer;
        }),
        analyticsServiceProvider.overrideWithValue(
          AnalyticsService(platform: analytics),
        ),
      ],
    );

    addTearDown(container.dispose);
  });

  void configureTarget(
    FocusNotifier notifier,
    FocusTargetType targetType, {
    int minutes = 1,
  }) {
    final id = targetType == FocusTargetType.task ? 'task-1' : 'subject-1';
    notifier.selectTarget(id, 'Target', targetType);
    notifier.setCustomDuration(minutes);
  }

  Future<void> startAndFlush(FocusNotifier notifier) async {
    notifier.startTimer();
    await pumpEventQueue();
  }

  void finishCurrentTimer(int seconds) {
    for (var second = 0; second < seconds; second++) {
      timer.fire();
    }
  }

  void changeSession(String? uid) {
    auth.currentUser = uid == null ? null : _User(uid);
    database.localMutations.observeSession(uid);
  }

  void wireHttp({
    required Future<http.Response> Function(http.Request) handler,
    Future<String?> Function()? idToken,
    Future<String?> Function()? appCheck,
  }) {
    final client = MockClient(handler);
    addTearDown(client.close);
    activeRemote = FocusRemoteDataSource(
      client: client,
      captureRemoteSend: () => container.read(focusRemoteSendPermitProvider)(),
      idTokenProvider: idToken ?? () async => 'private-id-token',
      appCheckTokenProvider: appCheck ?? () async => 'private-app-check',
      baseUrl: 'https://example.test/api/focus',
    );
  }

  http.Response successfulHttp(http.Request request) {
    final payload = jsonDecode(request.body) as Map<String, dynamic>;
    final operation = request.url.pathSegments.last;
    return http.Response(
      jsonEncode(switch (operation) {
        'start' => {
          'sessionId': 'verified-http',
          'status': 'RUNNING',
          'plannedDurationSeconds': payload['plannedDurationSeconds'],
          'startedAt': '2026-08-17T12:00:00Z',
          'expiresAt': '2026-08-17T13:00:00Z',
          'reused': false,
        },
        'finish' => {
          'sessionId': payload['sessionId'],
          'status': 'COMPLETED',
          'verifiedDurationSeconds': 60,
          'completedAt': '2026-08-17T13:00:00Z',
          'replayed': false,
        },
        _ => {
          'sessionId': payload['sessionId'],
          'status': 'CANCELLED',
          'cancelledAt': '2026-08-17T12:05:00Z',
          'replayed': false,
        },
      }),
      200,
    );
  }

  group('R1 aborted logout target recovery', () {
    for (final phase in ['ID Token', 'App Check']) {
      for (final releaseBeforeAbort in [false, true]) {
        test(
          '$phase pending, release before abort=$releaseBeforeAbort unlocks idle target',
          () async {
            final started = Completer<void>();
            final token = Completer<String?>();
            final postedTargets = <String>[];
            var idLoads = 0;
            var appLoads = 0;
            wireHttp(
              handler: (request) async {
                expect(request.url.pathSegments.last, 'start');
                postedTargets.add(
                  (jsonDecode(request.body) as Map<String, dynamic>)['targetId']
                      as String,
                );
                return successfulHttp(request);
              },
              idToken: () {
                idLoads++;
                if (phase == 'ID Token' && !started.isCompleted) {
                  started.complete();
                  return token.future;
                }
                return Future.value('private-id-token');
              },
              appCheck: () {
                appLoads++;
                if (phase == 'App Check' && !started.isCompleted) {
                  started.complete();
                  return token.future;
                }
                return Future.value('private-app-check');
              },
            );
            final originalAdmission = container.read(
              focusRemoteSendPermitProvider,
            )();
            final notifier = container.read(focusProvider.notifier);
            configureTarget(notifier, FocusTargetType.task);
            notifier.startTimer();
            await started.future;
            expect(container.read(focusProvider).targetLocked, isTrue);
            final barrier = database.localMutations.beginQuiesce('a');
            await barrier.drain();
            if (releaseBeforeAbort) {
              token.complete('private-token');
              await pumpEventQueue();
              // Returning from preflight while quiescent must hold no lease.
              await barrier.drain();
            }
            barrier.finish(signOutConfirmed: false);
            if (!releaseBeforeAbort) token.complete('private-token');
            await pumpEventQueue();

            final recovered = container.read(focusProvider);
            expect(recovered.targetLocked, isFalse);
            expect(recovered.isRunning, isFalse);
            expect(recovered.activeTargetId, 'task-1');
            expect(recovered.activeTargetType, FocusTargetType.task);
            expect(recovered.durationRemaining, 60);
            expect(originalAdmission.isCurrent, isFalse);
            expect(postedTargets, isEmpty);
            expect(timersCreated, 0);
            expect(idLoads, 1);
            expect(appLoads, phase == 'App Check' ? 1 : 0);

            // These public actions also prove the pending-start flag is cleared.
            notifier.selectTarget(
              'subject-new',
              'New subject',
              FocusTargetType.subject,
            );
            notifier.setCustomDuration(3);
            expect(container.read(focusProvider).activeTargetId, 'subject-new');
            expect(container.read(focusProvider).durationRemaining, 180);
            expect(postedTargets, isEmpty);
            expect(timersCreated, 0);
            notifier.startTimer();
            notifier.startTimer();
            await pumpEventQueue();
            expect(postedTargets, ['subject-new']);
            expect(timersCreated, 1);
            expect(container.read(focusProvider).isRunning, isTrue);
            expect(container.read(focusProvider).targetLocked, isTrue);
            expect(container.read(focusProvider).activeTargetId, 'subject-new');
            expect(originalAdmission.isCurrent, isFalse);
            expect(focusRepository.saveCalls, 0);
          },
        );
      }
    }

    test(
      'queued recovery after dispose cannot unlock a newer running cycle',
      () async {
        final started = Completer<void>();
        final token = Completer<String?>();
        final postedTargets = <String>[];
        wireHttp(
          handler: (request) async {
            postedTargets.add(
              (jsonDecode(request.body) as Map<String, dynamic>)['targetId']
                  as String,
            );
            return successfulHttp(request);
          },
          idToken: () {
            if (!started.isCompleted) {
              started.complete();
              return token.future;
            }
            return Future.value('private-token');
          },
        );
        final oldNotifier = container.read(focusProvider.notifier);
        configureTarget(oldNotifier, FocusTargetType.task);
        oldNotifier.startTimer();
        await started.future;
        final barrier = database.localMutations.beginQuiesce('a');
        await barrier.drain();
        token.complete('private-token');
        await pumpEventQueue();
        container.invalidate(focusProvider);
        final newNotifier = container.read(focusProvider.notifier);
        barrier.finish(signOutConfirmed: false);
        configureTarget(newNotifier, FocusTargetType.subject);
        newNotifier.startTimer();
        await pumpEventQueue();
        expect(postedTargets, ['subject-1']);
        expect(timersCreated, 1);
        expect(container.read(focusProvider).targetLocked, isTrue);
        expect(container.read(focusProvider).isRunning, isTrue);
        expect(container.read(focusProvider).activeTargetId, 'subject-1');
        newNotifier.selectTarget(
          'other-task',
          'Other task',
          FocusTargetType.task,
        );
        expect(container.read(focusProvider).activeTargetId, 'subject-1');
      },
    );

    for (final transition in ['A-B', 'A-null-A']) {
      test('queued recovery does not mutate state after $transition', () async {
        final started = Completer<void>();
        final token = Completer<String?>();
        var posts = 0;
        wireHttp(
          handler: (request) async {
            posts++;
            return successfulHttp(request);
          },
          idToken: () {
            started.complete();
            return token.future;
          },
        );
        final notifier = container.read(focusProvider.notifier);
        configureTarget(notifier, FocusTargetType.task);
        notifier.startTimer();
        await started.future;
        final before = container.read(focusProvider);
        final barrier = database.localMutations.beginQuiesce('a');
        await barrier.drain();
        token.complete('private-token');
        await pumpEventQueue();
        changeSession(transition == 'A-B' ? 'b' : null);
        barrier.finish(signOutConfirmed: false);
        if (transition == 'A-null-A') {
          changeSession('a');
          database.localMutations.openPreparedSession();
        }
        await pumpEventQueue();
        expect(container.read(focusProvider), same(before));
        expect(posts, 0);
        expect(timersCreated, 0);
        expect(focusRepository.saveCalls, 0);
      });
    }

    test(
      'running cycle after aborted logout keeps target and completes locally without finish POST',
      () async {
        final operations = <String>[];
        var idLoads = 0;
        var appLoads = 0;
        wireHttp(
          handler: (request) async {
            operations.add(request.url.pathSegments.last);
            return successfulHttp(request);
          },
          idToken: () async {
            idLoads++;
            return 'private-id-token';
          },
          appCheck: () async {
            appLoads++;
            return 'private-app-check';
          },
        );
        final originalAdmission = container.read(
          focusRemoteSendPermitProvider,
        )();
        final notifier = container.read(focusProvider.notifier);
        configureTarget(notifier, FocusTargetType.subject);
        await startAndFlush(notifier);
        timer.fire();
        final running = container.read(focusProvider);
        final barrier = database.localMutations.beginQuiesce('a');
        await barrier.drain();
        barrier.finish(signOutConfirmed: false);
        expect(originalAdmission.isCurrent, isFalse);
        expect(container.read(focusProvider), same(running));
        notifier.selectTarget('other-task', 'Other task', FocusTargetType.task);
        expect(container.read(focusProvider).activeTargetId, 'subject-1');
        expect(container.read(focusProvider).targetLocked, isTrue);
        expect(container.read(focusProvider).isRunning, isTrue);
        timer.fireAtTick(60);
        await pumpEventQueue();
        expect(operations, ['start']);
        expect(idLoads, 1);
        expect(appLoads, 1);
        expect(timersCreated, 1);
        expect(focusRepository.saveCalls, 1);
        expect(focusRepository.lastTargetId, 'subject-1');
        expect(focusRepository.lastTargetType, 'SUBJECT');
        expect(focusRepository.lastDurationSeconds, 60);
        expect(studyRepository.addStudyTimeCalls, 1);
        expect(studyRepository.lastSubjectId, 'subject-1');
        expect(tasksRepository.toggleCalls, 0);
        expect(container.read(focusProvider).isBreak, isTrue);
        expect(container.read(focusProvider).targetLocked, isFalse);
        expect(originalAdmission.isCurrent, isFalse);
      },
    );
  });

  group('remote session admission integration', () {
    for (final operation in ['finish', 'cancel']) {
      for (final phase in ['ID Token', 'App Check']) {
        test('$operation pending $phase cannot POST after logout', () async {
          final started = Completer<void>();
          final token = Completer<String?>();
          final operations = <String>[];
          var idLoads = 0;
          var appLoads = 0;
          wireHttp(
            handler: (request) async {
              operations.add(request.url.pathSegments.last);
              return successfulHttp(request);
            },
            idToken: () {
              idLoads++;
              if (phase == 'ID Token' && idLoads == 2) {
                started.complete();
                return token.future;
              }
              return Future.value('private-id-token');
            },
            appCheck: () {
              appLoads++;
              if (phase == 'App Check' && appLoads == 2) {
                started.complete();
                return token.future;
              }
              return Future.value('private-app-check');
            },
          );
          final notifier = container.read(focusProvider.notifier);
          configureTarget(notifier, FocusTargetType.task);
          await startAndFlush(notifier);
          if (operation == 'finish') {
            finishCurrentTimer(60);
          } else {
            notifier.resetTimer();
          }
          await started.future;
          final barrier = database.localMutations.beginQuiesce('a');
          await barrier.drain();
          expect(token.isCompleted, isFalse);
          changeSession(null);
          barrier.finish(signOutConfirmed: true);
          container.invalidate(focusProvider);
          container.read(focusProvider);
          token.complete('private-token');
          await pumpEventQueue();
          expect(operations, ['start']);
          expect(container.read(focusProvider).isRunning, isFalse);
          expect(container.read(focusProvider).isBreak, isFalse);
          expect(focusRepository.saveCalls, operation == 'finish' ? 1 : 0);
          expect(tasksRepository.toggleCalls, operation == 'finish' ? 1 : 0);
        });
      }
    }

    for (final phase in ['ID Token', 'App Check']) {
      test('logout during $phase stops POST without delaying drain', () async {
        final started = Completer<void>();
        final token = Completer<String?>();
        var posts = 0;
        Future<String?> holdToken() {
          started.complete();
          return token.future;
        }

        wireHttp(
          handler: (request) async {
            posts++;
            return successfulHttp(request);
          },
          idToken: phase == 'ID Token' ? holdToken : null,
          appCheck: phase == 'App Check' ? holdToken : null,
        );
        final notifier = container.read(focusProvider.notifier);
        configureTarget(notifier, FocusTargetType.task);
        notifier.startTimer();
        await started.future;
        final barrier = database.localMutations.beginQuiesce('a');
        await barrier.drain();
        expect(token.isCompleted, isFalse);
        changeSession(null);
        barrier.finish(signOutConfirmed: true);
        container.invalidate(focusProvider);
        container.read(focusProvider);
        token.complete('private-token');
        await pumpEventQueue();
        expect(posts, 0);
        expect(timersCreated, 0);
        expect(focusRepository.saveCalls, 0);
        expect(tasksRepository.toggleCalls, 0);
        expect(container.read(focusProvider).isRunning, isFalse);
      });
    }

    for (final transition in ['A-B', 'A-null-A', 'abort logout']) {
      test(
        '$transition cannot revive pending start even without dispose',
        () async {
          final started = Completer<void>();
          final token = Completer<String?>();
          var posts = 0;
          wireHttp(
            handler: (request) async {
              posts++;
              return successfulHttp(request);
            },
            idToken: () {
              if (!started.isCompleted) {
                started.complete();
                return token.future;
              }
              return Future.value('new-private-token');
            },
          );
          final notifier = container.read(focusProvider.notifier);
          configureTarget(notifier, FocusTargetType.task);
          notifier.startTimer();
          await started.future;
          final barrier = database.localMutations.beginQuiesce('a');
          await barrier.drain();
          if (transition == 'abort logout') {
            barrier.finish(signOutConfirmed: false);
          } else {
            changeSession(transition == 'A-B' ? 'b' : null);
            barrier.finish(signOutConfirmed: true);
            if (transition == 'A-null-A') {
              changeSession('a');
              database.localMutations.openPreparedSession();
            }
          }
          token.complete('old-private-token');
          await pumpEventQueue();
          expect(posts, 0);
          expect(timersCreated, 0);
          expect(container.read(focusProvider).isRunning, isFalse);
          if (transition != 'A-B') {
            await startAndFlush(notifier);
            expect(posts, 1);
            expect(timersCreated, 1);
            expect(container.read(focusProvider).isRunning, isTrue);
          }
        },
      );
    }

    test(
      'dispose during preflight invalidates only the old notifier',
      () async {
        final started = Completer<void>();
        final token = Completer<String?>();
        var posts = 0;
        wireHttp(
          handler: (request) async {
            posts++;
            return successfulHttp(request);
          },
          idToken: () {
            if (!started.isCompleted) {
              started.complete();
              return token.future;
            }
            return Future.value('new-private-token');
          },
        );
        final oldNotifier = container.read(focusProvider.notifier);
        configureTarget(oldNotifier, FocusTargetType.task);
        oldNotifier.startTimer();
        await started.future;
        container.invalidate(focusProvider);
        final newNotifier = container.read(focusProvider.notifier);
        token.complete('old-private-token');
        await pumpEventQueue();
        expect(posts, 0);
        expect(timersCreated, 0);
        configureTarget(newNotifier, FocusTargetType.subject);
        await startAndFlush(newNotifier);
        expect(posts, 1);
        expect(timersCreated, 1);
        expect(container.read(focusProvider).activeTargetId, 'subject-1');
      },
    );

    test(
      'already sent start response cannot revive invalidated session',
      () async {
        final sent = Completer<void>();
        final response = Completer<http.Response>();
        var posts = 0;
        late http.Request captured;
        wireHttp(
          handler: (request) {
            posts++;
            captured = request;
            sent.complete();
            return response.future;
          },
        );
        final notifier = container.read(focusProvider.notifier);
        configureTarget(notifier, FocusTargetType.task);
        notifier.startTimer();
        await sent.future;
        final barrier = database.localMutations.beginQuiesce('a');
        await barrier.drain();
        changeSession(null);
        barrier.finish(signOutConfirmed: true);
        response.complete(successfulHttp(captured));
        await pumpEventQueue();
        expect(posts, 1);
        expect(timersCreated, 0);
        expect(focusRepository.saveCalls, 0);
        expect(container.read(focusProvider).isRunning, isFalse);
      },
    );

    for (final action in ['reset', 'pause']) {
      test(
        '$action in same session permits late start and legitimate cancel',
        () async {
          final started = Completer<void>();
          final token = Completer<String?>();
          final operations = <String>[];
          wireHttp(
            handler: (request) async {
              operations.add(request.url.pathSegments.last);
              return successfulHttp(request);
            },
            idToken: () {
              if (!started.isCompleted) {
                started.complete();
                return token.future;
              }
              return Future.value('private-token');
            },
          );
          final notifier = container.read(focusProvider.notifier);
          configureTarget(notifier, FocusTargetType.task);
          notifier.startTimer();
          await started.future;
          if (action == 'reset') {
            notifier.resetTimer();
          } else {
            notifier.pauseTimer();
          }
          token.complete('private-token');
          await pumpEventQueue();
          expect(operations, ['start', 'cancel']);
          expect(timersCreated, 0);
          expect(focusRepository.saveCalls, 0);
          expect(container.read(focusProvider).isRunning, isFalse);
          expect(container.read(focusProvider).targetLocked, action == 'pause');
        },
      );
    }

    test(
      'normal HTTP flow has one start, one finish and one set of local effects',
      () async {
        final operations = <String>[];
        wireHttp(
          handler: (request) async {
            operations.add(request.url.pathSegments.last);
            return successfulHttp(request);
          },
        );
        final notifier = container.read(focusProvider.notifier);
        configureTarget(notifier, FocusTargetType.task);
        notifier.startTimer();
        notifier.startTimer();
        await pumpEventQueue();
        finishCurrentTimer(60);
        timer.fire(force: true);
        await pumpEventQueue();
        expect(operations, ['start', 'finish']);
        expect(focusRepository.saveCalls, 1);
        expect(tasksRepository.toggleCalls, 1);
        expect(container.read(focusProvider).isBreak, isTrue);
      },
    );

    test(
      'unavailable remote authentication preserves personal local fallback',
      () async {
        var posts = 0;
        wireHttp(
          handler: (request) async {
            posts++;
            return successfulHttp(request);
          },
          idToken: () async => null,
        );
        final notifier = container.read(focusProvider.notifier);
        configureTarget(notifier, FocusTargetType.subject);
        await startAndFlush(notifier);
        expect(container.read(focusProvider).isRunning, isTrue);
        expect(posts, 0);
        expect(timersCreated, 1);
        finishCurrentTimer(60);
        await pumpEventQueue();
        expect(posts, 0);
        expect(focusRepository.saveCalls, 1);
        expect(studyRepository.addStudyTimeCalls, 1);
        expect(container.read(focusProvider).isBreak, isTrue);
      },
    );

    for (final invalidUid in <String?>[null, '', '   ']) {
      test('production capture rejects UID $invalidUid', () {
        auth.currentUser = invalidUid == null ? null : _User(invalidUid);
        expect(
          () => container.read(focusRemoteSendPermitProvider),
          returnsNormally,
        );
        expect(
          () => container.read(focusRemoteSendPermitProvider)(),
          throwsA(isA<RemoteSessionStopped>()),
        );
      });
    }

    test('production capture fails closed without prepared database', () {
      final isolated = ProviderContainer(
        overrides: [
          firebaseAuthProvider.overrideWithValue(auth),
          databaseProvider.overrideWith(
            (ref) => throw StateError('not prepared'),
          ),
        ],
      );
      addTearDown(isolated.dispose);
      expect(
        () => isolated.read(focusRemoteSendPermitProvider)(),
        throwsA(isA<RemoteSessionStopped>()),
      );
    });
  });

  test('selecting a task defines TASK target type', () {
    container
        .read(focusProvider.notifier)
        .selectTarget('task-1', 'Task', FocusTargetType.task);

    final state = container.read(focusProvider);

    expect(state.activeTargetId, 'task-1');
    expect(state.activeTargetType, FocusTargetType.task);
    expect(state.activeTargetType?.value, 'TASK');
  });

  test('selecting a subject defines SUBJECT target type', () {
    container
        .read(focusProvider.notifier)
        .selectTarget('subject-1', 'Subject', FocusTargetType.subject);

    final state = container.read(focusProvider);

    expect(state.activeTargetId, 'subject-1');
    expect(state.activeTargetType, FocusTargetType.subject);
    expect(state.activeTargetType?.value, 'SUBJECT');
  });

  test('validateActiveTarget clears an invalid target', () {
    final notifier = container.read(focusProvider.notifier);

    notifier.selectTarget('task-1', 'Task', FocusTargetType.task);
    notifier.validateActiveTarget(const ['task-2']);

    final state = container.read(focusProvider);

    expect(state.activeTargetId, isNull);
    expect(state.activeTargetTitle, isNull);
    expect(state.activeTargetType, isNull);
  });

  test('target cannot change while verified start is pending', () async {
    final startCompleter = Completer<FocusStartResponse>();
    remoteDataSource.startOperation =
        ({
          required targetId,
          required targetType,
          required plannedDurationSeconds,
        }) => startCompleter.future;
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);

    notifier.startTimer();
    expect(container.read(focusProvider).targetLocked, isTrue);
    expect(container.read(focusProvider).isRunning, isFalse);
    notifier.selectTarget('subject-1', 'Subject', FocusTargetType.subject);

    expect(container.read(focusProvider).activeTargetId, 'task-1');

    startCompleter.complete(
      FocusStartResponse(
        sessionId: 'pending-session',
        plannedDurationSeconds: 60,
        startedAt: DateTime.utc(2026, 8, 17, 12),
        expiresAt: DateTime.utc(2026, 8, 17, 13),
        reused: false,
      ),
    );
    await pumpEventQueue();

    expect(container.read(focusProvider).isRunning, isTrue);
    expect(container.read(focusProvider).targetLocked, isTrue);
  });

  test('TASK full session starts and finishes verified exactly once', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);

    await startAndFlush(notifier);
    finishCurrentTimer(60);
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 1);
    expect(remoteDataSource.lastTargetId, 'task-1');
    expect(remoteDataSource.lastTargetType, FocusRemoteTargetType.task);
    expect(remoteDataSource.lastPlannedDurationSeconds, 60);
    expect(remoteDataSource.finishCalls, 1);
    expect(remoteDataSource.finishedSessionIds, ['verified-1']);
    expect(focusRepository.saveCalls, 1);
    expect(focusRepository.lastTargetId, 'task-1');
    expect(focusRepository.lastTargetType, 'TASK');
    expect(focusRepository.lastDurationSeconds, 60);
    expect(tasksRepository.toggleCalls, 1);
    expect(studyRepository.addStudyTimeCalls, 0);
    expect(container.read(focusProvider).isBreak, isTrue);
    expect(analytics.events, <RecordedAnalyticsEvent>[
      const RecordedAnalyticsEvent('focus_completed', {'duration_minutes': 1}),
    ]);
  });

  for (final firstSyncPending in [true, false]) {
    test(
      'TASK dispatches after enqueue while first sync is '
      '${firstSyncPending ? "pending" : "completed"} without delaying BREAK',
      () async {
        final events = <String>[];
        final upload = Completer<bool>();
        final toggleStarted = Completer<void>();
        final releaseToggle = Completer<void>();
        syncManager.processOperation = () {
          events.add('dispatch');
          if (!firstSyncPending && syncManager.processCalls == 1) {
            return Future.value(true);
          }
          return upload.future;
        };
        focusRepository.saveOperation = () async {
          events.add('save');
          unawaited(syncManager.processPendingItems());
        };
        tasksRepository.toggleOperation = () async {
          toggleStarted.complete();
          await releaseToggle.future;
          events.add('task-enqueued');
        };
        final notifier = container.read(focusProvider.notifier);
        configureTarget(notifier, FocusTargetType.task);
        await startAndFlush(notifier);

        finishCurrentTimer(60);
        await toggleStarted.future;
        expect(syncManager.processCalls, 1);
        expect(events, ['save', 'dispatch']);

        releaseToggle.complete();
        await pumpEventQueue();

        expect(events, ['save', 'dispatch', 'task-enqueued', 'dispatch']);
        expect(syncManager.processCalls, 2);
        expect(focusRepository.saveCalls, 1);
        expect(tasksRepository.toggleCalls, 1);
        expect(upload.isCompleted, isFalse);
        expect(container.read(focusProvider).isBreak, isTrue);

        upload.complete(true);
        await pumpEventQueue();
        expect(syncManager.processCalls, 2);
      },
    );
  }

  test(
    'TASK sync dispatch failure does not prevent local completion',
    () async {
      syncManager.processOperation = () =>
          Future<bool>.error(StateError('technical-dispatch-marker'));
      final notifier = container.read(focusProvider.notifier);
      configureTarget(notifier, FocusTargetType.task);
      await startAndFlush(notifier);

      finishCurrentTimer(60);
      await pumpEventQueue();

      expect(syncManager.processCalls, 1);
      expect(focusRepository.saveCalls, 1);
      expect(tasksRepository.toggleCalls, 1);
      expect(container.read(focusProvider).isBreak, isTrue);
      expect(container.read(focusProvider).isRunning, isFalse);
    },
  );

  test('skipped timer ticks reconcile elapsed time and finish once', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    expect(container.read(focusProvider).durationRemaining, 60);

    timer.fireAtTick(20);

    expect(container.read(focusProvider).durationRemaining, 40);
    expect(container.read(focusProvider).durationRemaining, isNot(59));

    timer.fireAtTick(60);

    expect(container.read(focusProvider).durationRemaining, 0);
    expect(container.read(focusProvider).isRunning, isFalse);

    await pumpEventQueue();
    timer.fire();
    await pumpEventQueue();

    expect(remoteDataSource.finishCalls, 1);
    expect(focusRepository.saveCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
  });

  test('SUBJECT full session finishes verified and adds study time', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.subject);

    await startAndFlush(notifier);
    finishCurrentTimer(60);
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 1);
    expect(remoteDataSource.lastTargetType, FocusRemoteTargetType.subject);
    expect(remoteDataSource.finishCalls, 1);
    expect(focusRepository.saveCalls, 1);
    expect(focusRepository.lastTargetId, 'subject-1');
    expect(focusRepository.lastTargetType, 'SUBJECT');
    expect(studyRepository.addStudyTimeCalls, 1);
    expect(studyRepository.lastSubjectId, 'subject-1');
    expect(studyRepository.lastElapsedSeconds, 60);
    expect(tasksRepository.toggleCalls, 0);
    expect(syncManager.processCalls, 0);
    expect(container.read(focusProvider).isBreak, isTrue);
    expect(analytics.events, <RecordedAnalyticsEvent>[
      const RecordedAnalyticsEvent('focus_completed', {'duration_minutes': 1}),
    ]);
  });

  test('start failure keeps the personal session local-only', () async {
    remoteDataSource.startOperation =
        ({
          required targetId,
          required targetType,
          required plannedDurationSeconds,
        }) async => throw StateError('offline');
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);

    await startAndFlush(notifier);

    expect(container.read(focusProvider).isRunning, isTrue);

    finishCurrentTimer(60);
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 1);
    expect(remoteDataSource.finishCalls, 0);
    expect(analytics.events, <RecordedAnalyticsEvent>[
      const RecordedAnalyticsEvent('focus_completed', {'duration_minutes': 1}),
    ]);
    expect(focusRepository.saveCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
    expect(container.read(focusProvider).isBreak, isTrue);
  });

  test('pause cancels a verified session and invalidates it', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    notifier.pauseTimer();
    await pumpEventQueue();

    expect(container.read(focusProvider).isRunning, isFalse);
    expect(remoteDataSource.cancelCalls, 1);
    expect(remoteDataSource.cancelledSessionIds, ['verified-1']);
    expect(remoteDataSource.finishCalls, 0);
    expect(analytics.events, isEmpty);
  });

  test('resume after pause does not create another verified start', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    final firstTimer = timer;
    firstTimer.fireAtTick(20);
    expect(container.read(focusProvider).durationRemaining, 40);

    notifier.pauseTimer();
    await pumpEventQueue();
    notifier.startTimer();

    final resumedTimer = timer;
    expect(container.read(focusProvider).isRunning, isTrue);
    expect(remoteDataSource.startCalls, 1);
    expect(resumedTimer, isNot(same(firstTimer)));
    expect(resumedTimer.tick, 0);

    resumedTimer.fireAtTick(15);
    expect(container.read(focusProvider).durationRemaining, 25);

    resumedTimer.fireAtTick(40);
    await pumpEventQueue();

    expect(remoteDataSource.finishCalls, 0);
    expect(focusRepository.saveCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
  });

  test(
    'reset cancels verified session and next full start verifies again',
    () async {
      final notifier = container.read(focusProvider.notifier);
      configureTarget(notifier, FocusTargetType.task);
      await startAndFlush(notifier);

      notifier.resetTimer();
      await pumpEventQueue();

      expect(remoteDataSource.cancelCalls, 1);
      expect(container.read(focusProvider).durationRemaining, 60);
      expect(container.read(focusProvider).isRunning, isFalse);
      expect(analytics.events, isEmpty);

      await startAndFlush(notifier);

      expect(remoteDataSource.startCalls, 2);
      expect(container.read(focusProvider).isRunning, isTrue);
    },
  );

  test('new start waits for pending reset cancel before starting', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    final cancelCompleter = Completer<FocusCancelResponse>();
    remoteDataSource.cancelOperation = ({required sessionId}) =>
        cancelCompleter.future;

    notifier.resetTimer();
    notifier.startTimer();

    expect(remoteDataSource.cancelCalls, 1);
    expect(remoteDataSource.startCalls, 1);
    expect(container.read(focusProvider).isRunning, isFalse);

    cancelCompleter.complete(
      FocusCancelResponse(
        sessionId: 'verified-1',
        cancelledAt: DateTime.utc(2026, 8, 17, 12, 30),
        replayed: false,
      ),
    );
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 2);
    expect(remoteDataSource.startedSessionIds, ['verified-1', 'verified-2']);
    expect(container.read(focusProvider).isRunning, isTrue);
  });

  test('failed pending reset cancel makes next cycle local-only', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    final cancelCompleter = Completer<FocusCancelResponse>();
    remoteDataSource.cancelOperation = ({required sessionId}) =>
        cancelCompleter.future;

    notifier.resetTimer();
    notifier.startTimer();

    expect(remoteDataSource.startCalls, 1);
    expect(container.read(focusProvider).isRunning, isFalse);

    cancelCompleter.completeError(StateError('cancel unavailable'));
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 1);
    expect(remoteDataSource.startedSessionIds, ['verified-1']);
    expect(container.read(focusProvider).isRunning, isTrue);

    finishCurrentTimer(60);
    await pumpEventQueue();

    expect(remoteDataSource.finishCalls, 0);
    expect(remoteDataSource.finishedSessionIds, isEmpty);
    expect(focusRepository.saveCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
    expect(container.read(focusProvider).isBreak, isTrue);
    expect(analytics.events, <RecordedAnalyticsEvent>[
      const RecordedAnalyticsEvent('focus_completed', {'duration_minutes': 1}),
    ]);
  });

  test(
    'failed cancel remains pending across local cycle until retry succeeds',
    () async {
      final notifier = container.read(focusProvider.notifier);
      configureTarget(notifier, FocusTargetType.task);
      await startAndFlush(notifier);

      final firstCancel = Completer<FocusCancelResponse>();
      remoteDataSource.cancelOperation = ({required sessionId}) =>
          firstCancel.future;

      notifier.resetTimer();
      notifier.startTimer();
      firstCancel.completeError(StateError('cancel unavailable'));
      await pumpEventQueue();

      expect(remoteDataSource.startCalls, 1);
      expect(container.read(focusProvider).isRunning, isTrue);

      finishCurrentTimer(60);
      await pumpEventQueue();
      expect(container.read(focusProvider).isBreak, isTrue);

      notifier.toggleSessionType();
      final retryCancel = Completer<FocusCancelResponse>();
      remoteDataSource.cancelOperation = ({required sessionId}) =>
          retryCancel.future;

      notifier.startTimer();

      expect(remoteDataSource.cancelCalls, 2);
      expect(remoteDataSource.startCalls, 1);
      expect(container.read(focusProvider).isRunning, isFalse);

      retryCancel.complete(
        FocusCancelResponse(
          sessionId: 'verified-1',
          cancelledAt: DateTime.utc(2026, 8, 17, 13),
          replayed: false,
        ),
      );
      await pumpEventQueue();

      expect(remoteDataSource.startCalls, 2);
      expect(remoteDataSource.startedSessionIds, ['verified-1', 'verified-2']);
      expect(container.read(focusProvider).isRunning, isTrue);
    },
  );

  test('FOCUS_SESSION_EXPIRED clears pending invalidation', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    remoteDataSource.cancelOperation = ({required sessionId}) async =>
        throw StateError('cancel unavailable');

    notifier.resetTimer();
    notifier.startTimer();
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 1);
    expect(container.read(focusProvider).isRunning, isTrue);

    finishCurrentTimer(60);
    await pumpEventQueue();
    notifier.toggleSessionType();

    remoteDataSource.cancelOperation = ({required sessionId}) async =>
        throw const FocusRemoteException(
          statusCode: 409,
          code: 'FOCUS_SESSION_EXPIRED',
          message: 'Session expired.',
          isRetryable: false,
        );

    await startAndFlush(notifier);

    expect(remoteDataSource.cancelCalls, 2);
    expect(remoteDataSource.startCalls, 2);
    expect(remoteDataSource.startedSessionIds, ['verified-1', 'verified-2']);
    expect(container.read(focusProvider).isRunning, isTrue);
  });

  test('BREAK performs no remote Focus operation', () async {
    final notifier = container.read(focusProvider.notifier);
    notifier.toggleSessionType();

    notifier.startTimer();
    timer.fireAtTick(120);

    expect(container.read(focusProvider).durationRemaining, 180);

    timer.fireAtTick(300);
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 0);
    expect(remoteDataSource.finishCalls, 0);
    expect(remoteDataSource.cancelCalls, 0);
    expect(analytics.events, isEmpty);
    expect(focusRepository.saveCalls, 0);
    expect(syncManager.processCalls, 0);
    expect(container.read(focusProvider).isBreak, isFalse);
  });

  test('finish failure does not block personal effects or break', () async {
    remoteDataSource.finishOperation = ({required sessionId}) async =>
        throw StateError('backend unavailable');
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    finishCurrentTimer(60);
    await pumpEventQueue();

    expect(remoteDataSource.finishCalls, 1);
    expect(focusRepository.saveCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
    expect(container.read(focusProvider).isBreak, isTrue);
  });

  test('duplicate timer callback does not duplicate any effects', () async {
    final saveCompleter = Completer<void>();
    focusRepository.saveOperation = () => saveCompleter.future;
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    finishCurrentTimer(60);
    timer.fire(force: true);

    expect(remoteDataSource.finishCalls, 1);
    expect(focusRepository.saveCalls, 1);

    saveCompleter.complete();
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 1);
    expect(remoteDataSource.finishCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
    expect(studyRepository.addStudyTimeCalls, 0);
    expect(analytics.events, <RecordedAnalyticsEvent>[
      const RecordedAnalyticsEvent('focus_completed', {'duration_minutes': 1}),
    ]);
  });

  test('Analytics failure does not break natural Focus completion', () async {
    analytics.throwOnEvent = true;
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    finishCurrentTimer(60);
    await pumpEventQueue();

    expect(focusRepository.saveCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
    expect(container.read(focusProvider).isBreak, isTrue);
  });

  test(
    'failed stale cancel remains pending before a future verified start',
    () async {
      final startCompleter = Completer<FocusStartResponse>();
      remoteDataSource.startOperation =
          ({
            required targetId,
            required targetType,
            required plannedDurationSeconds,
          }) => startCompleter.future;
      remoteDataSource.cancelOperation = ({required sessionId}) async =>
          throw StateError('cancel unavailable');
      final notifier = container.read(focusProvider.notifier);
      configureTarget(notifier, FocusTargetType.task);

      notifier.startTimer();
      notifier.resetTimer();
      startCompleter.complete(
        FocusStartResponse(
          sessionId: 'stale-session',
          plannedDurationSeconds: 60,
          startedAt: DateTime.utc(2026, 8, 17, 12),
          expiresAt: DateTime.utc(2026, 8, 17, 13),
          reused: false,
        ),
      );
      await pumpEventQueue();

      expect(container.read(focusProvider).isRunning, isFalse);
      expect(remoteDataSource.startCalls, 1);
      expect(remoteDataSource.cancelCalls, 1);
      expect(remoteDataSource.cancelledSessionIds, ['stale-session']);

      final retryCancel = Completer<FocusCancelResponse>();
      remoteDataSource.cancelOperation = ({required sessionId}) =>
          retryCancel.future;
      remoteDataSource.startOperation = null;
      notifier.startTimer();

      expect(remoteDataSource.cancelCalls, 2);
      expect(remoteDataSource.startCalls, 1);
      expect(container.read(focusProvider).isRunning, isFalse);

      retryCancel.complete(
        FocusCancelResponse(
          sessionId: 'stale-session',
          cancelledAt: DateTime.utc(2026, 8, 17, 13),
          replayed: false,
        ),
      );
      await pumpEventQueue();

      expect(remoteDataSource.startCalls, 2);
      expect(remoteDataSource.startedSessionIds, [
        'stale-session',
        'verified-2',
      ]);
      expect(container.read(focusProvider).isRunning, isTrue);
    },
  );

  test('double tap while start is pending performs one start only', () async {
    final startCompleter = Completer<FocusStartResponse>();
    remoteDataSource.startOperation =
        ({
          required targetId,
          required targetType,
          required plannedDurationSeconds,
        }) => startCompleter.future;
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);

    notifier.startTimer();
    notifier.startTimer();

    expect(remoteDataSource.startCalls, 1);

    notifier.resetTimer();
    startCompleter.complete(
      FocusStartResponse(
        sessionId: 'single-flight-session',
        plannedDurationSeconds: 60,
        startedAt: DateTime.utc(2026, 8, 17, 12),
        expiresAt: DateTime.utc(2026, 8, 17, 13),
        reused: false,
      ),
    );
    await pumpEventQueue();
  });

  test('unsupported personal duration runs local-only', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task, minutes: 2);

    notifier.startTimer();

    expect(container.read(focusProvider).isRunning, isTrue);
    expect(remoteDataSource.startCalls, 0);

    finishCurrentTimer(120);
    await pumpEventQueue();

    expect(remoteDataSource.finishCalls, 0);
    expect(focusRepository.saveCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
  });
  for (final targetType in FocusTargetType.values) {
    for (final elapsedTicks in [0, 1]) {
      test(
        '${targetType.value} paused after $elapsedTicks ticks keeps its target through completion',
        () async {
          final notifier = container.read(focusProvider.notifier);
          configureTarget(notifier, targetType);
          final originalId = targetType == FocusTargetType.task
              ? 'task-1'
              : 'subject-1';
          final otherType = targetType == FocusTargetType.task
              ? FocusTargetType.subject
              : FocusTargetType.task;
          expect(container.read(focusProvider).targetLocked, isFalse);

          await startAndFlush(notifier);
          expect(container.read(focusProvider).targetLocked, isTrue);
          if (elapsedTicks > 0) timer.fireAtTick(elapsedTicks);
          notifier.pauseTimer();
          expect(container.read(focusProvider).isRunning, isFalse);
          expect(container.read(focusProvider).targetLocked, isTrue);

          notifier.selectTarget('other-target', 'Other target', otherType);
          final paused = container.read(focusProvider);
          expect(paused.activeTargetId, originalId);
          expect(paused.activeTargetTitle, 'Target');
          expect(paused.activeTargetType, targetType);
          expect(paused.targetLocked, isTrue);

          await startAndFlush(notifier);
          expect(container.read(focusProvider).targetLocked, isTrue);
          finishCurrentTimer(60 - elapsedTicks);
          await pumpEventQueue();

          expect(focusRepository.saveCalls, 1);
          expect(focusRepository.lastTargetId, originalId);
          expect(focusRepository.lastTargetType, targetType.value);
          expect(focusRepository.lastDurationSeconds, 60);
          expect(remoteDataSource.startCalls, 1);
          expect(remoteDataSource.finishCalls, 0);
          if (targetType == FocusTargetType.task) {
            expect(tasksRepository.toggleCalls, 1);
            expect(tasksRepository.lastTaskId, originalId);
            expect(studyRepository.addStudyTimeCalls, 0);
          } else {
            expect(studyRepository.addStudyTimeCalls, 1);
            expect(studyRepository.lastSubjectId, originalId);
            expect(studyRepository.lastElapsedSeconds, 60);
            expect(tasksRepository.toggleCalls, 0);
          }
          expect(container.read(focusProvider).isBreak, isTrue);
          expect(container.read(focusProvider).targetLocked, isFalse);
        },
      );
    }
  }

  test(
    'reset releases the paused target and the next cycle belongs to B',
    () async {
      final notifier = container.read(focusProvider.notifier);
      configureTarget(notifier, FocusTargetType.task);
      await startAndFlush(notifier);
      timer.fire();
      notifier.pauseTimer();
      expect(container.read(focusProvider).targetLocked, isTrue);

      notifier.resetTimer();
      expect(container.read(focusProvider).targetLocked, isFalse);
      notifier.selectTarget('subject-B', 'Subject B', FocusTargetType.subject);
      expect(container.read(focusProvider).activeTargetId, 'subject-B');
      await startAndFlush(notifier);
      expect(container.read(focusProvider).targetLocked, isTrue);
      expect(remoteDataSource.lastTargetId, 'subject-B');
      finishCurrentTimer(60);
      await pumpEventQueue();

      expect(focusRepository.saveCalls, 1);
      expect(focusRepository.lastTargetId, 'subject-B');
      expect(focusRepository.lastTargetType, 'SUBJECT');
      expect(studyRepository.lastSubjectId, 'subject-B');
      expect(tasksRepository.toggleCalls, 0);
      expect(container.read(focusProvider).targetLocked, isFalse);
    },
  );

  test(
    'reset during pending start unlocks and late response cannot restore A',
    () async {
      final startCompleter = Completer<FocusStartResponse>();
      remoteDataSource.startOperation =
          ({
            required targetId,
            required targetType,
            required plannedDurationSeconds,
          }) => startCompleter.future;
      final notifier = container.read(focusProvider.notifier);
      configureTarget(notifier, FocusTargetType.task);
      notifier.startTimer();
      expect(container.read(focusProvider).targetLocked, isTrue);

      notifier.resetTimer();
      expect(container.read(focusProvider).targetLocked, isFalse);
      notifier.selectTarget('subject-B', 'Subject B', FocusTargetType.subject);
      expect(container.read(focusProvider).activeTargetId, 'subject-B');
      startCompleter.complete(
        FocusStartResponse(
          sessionId: 'late-target-A',
          plannedDurationSeconds: 60,
          startedAt: DateTime.utc(2026, 8, 17, 12),
          expiresAt: DateTime.utc(2026, 8, 17, 13),
          reused: false,
        ),
      );
      await pumpEventQueue();
      expect(container.read(focusProvider).targetLocked, isFalse);
      expect(container.read(focusProvider).isRunning, isFalse);
      expect(container.read(focusProvider).activeTargetId, 'subject-B');
      expect(container.read(focusProvider).activeTargetTitle, 'Subject B');
      expect(remoteDataSource.cancelledSessionIds, ['late-target-A']);
      expect(focusRepository.saveCalls, 0);

      notifier.selectTarget('subject-B', 'Subject B', FocusTargetType.subject);
      expect(container.read(focusProvider).activeTargetId, 'subject-B');
      expect(container.read(focusProvider).targetLocked, isFalse);
      remoteDataSource.startOperation = null;
      await startAndFlush(notifier);
      expect(container.read(focusProvider).targetLocked, isTrue);
      expect(container.read(focusProvider).activeTargetId, 'subject-B');
      expect(remoteDataSource.lastTargetId, 'subject-B');
    },
  );

  test(
    'completion and break release selection for the next work cycle',
    () async {
      final notifier = container.read(focusProvider.notifier);
      configureTarget(notifier, FocusTargetType.task);
      await startAndFlush(notifier);
      finishCurrentTimer(60);
      await pumpEventQueue();
      expect(container.read(focusProvider).isBreak, isTrue);
      expect(container.read(focusProvider).targetLocked, isFalse);

      notifier.startTimer();
      expect(container.read(focusProvider).targetLocked, isFalse);
      notifier.pauseTimer();
      expect(container.read(focusProvider).targetLocked, isFalse);
      notifier.toggleSessionType();
      expect(container.read(focusProvider).isBreak, isFalse);
      expect(container.read(focusProvider).targetLocked, isFalse);
      notifier.selectTarget('subject-B', 'Subject B', FocusTargetType.subject);
      expect(container.read(focusProvider).activeTargetId, 'subject-B');
    },
  );

  test('local-only work also locks its target during pause', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task, minutes: 2);
    notifier.startTimer();
    expect(container.read(focusProvider).targetLocked, isTrue);
    timer.fire();
    notifier.pauseTimer();
    notifier.selectTarget('subject-B', 'Subject B', FocusTargetType.subject);
    expect(container.read(focusProvider).activeTargetId, 'task-1');
    expect(container.read(focusProvider).targetLocked, isTrue);
    expect(remoteDataSource.startCalls, 0);
  });
  test('late invalidated START cannot release a newer pending START', () async {
    final oldStart = Completer<FocusStartResponse>();
    final newStart = Completer<FocusStartResponse>();
    remoteDataSource.startOperation =
        ({
          required targetId,
          required targetType,
          required plannedDurationSeconds,
        }) => targetId == 'task-1' ? oldStart.future : newStart.future;
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    notifier.startTimer();
    notifier.resetTimer();
    notifier.selectTarget('subject-B', 'Subject B', FocusTargetType.subject);
    notifier.startTimer();
    expect(remoteDataSource.startCalls, 2);
    expect(container.read(focusProvider).targetLocked, isTrue);

    oldStart.complete(
      FocusStartResponse(
        sessionId: 'old-A',
        plannedDurationSeconds: 60,
        startedAt: DateTime.utc(2026, 8, 17, 12),
        expiresAt: DateTime.utc(2026, 8, 17, 13),
        reused: false,
      ),
    );
    await pumpEventQueue();
    expect(container.read(focusProvider).activeTargetId, 'subject-B');
    expect(container.read(focusProvider).targetLocked, isTrue);
    expect(container.read(focusProvider).isRunning, isFalse);
    notifier.startTimer();
    notifier.selectTarget('task-C', 'Task C', FocusTargetType.task);
    expect(remoteDataSource.startCalls, 2);
    expect(container.read(focusProvider).activeTargetId, 'subject-B');
    expect(remoteDataSource.cancelledSessionIds, ['old-A']);

    newStart.complete(
      FocusStartResponse(
        sessionId: 'new-B',
        plannedDurationSeconds: 60,
        startedAt: DateTime.utc(2026, 8, 17, 12),
        expiresAt: DateTime.utc(2026, 8, 17, 13),
        reused: false,
      ),
    );
    await pumpEventQueue();
    expect(container.read(focusProvider).targetLocked, isTrue);
    expect(container.read(focusProvider).isRunning, isTrue);
    finishCurrentTimer(60);
    await pumpEventQueue();
    expect(focusRepository.lastTargetId, 'subject-B');
    expect(studyRepository.lastSubjectId, 'subject-B');
    expect(tasksRepository.toggleCalls, 0);
    expect(remoteDataSource.finishedSessionIds, ['new-B']);
    expect(container.read(focusProvider).targetLocked, isFalse);
  });
}

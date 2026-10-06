// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/app_database.dart'
    show SyncQueueTableData;
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/features/circles/data/remote/circle_leave_remote_data_source.dart';
import 'package:life_os/features/circles/data/remote/circle_delete_remote_data_source.dart';
import 'sync_manager_test.dart' show FakeSyncQueueStore, createSyncItem;

class _User extends Fake implements User {
  _User(this.uid);
  @override
  final String uid;
}

class _Auth extends Fake implements FirebaseAuth {
  User? user = _User('a');
  @override
  User? get currentUser => user;
}

class _Firestore extends Fake implements FirebaseFirestore {}

class _Session {
  final auth = _Auth();
  late final gate = LocalMutationGate(ownerUid: 'a')
    ..bindSessionReader(() => auth.currentUser?.uid)
    ..openPreparedSession();
  RemoteSendPermit capture() => gate.captureRemoteSend(expectedUid: 'a');
  void change(String? uid) {
    auth.user = uid == null ? null : _User(uid);
    gate.observeSession(uid);
  }

  void reloginA() {
    change(null);
    change('a');
    gate.openPreparedSession();
  }

  FirestoreSyncRemoteDataSource sync({
    required http.Client client,
    Future<String?> Function(User, bool)? idToken,
    Future<String?> Function()? appCheck,
  }) => FirestoreSyncRemoteDataSource(
    _Firestore(),
    auth,
    captureRemoteSend: (_) => capture(),
    clientFactory: () => client,
    idTokenProvider: idToken ?? (_, _) async => 'private-id-token-a',
    appCheckTokenProvider: appCheck ?? () async => 'private-app-check',
  );
}

void main() {
  final item = createSyncItem(
    ownerUid: 'a',
    collection: 'tasks',
    docId: 'task',
    operationType: 'delete',
    payloadJson: '{}',
  );

  for (final preflight in ['id-token', 'app-check']) {
    for (final stop in ['manager', 'quiesce', 'a-to-b', 'aba', 'dispose']) {
      test('Sync $preflight pending + $stop cannot start HTTP', () async {
        final session = _Session();
        final started = Completer<void>();
        final release = Completer<String?>();
        final finished = Completer<void>();
        var calls = 0;
        final source = session.sync(
          client: MockClient((_) async {
            calls++;
            return http.Response('{}', 200);
          }),
          idToken: (_, _) {
            if (preflight == 'id-token') {
              started.complete();
              return release.future;
            }
            return Future.value('private-id-token-a');
          },
          appCheck: () {
            if (preflight == 'app-check') {
              started.complete();
              return release.future;
            }
            return Future.value('private-app-check');
          },
        );
        final store = FakeSyncQueueStore([item]);
        // Track the real producer independently of the manager's Future.any.
        final tracking = _TrackingSource(source, finished);
        final trackedManager = SyncManager(
          queueStore: store,
          remoteDataSource: tracking,
          currentUserId: () => session.auth.currentUser?.uid,
        );
        addTearDown(trackedManager.dispose);
        final processing = trackedManager.processPendingItems();
        await started.future;
        if (stop == 'dispose') {
          trackedManager.dispose();
        } else if (stop == 'quiesce') {
          final q = session.gate.beginQuiesce('a');
          await q.drain(); // The remote producer holds no local mutation lease.
          q.finish(signOutConfirmed: false);
          expect(session.capture().isCurrent, true);
        } else {
          expect(await trackedManager.prepareForSessionDetach('a'), true);
          if (stop == 'a-to-b') {
            session.change(null);
            session.change('b');
          }
          if (stop == 'aba') {
            session.reloginA();
          }
        }
        release.complete('private-released-token');
        await finished.future;
        expect(await processing, false);
        expect(calls, 0);
        expect(store.markedAsSynced, isEmpty);
        expect(store.rejected, isEmpty);
        expect(store.items.single.status, 'pending');
      });
    }
  }

  test(
    'HTTP already started: stop finishes without response and late success has no ACK',
    () async {
      final session = _Session();
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final finished = Completer<void>();
      final source = session.sync(
        client: MockClient((_) {
          started.complete();
          return response.future;
        }),
      );
      final store = FakeSyncQueueStore([item]);
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: _TrackingSource(source, finished),
        currentUserId: () => session.auth.currentUser?.uid,
      );
      addTearDown(manager.dispose);
      final processing = manager.processPendingItems();
      await started.future;
      expect(await manager.prepareForSessionDetach('a'), true);
      expect(response.isCompleted, false);
      expect(await processing, false);
      response.complete(http.Response('{}', 200));
      await finished.future;
      expect(store.markedAsSynced, isEmpty);
      expect(store.items.single.status, 'pending');
    },
  );

  for (final refreshPending in [false, true]) {
    test(
      '401 stop ${refreshPending ? "during refresh" : "before refresh"} prevents second HTTP',
      () async {
        final session = _Session();
        final entered = Completer<void>();
        final refresh = Completer<String?>();
        var calls = 0, refreshCalls = 0;
        final source = session.sync(
          client: MockClient((_) async {
            calls++;
            if (!refreshPending) session.gate.beginQuiesce('a');
            return http.Response('{}', 401);
          }),
          idToken: (_, force) {
            if (force) {
              refreshCalls++;
              entered.complete();
              return refresh.future;
            }
            return Future.value('private-id-token-a');
          },
        );
        final result = source.process('a', item);
        if (refreshPending) {
          await entered.future;
          session.reloginA();
          refresh.complete('private-fresh-token');
        }
        expect((await result).code, 'SESSION_STOPPED');
        expect(calls, 1);
        expect(refreshCalls, refreshPending ? 1 : 0);
      },
    );
  }

  for (final relogin in [false, true]) {
    test(
      'new authorized execution replays pending A after ${relogin ? "relogin" : "logout abort"}',
      () async {
        final session = _Session();
        final store = FakeSyncQueueStore([item]);
        final entered = Completer<void>(), finished = Completer<void>();
        final release = Completer<String?>();
        var first = true, calls = 0;
        final source = session.sync(
          client: MockClient((_) async {
            calls++;
            return http.Response('{}', 200);
          }),
          appCheck: () {
            if (first) {
              first = false;
              entered.complete();
              return release.future;
            }
            return Future.value('app');
          },
        );
        final manager = SyncManager(
          queueStore: store,
          remoteDataSource: _TrackingSource(source, finished),
          currentUserId: () => session.auth.currentUser?.uid,
        );
        addTearDown(manager.dispose);
        final old = manager.processPendingItems();
        await entered.future;
        final q = session.gate.beginQuiesce('a');
        await manager.prepareForSessionDetach('a');
        q.finish(signOutConfirmed: false);
        expect(manager.resumeForPreparedSession('a'), true);
        release.complete('private-old-app-check');
        await finished.future;
        expect(await old, false);
        expect(calls, 0);
        if (relogin) session.reloginA();
        expect(await manager.processPendingItems(), true);
        expect(calls, 1);
        expect(store.markedAsSynced, [item.id]);
      },
    );
  }

  for (final action in ['leave', 'delete']) {
    for (final stage in ['id-token', 'app-check', 'sent']) {
      for (final nextUid in ['b', 'a']) {
        test(
          'Circle $action $stage rejects late result in new $nextUid session',
          () async {
            final session = _Session();
            final started = Completer<void>();
            final token = Completer<String?>();
            final response = Completer<http.Response>();
            var calls = 0;
            final client = MockClient((_) {
              calls++;
              started.complete();
              return response.future;
            });
            Future<String?> idToken() {
              if (stage == 'id-token') {
                started.complete();
                return token.future;
              }
              return Future.value('private-id-token-a');
            }

            Future<String?> appCheck() {
              if (stage == 'app-check') {
                started.complete();
                return token.future;
              }
              return Future.value('private-app-check');
            }

            final Future<void> operation;
            if (action == 'leave') {
              final source = CircleLeaveRemoteDataSource(
                client: client,
                captureRemoteSend: session.capture,
                idTokenProvider: idToken,
                appCheckTokenProvider: appCheck,
              );
              operation = source.leaveCircle('circle');
            } else {
              final source = CircleDeleteRemoteDataSource(
                client: client,
                captureRemoteSend: session.capture,
                idTokenProvider: idToken,
                appCheckTokenProvider: appCheck,
              );
              operation = source.deleteCircle('circle');
            }
            final checked = expectLater(
              operation,
              throwsA(
                predicate((e) {
                  final code = e is CircleLeaveRemoteException
                      ? e.code
                      : (e as CircleDeleteRemoteException).code;
                  final ambiguous = e is CircleLeaveRemoteException
                      ? e.isAmbiguous
                      : (e as CircleDeleteRemoteException).isAmbiguous;
                  expect(ambiguous, stage == 'sent');
                  expect(e.toString(), isNot(contains('private-')));
                  return code == 'SESSION_STOPPED';
                }),
              ),
            );
            await started.future;
            session.change(null);
            session.change(nextUid);
            if (nextUid == 'a') session.gate.openPreparedSession();
            if (stage == 'sent')
              response.complete(
                http.Response(
                  '{"${action == 'leave' ? 'left' : 'deleted'}":true}',
                  200,
                ),
              );
            else
              token.complete('private-released-token');
            await checked;
            expect(calls, stage == 'sent' ? 1 : 0);
          },
        );
      }
    }
  }

  for (final stage in ['id-token', 'app-check', 'transport']) {
    test('Sync $stage exception never exposes credentials', () async {
      final session = _Session();
      final source = session.sync(
        client: MockClient(
          (_) async => throw http.ClientException(
            'private-id-token-a private-app-check',
          ),
        ),
        idToken: (_, _) async {
          if (stage == 'id-token') throw StateError('private-id-token-a');
          return 'private-id-token-a';
        },
        appCheck: () async {
          if (stage == 'app-check') throw StateError('private-app-check');
          return 'private-app-check';
        },
      );
      final result = await source.process('a', item);
      expect(result.shouldRetry, true);
      expect('${result.code} ${result.message}', isNot(contains('private-')));
    });
  }
}

class _TrackingSource implements SessionBoundSyncRemoteDataSource {
  _TrackingSource(this.source, this.finished);
  final FirestoreSyncRemoteDataSource source;
  final Completer<void> finished;
  @override
  Future<SyncOperationResult> process(String uid, SyncQueueTableData item) =>
      processForSession(uid, item, canSend: () => true);
  @override
  Future<SyncOperationResult> processForSession(
    String uid,
    SyncQueueTableData item, {
    required bool Function() canSend,
  }) async {
    try {
      return await source.processForSession(uid, item, canSend: canSend);
    } finally {
      if (!finished.isCompleted) finished.complete();
    }
  }
}

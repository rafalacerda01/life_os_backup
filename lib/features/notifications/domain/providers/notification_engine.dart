import 'package:life_os/core/database/local_account_session.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/notifications/data/repositories/notifications_repository.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';

import 'package:life_os/features/notifications/domain/services/notification_module_reconciler.dart';

export 'package:life_os/features/notifications/domain/services/notification_module_reconciler.dart';

part 'notification_engine.g.dart';

final notificationBootstrapCoordinatorProvider =
    Provider<NotificationBootstrapCoordinator>((ref) {
      ref.watch(localAccountSessionProvider);
      return NotificationBootstrapCoordinator();
    });

class NotificationBootstrapCoordinator {
  String? _completedUid;
  DateTime? _completedDay;
  String? _inFlightUid;
  DateTime? _inFlightDay;
  Future<void>? _inFlightJob;
  Object? _inFlightToken;
  int? _inFlightGeneration;
  int _generation = 0;
  bool _isDraining = false;

  Future<void> ensureBootstrapped({
    required String uid,
    required DateTime now,
    required Future<void> Function() bootstrap,
  }) {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) return Future<void>.value();

    if (_isDraining) {
      return _inFlightJob ?? Future<void>.value();
    }

    final day = DateTime(now.year, now.month, now.day);
    if (_completedUid == normalizedUid && _completedDay == day) {
      return Future<void>.value();
    }

    final currentJob = _inFlightJob;
    if (currentJob != null) {
      if (_inFlightUid == normalizedUid &&
          _inFlightDay == day &&
          _inFlightGeneration == _generation) {
        return currentJob;
      }
      return _startBootstrap(
        uid: normalizedUid,
        day: day,
        bootstrap: () => _runAfter(currentJob, bootstrap),
      );
    }

    return _startBootstrap(uid: normalizedUid, day: day, bootstrap: bootstrap);
  }

  Future<void> _startBootstrap({
    required String uid,
    required DateTime day,
    required Future<void> Function() bootstrap,
  }) {
    final generation = _generation;
    final token = Object();
    final job = Future<void>.sync(bootstrap)
        .then((_) {
          if (_generation != generation) return;
          _completedUid = uid;
          _completedDay = day;
        })
        .whenComplete(() {
          if (!identical(_inFlightToken, token)) return;
          _inFlightUid = null;
          _inFlightDay = null;
          _inFlightJob = null;
          _inFlightToken = null;
          _inFlightGeneration = null;
        });

    _inFlightUid = uid;
    _inFlightDay = day;
    _inFlightJob = job;
    _inFlightToken = token;
    _inFlightGeneration = generation;
    return job;
  }

  Future<void> _runAfter(
    Future<void> previous,
    Future<void> Function() bootstrap,
  ) async {
    try {
      await previous;
    } on Object {
      // O próximo bootstrap ainda precisa executar após uma falha anterior.
    }
    await bootstrap();
  }

  void reset() {
    _generation += 1;
    _completedUid = null;
    _completedDay = null;
  }

  Future<void> resetAndDrain() async {
    _generation += 1;
    _completedUid = null;
    _completedDay = null;
    _isDraining = true;

    try {
      final currentJob = _inFlightJob;
      if (currentJob == null) return;

      try {
        await currentJob;
      } on Object {
        // A limpeza local depende do término, não do resultado do bootstrap.
      }
    } finally {
      _isDraining = false;
    }
  }
}

class _NotificationBootstrapCancelled implements Exception {
  const _NotificationBootstrapCancelled();
}

@riverpod
class NotificationEngine extends _$NotificationEngine {
  bool _disposed = false;

  @override
  Stream<List<NotificationModel>> build() {
    final repository = ref.watch(notificationsRepositoryProvider);
    final db = ref.read(databaseProvider);
    final preferencesStore = ref.read(notificationPreferencesStoreProvider);

    ref.onDispose(() {
      _disposed = true;
    });

    _scheduleBootstrap(
      repository: repository,
      db: db,
      preferencesStore: preferencesStore,
    );

    return repository.watchLocalNotifications();
  }

  void _scheduleBootstrap({
    required NotificationsRepository repository,
    required AppDatabase db,
    required NotificationPreferencesStore preferencesStore,
  }) {
    final today = _startOfDay(DateTime.now());
    final uid = repository.auth.currentUser?.uid.trim();

    if (_disposed || uid == null || uid.isEmpty) return;

    final job = ref
        .read(notificationBootstrapCoordinatorProvider)
        .ensureBootstrapped(
          uid: uid,
          now: today,
          bootstrap: () => _runBootstrap(
            uid: uid,
            today: today,
            repository: repository,
            db: db,
            preferencesStore: preferencesStore,
          ),
        );
    unawaited(
      job.catchError((Object error, StackTrace stackTrace) {
        if (error is _NotificationBootstrapCancelled) return;
        AppLogger.e(
          'NotificationEngine: falha no bootstrap inicial',
          error,
          stackTrace,
        );
      }),
    );
  }

  Future<void> _runBootstrap({
    required String uid,
    required DateTime today,
    required NotificationsRepository repository,
    required AppDatabase db,
    required NotificationPreferencesStore preferencesStore,
  }) async {
    void requireCurrentUser() {
      if (repository.auth.currentUser?.uid != uid) {
        throw const _NotificationBootstrapCancelled();
      }
    }

    requireCurrentUser();
    final preferences = await preferencesStore.load();
    requireCurrentUser();
    await repository.syncNotificationsFromFirebaseToLocal();
    requireCurrentUser();
    await const NotificationModuleReconciler().sync(
      repository: repository,
      db: db,
      preferences: preferences,
      today: today,
      isCancelled: () => repository.auth.currentUser?.uid != uid,
    );
    requireCurrentUser();
  }

  /// Reconcilia notificações derivadas dos módulos existentes.
  ///
  /// As dependências são recebidas por parâmetro para impedir que
  /// `ref.read()` seja executado depois de um `await`.
  ///
  /// As notificações possuem IDs estáveis e o repository utiliza
  /// upsertPreservingState(), preservando o estado de leitura/conclusão.
  Future<void> syncExistingModules({
    required NotificationsRepository repository,
    required AppDatabase db,
    required NotificationPreferences preferences,
    DateTime? today,
  }) async {
    if (_disposed) return;

    await const NotificationModuleReconciler().sync(
      repository: repository,
      db: db,
      preferences: preferences,
      today: today,
      isCancelled: () => _disposed,
    );
  }

  Future<void> markAsRead(String id) async {
    if (_disposed) return;

    final repository = ref.read(notificationsRepositoryProvider);
    await repository.markAsReadLocal(id);
  }

  Future<void> markAsCompleted(String id) async {
    if (_disposed) return;

    final repository = ref.read(notificationsRepositoryProvider);
    await repository.markAsCompletedLocal(id);
  }

  Future<void> removeNotification(String id) async {
    if (_disposed) return;

    final repository = ref.read(notificationsRepositoryProvider);
    await repository.deleteNotification(id);
  }

  DateTime _startOfDay(DateTime value) {
    return DateTime(value.year, value.month, value.day);
  }
}

@riverpod
int unreadNotificationsCount(Ref ref) {
  final notificationsAsync = ref.watch(notificationEngineProvider);

  return notificationsAsync.maybeWhen(
    data: (notifications) => notifications
        .where(
          (notification) => !notification.isRead && !notification.isCompleted,
        )
        .length,
    orElse: () => 0,
  );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/tasks/data/models/task_model.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/tasks/presentation/tasks_screen.dart';

class _SyncManager extends Fake implements SyncManager {
  final drained = Completer<bool>();
  int calls = 0;
  @override
  Future<bool> processPendingItems() {
    calls++;
    return drained.future;
  }
}

class _Repository extends Fake implements TasksRepository {
  int pulls = 0;
  @override
  Future<void> syncTasksFromFirebaseToLocal() async {
    pulls++;
  }
}

void main() {
  for (final drained in [false, true]) {
    testWidgets('opening hydrates only after queue drains: $drained', (
      tester,
    ) async {
      final manager = _SyncManager();
      final repository = _Repository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncManagerProvider.overrideWithValue(manager),
            tasksRepositoryProvider.overrideWithValue(repository),
            tasksStreamProvider.overrideWith(
              (ref) => const Stream<List<TaskModel>>.empty(),
            ),
          ],
          child: const MaterialApp(home: TasksScreen()),
        ),
      );
      await tester.pump();
      expect(manager.calls, 1);
      expect(repository.pulls, 0);
      manager.drained.complete(drained);
      await tester.pump();
      expect(repository.pulls, drained ? 1 : 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('erro de tarefas é sanitizado e permite tentar novamente', (
    tester,
  ) async {
    const technicalError = 'technical-tasks-database-error';
    final manager = _SyncManager()..drained.complete(false);
    final repository = _Repository();
    var streamBuilds = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncManagerProvider.overrideWithValue(manager),
          tasksRepositoryProvider.overrideWithValue(repository),
          tasksStreamProvider.overrideWith((ref) {
            streamBuilds++;
            return Stream<List<TaskModel>>.error(StateError(technicalError));
          }),
        ],
        child: const MaterialApp(home: TasksScreen()),
      ),
    );
    await tester.pump();

    expect(
      find.text('Não foi possível carregar suas tarefas.'),
      findsOneWidget,
    );
    expect(find.text('Tentar novamente'), findsOneWidget);
    expect(find.textContaining(technicalError), findsNothing);

    final buildsBeforeRetry = streamBuilds;
    await tester.tap(find.text('Tentar novamente'));
    await tester.pump();

    expect(streamBuilds, greaterThan(buildsBeforeRetry));
  });
}

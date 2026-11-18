import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/runtime/app_runtime_mode.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/tasks/presentation/tasks_screen.dart';

void main() {
  // This test intentionally uses real Drift I/O and a real-time widget binding.
  LiveTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  testWidgets(
    'local screen performs CRUD with no Firebase or scheduled sync',
    (tester) async {
      final db = AppDatabase.forUser(
        identity: LocalDatabaseIdentity(
          'local-v1-123e4567-e89b-42d3-a456-426614174000',
        ),
        executor: NativeDatabase.memory(),
        syncPolicy: DatabaseSyncPolicy.localOnly,
      );
      await tester.runAsync(() async {
        await db.customSelect('SELECT 1').get();
      });
      var syncReads = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appRuntimeModeProvider.overrideWithValue(AppRuntimeMode.localFirst),
            syncManagerProvider.overrideWith((ref) {
              syncReads++;
              throw StateError('NO_AUTOMATIC_SYNC');
            }),
          ],
          child: const MaterialApp(home: TasksScreen()),
        ),
      );
      try {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Nova tarefa'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField),
          'Tarefa local sem login',
        );
        await tester.tap(find.text('Adicionar à Rotina'));
        await tester.pumpAndSettle();
        expect(find.text('Tarefa local sem login'), findsOneWidget);
        await tester.ensureVisible(find.text('Tarefa local sem login'));
        await tester.tap(find.text('Tarefa local sem login'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          expect(
            (await db.select(db.taskTable).get()).single.isCompleted,
            true,
          );
        });
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Excluir tarefa'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Excluir'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          expect(await db.select(db.taskTable).get(), isEmpty);
        });
        await tester.runAsync(() async {
          expect(await db.select(db.syncQueueTable).get(), isEmpty);
        });
        expect(syncReads, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await db.close();
        });
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

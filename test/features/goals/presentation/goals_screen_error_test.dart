import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/goals/data/models/local/repositories/goal_repository.dart';
import 'package:life_os/features/goals/domain/entities/goal_entity.dart';
import 'package:life_os/features/goals/presentation/goals_provider.dart';
import 'package:life_os/features/goals/presentation/goals_screen.dart';

class _SyncManager extends Fake implements SyncManager {
  @override
  Future<bool> processPendingItems() async => false;
}

class _GoalRepository extends Fake implements GoalRepository {}

void main() {
  testWidgets('erro de metas é sanitizado e permite tentar novamente', (
    tester,
  ) async {
    const technicalError = 'technical-goals-database-error';
    var streamBuilds = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncManagerProvider.overrideWithValue(_SyncManager()),
          goalRepositoryProvider.overrideWithValue(_GoalRepository()),
          goalsStreamProvider.overrideWith((ref) {
            streamBuilds++;
            return Stream<List<GoalEntity>>.error(StateError(technicalError));
          }),
        ],
        child: const MaterialApp(home: GoalsScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Não foi possível carregar suas metas.'), findsOneWidget);
    expect(find.text('Tente novamente em instantes.'), findsOneWidget);
    expect(find.text('Tentar novamente'), findsOneWidget);
    expect(find.textContaining(technicalError), findsNothing);

    final buildsBeforeRetry = streamBuilds;
    await tester.tap(find.text('Tentar novamente'));
    await tester.pump();

    expect(streamBuilds, greaterThan(buildsBeforeRetry));
  });
}

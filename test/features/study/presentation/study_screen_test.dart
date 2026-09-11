import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/study/data/models/study_model.dart';
import 'package:life_os/features/study/data/study_repository.dart';
import 'package:life_os/features/study/domain/entities/study_subject_entity.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/study/presentation/study_screen.dart';

class _StudyRepository extends Fake implements StudyRepository {
  int syncCalls = 0;
  int resetCalls = 0;

  @override
  Future<void> syncStudyFromFirebaseToLocal() async {
    syncCalls += 1;
  }

  @override
  Future<void> resetDailyProgress(StudyModel currentStatus) async {
    resetCalls += 1;
  }
}

Future<void> _pumpStudyScreen(
  WidgetTester tester, {
  required _StudyRepository repository,
  required Stream<StudyModel> study,
  required Stream<List<StudySubjectEntity>> subjects,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        studyRepositoryProvider.overrideWithValue(repository),
        studyStreamProvider.overrideWith((ref) => study),
        subjectsStreamProvider.overrideWith((ref) => subjects),
      ],
      child: const MaterialApp(home: StudyScreen()),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('hierarquia prioriza revisões e mantém dados das disciplinas', (
    tester,
  ) async {
    final repository = _StudyRepository();
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpStudyScreen(
      tester,
      repository: repository,
      study: Stream.value(
        StudyModel(streak: 6, reviewQueue: 3, progress: 0.65),
      ),
      subjects: Stream.value([
        StudySubjectEntity(
          id: 'subject-1',
          title: 'Disciplina com um título longo para validar responsividade',
          cardsToReview: 2,
          streakDays: 4,
          progress: 0.4,
          hasExam: true,
          examDate: DateTime(2026, 9, 20),
        ),
      ]),
    );

    expect(find.text('Estudos'), findsOneWidget);
    expect(find.text('Revisões de hoje'), findsOneWidget);
    expect(find.text('Revisar agora'), findsOneWidget);
    expect(find.text('3 revisões aguardando você'), findsOneWidget);
    expect(find.text('Fila de Revisões (Anki)'), findsNothing);
    expect(find.text('65%'), findsOneWidget);
    expect(find.text('2 revisões'), findsOneWidget);
    expect(find.text('Prova em 20/09'), findsOneWidget);
    expect(repository.syncCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('estado vazio orienta criação e mantém acesso às revisões', (
    tester,
  ) async {
    final repository = _StudyRepository();
    await _pumpStudyScreen(
      tester,
      repository: repository,
      study: Stream.value(StudyModel(streak: 0, reviewQueue: 0, progress: 0)),
      subjects: Stream.value(const []),
    );

    expect(find.text('Revisões em dia'), findsOneWidget);
    expect(find.text('Ver revisões'), findsOneWidget);
    expect(find.text('Comece sua área de estudos'), findsOneWidget);
    expect(
      find.text('Adicione uma disciplina para desbloquear'),
      findsOneWidget,
    );
  });

  testWidgets('reset exige confirmação antes de chamar repository', (
    tester,
  ) async {
    final repository = _StudyRepository();
    await _pumpStudyScreen(
      tester,
      repository: repository,
      study: Stream.value(StudyModel(streak: 2, reviewQueue: 1, progress: 0.5)),
      subjects: Stream.value(const []),
    );

    final resetAction = find.text('Resetar progresso diário');
    await tester.ensureVisible(resetAction);
    await tester.tap(resetAction);
    await tester.pumpAndSettle();

    expect(find.text('Resetar progresso diário?'), findsOneWidget);
    expect(repository.resetCalls, 0);
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await tester.pumpAndSettle();
    expect(repository.resetCalls, 0);

    await tester.tap(resetAction);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Resetar'));
    await tester.pumpAndSettle();
    expect(repository.resetCalls, 1);
  });

  testWidgets('erro de estudos usa mensagem genérica', (tester) async {
    final repository = _StudyRepository();
    await _pumpStudyScreen(
      tester,
      repository: repository,
      study: Stream.error(Exception('private-study-error')),
      subjects: Stream.value(const []),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Não foi possível carregar seus estudos agora.'),
      findsOneWidget,
    );
    expect(find.textContaining('private-study-error'), findsNothing);
  });
}

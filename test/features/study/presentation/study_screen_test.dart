import 'dart:async';
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
  int retryCalls = 0;
  Future<void>? retryWait;
  Stream<ReviewCreationSyncState> visibility = Stream.value(
    const ReviewCreationSyncState.empty(),
  );
  @override
  Stream<ReviewCreationSyncState> watchReviewCreationSync() => visibility;
  @override
  Future<void> retryReviewCreationSync(ReviewCreationSyncState state) async {
    retryCalls++;
    await retryWait;
  }

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
        flashcardStreamProvider.overrideWith((ref) => Stream.value(const [])),
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
  group('ReviewQueue contextual visibility', () {
    ReviewCreationSyncState status({
      int pending = 0,
      int unknown = 0,
      int recovery = 0,
      Object? session,
      bool Function()? current,
    }) => ReviewCreationSyncState(
      current ?? () => true,
      pending: pending,
      indeterminate: unknown,
      retryEligible: unknown > 0 && recovery == 0,
      recovery: recovery,
      sessionToken: session ?? Object(),
    );
    Future<void> pump(WidgetTester tester, _StudyRepository repository) =>
        _pumpStudyScreen(
          tester,
          repository: repository,
          study: Stream.value(
            StudyModel(streak: 2, reviewQueue: 1, progress: .5),
          ),
          subjects: Stream.value(const []),
        );
    for (final kind in ['normal', 'unknown', 'recovery'])
      testWidgets(
        '$kind notice has distinct text, no private identifiers or lost-data claims',
        (tester) async {
          final repository = _StudyRepository()
            ..visibility = Stream.value(
              kind == 'normal'
                  ? status(pending: 1)
                  : kind == 'unknown'
                  ? status(unknown: 1)
                  : status(recovery: 1),
            );
          await pump(tester, repository);
          expect(
            find.byKey(const Key('review-creation-sync-notice')),
            findsOneWidget,
          );
          expect(
            find.text(
              kind == 'normal'
                  ? 'Sincronização pendente'
                  : kind == 'unknown'
                  ? 'Confirmação pendente'
                  : 'Verificação necessária',
            ),
            findsOneWidget,
          );
          if (kind == 'normal')
            expect(
              find.textContaining('verificação para concluir'),
              findsNothing,
            );
          expect(find.textContaining('conta excluída'), findsNothing);
          expect(find.textContaining('perda de dados'), findsNothing);
          expect(find.textContaining('REVIEW_CREATE'), findsNothing);
          expect(find.textContaining('user-a'), findsNothing);
          expect(find.text('Revisar agora'), findsOneWidget);
          expect(repository.syncCalls, 1);
          expect(tester.takeException(), isNull);
        },
      );
    testWidgets(
      'confirmed resolution removes one aggregate notice without extra pull',
      (tester) async {
        final controller = StreamController<ReviewCreationSyncState>();
        addTearDown(controller.close);
        final repository = _StudyRepository()..visibility = controller.stream;
        await pump(tester, repository);
        controller.add(status(unknown: 2, recovery: 1));
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const Key('review-creation-sync-notice')),
          findsOneWidget,
        );
        expect(find.text('3 cartões aguardam confirmação.'), findsOneWidget);
        controller.add(const ReviewCreationSyncState.empty());
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const Key('review-creation-sync-notice')),
          findsNothing,
        );
        expect(repository.syncCalls, 1);
      },
    );
    testWidgets(
      'late A snapshot is invisible to B and B-A events rehydrate own status',
      (tester) async {
        var currentA = true;
        final controller = StreamController<ReviewCreationSyncState>();
        addTearDown(controller.close);
        final repository = _StudyRepository()..visibility = controller.stream;
        await pump(tester, repository);
        final a = status(recovery: 1, current: () => currentA);
        controller.add(a);
        await tester.pump();
        await tester.pump();
        expect(find.text('Verificação necessária'), findsOneWidget);
        currentA = false;
        controller.add(a);
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const Key('review-creation-sync-notice')),
          findsNothing,
        );
        controller.add(status(pending: 1));
        await tester.pump();
        await tester.pump();
        expect(find.text('Sincronização pendente'), findsOneWidget);
        controller.add(a);
        await tester.pump();
        await tester.pump();
        expect(find.text('Verificação necessária'), findsNothing);
        currentA = true;
        controller.add(status(recovery: 1));
        await tester.pump();
        await tester.pump();
        expect(find.text('Verificação necessária'), findsOneWidget);
      },
    );
    testWidgets(
      'manual retry is real, one-shot while unresolved, never presents success',
      (tester) async {
        final finish = Completer<void>();
        final repository = _StudyRepository()
          ..visibility = Stream.value(status(unknown: 1))
          ..retryWait = finish.future;
        await pump(tester, repository);
        await tester.ensureVisible(find.text('Tentar sincronizar novamente'));
        await tester.tap(find.text('Tentar sincronizar novamente'));
        await tester.pump();
        expect(repository.retryCalls, 1);
        expect(find.text('Tentativa solicitada…'), findsOneWidget);
        finish.complete();
        await tester.pump();
        await tester.pump();
        expect(find.text('Confirmação pendente'), findsOneWidget);
        expect(find.text('Tentar sincronizar novamente'), findsNothing);
        expect(find.text('A confirmação ainda está pendente.'), findsOneWidget);
        expect(repository.retryCalls, 1);
      },
    );
    testWidgets(
      'recovery/legacy/rejected has no inert retry or discard/recreate shortcut',
      (tester) async {
        final repository = _StudyRepository()
          ..visibility = Stream.value(status(recovery: 1));
        await pump(tester, repository);
        expect(find.text('Tentar sincronizar novamente'), findsNothing);
        expect(find.textContaining('Descartar dados'), findsNothing);
        expect(find.textContaining('Crie o cartão novamente'), findsNothing);
        expect(repository.retryCalls, 0);
      },
    );
    testWidgets(
      'dispose cancels notice observer and ignores delayed retry completion',
      (tester) async {
        var cancelled = 0;
        final controller = StreamController<ReviewCreationSyncState>(
          onCancel: () => cancelled++,
        );
        addTearDown(controller.close);
        final finish = Completer<void>(),
            repository = _StudyRepository()
              ..visibility = controller.stream
              ..retryWait = finish.future;
        await pump(tester, repository);
        controller.add(status(unknown: 1));
        await tester.pump();
        await tester.pump();
        await tester.ensureVisible(find.text('Tentar sincronizar novamente'));
        await tester.tap(find.text('Tentar sincronizar novamente'));
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(cancelled, 1);
        finish.complete();
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'notice exposes text semantics and accessible retry target on dark theme',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final repository = _StudyRepository()
            ..visibility = Stream.value(status(unknown: 1));
          await pump(tester, repository);
          await tester.ensureVisible(find.text('Tentar sincronizar novamente'));
          await tester.pump();
          expect(
            find.bySemanticsLabel(RegExp('Confirmação pendente')),
            findsOneWidget,
          );
          expect(
            find.bySemanticsLabel('Tentar sincronizar novamente'),
            findsOneWidget,
          );
          final rect = tester.getRect(
            find.widgetWithText(TextButton, 'Tentar sincronizar novamente'),
          );
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
    testWidgets('notice remains readable with large text at narrow width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 840));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _StudyRepository()
        ..visibility = Stream.value(status(recovery: 3));
      await pump(tester, repository);
      // Exercise this notice at large text without changing unrelated Study sections.
      final notice = tester.widget<Widget>(find.byKey(ObjectKey(repository)));
      repository.visibility = Stream.value(status(recovery: 3));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: Scaffold(body: SingleChildScrollView(child: notice)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Verificação necessária'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'navigation to reviews remains available while verification notice exists',
      (tester) async {
        final repository = _StudyRepository()
          ..visibility = Stream.value(status(recovery: 1));
        await pump(tester, repository);
        await tester.tap(find.text('Revisar agora'));
        await tester.pumpAndSettle();
        expect(find.text('Revisão'), findsOneWidget);
        expect(find.text('Revisões concluídas'), findsOneWidget);
      },
    );
  });
  group('S3 local HOLD notice', () {
    ReviewCreationSyncState state({
      int cards = 0,
      int missing = 0,
      int hold = 0,
      int rejected = 0,
      bool blocked = false,
      int waiting = 0,
      bool verified = true,
      Object? token,
      bool retry = false,
    }) => ReviewCreationSyncState(
      () => true,
      recovery: cards,
      pendingWithoutCard: missing,
      studyInfoHold: hold,
      rejectedWithoutCard: rejected,
      headBlocked: blocked,
      waitingBehindHead: waiting,
      queueVerified: verified,
      indeterminate: retry ? 1 : 0,
      retryEligible: retry,
      sessionToken: token ?? Object(),
    );
    Future<void> pump(WidgetTester tester, _StudyRepository r) =>
        _pumpStudyScreen(
          tester,
          repository: r,
          study: Stream.value(
            StudyModel(streak: 0, reviewQueue: 0, progress: 0),
          ),
          subjects: Stream.value(const []),
        );
    const message =
        'A sincronização precisa de verificação. Seus registros foram preservados.';
    for (final kind in ['study', 'orphan', 'legacy-card']) {
      testWidgets(
        '$kind is visible with honest counts and no recovery action',
        (tester) async {
          final r = _StudyRepository()
            ..visibility = Stream.value(
              state(
                hold: kind == 'study' ? 1 : 0,
                missing: kind == 'orphan' ? 2 : 0,
                cards: kind == 'legacy-card' ? 1 : 0,
                blocked: true,
              ),
            );
          await pump(tester, r);
          expect(find.text(message), findsOneWidget);
          expect(find.text('Tentar sincronizar novamente'), findsNothing);
          expect(find.textContaining('operações posteriores'), findsNothing);
          expect(find.textContaining('posterior aguarda'), findsNothing);
          if (kind == 'study')
            expect(
              find.text('1 registro antigo de estudos precisa de verificação.'),
              findsOneWidget,
            );
          if (kind == 'orphan') {
            expect(
              find.text('2 operações pendentes sem cartão neste dispositivo.'),
              findsOneWidget,
            );
            expect(find.text('2 cartões aguardam confirmação.'), findsNothing);
          }
          expect(find.textContaining('study_info'), findsNothing);
          expect(find.textContaining('user-a'), findsNothing);
          expect(find.textContaining('Recuperar'), findsNothing);
          expect(r.retryCalls, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
    for (final pair in [(true, true), (false, true), (true, false)]) {
      testWidgets(
        'later operations claim requires verified problematic head: $pair',
        (tester) async {
          final r = _StudyRepository()
            ..visibility = Stream.value(
              state(hold: 1, blocked: pair.$1, verified: pair.$2, waiting: 2),
            );
          await pump(tester, r);
          expect(find.text(message), findsOneWidget);
          expect(
            find.text('2 operações posteriores aguardam nesta fila.'),
            pair.$1 && pair.$2 ? findsOneWidget : findsNothing,
          );
        },
      );
    }
    testWidgets(
      'rejected without card is not a pending notice and cannot claim FIFO block',
      (tester) async {
        final r = _StudyRepository()
          ..visibility = Stream.value(state(rejected: 3));
        await pump(tester, r);
        expect(
          find.byKey(const Key('review-creation-sync-notice')),
          findsNothing,
        );
        expect(r.retryCalls, 0);
      },
    );
    testWidgets(
      'late retry from A cannot decorate a new B HOLD or prevent B-A session refresh',
      (tester) async {
        final controller = StreamController<ReviewCreationSyncState>();
        addTearDown(controller.close);
        final finish = Completer<void>(),
            r = _StudyRepository()
              ..visibility = controller.stream
              ..retryWait = finish.future;
        await pump(tester, r);
        controller.add(state(retry: true));
        await tester.pump();
        await tester.pump();
        await tester.ensureVisible(find.text('Tentar sincronizar novamente'));
        await tester.tap(find.text('Tentar sincronizar novamente'));
        await tester.pump();
        expect(r.retryCalls, 1);
        controller.add(state(hold: 1, blocked: true));
        await tester.pump();
        await tester.pump();
        expect(find.text('Tentativa solicitada…'), findsNothing);
        expect(find.text(message), findsOneWidget);
        finish.complete();
        await tester.pump();
        await tester.pump();
        expect(find.text('A confirmação ainda está pendente.'), findsNothing);
        expect(find.text(message), findsOneWidget);
        controller.add(state(retry: true));
        await tester.pump();
        await tester.pump();
        expect(find.text('Tentar sincronizar novamente'), findsOneWidget);
        expect(r.retryCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'HOLD notice has accessible semantics and no overflow at narrow width and large text',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await tester.binding.setSurfaceSize(const Size(320, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final r = _StudyRepository()
            ..visibility = Stream.value(
              state(cards: 2, missing: 3, hold: 1, blocked: true, waiting: 4),
            );
          await pump(tester, r);
          // Isolate the actual notice; the preexisting unrelated SectionTitle issue
          // at large text is outside this four-file visibility change.
          final notice = tester.widget<Widget>(find.byKey(ObjectKey(r)));
          r.visibility = Stream.value(
            state(cards: 2, missing: 3, hold: 1, blocked: true, waiting: 4),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: Scaffold(body: SingleChildScrollView(child: notice)),
              ),
            ),
          );
          await tester.pump();
          await tester.pump();
          expect(
            find.bySemanticsLabel(
              RegExp('A sincronização precisa de verificação'),
            ),
            findsOneWidget,
          );
          expect(find.text('2 cartões aguardam confirmação.'), findsOneWidget);
          expect(
            find.text('3 operações pendentes sem cartão neste dispositivo.'),
            findsOneWidget,
          );
          expect(
            find.text('4 operações posteriores aguardam nesta fila.'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  });
  group('F01 accessible Study verification notice', () {
    for (final historical in [false, true]) {
      testWidgets(
        'F01 historical=$historical is visible without technical details, retry or false FIFO claims',
        (tester) async {
          final r = _StudyRepository()
            ..visibility = Stream.value(
              ReviewCreationSyncState(
                () => true,
                studyStateHold: historical ? 0 : 1,
                studyStateRejected: historical ? 1 : 0,
                headBlocked: !historical,
                waitingBehindHead: historical ? 0 : 2,
                sessionToken: Object(),
              ),
            );
          final semantics = tester.ensureSemantics();
          try {
            await _pumpStudyScreen(
              tester,
              repository: r,
              study: Stream.value(
                StudyModel(streak: 0, reviewQueue: 0, progress: 0),
              ),
              subjects: Stream.value(const []),
            );
            expect(find.text('Verificação necessária'), findsOneWidget);
            expect(
              find.text(
                'A sincronização precisa de verificação. Seus registros foram preservados.',
              ),
              findsOneWidget,
            );
            expect(
              find.text('1 operação de estudos precisa de verificação.'),
              findsOneWidget,
            );
            expect(find.text('Tentar sincronizar novamente'), findsNothing);
            expect(
              find.text('2 operações posteriores aguardam nesta fila.'),
              historical ? findsNothing : findsOneWidget,
            );
            expect(
              find.bySemanticsLabel(
                RegExp('A sincronização precisa de verificação'),
              ),
              findsOneWidget,
            );
            for (final text in [
              'STUDY_REVIEW',
              'INVALID_PAYLOAD',
              'user-a',
              'subject-1',
              '409',
              'recuperação concluída',
            ])
              expect(find.textContaining(text), findsNothing);
            expect(r.retryCalls, 0);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
    testWidgets(
      'F01 notice remains readable at 320px and 2x text without allowing retry',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        ReviewCreationSyncState state() => ReviewCreationSyncState(
          () => true,
          studyStateHold: 1,
          studyStateRejected: 1,
          headBlocked: true,
          waitingBehindHead: 2,
          indeterminate: 1,
          retryEligible: true,
          sessionToken: Object(),
        );
        final r = _StudyRepository()..visibility = Stream.value(state());
        await _pumpStudyScreen(
          tester,
          repository: r,
          study: Stream.value(
            StudyModel(streak: 0, reviewQueue: 0, progress: 0),
          ),
          subjects: Stream.value(const []),
        );
        final notice = tester.widget<Widget>(find.byKey(ObjectKey(r)));
        r.visibility = Stream.value(state());
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(body: SingleChildScrollView(child: notice)),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(
          find.text('2 operações de estudos precisam de verificação.'),
          findsOneWidget,
        );
        expect(find.text('Tentar sincronizar novamente'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });
}

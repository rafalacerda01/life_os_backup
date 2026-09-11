import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/study/data/models/flashcard_model.dart';
import 'package:life_os/features/study/data/study_repository.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/study/presentation/screens/revisar_screen.dart';

class _Repository extends Fake implements StudyRepository {
  final syncCompleter = Completer<void>();
  final completeCompleter = Completer<void>();
  int completeCalls = 0;

  @override
  Future<void> syncStudyFromFirebaseToLocal() => syncCompleter.future;

  @override
  Future<void> completeCard(String cardId) {
    completeCalls += 1;
    return completeCompleter.future;
  }
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required _Repository repository,
  required Stream<List<FlashcardModel>> cards,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        studyRepositoryProvider.overrideWithValue(repository),
        flashcardStreamProvider.overrideWith((ref) => cards),
      ],
      child: const MaterialApp(home: RevisarScreen()),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets(
    'dados locais aparecem sem rede e revisão bloqueia double-submit',
    (tester) async {
      final repository = _Repository();
      await _pumpScreen(
        tester,
        repository: repository,
        cards: Stream.value([
          FlashcardModel(
            id: 'card-1',
            question: 'Pergunta local',
            answer: 'Resposta local',
          ),
        ]),
      );

      expect(find.text('Pergunta local'), findsOneWidget);
      expect(find.text('1 revisão restante'), findsOneWidget);
      await tester.tap(find.text('Ver resposta'));
      await tester.pump();
      expect(find.text('Resposta local'), findsOneWidget);
      final submit = find.text('Marcar como revisado');
      await tester.tap(submit);
      await tester.tap(submit);
      await tester.pump();

      expect(repository.completeCalls, 1);
      repository.completeCompleter.complete();
      repository.syncCompleter.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('estado vazio comunica conclusão e oferece retorno', (
    tester,
  ) async {
    final repository = _Repository();
    await _pumpScreen(
      tester,
      repository: repository,
      cards: Stream.value(const []),
    );

    expect(find.text('Revisões concluídas'), findsOneWidget);
    expect(find.text('Você está em dia por hoje.'), findsOneWidget);
    expect(find.text('Voltar aos estudos'), findsOneWidget);
    expect(find.textContaining('Erro:'), findsNothing);

    repository.syncCompleter.complete();
  });

  testWidgets('contador plural mostra revisões restantes', (tester) async {
    final repository = _Repository();
    await _pumpScreen(
      tester,
      repository: repository,
      cards: Stream.value([
        FlashcardModel(id: 'card-1', question: 'Q1', answer: 'A1'),
        FlashcardModel(id: 'card-2', question: 'Q2', answer: 'A2'),
      ]),
    );

    expect(find.text('2 revisões restantes'), findsOneWidget);
    repository.syncCompleter.complete();
  });

  testWidgets('erro de stream não expõe detalhes internos', (tester) async {
    final repository = _Repository();
    await _pumpScreen(
      tester,
      repository: repository,
      cards: Stream.error(Exception('private-review-error')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Não foi possível carregar as revisões agora.'),
      findsOneWidget,
    );
    expect(find.textContaining('private-review-error'), findsNothing);
    repository.syncCompleter.complete();
  });
}

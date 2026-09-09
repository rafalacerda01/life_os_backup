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

void main() {
  testWidgets(
    'dados locais aparecem sem rede e revisão bloqueia double-submit',
    (tester) async {
      final repository = _Repository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            studyRepositoryProvider.overrideWithValue(repository),
            flashcardStreamProvider.overrideWith(
              (ref) => Stream.value([
                FlashcardModel(
                  id: 'card-1',
                  question: 'Pergunta local',
                  answer: 'Resposta local',
                ),
              ]),
            ),
          ],
          child: const MaterialApp(home: RevisarScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Pergunta local'), findsOneWidget);
      await tester.tap(find.text('Ver Resposta'));
      await tester.pump();
      final submit = find.text('Acertei! Marcar como Revisado');
      await tester.tap(submit);
      await tester.tap(submit);
      await tester.pump();

      expect(repository.completeCalls, 1);
      repository.completeCompleter.complete();
      repository.syncCompleter.complete();
      await tester.pumpAndSettle();
    },
  );
}

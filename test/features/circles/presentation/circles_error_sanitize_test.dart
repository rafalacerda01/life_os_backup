// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/circles/data/remote/circle_delete_remote_data_source.dart';
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';
import 'package:life_os/features/circles/domain/entities/circle_entity.dart';
import 'package:life_os/features/circles/presentation/circles_provider.dart';
import 'package:life_os/features/circles/presentation/create_challenge_screen.dart';

class _FakeFirestore extends Fake implements FirebaseFirestore {}

class _FakeAuth extends Fake implements FirebaseAuth {}

class _FakeDeleteGateway implements CircleDeleteGateway {
  @override
  Future<void> deleteCircle(String circleId) async {}
}

class _FakeCirclesRepository extends CirclesRepository {
  _FakeCirclesRepository({this.joinError})
    : super(_FakeFirestore(), _FakeAuth(), _FakeDeleteGateway());

  final Object? joinError;

  static const circle = CircleEntity(
    id: 'circle-1',
    name: 'Circle',
    description: 'Description',
    adminId: 'admin-1',
    memberCount: 1,
    memberLimit: 3,
    schemaVersion: 2,
    members: [],
    challenges: [],
  );

  @override
  Stream<CircleEntity?> getCircleStream(String circleId) =>
      Stream<CircleEntity?>.value(circle);

  @override
  Future<void> joinCircleByCode(String circleId) async {
    if (joinError != null) throw joinError!;
  }
}
class _ErrorChallengeNotifier extends CirclesNotifier {
  @override
  CirclesState build() {
    return const CirclesState(
      availableCircles: [],
      joinedCircle: _FakeCirclesRepository.circle,
      isLoading: false,
    );
  }

  @override
  Future<void> createNewChallenge({
    required String title,
    required ChallengeType type,
    required int targetValue,
    required DateTime endAt,
  }) async {
    throw StateError('technical-challenge-firestore-error');
  }
}
void main() {
  test('join por código devolve mensagem segura e encerra loading', () async {
    const technicalError = 'technical-circle-firestore-permission-error';
    final repository = _FakeCirclesRepository(
      joinError: StateError(technicalError),
    );
    final container = ProviderContainer(
      overrides: [circlesRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    final message = await container
        .read(circlesProvider.notifier)
        .joinCircleByCode('circle-1');

    expect(
      message,
      'Não foi possível entrar no círculo. Verifique o código e tente novamente.',
    );
    expect(message, isNot(contains(technicalError)));
    expect(container.read(circlesProvider).isLoading, isFalse);
  });

  test('join por código bem-sucedido continua retornando null', () async {
    final repository = _FakeCirclesRepository();
    final container = ProviderContainer(
      overrides: [circlesRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    final message = await container
        .read(circlesProvider.notifier)
        .joinCircleByCode('circle-1');
    await Future<void>.delayed(Duration.zero);

    expect(message, isNull);
    expect(container.read(circlesProvider).isLoading, isFalse);
  });

  testWidgets('erro ao criar desafio não expõe exception no SnackBar', (
  tester,
) async {
  const technicalError = 'technical-challenge-firestore-error';

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        circlesProvider.overrideWith(_ErrorChallengeNotifier.new),
      ],
      child: const MaterialApp(
        home: CreateChallengeScreen(circleId: 'circle-1'),
      ),
    ),
  );

  await tester.enterText(find.byType(TextFormField).at(0), 'Desafio');
  await tester.enterText(find.byType(TextFormField).at(1), '10');

  await tester.tap(find.text('Criar Desafio'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  expect(
    find.text('Não foi possível criar o desafio. Tente novamente.'),
    findsOneWidget,
  );
  expect(find.textContaining(technicalError), findsNothing);

  // Finaliza o ciclo de vida do SnackBar e desmonta a tela explicitamente.
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
});
}

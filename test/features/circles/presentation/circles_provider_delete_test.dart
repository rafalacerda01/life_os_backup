// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/features/circles/data/remote/circle_delete_remote_data_source.dart';
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';
import 'package:life_os/features/circles/domain/entities/circle_entity.dart';
import 'package:life_os/features/circles/presentation/circles_provider.dart';

class FakeFirestore extends Fake implements FirebaseFirestore {}

class FakeAuth extends Fake implements FirebaseAuth {}

class FakeDeleteGateway implements CircleDeleteGateway {
  @override
  Future<void> deleteCircle(String circleId) async {}
}

class FakeCirclesRepository extends CirclesRepository {
  final CircleEntity circle;
  Stream<CircleEntity?>? circleStream;
  Future<void> Function(String circleId)? deleteAction;
  Object? deleteError;
  int deleteCalls = 0;
  int leaveCalls = 0;

  FakeCirclesRepository(this.circle)
    : super(FakeFirestore(), FakeAuth(), FakeDeleteGateway());

  @override
  Stream<CircleEntity?> getCircleStream(String circleId) =>
      circleStream ?? Stream.value(circle);

  @override
  Future<void> deleteCircle(String circleId) async {
    deleteCalls += 1;
    if (deleteError != null) throw deleteError!;
    await deleteAction?.call(circleId);
  }

  @override
  Future<void> leaveCircle(String circleId) async {
    leaveCalls += 1;
  }
}

CircleEntity fixtureCircle() {
  return const CircleEntity(
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
}

Future<void> settleStream() => Future<void>.delayed(Duration.zero);

void main() {
  test('erro de delete mantém Circle local visível', () async {
    final repository = FakeCirclesRepository(fixtureCircle())
      ..deleteError = StateError('backend failed');
    final container = ProviderContainer(
      overrides: [circlesRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(circlesProvider.notifier);
    await notifier.joinCircle('circle-1');
    await settleStream();

    await expectLater(
      notifier.deleteCircle('circle-1'),
      throwsA(isA<StateError>()),
    );

    expect(container.read(circlesProvider).joinedCircle?.id, 'circle-1');
    expect(repository.deleteCalls, 1);
  });

  test('delete confirmado limpa o Circle do estado', () async {
    final repository = FakeCirclesRepository(fixtureCircle());
    final container = ProviderContainer(
      overrides: [circlesRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(circlesProvider.notifier);
    await notifier.joinCircle('circle-1');
    await settleStream();

    await notifier.deleteCircle('circle-1');

    expect(repository.deleteCalls, 1);
    expect(container.read(circlesProvider).joinedCircle, isNull);
    expect(container.read(circlesProvider).availableCircles, isEmpty);
  });

  test('cancel bem-sucedido mantém delete confirmado como sucesso', () async {
    var canceled = false;
    final controller = StreamController<CircleEntity?>(
      onCancel: () => canceled = true,
    );
    addTearDown(controller.close);
    final repository = FakeCirclesRepository(fixtureCircle())
      ..circleStream = controller.stream
      ..deleteAction = (_) async {
        controller.add(null);
        await settleStream();
      };
    final container = ProviderContainer(
      overrides: [circlesRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(circlesProvider.notifier);
    await notifier.joinCircle('circle-1');
    controller.add(fixtureCircle());
    await settleStream();

    await expectLater(notifier.deleteCircle('circle-1'), completes);

    expect(container.read(circlesProvider).joinedCircle, isNull);
    expect(canceled, isTrue);
  });

  test(
    'falha de cancel pós-confirmação não transforma delete em erro',
    () async {
      final controller = StreamController<CircleEntity?>(
        onCancel: () => throw StateError('cancel failed'),
      );
      addTearDown(controller.close);
      final repository = FakeCirclesRepository(fixtureCircle())
        ..circleStream = controller.stream;
      final container = ProviderContainer(
        overrides: [circlesRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(circlesProvider.notifier);
      await notifier.joinCircle('circle-1');
      controller.add(fixtureCircle());
      await settleStream();

      await expectLater(notifier.deleteCircle('circle-1'), completes);
      controller.add(fixtureCircle());
      await settleStream();

      expect(repository.deleteCalls, 1);
      expect(container.read(circlesProvider).joinedCircle, isNull);
    },
  );

  test(
    '404 idempotente do gateway permite ao provider limpar Circle',
    () async {
      final gateway = CircleDeleteRemoteDataSource(
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode({'code': 'CIRCLE_NOT_FOUND'}), 404),
        ),
        idTokenProvider: () async => 'firebase-token',
        appCheckTokenProvider: () async => 'firebase-app-check-token',
        url: 'https://example.test/api/circles/delete',
      );
      final repository = FakeCirclesRepository(fixtureCircle())
        ..deleteAction = gateway.deleteCircle;
      final container = ProviderContainer(
        overrides: [circlesRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(circlesProvider.notifier);
      await notifier.joinCircle('circle-1');
      await settleStream();

      await expectLater(notifier.deleteCircle('circle-1'), completes);

      expect(repository.deleteCalls, 1);
      expect(container.read(circlesProvider).joinedCircle, isNull);
    },
  );

  test('leaveCircle permanece separado do delete server-side', () async {
    final repository = FakeCirclesRepository(fixtureCircle());
    final container = ProviderContainer(
      overrides: [circlesRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(circlesProvider.notifier);
    await notifier.joinCircle('circle-1');
    await settleStream();

    await notifier.leaveCircle('circle-1');

    expect(repository.leaveCalls, 1);
    expect(repository.deleteCalls, 0);
    expect(container.read(circlesProvider).joinedCircle, isNull);
  });
}

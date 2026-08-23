// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/circles/data/remote/circle_delete_remote_data_source.dart';
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';

class FakeUser extends Fake implements User {
  @override
  String get uid => 'admin-1';
}

class FakeAuth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => FakeUser();
}

class RecordingDeleteGateway implements CircleDeleteGateway {
  final calls = <String>[];
  Object? error;

  @override
  Future<void> deleteCircle(String circleId) async {
    calls.add(circleId);
    if (error != null) throw error!;
  }
}

class FakeFirestore extends Fake implements FirebaseFirestore {
  int batchCalls = 0;

  @override
  WriteBatch batch() {
    batchCalls += 1;
    throw UnimplementedError();
  }
}

void main() {
  test('deleteCircle usa somente o gateway server-authoritative', () async {
    final firestore = FakeFirestore();
    final gateway = RecordingDeleteGateway();
    final repository = CirclesRepository(firestore, FakeAuth(), gateway);

    await repository.deleteCircle('circle-1');

    expect(gateway.calls, ['circle-1']);
    expect(firestore.batchCalls, 0);
  });

  test(
    'falha do backend é propagada sem executar limpeza Firestore local',
    () async {
      final firestore = FakeFirestore();
      final gateway = RecordingDeleteGateway()
        ..error = const CircleDeleteRemoteException(
          statusCode: 500,
          code: 'CIRCLE_DELETE_SERVER_ERROR',
          message: 'Falha',
          isAmbiguous: true,
        );
      final repository = CirclesRepository(firestore, FakeAuth(), gateway);

      await expectLater(
        repository.deleteCircle('circle-1'),
        throwsA(isA<CircleDeleteRemoteException>()),
      );

      expect(gateway.calls, ['circle-1']);
      expect(firestore.batchCalls, 0);
    },
  );
}

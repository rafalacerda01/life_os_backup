// ignore_for_file: subtype_of_sealed_class
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/circles/data/remote/circle_delete_remote_data_source.dart';
import 'package:life_os/features/circles/data/remote/circle_leave_remote_data_source.dart';
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';

class _User extends Fake implements User {
  @override
  String get uid => 'member';
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => _User();
}

class _Delete extends Fake implements CircleDeleteGateway {}

class _Firestore extends Fake implements FirebaseFirestore {
  int batches = 0;
  @override
  WriteBatch batch() {
    batches++;
    throw StateError('No client leave batch allowed');
  }
}

class _Leave implements CircleLeaveGateway {
  final calls = <String>[];
  Object? error;
  @override
  Future<void> leaveCircle(String circleId) async {
    calls.add(circleId);
    if (error != null) throw error!;
  }
}

void main() {
  test(
    'leave uses only the authoritative gateway and never a Firestore batch',
    () async {
      final db = _Firestore();
      final gateway = _Leave();
      final repository = CirclesRepository(
        db,
        _Auth(),
        _Delete(),
        leaveRemote: gateway,
      );
      await repository.leaveCircle('circle');
      expect(gateway.calls, ['circle']);
      expect(db.batches, 0);
    },
  );
  test(
    'gateway failure propagates without reporting successful leave or client writes',
    () async {
      final db = _Firestore();
      final gateway = _Leave()
        ..error = const CircleLeaveRemoteException(
          code: 'CIRCLE_LEAVE_TIMEOUT',
          isAmbiguous: true,
        );
      final repository = CirclesRepository(
        db,
        _Auth(),
        _Delete(),
        leaveRemote: gateway,
      );
      await expectLater(
        repository.leaveCircle('circle'),
        throwsA(isA<CircleLeaveRemoteException>()),
      );
      expect(gateway.calls, ['circle']);
      expect(db.batches, 0);
    },
  );
}

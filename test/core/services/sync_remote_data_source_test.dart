// ignore_for_file: subtype_of_sealed_class, must_be_immutable

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';

class _RecordingHealthDocumentReference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final Map<String, dynamic> storedData = <String, dynamic>{};
  Map<String, dynamic>? lastData;
  SetOptions? lastOptions;
  FirebaseException? setError;

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    final error = setError;

    if (error != null) {
      throw error;
    }

    lastData = Map<String, dynamic>.from(data);
    lastOptions = options;

    if (options?.merge == true) {
      storedData.addAll(data);
    } else {
      storedData
        ..clear()
        ..addAll(data);
    }
  }
}

class _RecordingHealthCollectionReference extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final _RecordingHealthDocumentReference documentReference;

  _RecordingHealthCollectionReference(this.documentReference);

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    return documentReference;
  }
}

class _RecordingUserDocumentReference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final _RecordingHealthCollectionReference healthCollection;

  _RecordingUserDocumentReference(this.healthCollection);

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    if (path != 'health_info') {
      throw UnsupportedError('Unexpected collection: $path');
    }

    return healthCollection;
  }
}

class _RecordingUsersCollectionReference extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final _RecordingUserDocumentReference userDocumentReference;

  _RecordingUsersCollectionReference(this.userDocumentReference);

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    return userDocumentReference;
  }
}

class _RecordingFirestore extends Fake implements FirebaseFirestore {
  final _RecordingUsersCollectionReference usersCollection;

  _RecordingFirestore(this.usersCollection);

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    if (path != 'users') {
      throw UnsupportedError('Unexpected collection: $path');
    }

    return usersCollection;
  }
}

class _FakeFirebaseAuth extends Fake implements FirebaseAuth {}

SyncQueueTableData createHealthItem({
  required String operationType,
  required Map<String, dynamic> payload,
}) {
  return SyncQueueTableData(
    id: 1,
    collection: 'health_info',
    docId: '2026-08-21',
    operationType: operationType,
    payloadJson: jsonEncode(payload),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
  );
}

void main() {
  late _RecordingHealthDocumentReference healthDoc;
  late FirestoreSyncRemoteDataSource remote;

  setUp(() {
    healthDoc = _RecordingHealthDocumentReference();
    final healthCollection = _RecordingHealthCollectionReference(healthDoc);
    final userDoc = _RecordingUserDocumentReference(healthCollection);
    final usersCollection = _RecordingUsersCollectionReference(userDoc);
    final firestore = _RecordingFirestore(usersCollection);

    remote = FirestoreSyncRemoteDataSource(firestore, _FakeFirebaseAuth());
  });

  test('health_info update usa set com merge:true', () async {
    final item = createHealthItem(
      operationType: 'update',
      payload: {'mood': 'Radiante', 'date': '2026-08-21T10:00:00.000Z'},
    );

    final result = await remote.process('user-123', item);

    expect(result.isSuccess, isTrue);
    expect(healthDoc.lastData?['mood'], 'Radiante');
    expect(healthDoc.lastData?['date'], isA<Timestamp>());
    expect(healthDoc.lastOptions?.merge, isTrue);
  });

  test('health_info create também usa set com merge:true', () async {
    final item = createHealthItem(
      operationType: 'create',
      payload: {'waterIntakeMl': 250, 'date': '2026-08-21T10:00:00.000Z'},
    );

    final result = await remote.process('user-123', item);

    expect(result.isSuccess, isTrue);
    expect(healthDoc.lastData?['waterIntakeMl'], 250);
    expect(healthDoc.lastData?['date'], isA<Timestamp>());
    expect(healthDoc.lastOptions?.merge, isTrue);
  });

  test('humor seguido de água preserva ambos os campos', () async {
    await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {'mood': 'Radiante', 'date': '2026-08-21T10:00:00.000Z'},
      ),
    );
    await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {'waterIntakeMl': 750, 'date': '2026-08-21T10:05:00.000Z'},
      ),
    );

    expect(healthDoc.storedData['mood'], 'Radiante');
    expect(healthDoc.storedData['waterIntakeMl'], 750);
  });

  test('água seguida de humor preserva ambos os campos', () async {
    await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {'waterIntakeMl': 750, 'date': '2026-08-21T10:00:00.000Z'},
      ),
    );
    await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {'mood': 'Radiante', 'date': '2026-08-21T10:05:00.000Z'},
      ),
    );

    expect(healthDoc.storedData['waterIntakeMl'], 750);
    expect(healthDoc.storedData['mood'], 'Radiante');
  });

  test('ciclo parcial não apaga humor nem água', () async {
    healthDoc.storedData.addAll({'mood': 'Radiante', 'waterIntakeMl': 1000});

    final result = await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {
          'menstrualCycle': {
            'isEnabled': true,
            'lastPeriodStart': '2026-08-01T00:00:00.000',
            'cycleLengthDays': 28,
            'periodLengthDays': 5,
          },
          'date': '2026-08-21T10:10:00.000Z',
        },
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(healthDoc.storedData['mood'], 'Radiante');
    expect(healthDoc.storedData['waterIntakeMl'], 1000);
    expect(healthDoc.storedData['menstrualCycle'], isA<Map>());
  });

  test('permission-denied em health_info permanece recuperável', () async {
    healthDoc.setError = FirebaseException(
      plugin: 'cloud_firestore',
      code: 'permission-denied',
      message: 'App Check rejeitou a requisição.',
    );

    final result = await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {'mood': 'Radiante', 'date': '2026-08-21T10:00:00.000Z'},
      ),
    );

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'PERMISSION-DENIED');
  });

  test('data inválida de health_info não chega ao Firestore', () async {
    final result = await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {'mood': 'Radiante', 'date': 'data-inválida'},
      ),
    );

    expect(result.isPermanentFailure, isTrue);
    expect(healthDoc.lastData, isNull);
  });
}

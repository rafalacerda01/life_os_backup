// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/circles/data/remote/circle_delete_remote_data_source.dart';
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';

class _User extends Fake implements User {
  @override
  String get uid => 'admin';
}

class _Auth extends Fake implements FirebaseAuth {
  _Auth({this.authenticated = true});
  final bool authenticated;
  @override
  User? get currentUser => authenticated ? _User() : null;
}

class _Gateway extends Fake implements CircleDeleteGateway {}

class _Snapshot extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  _Snapshot(this.value);
  final Map<String, dynamic>? value;
  @override
  String get id => 'circle';
  @override
  bool get exists => value != null;
  @override
  Map<String, dynamic>? data() => value;
}

class _Document extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _Document(this.store, this.path);
  final _Firestore store;
  @override
  final String path;
  @override
  String get id => path.split('/').last;
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async => _Snapshot(store.documents[path]);
  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) => Stream.value(_Snapshot(store.documents[path]));
  @override
  CollectionReference<Map<String, dynamic>> collection(String name) =>
      _Collection(store, '$path/$name');
}

class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.store, this.path);
  final _Firestore store;
  @override
  final String path;
  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async => _EmptyQuery();
  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) => const Stream.empty();
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) {
    if (id == null) {
      store.generatedIds++;
      id = 'challenge-${store.generatedIds}';
    }
    return _Document(store, '$path/$id');
  }
}

class _EmptyQuery extends Fake implements QuerySnapshot<Map<String, dynamic>> {
  @override
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get docs => [];
}

class _Transaction extends Fake implements Transaction {
  _Transaction(this.store);
  final _Firestore store;
  final writes = <String, Map<String, dynamic>>{};
  final creates = <String>[];
  @override
  Future<DocumentSnapshot<T>> get<T>(DocumentReference<T> ref) async {
    expect(writes, isEmpty, reason: 'All reads precede writes');
    final value = store.documents[ref.path];
    return _Snapshot(value == null ? null : Map.of(value))
        as DocumentSnapshot<T>;
  }

  @override
  Transaction set<T>(DocumentReference<T> ref, T data, [SetOptions? options]) {
    creates.add(ref.path);
    writes[ref.path] = Map.of(data as Map<String, dynamic>);
    return this;
  }

  @override
  Transaction update(DocumentReference ref, Map<String, dynamic> data) {
    writes[ref.path] = Map.of(data);
    return this;
  }
}

class _Firestore extends Fake implements FirebaseFirestore {
  _Firestore(Map<String, dynamic>? root) {
    if (root != null) documents['circles/circle'] = Map.of(root);
  }
  final documents = <String, Map<String, dynamic>>{};
  final attempts = <_Transaction>[];
  int generatedIds = 0;
  int revision = 0;
  bool retryOnce = false;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(this, path);
  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> callback, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    for (var index = 0; index < maxAttempts; index++) {
      final oldRevision = revision;
      final transaction = _Transaction(this);
      attempts.add(transaction);
      final result = await callback(transaction);
      if (oldRevision != revision || (retryOnce && index == 0)) continue;
      for (final entry in transaction.writes.entries) {
        documents[entry.key] = {...?documents[entry.key], ...entry.value};
      }
      revision++;
      return result;
    }
    throw StateError('Transaction attempts exhausted');
  }
}

Map<String, dynamic> _root(int count) => {
  'name': 'Circle',
  'description': 'Description',
  'schemaVersion': 2,
  'challengeCount': count,
  'lastChallengeId': null,
  'adminId': 'admin',
  'memberCount': 1,
  'memberLimit': 3,
};

Future<void> _create(
  CirclesRepository repository, {
  String title = '  Challenge  ',
  int targetValue = 10,
  DateTime? endAt,
  ChallengeType type = ChallengeType.focusMinutes,
}) => repository.createChallenge(
  circleId: 'circle',
  title: title,
  type: type,
  targetValue: targetValue,
  endAt: endAt ?? DateTime.now().add(const Duration(days: 1)),
);

void main() {
  test(
    'getCircleStream and CircleEntity tolerate new metadata unchanged',
    () async {
      final root = _root(0);
      final store = _Firestore(root);
      final repository = CirclesRepository(store, _Auth(), _Gateway());
      final circle = await repository.getCircleStream('circle').first;
      expect(circle, isNotNull);
      expect(circle!.name, 'Circle');
      expect(circle.schemaVersion, 2);
      expect(circle.memberCount, 1);
      expect(circle.memberLimit, 3);
      expect(store.documents['circles/circle'], root);
      expect(store.attempts, isEmpty);
    },
  );

  for (final count in [0, 239]) {
    test(
      'count $count atomically creates Challenge and exact root increment',
      () async {
        final root = _root(count);
        final store = _Firestore(root);
        final repository = CirclesRepository(store, _Auth(), _Gateway());
        final end = DateTime.now().add(const Duration(days: 1));
        await _create(repository, endAt: end);
        final tx = store.attempts.single;
        expect(
          tx.writes.keys,
          unorderedEquals([
            'circles/circle',
            'circles/circle/challenges/challenge-1',
          ]),
        );
        expect(tx.writes['circles/circle'], {
          'challengeCount': count + 1,
          'lastChallengeId': 'challenge-1',
          'updatedAt': FieldValue.serverTimestamp(),
        });
        expect(store.documents['circles/circle/challenges/challenge-1'], {
          'type': 'FOCUS_MINUTES',
          'title': 'Challenge',
          'targetValue': 10,
          'startAt': FieldValue.serverTimestamp(),
          'endAt': Timestamp.fromDate(end),
          'createdBy': 'admin',
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
          'schemaVersion': 2,
        });
        expect(store.documents['circles/circle'], {
          ...root,
          ...tx.writes['circles/circle']!,
        });
      },
    );
  }

  final invalidRoots = <String, Map<String, dynamic>?>{
    'at cap': _root(240),
    'missing count': {..._root(0)}..remove('challengeCount'),
    'string count': {..._root(0), 'challengeCount': '0'},
    'null count': {..._root(0), 'challengeCount': null},
    'negative count': _root(-1),
    'over cap': _root(241),
    'fraction count': {..._root(0), 'challengeCount': 0.5},
    'missing Circle': null,
    'invalid schema': {..._root(0), 'schemaVersion': 1},
    'deleting Circle': {..._root(0), 'deletionState': 'SERVER_DELETING'},
    'present null deletion state': {..._root(0), 'deletionState': null},
    'partial metadata': {..._root(0)}..remove('lastChallengeId'),
    'invalid last ID': {..._root(0), 'lastChallengeId': ' bad '},
  };
  for (final entry in invalidRoots.entries) {
    test(
      '${entry.key} fails closed without creating or updating anything',
      () async {
        final store = _Firestore(entry.value);
        final repository = CirclesRepository(store, _Auth(), _Gateway());
        await expectLater(_create(repository), throwsStateError);
        expect(store.attempts.single.writes, isEmpty);
        expect(store.documents['circles/circle'], entry.value);
        expect(
          store.documents.keys.where((path) => path.contains('/challenges/')),
          isEmpty,
        );
      },
    );
  }

  test(
    'transaction retry reuses the exact same Challenge reference and ID',
    () async {
      final store = _Firestore(_root(0))..retryOnce = true;
      await _create(CirclesRepository(store, _Auth(), _Gateway()));
      expect(store.generatedIds, 1);
      expect(store.attempts, hasLength(2));
      expect(store.attempts[0].creates, [
        'circles/circle/challenges/challenge-1',
      ]);
      expect(store.attempts[1].creates, store.attempts[0].creates);
      expect(store.documents['circles/circle']!['challengeCount'], 1);
    },
  );

  test(
    'concurrent creations at 239 admit only one after transaction retry',
    () async {
      final store = _Firestore(_root(239));
      final repository = CirclesRepository(store, _Auth(), _Gateway());
      Future<bool> attempt() async {
        try {
          await _create(repository);
          return true;
        } on StateError {
          return false;
        }
      }

      final results = await Future.wait([attempt(), attempt()]);
      expect(results.where((success) => success), hasLength(1));
      expect(store.documents['circles/circle']!['challengeCount'], 240);
      expect(
        store.documents.keys.where((path) => path.contains('/challenges/')),
        hasLength(1),
      );
    },
  );

  for (final type in ChallengeType.values) {
    test('preserves ChallengeType ${type.value}', () async {
      final store = _Firestore(_root(0));
      await _create(CirclesRepository(store, _Auth(), _Gateway()), type: type);
      expect(
        store.documents['circles/circle/challenges/challenge-1']!['type'],
        type.value,
      );
    });
  }

  for (final invalid in [
    'empty title',
    'long title',
    'zero target',
    'large target',
    'past date',
    'distant date',
  ]) {
    test('$invalid is rejected before any transaction', () async {
      final store = _Firestore(_root(0));
      final repository = CirclesRepository(store, _Auth(), _Gateway());
      await expectLater(
        _create(
          repository,
          title: invalid == 'empty title'
              ? ' '
              : invalid == 'long title'
              ? 'x' * 201
              : 'Valid',
          targetValue: invalid == 'zero target'
              ? 0
              : invalid == 'large target'
              ? 1000001
              : 10,
          endAt: invalid == 'past date'
              ? DateTime(2000)
              : invalid == 'distant date'
              ? DateTime.now().add(const Duration(days: 367))
              : null,
        ),
        throwsArgumentError,
      );
      expect(store.attempts, isEmpty);
      expect(store.generatedIds, 0);
    });
  }
  test('unauthenticated creation never accesses Firestore', () async {
    final store = _Firestore(_root(0));
    await expectLater(
      _create(
        CirclesRepository(store, _Auth(authenticated: false), _Gateway()),
      ),
      throwsException,
    );
    expect(store.attempts, isEmpty);
    expect(store.generatedIds, 0);
  });
}

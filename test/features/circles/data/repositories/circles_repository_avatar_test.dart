// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/circles/data/remote/circle_delete_remote_data_source.dart';
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';
import 'package:life_os/features/circles/domain/entities/circle_entity.dart';

class _User extends Fake implements User {
  @override
  String get uid => 'user-a';

  @override
  String? get displayName => 'User A';

  @override
  String? get photoURL => null;
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => _User();
}

class _Gateway extends Fake implements CircleDeleteGateway {}

class _DocumentSnapshot extends Fake
    implements DocumentSnapshot<Map<String, dynamic>> {
  _DocumentSnapshot(this.document, this.value);

  final _Document document;
  final Map<String, dynamic>? value;

  @override
  String get id => document.id;

  @override
  bool get exists => value != null;

  @override
  DocumentReference<Map<String, dynamic>> get reference => document;

  @override
  Map<String, dynamic>? data() => value == null ? null : Map.of(value!);
}

class _QueryDocumentSnapshot extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _QueryDocumentSnapshot(this.document, this.value);

  final _Document document;
  final Map<String, dynamic> value;

  @override
  String get id => document.id;

  @override
  bool get exists => true;

  @override
  DocumentReference<Map<String, dynamic>> get reference => document;

  @override
  Map<String, dynamic> data() => Map.of(value);
}

class _QuerySnapshot extends Fake
    implements QuerySnapshot<Map<String, dynamic>> {
  _QuerySnapshot(this.docs);

  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

class _Document extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _Document(this.store, this.location);

  final _Firestore store;
  final String location;

  @override
  String get id => location.split('/').last;

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async => _DocumentSnapshot(this, store.documents[location]);

  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) => Stream.value(_DocumentSnapshot(this, store.documents[location]));

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(store, '$location/$path');
}

class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.store, this.location);

  final _Firestore store;
  final String location;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _Document(store, '$location/${path ?? 'new-circle'}');

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    final prefix = '$location/';
    final docs = store.documents.entries
        .where(
          (entry) =>
              entry.key.startsWith(prefix) &&
              !entry.key.substring(prefix.length).contains('/'),
        )
        .map(
          (entry) =>
              _QueryDocumentSnapshot(_Document(store, entry.key), entry.value),
        )
        .toList();
    return _QuerySnapshot(docs);
  }

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) => const Stream.empty();
}

class _Batch extends Fake implements WriteBatch {
  final writes = <String, Object?>{};

  @override
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) {
    writes[(document as _Document).location] = data;
  }

  @override
  void update(DocumentReference document, Map<String, dynamic> data) {
    writes[(document as _Document).location] = data;
  }

  @override
  Future<void> commit() async {}
}

class _Firestore extends Fake implements FirebaseFirestore {
  _Firestore([Map<String, Map<String, dynamic>>? documents])
    : documents = documents ?? <String, Map<String, dynamic>>{};

  final Map<String, Map<String, dynamic>> documents;
  final recordingBatch = _Batch();

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(this, path);

  @override
  WriteBatch batch() => recordingBatch;
}

Future<Object?> _createdMemberPhoto(Object? photoUrl) async {
  final firestore = _Firestore({
    'users/user-a': {
      'displayName': 'User A',
      'photoUrl': photoUrl,
      'activeCircleId': null,
      'isPremium': false,
    },
  });
  final repository = CirclesRepository(firestore, _Auth(), _Gateway());

  await repository.createCircle('Circle', 'Description');

  final member =
      firestore.recordingBatch.writes['circles/new-circle/members/user-a']
          as Map<String, dynamic>;
  return member['photoUrlSnapshot'];
}

Future<String?> _readMemberPhoto(Object? photoUrl) async {
  final firestore = _Firestore({
    'circles/circle-1': {
      'name': 'Circle',
      'description': 'Description',
      'adminId': 'user-a',
      'memberCount': 1,
      'memberLimit': 3,
      'schemaVersion': 2,
    },
    'circles/circle-1/members/user-a': {
      'role': CircleMemberRole.admin.value,
      'displayNameSnapshot': 'User A',
      'photoUrlSnapshot': photoUrl,
      'joinedAt': Timestamp.fromDate(DateTime.utc(2026, 1, 1)),
    },
  });
  final repository = CirclesRepository(firestore, _Auth(), _Gateway());

  final circle = await repository.getCircleStream('circle-1').first;

  return circle!.members.single.photoUrl;
}

void main() {
  test('caminho local não vira photoUrlSnapshot', () async {
    expect(
      await _createdMemberPhoto(
        '/data/user/0/com.rafalacerda.lifeos/cache/profile.jpg',
      ),
      isNull,
    );
  });

  test('snapshot legado com caminho local é lido como null', () async {
    expect(
      await _readMemberPhoto(
        '/data/user/0/com.rafalacerda.lifeos/cache/profile.jpg',
      ),
      isNull,
    );
  });

  test('avatar simbólico é preservado na escrita e leitura', () async {
    expect(await _createdMemberPhoto('avatar_cyber'), 'avatar_cyber');
    expect(await _readMemberPhoto('avatar_cyber'), 'avatar_cyber');
  });

  test('URL HTTPS é preservada na escrita e leitura', () async {
    const url = 'https://images.example.test/profile.jpg';
    expect(await _createdMemberPhoto(url), url);
    expect(await _readMemberPhoto(url), url);
  });
}

// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/circles/data/remote/circle_delete_remote_data_source.dart';
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';

class _User extends Fake implements User {
  @override
  String get uid => 'admin';
  @override
  String? get displayName => 'Admin';
  @override
  String? get photoURL => null;
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => _User();
}

class _Gateway extends Fake implements CircleDeleteGateway {}

class _Snapshot extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  _Snapshot(this.value);
  final Map<String, dynamic> value;
  @override
  Map<String, dynamic>? data() => value;
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
  ]) async => _Snapshot(store.user);
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
}

class _Batch extends Fake implements WriteBatch {
  final writes = <String, Object?>{};
  bool committed = false;
  @override
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) {
    writes[(document as _Document).location] = data;
  }

  @override
  void update(DocumentReference document, Map<String, dynamic> data) {
    writes[(document as _Document).location] = data;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }
}

class _Firestore extends Fake implements FirebaseFirestore {
  _Firestore(this.user);
  final Map<String, dynamic> user;
  final recordingBatch = _Batch();
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(this, path);
  @override
  WriteBatch batch() => recordingBatch;
}

void main() {
  Map<String, dynamic> premium() => {
    'isPremium': true,
    'premiumProvider': 'google_play',
    'premiumProductId': 'life_os_premium',
    'premiumTier': 'monthly',
    'premiumBasePlanId': 'monthly',
    'premiumSubscriptionState': 'SUBSCRIPTION_STATE_ACTIVE',
    'premiumExpiresAt': Timestamp.fromDate(
      DateTime.now().add(const Duration(hours: 1)),
    ),
  };

  final cases = <String, (Map<String, dynamic>, int)>{
    'Free': ({'isPremium': false}, 3),
    'raw flag': ({'isPremium': true}, 3),
    'valid monthly': (premium(), 30),
    'valid annual': (
      {...premium(), 'premiumTier': 'annual', 'premiumBasePlanId': 'annual'},
      30,
    ),
    'grace period': (
      {
        ...premium(),
        'premiumSubscriptionState': 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
      },
      30,
    ),
    'canceled but unexpired': (
      {...premium(), 'premiumSubscriptionState': 'SUBSCRIPTION_STATE_CANCELED'},
      30,
    ),
    'expired': (
      {
        ...premium(),
        'premiumExpiresAt': Timestamp.fromMillisecondsSinceEpoch(1),
      },
      3,
    ),
    'wrong provider': ({...premium(), 'premiumProvider': 'mock'}, 3),
    'wrong product': ({...premium(), 'premiumProductId': 'other'}, 3),
    'mismatched plan': ({...premium(), 'premiumBasePlanId': 'annual'}, 3),
    'on hold': (
      {...premium(), 'premiumSubscriptionState': 'SUBSCRIPTION_STATE_ON_HOLD'},
      3,
    ),
  };
  for (final entry in cases.entries) {
    test(
      'createCircle ${entry.key} writes limit ${entry.value.$2} atomically',
      () async {
        final store = _Firestore(entry.value.$1);
        final repository = CirclesRepository(store, _Auth(), _Gateway());
        expect(
          await repository.createCircle('Circle', 'Description'),
          'new-circle',
        );
        expect(store.recordingBatch.committed, isTrue);
        expect(
          store.recordingBatch.writes.keys,
          unorderedEquals([
            'circles/new-circle',
            'circles/new-circle/members/admin',
            'users/admin',
          ]),
        );
        expect(
          (store.recordingBatch.writes['circles/new-circle']
              as Map)['memberLimit'],
          entry.value.$2,
        );
        expect(store.recordingBatch.writes['users/admin'], {
          'activeCircleId': 'new-circle',
        });
      },
    );
  }
}

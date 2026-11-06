// Strict test ports implement SDK sealed value types; production does not.
// ignore_for_file: subtype_of_sealed_class, must_be_immutable
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/trusted_account_access.dart';

const ga = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const gb = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

class App extends Fake implements FirebaseApp {
  App(this.label);
  final String label;
  @override
  String get name => label;
  @override
  FirebaseOptions get options => const FirebaseOptions(
    apiKey: 'demo-key',
    appId: 'demo-app',
    messagingSenderId: 'demo',
    projectId: 'demo-life-os',
  );
}

class Token extends Fake implements IdTokenResult {
  Token(this.generation);
  final String? generation;
  @override
  Map<String, dynamic> get claims => {
    'aud': 'demo-life-os',
    'iss': 'https://securetoken.google.com/demo-life-os',
    'firebase': <String, dynamic>{},
    if (generation != null) 'lifeos_generation': generation,
  };
}

class Person extends Fake implements User {
  Person(this.id, this.generation);
  final String id;
  final String? generation;
  @override
  String get uid => id;
  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) async =>
      Token(generation);
}

class Auth extends Fake implements FirebaseAuth {
  User? person = Person('A', ga);
  String label = 'test-app';
  @override
  User? get currentUser => person;
  @override
  FirebaseApp get app => App(label);
}

class Metadata extends Fake implements SnapshotMetadata {
  Metadata({this.cache = false, this.pending = false});
  final bool cache, pending;
  @override
  bool get isFromCache => cache;
  @override
  bool get hasPendingWrites => pending;
}

class Snapshot extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  Snapshot(this.info);
  final Metadata info;
  @override
  SnapshotMetadata get metadata => info;
  @override
  bool get exists => true;
  @override
  Map<String, dynamic> data() => {
    'version': 1,
    'projectId': 'demo-life-os',
    'databaseId': '(default)',
    'uid': 'A',
    'generation': ga,
    'policy': 'AUTH_BLOCKING_GENESIS_V1',
    'state': 'ACTIVE',
  };
}

class Reference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  bool offline = false;
  Metadata metadata = Metadata();
  final reads = <Source>[];
  Future<void> Function()? beforeReply;
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async {
    final source = options?.source ?? Source.serverAndCache;
    reads.add(source);
    await beforeReply?.call();
    if (source == Source.server && offline)
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    return Snapshot(metadata);
  }
}

class Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  Collection(this.reference);
  final Reference reference;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    expect(path, 'A');
    return reference;
  }
}

class Store extends Fake implements FirebaseFirestore {
  final reference = Reference();
  String label = 'test-app';
  String database = '(default)';
  @override
  FirebaseApp get app => App(label);
  @override
  String get databaseId => database;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    expect(path, 'trusted_account_origins');
    return Collection(reference);
  }
}

void main() {
  test('offline cached receipt never admits a remote session', () async {
    final a = Auth(), s = Store();
    s.reference.offline = true;
    await expectLater(
      TrustedAccountAccess.ensureReady(a, s, 'A', allowBootstrap: false),
      throwsA(isA<FirebaseException>()),
    );
    expect(s.reference.reads, [Source.server]);
  });
  for (final cache in [false, true])
    for (final pending in [false, true]) {
      if (!cache && !pending) continue;
      test(
        'receipt cache=$cache pending=$pending is not server confirmation',
        () async {
          final a = Auth(), s = Store();
          s.reference.metadata = Metadata(cache: cache, pending: pending);
          await expectLater(
            TrustedAccountAccess.ensureReady(a, s, 'A', allowBootstrap: false),
            throwsA(isA<TrustedAccountPending>()),
          );
        },
      );
    }
  test(
    'same project but different FirebaseApp cannot mix Auth and Firestore',
    () async {
      final a = Auth(), s = Store()..label = 'foreign-auth-store';
      await expectLater(
        TrustedAccountAccess.ensureReady(a, s, 'A', allowBootstrap: false),
        throwsA(isA<TrustedAccountPending>()),
      );
      expect(s.reference.reads, isEmpty);
    },
  );
  test(
    'confirmed server receipt preserves existing positive consistency contract',
    () async {
      expect(
        await TrustedAccountAccess.ensureReady(
          Auth(),
          Store(),
          'A',
          allowBootstrap: false,
        ),
        ga,
      );
    },
  );
  test('legacy account without a generation never reads a receipt', () async {
    final a = Auth()..person = Person('A', null), s = Store();
    await expectLater(
      TrustedAccountAccess.ensureReady(a, s, 'A', allowBootstrap: false),
      throwsA(isA<TrustedAccountPending>()),
    );
    expect(s.reference.reads, isEmpty);
  });
  test(
    'same UID generation changes while receipt is in flight: no admission',
    () async {
      final a = Auth(), s = Store();
      s.reference.beforeReply = () async {
        a.person = Person('A', gb);
      };
      await expectLater(
        TrustedAccountAccess.ensureReady(a, s, 'A', allowBootstrap: false),
        throwsA(isA<TrustedAccountPending>()),
      );
    },
  );
  test('logout during receipt read never admits a stale response', () async {
    final a = Auth(), s = Store();
    s.reference.beforeReply = () async {
      a.person = null;
    };
    await expectLater(
      TrustedAccountAccess.ensureReady(a, s, 'A', allowBootstrap: false),
      throwsA(isA<TrustedAccountPending>()),
    );
  });
  test('foreign database is refused before receipt IO', () async {
    final a = Auth(), s = Store()..database = 'foreign';
    await expectLater(
      TrustedAccountAccess.ensureReady(a, s, 'A', allowBootstrap: false),
      throwsA(isA<TrustedAccountPending>()),
    );
    expect(s.reference.reads, isEmpty);
  });
}

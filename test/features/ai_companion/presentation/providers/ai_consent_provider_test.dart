// ignore_for_file: must_be_immutable, subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_consent_provider.dart';

class _FakeSnapshot extends Fake
    implements DocumentSnapshot<Map<String, dynamic>> {
  final Map<String, dynamic>? value;

  _FakeSnapshot(this.value);

  @override
  bool get exists => value != null;

  @override
  Map<String, dynamic>? data() => value == null ? null : Map.of(value!);
}

class _FakeConsentDocument extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  Map<String, dynamic>? stored;
  Map<String, dynamic>? lastSet;
  Map<Object, Object?>? lastUpdate;
  bool failGet = false;
  bool failWrite = false;
  int _clock = 0;

  _FakeConsentDocument([Map<String, dynamic>? initial])
    : stored = initial == null ? null : Map.of(initial);

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async {
    if (failGet) throw FirebaseException(plugin: 'cloud_firestore');
    return _FakeSnapshot(stored);
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    if (failWrite) throw FirebaseException(plugin: 'cloud_firestore');
    lastSet = Map.of(data);
    stored = _resolveServerTimestamps(data);
  }

  @override
  Future<void> update(Map<Object, Object?> data) async {
    if (failWrite) throw FirebaseException(plugin: 'cloud_firestore');
    lastUpdate = Map.of(data);
    stored = {...?stored, ..._resolveServerTimestamps(data)};
  }

  Map<String, dynamic> _resolveServerTimestamps(Map<Object, Object?> data) {
    final timestamp = Timestamp.fromMillisecondsSinceEpoch(++_clock * 1000);
    return data.map(
      (key, value) =>
          MapEntry(key.toString(), value is FieldValue ? timestamp : value),
    );
  }
}

class _FakeCache {
  final Map<String, bool> values = {};
  bool throwOnWrite = false;
  bool throwOnRemove = false;

  Future<bool> write(String key, bool value) async {
    if (throwOnWrite) throw StateError('cache failure');
    values[key] = value;
    return true;
  }

  Future<bool> remove(String key) async {
    if (throwOnRemove) throw StateError('cache failure');
    values.remove(key);
    return true;
  }
}

const _userId = 'user-1';
const _cacheKey = 'ai_consent_accepted_$_userId';

Map<String, dynamic> acceptedDocument({Timestamp? acceptedAt}) => {
  'accepted': true,
  'userId': _userId,
  'consentVersion': '1.0',
  'acceptedAt': acceptedAt ?? Timestamp.fromMillisecondsSinceEpoch(100),
  'revokedAt': null,
  'updatedAt': Timestamp.fromMillisecondsSinceEpoch(100),
  'source': 'life_os_app',
};

Map<String, dynamic> revokedDocument() => {
  ...acceptedDocument(),
  'accepted': false,
  'revokedAt': Timestamp.fromMillisecondsSinceEpoch(200),
  'updatedAt': Timestamp.fromMillisecondsSinceEpoch(200),
};

ProviderContainer _createContainer(
  _FakeConsentDocument document,
  _FakeCache cache, {
  String? userId = _userId,
}) {
  return ProviderContainer(
    overrides: [
      aiConsentProvider.overrideWith(
        () => AiConsentNotifier(
          userIdProvider: () => userId,
          documentProvider: (_) => document,
          cacheWrite: cache.write,
          cacheRemove: cache.remove,
        ),
      ),
    ],
  );
}

void main() {
  test('primeiro aceite cria schema completo com revokedAt null', () async {
    final document = _FakeConsentDocument();
    final cache = _FakeCache();
    final container = _createContainer(document, cache);
    addTearDown(container.dispose);
    await container.read(aiConsentProvider.future);

    await container.read(aiConsentProvider.notifier).acceptConsent();

    expect(document.lastSet, {
      'accepted': true,
      'userId': _userId,
      'consentVersion': '1.0',
      'acceptedAt': isA<FieldValue>(),
      'revokedAt': null,
      'updatedAt': isA<FieldValue>(),
      'source': 'life_os_app',
    });
    expect(container.read(aiConsentProvider).value, isTrue);
    expect(cache.values[_cacheKey], isTrue);
  });

  test('revogação preserva acceptedAt e preenche revokedAt', () async {
    final acceptedAt = Timestamp.fromMillisecondsSinceEpoch(123);
    final document = _FakeConsentDocument(
      acceptedDocument(acceptedAt: acceptedAt),
    );
    final cache = _FakeCache()..values[_cacheKey] = true;
    final container = _createContainer(document, cache);
    addTearDown(container.dispose);
    expect(await container.read(aiConsentProvider.future), isTrue);

    await container.read(aiConsentProvider.notifier).revokeConsent();

    expect(document.lastUpdate, {
      'accepted': false,
      'revokedAt': isA<FieldValue>(),
      'updatedAt': isA<FieldValue>(),
    });
    expect(document.stored?['acceptedAt'], acceptedAt);
    expect(document.stored?['revokedAt'], isA<Timestamp>());
    expect(container.read(aiConsentProvider).value, isFalse);
    expect(cache.values.containsKey(_cacheKey), isFalse);
  });

  test('reaceite atualiza acceptedAt e limpa revokedAt', () async {
    final document = _FakeConsentDocument(revokedDocument());
    final previousAcceptedAt = document.stored?['acceptedAt'];
    final cache = _FakeCache();
    final container = _createContainer(document, cache);
    addTearDown(container.dispose);
    expect(await container.read(aiConsentProvider.future), isFalse);

    await container.read(aiConsentProvider.notifier).acceptConsent();

    expect(document.lastUpdate, {
      'accepted': true,
      'acceptedAt': isA<FieldValue>(),
      'revokedAt': null,
      'updatedAt': isA<FieldValue>(),
    });
    expect(document.stored?['acceptedAt'], isNot(previousAcceptedAt));
    expect(document.stored?['revokedAt'], isNull);
    expect(container.read(aiConsentProvider).value, isTrue);
  });

  test('aceite já ativo não envia update true para true', () async {
    final document = _FakeConsentDocument(acceptedDocument());
    final cache = _FakeCache();
    final container = _createContainer(document, cache);
    addTearDown(container.dispose);
    expect(await container.read(aiConsentProvider.future), isTrue);

    await container.read(aiConsentProvider.notifier).acceptConsent();

    expect(document.lastUpdate, isNull);
    expect(container.read(aiConsentProvider).value, isTrue);
    expect(cache.values[_cacheKey], isTrue);
  });

  test('revogação já concluída não envia update false para false', () async {
    final document = _FakeConsentDocument(revokedDocument());
    final cache = _FakeCache()..values[_cacheKey] = true;
    final container = _createContainer(document, cache);
    addTearDown(container.dispose);
    expect(await container.read(aiConsentProvider.future), isFalse);

    await container.read(aiConsentProvider.notifier).revokeConsent();

    expect(document.lastUpdate, isNull);
    expect(container.read(aiConsentProvider).value, isFalse);
    expect(cache.values.containsKey(_cacheKey), isFalse);
  });

  test('build mantém true quando escrita do cache falha', () async {
    final document = _FakeConsentDocument(acceptedDocument());
    final cache = _FakeCache()..throwOnWrite = true;
    final container = _createContainer(document, cache);
    addTearDown(container.dispose);

    expect(await container.read(aiConsentProvider.future), isTrue);
    expect(container.read(aiConsentProvider).value, isTrue);
  });

  test('build deriva documento e cache do mesmo UID capturado', () async {
    final document = _FakeConsentDocument(acceptedDocument());
    final cache = _FakeCache();
    var userIdReads = 0;
    String? documentUserId;
    final container = ProviderContainer(
      overrides: [
        aiConsentProvider.overrideWith(
          () => AiConsentNotifier(
            userIdProvider: () {
              userIdReads++;
              return userIdReads == 1 ? _userId : 'user-2';
            },
            documentProvider: (userId) {
              documentUserId = userId;
              return document;
            },
            cacheWrite: cache.write,
            cacheRemove: cache.remove,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(aiConsentProvider.future), isTrue);

    expect(userIdReads, 1);
    expect(documentUserId, _userId);
    expect(cache.values[_cacheKey], isTrue);
    expect(cache.values.containsKey('ai_consent_accepted_user-2'), isFalse);
  });

  test(
    'aceite remoto mantém state true quando escrita do cache falha',
    () async {
      final document = _FakeConsentDocument();
      final cache = _FakeCache()..throwOnWrite = true;
      final container = _createContainer(document, cache);
      addTearDown(container.dispose);
      expect(await container.read(aiConsentProvider.future), isFalse);

      await expectLater(
        container.read(aiConsentProvider.notifier).acceptConsent(),
        completes,
      );

      expect(document.stored?['accepted'], isTrue);
      expect(container.read(aiConsentProvider).value, isTrue);
    },
  );

  test('usuário não autenticado não aceita nem revoga', () async {
    final document = _FakeConsentDocument();
    final cache = _FakeCache();
    final container = _createContainer(document, cache, userId: null);
    addTearDown(container.dispose);
    expect(await container.read(aiConsentProvider.future), isFalse);

    await expectLater(
      container.read(aiConsentProvider.notifier).acceptConsent(),
      throwsException,
    );
    await expectLater(
      container.read(aiConsentProvider.notifier).revokeConsent(),
      throwsException,
    );

    expect(document.lastSet, isNull);
    expect(document.lastUpdate, isNull);
  });

  test('falha Firestore durante revoke não conclui revogação', () async {
    final document = _FakeConsentDocument(acceptedDocument());
    final cache = _FakeCache()..values[_cacheKey] = true;
    final container = _createContainer(document, cache);
    addTearDown(container.dispose);
    await container.read(aiConsentProvider.future);
    document.failWrite = true;

    await expectLater(
      container.read(aiConsentProvider.notifier).revokeConsent(),
      throwsA(isA<FirebaseException>()),
    );

    expect(document.stored?['accepted'], isTrue);
    expect(container.read(aiConsentProvider).hasError, isTrue);
    expect(cache.values[_cacheKey], isTrue);
  });

  test('revoke remoto prevalece quando limpeza local falha', () async {
    final document = _FakeConsentDocument(acceptedDocument());
    final cache = _FakeCache()
      ..values[_cacheKey] = true
      ..throwOnRemove = true;
    final container = _createContainer(document, cache);
    addTearDown(container.dispose);
    await container.read(aiConsentProvider.future);

    await expectLater(
      container.read(aiConsentProvider.notifier).revokeConsent(),
      completes,
    );

    expect(document.stored?['accepted'], isFalse);
    expect(container.read(aiConsentProvider).value, isFalse);
  });

  test('build com accepted false retorna false e remove cache', () async {
    final document = _FakeConsentDocument(revokedDocument());
    final cache = _FakeCache()..values[_cacheKey] = true;
    final container = _createContainer(document, cache);
    addTearDown(container.dispose);

    expect(await container.read(aiConsentProvider.future), isFalse);
    expect(cache.values.containsKey(_cacheKey), isFalse);
  });
}

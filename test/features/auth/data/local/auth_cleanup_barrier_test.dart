import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/auth/data/local/auth_cleanup_barrier.dart';

const _storageKey = 'life_os_auth_cleanup_pending_v1';
const _revisionA = 'AAAAAAAAAAAAAAAAAAAAAA';
const _revisionB = 'BBBBBBBBBBBBBBBBBBBBBB';
const _revisionC = 'CCCCCCCCCCCCCCCCCCCCCC';

class _MemoryBarrierStorage implements AuthCleanupBarrierStorage {
  _MemoryBarrierStorage([Map<String, String>? values])
    : values = values ?? <String, String>{};

  final Map<String, String> values;
  bool throwOnWrite = false;
  bool throwOnDelete = false;
  Completer<void>? deleteStarted;
  Completer<void>? allowDelete;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (throwOnWrite) throw StateError('private write failure');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (throwOnDelete) throw StateError('private delete failure');
    final started = deleteStarted;
    if (started != null && !started.isCompleted) started.complete();
    await allowDelete?.future;
    values.remove(key);
  }
}

class _RevisionFactory {
  _RevisionFactory(this._values);

  final List<String> _values;

  String call() => _values.removeAt(0);
}

AuthCleanupBarrierStore _store(
  _MemoryBarrierStorage storage, [
  List<String> revisions = const <String>[_revisionA, _revisionB, _revisionC],
]) {
  return AuthCleanupBarrierStore(
    storage,
    revisionFactory: _RevisionFactory(List<String>.of(revisions)).call,
  );
}

PendingAuthCleanup _differentMarker(
  PendingAuthCleanup marker, {
  String? userId,
  String? revision,
}) {
  return PendingAuthCleanup(
    version: marker.version,
    userId: userId ?? marker.userId,
    intent: marker.intent,
    revision: revision ?? marker.revision,
  );
}

void main() {
  test('pending sobrevive a nova instância do store', () async {
    final values = <String, String>{};
    final first = AuthCleanupBarrierStore(_MemoryBarrierStorage(values));

    await first.setPending('user-a', AuthCleanupIntent.isolation);

    final second = AuthCleanupBarrierStore(_MemoryBarrierStorage(values));
    final pending = await second.readPending();
    expect(pending?.userId, 'user-a');
    expect(pending?.intent, AuthCleanupIntent.isolation);
  });

  test('clear persiste ausência para nova instância', () async {
    final values = <String, String>{};
    final storage = _MemoryBarrierStorage(values);
    final first = AuthCleanupBarrierStore(storage);
    final marker = await first.setPending('user-a', AuthCleanupIntent.logout);

    expect(await first.clearIfCurrent(marker), isTrue);

    final second = AuthCleanupBarrierStore(_MemoryBarrierStorage(values));
    expect(await second.readPending(), isNull);
  });

  test('falha de write propaga sem criar marker', () async {
    final storage = _MemoryBarrierStorage()..throwOnWrite = true;
    final store = AuthCleanupBarrierStore(storage);

    await expectLater(
      store.setPending('user-a', AuthCleanupIntent.isolation),
      throwsStateError,
    );
    expect(await store.readPending(), isNull);
  });

  test('falha de clear propaga e mantém pending', () async {
    final storage = _MemoryBarrierStorage();
    final store = AuthCleanupBarrierStore(storage);
    final marker = await store.setPending('user-a', AuthCleanupIntent.logout);
    storage.throwOnDelete = true;

    await expectLater(store.clearIfCurrent(marker), throwsStateError);

    final pending = await AuthCleanupBarrierStore(
      _MemoryBarrierStorage(storage.values),
    ).readPending();
    expect(pending?.userId, 'user-a');
    expect(pending?.requiresSignOut, isTrue);
  });

  test('logout faz upgrade e nunca é rebaixado para isolation', () async {
    final store = AuthCleanupBarrierStore(_MemoryBarrierStorage());

    await store.setPending('user-a', AuthCleanupIntent.isolation);
    await store.setPending('user-a', AuthCleanupIntent.logout);
    await store.setPending('user-a', AuthCleanupIntent.isolation);

    expect((await store.readPending())?.requiresSignOut, isTrue);
  });

  test('UID diferente não substitui cleanup já pendente', () async {
    final store = AuthCleanupBarrierStore(_MemoryBarrierStorage());
    await store.setPending('user-a', AuthCleanupIntent.isolation);

    await expectLater(
      store.setPending('user-b', AuthCleanupIntent.isolation),
      throwsStateError,
    );
    expect((await store.readPending())?.userId, 'user-a');
  });

  test('create isolation retorna marker versionado com revisão', () async {
    final store = _store(_MemoryBarrierStorage());

    final marker = await store.setPending(
      'user-a',
      AuthCleanupIntent.isolation,
    );

    expect(marker.version, 2);
    expect(marker.userId, 'user-a');
    expect(marker.intent, AuthCleanupIntent.isolation);
    expect(marker.revision, _revisionA);
    expect(await store.readPending(), marker);
  });

  test('same intent reutiliza a mesma revisão', () async {
    final store = _store(_MemoryBarrierStorage());
    final first = await store.setPending('user-a', AuthCleanupIntent.isolation);

    final second = await store.setPending(
      'user-a',
      AuthCleanupIntent.isolation,
    );

    expect(second, first);
    expect(second.revision, first.revision);
  });

  test('promotion isolation para logout cria nova revisão', () async {
    final store = _store(_MemoryBarrierStorage());
    final isolation = await store.setPending(
      'user-a',
      AuthCleanupIntent.isolation,
    );

    final logout = await store.setPending('user-a', AuthCleanupIntent.logout);

    expect(logout.requiresSignOut, isTrue);
    expect(logout.revision, _revisionB);
    expect(logout.revision, isNot(isolation.revision));
    expect(
      await store.setPending('user-a', AuthCleanupIntent.isolation),
      logout,
    );
  });

  test('clear stale não remove marker promovido', () async {
    final store = _store(_MemoryBarrierStorage());
    final isolation = await store.setPending(
      'user-a',
      AuthCleanupIntent.isolation,
    );
    final logout = await store.setPending('user-a', AuthCleanupIntent.logout);

    expect(await store.clearIfCurrent(isolation), isFalse);
    expect(await store.readPending(), logout);
  });

  test('UID ou revisão incorretos não removem marker atual', () async {
    final store = _store(_MemoryBarrierStorage());
    final marker = await store.setPending('user-a', AuthCleanupIntent.logout);

    expect(
      await store.clearIfCurrent(_differentMarker(marker, userId: 'user-b')),
      isFalse,
    );
    expect(
      await store.clearIfCurrent(
        _differentMarker(marker, revision: _revisionB),
      ),
      isFalse,
    );
    expect(await store.readPending(), marker);
  });

  test('clear antigo bloqueado não remove logout mais novo', () async {
    final store = _store(_MemoryBarrierStorage());
    final isolation = await store.setPending(
      'user-a',
      AuthCleanupIntent.isolation,
    );
    final allowOldClear = Completer<void>();
    final oldCleanup = () async {
      await allowOldClear.future;
      return store.clearIfCurrent(isolation);
    }();

    final logout = await store.setPending('user-a', AuthCleanupIntent.logout);
    allowOldClear.complete();

    expect(await oldCleanup, isFalse);
    expect(await store.readPending(), logout);
  });

  test('duas instâncias serializam clear anterior ao novo logout', () async {
    final storage = _MemoryBarrierStorage();
    final clearStore = _store(storage, const <String>[_revisionA]);
    final setStore = _store(storage, const <String>[_revisionB]);
    final isolation = await clearStore.setPending(
      'user-a',
      AuthCleanupIntent.isolation,
    );
    storage.deleteStarted = Completer<void>();
    storage.allowDelete = Completer<void>();

    final clear = clearStore.clearIfCurrent(isolation);
    await storage.deleteStarted!.future;
    final logoutFuture = setStore.setPending(
      'user-a',
      AuthCleanupIntent.logout,
    );
    storage.allowDelete!.complete();

    expect(await clear, isTrue);
    final logout = await logoutFuture;
    expect(logout.requiresSignOut, isTrue);
    expect(logout.revision, _revisionB);
    expect(await clearStore.readPending(), logout);
  });

  test('marker malformado falha fechado', () async {
    final storage = _MemoryBarrierStorage(<String, String>{_storageKey: '{'});

    await expectLater(_store(storage).readPending(), throwsFormatException);
  });

  test('versão desconhecida falha fechado', () async {
    final storage = _MemoryBarrierStorage(<String, String>{
      _storageKey: jsonEncode(<String, Object>{
        'v': 99,
        'uid': 'user-a',
        'logout': false,
        'revision': _revisionA,
      }),
    });

    await expectLater(_store(storage).readPending(), throwsFormatException);
  });

  test('intent inválida falha fechado', () async {
    final storage = _MemoryBarrierStorage(<String, String>{
      _storageKey: jsonEncode(<String, Object>{
        'v': 2,
        'uid': 'user-a',
        'logout': 'invalid',
        'revision': _revisionA,
      }),
    });

    await expectLater(_store(storage).readPending(), throwsFormatException);
  });

  test('UID vazio falha fechado', () async {
    final storage = _MemoryBarrierStorage(<String, String>{
      _storageKey: jsonEncode(<String, Object>{
        'v': 2,
        'uid': ' ',
        'logout': false,
        'revision': _revisionA,
      }),
    });

    await expectLater(_store(storage).readPending(), throwsArgumentError);
  });

  test('revision ausente falha fechado', () async {
    final storage = _MemoryBarrierStorage(<String, String>{
      _storageKey: jsonEncode(<String, Object>{
        'v': 2,
        'uid': 'user-a',
        'logout': false,
      }),
    });

    await expectLater(_store(storage).readPending(), throwsFormatException);
  });
}

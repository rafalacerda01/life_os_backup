import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_security.dart';

class _MemoryTokenStorage implements CycleReminderActionTokenStorage {
  final Map<String, String> values = <String, String>{};
  bool throwOnRead = false;
  bool throwOnWrite = false;
  int writeFailuresRemaining = 0;
  int writeCalls = 0;
  Completer<void>? firstWriteStarted;
  Future<void>? writeGate;

  @override
  Future<String?> read(String key) async {
    if (throwOnRead) throw StateError('private read failure');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writeCalls += 1;
    final started = firstWriteStarted;
    if (writeCalls == 1 && started != null && !started.isCompleted) {
      started.complete();
    }
    final gate = writeGate;
    if (gate != null) await gate;
    if (writeFailuresRemaining > 0) {
      writeFailuresRemaining -= 1;
      throw StateError('private write failure');
    }
    if (throwOnWrite) throw StateError('private write failure');
    values[key] = value;
  }
}

void main() {
  const codec = CycleReminderActionPayloadCodec();
  final token = base64Url.encode(List<int>.filled(32, 7)).replaceAll('=', '');

  test('payload válido usa somente versão, kind e token opaco', () {
    final encoded = codec.encode(CycleReminderActionPayload(token));
    final decoded = codec.decode(encoded);
    final json = jsonDecode(encoded) as Map<String, dynamic>;

    expect(decoded?.token, token);
    expect(json.keys.toSet(), {'v', 'k', 'o'});
    expect(json['v'], cycleReminderActionPayloadVersion);
    expect(json['k'], cycleReminderActionKind);
  });

  test('codec rejeita JSON e contratos inválidos sem lançar', () {
    final invalidPayloads = <String>[
      '{',
      '{}',
      jsonEncode(<String, Object>{'v': 2, 'k': 'cr', 'o': token}),
      jsonEncode(<String, Object>{'v': 1, 'k': 'other', 'o': token}),
      jsonEncode(<String, Object>{'v': 1, 'k': 'cr', 'o': ''}),
      jsonEncode(<String, Object>{'v': 1, 'k': 'cr', 'o': 4}),
      jsonEncode(<String, Object>{
        'v': 1,
        'k': 'cr',
        'o': token,
        'extra': true,
      }),
      'x' * (CycleReminderActionPayloadCodec.maxPayloadLength + 1),
    ];

    for (final payload in invalidPayloads) {
      expect(codec.decode(payload), isNull);
    }
  });

  test('payload e token não contêm UID nem metadados privados', () {
    const userId = 'private-user-id';
    final encoded = codec.encode(CycleReminderActionPayload(token));

    expect(token, isNot(contains(userId)));
    expect(encoded, isNot(contains(userId)));
    for (final forbidden in <String>[
      'uid',
      'title',
      'body',
      'type',
      'time',
      'weekdays',
      'cycle',
      'pill',
    ]) {
      expect(encoded.toLowerCase(), isNot(contains(forbidden)));
    }
  });

  test('getOrCreate é estável por UID e distinto entre UIDs', () async {
    final storage = _MemoryTokenStorage();
    var generation = 0;
    final store = CycleReminderActionTokenStore(
      storage,
      randomBytes: (length) {
        generation += 1;
        return List<int>.filled(length, generation);
      },
    );

    final firstA = await store.getOrCreate('user-a');
    final secondA = await store.getOrCreate('user-a');
    final firstB = await store.getOrCreate('user-b');

    expect(firstA, secondA);
    expect(firstA, isNot(firstB));
    expect(isValidCycleReminderActionToken(firstA), isTrue);
    expect(isValidCycleReminderActionToken(firstB), isTrue);
    expect(generation, 2);
  });

  test('rotate substitui T1 por T2 seguro para o mesmo UID', () async {
    final storage = _MemoryTokenStorage();
    var generation = 0;
    final store = CycleReminderActionTokenStore(
      storage,
      randomBytes: (length) {
        generation += 1;
        return List<int>.filled(length, generation);
      },
    );

    final first = await store.getOrCreate('user-a');
    final rotated = await store.rotate('user-a');
    final current = await store.getOrCreate('user-a');

    expect(rotated, isNot(first));
    expect(current, rotated);
    expect(isValidCycleReminderActionToken(first), isTrue);
    expect(isValidCycleReminderActionToken(rotated), isTrue);
    expect(generation, 2);
  });

  test('getOrCreate concorrente não sobrescreve token rotacionado', () async {
    final storage = _MemoryTokenStorage();
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    storage
      ..firstWriteStarted = firstWriteStarted
      ..writeGate = releaseFirstWrite.future;
    var generation = 0;
    final store = CycleReminderActionTokenStore(
      storage,
      randomBytes: (length) {
        generation += 1;
        return List<int>.filled(length, generation);
      },
    );

    final oldGetOrCreate = store.getOrCreate('user-a');
    await firstWriteStarted.future;
    final rotation = store.rotate('user-a');
    releaseFirstWrite.complete();

    final oldToken = await oldGetOrCreate;
    final newToken = await rotation;
    final storedToken = await store.load('user-a');

    expect(newToken, isNot(oldToken));
    expect(storedToken, newToken);
    expect(await store.getOrCreate('user-a'), newToken);
    expect(storage.writeCalls, 2);
  });

  test('falha de rotação propaga e retry posterior conclui', () async {
    final storage = _MemoryTokenStorage();
    var generation = 0;
    final store = CycleReminderActionTokenStore(
      storage,
      randomBytes: (length) {
        generation += 1;
        return List<int>.filled(length, generation);
      },
    );
    final first = await store.getOrCreate('user-a');
    storage.writeFailuresRemaining = 1;

    await expectLater(store.rotate('user-a'), throwsStateError);
    expect(await store.load('user-a'), first);

    final rotated = await store.rotate('user-a');
    expect(rotated, isNot(first));
    expect(await store.load('user-a'), rotated);
  });

  test('UID vazio é rejeitado', () async {
    final store = CycleReminderActionTokenStore(_MemoryTokenStorage());

    expect(() => store.getOrCreate('  '), throwsArgumentError);
    expect(() => store.rotate('  '), throwsArgumentError);
    await expectLater(store.load('  '), throwsArgumentError);
  });

  test('falha de storage propaga para permitir fail-closed', () async {
    final readFailure = _MemoryTokenStorage()..throwOnRead = true;
    final writeFailure = _MemoryTokenStorage()..throwOnWrite = true;

    await expectLater(
      CycleReminderActionTokenStore(readFailure).getOrCreate('user-a'),
      throwsStateError,
    );
    await expectLater(
      CycleReminderActionTokenStore(writeFailure).getOrCreate('user-a'),
      throwsStateError,
    );
  });

  test('token persistido semanticamente inválido falha fechado', () async {
    final storage = _MemoryTokenStorage();
    storage.values['life_os_cycle_action_token_v1_user-a'] = 'invalid';
    final store = CycleReminderActionTokenStore(storage);

    await expectLater(store.load('user-a'), throwsFormatException);
  });
}

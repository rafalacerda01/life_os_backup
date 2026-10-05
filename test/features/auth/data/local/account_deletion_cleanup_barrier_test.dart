import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/auth/data/local/account_deletion_cleanup_barrier.dart';
import 'package:life_os/features/auth/data/local/auth_cleanup_barrier.dart';

class _Storage implements AuthCleanupBarrierStorage {
  final values = <String, String>{};
  bool discardWrites = false;
  bool discardDeletes = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (!discardWrites) values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (!discardDeletes) values.remove(key);
  }
}

void main() {
  late _Storage storage;
  late AccountDeletionCleanupBarrier barrier;
  setUp(() {
    storage = _Storage();
    barrier = AccountDeletionCleanupBarrier(storage);
  });

  test(
    'requested is versioned, non-destructive and persists across instances',
    () async {
      final requested = await barrier.request(' A ');
      expect(requested.userId, 'A');
      expect(requested.phase, AccountDeletionPhase.requested);
      expect(
        await AccountDeletionCleanupBarrier(storage).readForUser('A'),
        requested,
      );
      expect(
        jsonDecode(
          storage.values[AccountDeletionCleanupBarrier.storageKey]!,
        )['v'],
        2,
      );
      expect(await barrier.request('A'), requested);
    },
  );
  test('confirmation is CAS and replaces the immutable revision', () async {
    final requested = await barrier.request('A');
    final confirmed = await barrier.confirmIfCurrent(requested);
    expect(confirmed.phase, AccountDeletionPhase.remoteConfirmed);
    expect(confirmed.revision, isNot(requested.revision));
    expect(await barrier.clearIfCurrent(requested), isFalse);
    expect(await barrier.readForUser('A'), confirmed);
  });
  test('stale requested cannot confirm or clear a newer attempt', () async {
    final old = await barrier.request('A');
    expect(await barrier.clearIfCurrent(old), isTrue);
    final fresh = await barrier.request('A');
    await expectLater(barrier.confirmIfCurrent(old), throwsStateError);
    expect(await barrier.clearIfCurrent(old), isFalse);
    expect(await barrier.readForUser('A'), fresh);
  });
  test('stale confirmed cannot clear a newer owner marker', () async {
    final old = await barrier.confirmIfCurrent(await barrier.request('A'));
    await barrier.clearIfCurrent(old);
    final fresh = await barrier.request('B');
    expect(await barrier.clearIfCurrent(old), isFalse);
    expect(await barrier.readForUser('B'), fresh);
  });
  test('another UID coexists without replacing an unresolved marker', () async {
    final marker = await barrier.request('A');
    final other = await barrier.request('B');
    expect(await barrier.readForUser('A'), marker);
    expect(await barrier.readForUser('B'), other);
    expect(await barrier.readAll(), [marker, other]);
  });
  test('unconfirmed writes fail closed', () async {
    storage.discardWrites = true;
    await expectLater(barrier.request('A'), throwsStateError);
  });
  test(
    'confirm and clear affect only their UID and stale CAS preserves both',
    () async {
      final a = await barrier.request('A');
      final b = await barrier.request('B');
      expect(a.revision, isNot(b.revision));
      final confirmedA = await barrier.confirmIfCurrent(a);
      expect(await barrier.readForUser('B'), b);
      final confirmedB = await barrier.confirmIfCurrent(b);
      expect(await barrier.readForUser('A'), confirmedA);
      await expectLater(barrier.confirmIfCurrent(a), throwsStateError);
      expect(await barrier.clearIfCurrent(a), isFalse);
      expect(await barrier.readAll(), [confirmedA, confirmedB]);
      expect(await barrier.clearIfCurrent(confirmedB), isTrue);
      expect(await barrier.readAll(), [confirmedA]);
      final freshB = await barrier.request('B');
      expect(await barrier.clearIfCurrent(confirmedA), isTrue);
      expect(await barrier.readForUser('B'), freshB);
      expect(await barrier.readAll(), [freshB]);
      expect(await barrier.clearIfCurrent(freshB), isTrue);
      expect(await barrier.readAll(), isEmpty);
      expect(
        storage.values.containsKey(AccountDeletionCleanupBarrier.storageKey),
        isFalse,
      );
    },
  );

  test(
    'concurrent mutations across instances retain independent markers',
    () async {
      final other = AccountDeletionCleanupBarrier(storage);
      final markers = await Future.wait([
        barrier.request('A'),
        other.request('B'),
      ]);
      expect(await barrier.readAll(), markers);
      final confirmed = await Future.wait([
        barrier.confirmIfCurrent(markers[0]),
        other.confirmIfCurrent(markers[1]),
      ]);
      expect(await barrier.readAll(), confirmed);
      expect(
        await Future.wait([
          barrier.clearIfCurrent(confirmed[0]),
          other.clearIfCurrent(confirmed[1]),
        ]),
        [true, true],
      );
      expect(await barrier.readAll(), isEmpty);
    },
  );

  test(
    'unconfirmed multi-marker writes and clears retain every owner',
    () async {
      final a = await barrier.request('A');
      final b = await barrier.request('B');
      storage.discardWrites = true;
      await expectLater(barrier.confirmIfCurrent(a), throwsStateError);
      await expectLater(barrier.clearIfCurrent(b), throwsStateError);
      expect(await barrier.readAll(), [a, b]);
    },
  );

  test(
    'UID arguments are normalized but empty UIDs cannot mutate markers',
    () async {
      final a = await barrier.request(' A ');
      expect(await barrier.readForUser(' A '), a);
      expect(await barrier.readForUser('B'), isNull);
      await expectLater(barrier.request('   '), throwsArgumentError);
      await expectLater(barrier.readForUser(''), throwsArgumentError);
      expect(await barrier.readAll(), [a]);
    },
  );

  for (final phase in AccountDeletionPhase.values) {
    test(
      'valid v1 ${phase.name} is readable and preserved during v2 mutation',
      () async {
        final legacy = jsonEncode({
          'v': 1,
          'uid': 'A',
          'phase': phase.name,
          'revision': 'a' * 22,
        });
        storage.values[AccountDeletionCleanupBarrier.storageKey] = legacy;
        final a = (await barrier.readForUser('A'))!;
        expect(a.phase, phase);
        expect(await barrier.readAll(), [a]);
        expect(
          storage.values[AccountDeletionCleanupBarrier.storageKey],
          legacy,
        );
        final b = await barrier.request('B');
        expect(await barrier.readAll(), [a, b]);
        expect(
          jsonDecode(
            storage.values[AccountDeletionCleanupBarrier.storageKey]!,
          )['v'],
          2,
        );
        expect(await barrier.clearIfCurrent(b), isTrue);
        expect(await barrier.readForUser('A'), a);
      },
    );
  }

  test(
    'v1 requested confirmation migrates without losing the marker',
    () async {
      storage.values[AccountDeletionCleanupBarrier.storageKey] = jsonEncode({
        'v': 1,
        'uid': 'A',
        'phase': 'requested',
        'revision': 'a' * 22,
      });
      final requested = (await barrier.readForUser('A'))!;
      final confirmed = await barrier.confirmIfCurrent(requested);
      expect(confirmed.phase, AccountDeletionPhase.remoteConfirmed);
      expect(await barrier.readAll(), [confirmed]);
      expect(
        jsonDecode(
          storage.values[AccountDeletionCleanupBarrier.storageKey]!,
        )['v'],
        2,
      );
    },
  );

  test(
    'duplicate UID entries fail closed without replacing the document',
    () async {
      final marker = {'uid': 'A', 'phase': 'requested', 'revision': 'a' * 22};
      final document = jsonEncode({
        'v': 2,
        'markers': [marker, marker],
      });
      storage.values[AccountDeletionCleanupBarrier.storageKey] = document;
      await expectLater(barrier.readAll(), throwsFormatException);
      await expectLater(barrier.readForUser('B'), throwsFormatException);
      await expectLater(barrier.request('B'), throwsFormatException);
      expect(
        storage.values[AccountDeletionCleanupBarrier.storageKey],
        document,
      );
    },
  );

  final validEntry = {'uid': 'A', 'phase': 'requested', 'revision': 'a' * 22};
  final invalidDocuments = <String, Object?>{
    'missing markers': {'v': 2},
    'null markers': {'v': 2, 'markers': null},
    'non-list markers': {'v': 2, 'markers': {}},
    'null entry': {
      'v': 2,
      'markers': [null],
    },
    'extra root field': {
      'v': 2,
      'markers': [validEntry],
      'extra': true,
    },
    'extra entry field': {
      'v': 2,
      'markers': [
        {...validEntry, 'extra': true},
      ],
    },
    'empty UID': {
      'v': 2,
      'markers': [
        {...validEntry, 'uid': ''},
      ],
    },
    'non-normalized UID': {
      'v': 2,
      'markers': [
        {...validEntry, 'uid': ' A '},
      ],
    },
    'invalid phase': {
      'v': 2,
      'markers': [
        {...validEntry, 'phase': 'deleted'},
      ],
    },
    'invalid revision': {
      'v': 2,
      'markers': [
        {...validEntry, 'revision': null},
      ],
    },
    'unknown version': {
      'v': 3,
      'markers': [validEntry],
    },
  };
  for (final entry in invalidDocuments.entries) {
    test('malformed multi-marker ${entry.key} fails closed', () async {
      final document = jsonEncode(entry.value);
      storage.values[AccountDeletionCleanupBarrier.storageKey] = document;
      await expectLater(barrier.readAll(), throwsFormatException);
      await expectLater(barrier.request('B'), throwsFormatException);
      expect(
        storage.values[AccountDeletionCleanupBarrier.storageKey],
        document,
      );
    });
  }
  test(
    'failed promotion retains requested and cannot authorize destroy',
    () async {
      final requested = await barrier.request('A');
      storage.discardWrites = true;
      await expectLater(barrier.confirmIfCurrent(requested), throwsStateError);
      expect(await barrier.readForUser('A'), requested);
    },
  );
  test('unconfirmed clear retains the remoteConfirmed marker', () async {
    final marker = await barrier.confirmIfCurrent(await barrier.request('A'));
    storage.discardDeletes = true;
    await expectLater(barrier.clearIfCurrent(marker), throwsStateError);
    expect(await barrier.readForUser('A'), marker);
  });
  test(
    'invalid version or fields fail closed rather than hiding the marker',
    () async {
      storage.values[AccountDeletionCleanupBarrier.storageKey] = jsonEncode({
        'v': 9,
        'uid': 'A',
        'phase': 'requested',
        'revision': 'x' * 22,
      });
      await expectLater(barrier.readForUser('A'), throwsFormatException);
      storage.values[AccountDeletionCleanupBarrier.storageKey] = '{';
      await expectLater(barrier.readForUser('A'), throwsFormatException);
    },
  );
}

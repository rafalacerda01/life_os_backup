import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/local_profile_admission.dart';
import 'package:sqlite3/sqlite3.dart';

Future<void> _increment(String path) async {
  final directory = Directory(path);
  for (var index = 0; index < 4; index++) {
    await LocalProfileAdmission(directory).run(() async {
      final counter = File('$path/counter.synthetic');
      final value = int.parse(await counter.readAsString());
      await Future<void>.delayed(const Duration(milliseconds: 8));
      await counter.writeAsString('${value + 1}', flush: true);
    });
  }
}

void main() {
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('local-admission-'),
  );
  tearDown(() async => directory.delete(recursive: true));
  File file() => File('${directory.path}/${LocalProfileAdmission.fileName}');

  test(
    'serializes independent admission objects and leaves no payload',
    () async {
      var active = 0;
      var peak = 0;
      await Future.wait(
        List.generate(
          6,
          (_) => LocalProfileAdmission(directory).run(() async {
            active++;
            if (active > peak) peak = active;
            expect(LocalProfileAdmission.isCurrentFile(file().path), true);
            await Future<void>.delayed(const Duration(milliseconds: 10));
            active--;
          }),
        ),
      );
      expect(peak, 1);
      expect(await file().length(), 0);
      expect(LocalProfileAdmission.isCurrentFile(file().path), false);
    },
  );

  test('serializes SQLite connections in separate Dart isolates', () async {
    final path = directory.path;
    await File('$path/counter.synthetic').writeAsString('0');
    await Future.wait(
      List.generate(4, (_) => Isolate.run(() => _increment(path))),
    );
    expect(await File('$path/counter.synthetic').readAsString(), '16');
    expect(await file().length(), 0);
  });

  test('release after domain failure allows another acquisition', () async {
    await expectLater(
      LocalProfileAdmission(directory).run(() async {
        throw StateError('synthetic-failure');
      }),
      throwsStateError,
    );
    expect(await LocalProfileAdmission(directory).run(() async => 7), 7);
  });

  test(
    'nested sequential admission reuses lease but escaped zone expires',
    () async {
      late Future<bool> Function() escaped;
      await LocalProfileAdmission(directory).run(() async {
        expect(await LocalProfileAdmission(directory).run(() async => 1), 1);
        final zone = Zone.current;
        escaped = () => zone.run(
          () async => LocalProfileAdmission.isCurrentFile(file().path),
        );
      });
      expect(await escaped(), false);
    },
  );

  test('bounded contention fails closed then recovers after release', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = LocalProfileAdmission(directory).run(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    try {
      await expectLater(
        LocalProfileAdmission(
          directory,
          timeout: const Duration(milliseconds: 50),
        ).run(() async => 1),
        throwsA(
          predicate(
            (Object? e) =>
                e.toString().contains('LOCAL_PROFILE_ADMISSION_BUSY'),
          ),
        ),
      );
    } finally {
      release.complete();
      await first;
    }
    expect(await LocalProfileAdmission(directory).run(() async => 2), 2);
  });

  test(
    'nonempty SQLite coordination file is refused without modification',
    () async {
      final db = sqlite3.open(file().path);
      db.execute('CREATE TABLE sentinel (payload TEXT)');
      db.execute("INSERT INTO sentinel VALUES ('synthetic-preserve')");
      db.dispose();
      final before = await file().readAsBytes();
      await expectLater(
        LocalProfileAdmission(directory).run(() async => 1),
        throwsStateError,
      );
      expect(await file().readAsBytes(), before);
    },
  );

  test('orphan coordination sidecar is preserved and refused', () async {
    final sidecar = File('${file().path}-wal');
    await sidecar.writeAsString('synthetic-wal');
    await expectLater(
      LocalProfileAdmission(directory).run(() async => 1),
      throwsStateError,
    );
    expect(await sidecar.readAsString(), 'synthetic-wal');
    expect(await file().exists(), false);
  });
}

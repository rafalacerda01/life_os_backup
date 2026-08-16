import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:life_os/core/database/app_database.dart';
import 'dart:convert';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
  });

  tearDown(() async {
    await db.closeDatabase();
  });

  test(
    'transactionWithSync salva dado local e operação na fila atomicamente',
    () async {
      const habitId = 'habit-test-1';
      const title = 'Hábito de teste';
      final dates = <String>[];

      await db.transactionWithSync(
        localOperation: () async {
          await db
              .into(db.habits)
              .insert(
                HabitsCompanion.insert(
                  id: habitId,
                  title: title,
                  completedDates: jsonEncode(dates),
                ),
              );
        },
        collection: 'habits',
        docId: habitId,
        operationType: 'create',
        payloadJson: jsonEncode({'title': title, 'completedDates': dates}),
      );

      final habit = await (db.select(
        db.habits,
      )..where((table) => table.id.equals(habitId))).getSingle();

      expect(habit.id, habitId);
      expect(habit.title, title);
      expect(habit.completedDates, '[]');

      final pending = await db.getPendingSyncItems();

      expect(pending.length, 1);
      expect(pending.single.collection, 'habits');
      expect(pending.single.docId, habitId);
      expect(pending.single.operationType, 'create');
      expect(jsonDecode(pending.single.payloadJson), {
        'title': title,
        'completedDates': dates,
      });
      expect(pending.single.isSynced, false);
    },
  );

  test('falha na operação local não cria item na SyncQueue', () async {
    const habitId = 'habit-test-2';

    expect(
      () => db.transactionWithSync(
        localOperation: () async {
          throw StateError('Falha simulada');
        },
        collection: 'habits',
        docId: habitId,
        operationType: 'create',
        payloadJson: '{"title":"Falha"}',
      ),
      throwsA(isA<StateError>()),
    );

    final pending = await db.getPendingSyncItems();

    expect(pending, isEmpty);
  });
}

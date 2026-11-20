import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/features/notifications/data/repositories/local_notification_inbox.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  final identity = LocalDatabaseIdentity(
    'local-v1-123e4567-e89b-42d3-a456-426614174000',
  );

  test('refuses databases with remote sync policy', () {
    final db = AppDatabase.forUser(
      identity: LocalDatabaseIdentity('synthetic-uid'),
      executor: NativeDatabase.memory(),
    );
    addTearDown(db.close);
    expect(() => LocalNotificationInbox(db), throwsArgumentError);
  });

  test(
    'derives local occurrences and preserves a historical queue across reopen',
    () async {
      final root = await Directory.systemTemp.createTemp('lifeos-local-inbox-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/synthetic.sqlite');
      final today = DateTime(2026, 11, 19);
      final tomorrow = DateTime(2026, 11, 20);
      AppDatabase open() => AppDatabase.forUser(
        identity: identity,
        executor: NativeDatabase(file),
        syncPolicy: DatabaseSyncPolicy.localOnly,
      );

      final seed = open();
      await seed
          .into(seed.subjects)
          .insert(
            SubjectsCompanion.insert(
              id: 'inbox-exam',
              title: 'Prova sintética',
              cardsToReview: 0,
              streakDays: 0,
              progress: 0,
              hasExam: true,
              examDate: Value(today.millisecondsSinceEpoch),
            ),
          );
      await seed
          .into(seed.habits)
          .insert(
            HabitsCompanion.insert(
              id: 'inbox-habit',
              title: 'Hábito sintético',
              completedDates: '[]',
            ),
          );
      await seed
          .into(seed.medications)
          .insert(
            MedicationsCompanion.insert(
              firestoreId: 'inbox-treatment',
              name: 'Tratamento sintético',
              startDate: today,
              endDate: Value(tomorrow),
            ),
          );
      await seed.close();

      // Model a historical row predating the per-connection SQL guards.
      final fixture = sqlite.sqlite3.open(file.path);
      try {
        fixture.execute(
          'INSERT INTO sync_queue_table (owner_uid, collection, doc_id, operation_type, payload_json, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?)',
          ['synthetic-uid', 'tasks', 'historical', 'create', '{}', 123],
        );
      } finally {
        fixture.dispose();
      }

      final db = open();
      late final SyncQueueTableData originalQueueRow;
      try {
        final inbox = LocalNotificationInbox(db);
        originalQueueRow = (await db.select(db.syncQueueTable).get()).single;
        await Future.wait([
          inbox.reconcile(today: today),
          inbox.reconcile(today: today),
        ]);
        final cards = await inbox.watch().first;
        expect(
          cards.map((row) => row.id),
          unorderedEquals([
            'exam_inbox-exam',
            'habit_inbox-habit',
            'health_med_inbox-treatment',
          ]),
        );
        final habit = cards.singleWhere((row) => row.moduleType == 'habits');
        final exam = cards.singleWhere((row) => row.moduleType == 'studies');
        final medication = cards.singleWhere(
          (row) => row.moduleType == 'health',
        );
        await inbox.markAsRead(exam);
        await inbox.markAsCompleted(medication);
        await inbox.dismiss(habit);
        await inbox.reconcile(today: today);
        final after = await inbox.getLocalNotifications();
        expect(after.singleWhere((row) => row.id == exam.id).isRead, isTrue);
        expect(
          after.singleWhere((row) => row.id == medication.id).isCompleted,
          isTrue,
        );
        expect(after.map((row) => row.id), isNot(contains(habit.id)));
        expect(
          (await db.select(db.syncQueueTable).get()).single,
          originalQueueRow,
        );
      } finally {
        await db.close();
      }

      final reopened = open();
      addTearDown(reopened.close);
      final inbox = LocalNotificationInbox(reopened);
      await inbox.reconcile(today: tomorrow);
      final cards = await inbox.getLocalNotifications();
      final newHabit = cards.singleWhere((row) => row.moduleType == 'habits');
      expect(newHabit.dueDate, tomorrow);
      expect(newHabit.isCompleted, isFalse);
      expect(cards.where((row) => row.moduleType == 'studies'), isEmpty);
      expect(
        cards.singleWhere((row) => row.moduleType == 'health').isCompleted,
        isTrue,
      );
      await expectLater(
        inbox.dismiss(newHabit.copyWith(dueDate: today)),
        throwsStateError,
      );
      expect(
        (await inbox.getLocalNotifications()).map((row) => row.id),
        contains(newHabit.id),
      );
      expect(
        (await reopened.select(reopened.notificationDismissals).get())
            .single
            .notificationId,
        newHabit.id,
      );
      expect(
        (await reopened.select(reopened.syncQueueTable).get()).single,
        originalQueueRow,
      );
    },
  );
}

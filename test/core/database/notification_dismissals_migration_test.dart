import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

void main() {
  test(
    'upgrade 8 to 9 preserves notifications, entities and owner queue',
    () async {
      final directory = Directory.systemTemp.createTempSync('notification_v8_');
      final file = File('${directory.path}/existing.sqlite');
      addTearDown(() => directory.deleteSync(recursive: true));
      var db = AppDatabase(executor: NativeDatabase(file));
      await db
          .into(db.habits)
          .insert(
            HabitsCompanion.insert(
              id: 'existing',
              title: 'Offline habit',
              completedDates: '[]',
            ),
          );
      await db
          .into(db.notificationsTable)
          .insert(
            NotificationsTableCompanion.insert(
              id: 'habit_existing',
              title: 'Fixture',
              description: 'Fixture',
              priority: 'today',
              moduleType: 'habits',
              route: '/',
              createdAt: DateTime(2026, 10, 5),
            ),
          );
      await db.insertSyncItem(
        ownerUid: 'user-a',
        collection: 'habits',
        docId: 'existing',
        operationType: 'create',
        payloadJson: '{"title":"Offline habit"}',
      );
      final habit = await db.select(db.habits).getSingle();
      final notification = await db.select(db.notificationsTable).getSingle();
      final pending = await db.select(db.syncQueueTable).getSingle();
      await db.close();
      // Exact v8 schema: v9 adds the dismissal table and local occurrence key.
      final raw = sqlite3.sqlite3.open(file.path);
      raw.execute('DROP TABLE notification_dismissals');
      raw.execute('ALTER TABLE notifications_table DROP COLUMN occurrence_key');
      raw.execute('PRAGMA user_version = 8');
      raw.dispose();
      db = AppDatabase(executor: NativeDatabase(file));
      addTearDown(db.close);
      expect(await db.select(db.habits).getSingle(), habit);
      expect(await db.select(db.notificationsTable).getSingle(), notification);
      expect(await db.select(db.syncQueueTable).getSingle(), pending);
      expect(await db.select(db.notificationDismissals).get(), isEmpty);
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        9,
      );
      expect(db.allTables, hasLength(14));
    },
  );
}

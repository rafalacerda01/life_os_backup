import 'package:drift/drift.dart';

/// Account-scoped user intent, independent of SyncQueue delivery retention.
class NotificationDismissals extends Table {
  TextColumn get notificationId => text()();
  TextColumn get occurrenceKey => text()();
  DateTimeColumn get dismissedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {notificationId, occurrenceKey};
}

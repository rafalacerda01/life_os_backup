import 'dart:convert';

import 'package:life_os/core/database/app_database.dart';

/// Pre-launch isolation, never a conversion or an acknowledgement of V1 water.
abstract final class LegacyWaterQueue {
  static Map<dynamic, dynamic>? _payload(SyncQueueTableData item) {
    if (item.collection.trim() != 'health_info') return null;
    try {
      final decoded = jsonDecode(item.payloadJson);
      return decoded is Map ? decoded : null;
    } on FormatException {
      return null; // Invalid JSON still follows the existing validation path.
    }
  }

  static bool isBlocked(SyncQueueTableData item) =>
      item.collection.trim() == 'health_info' &&
      (item.operationType.trim().toLowerCase() == 'delete' ||
          (_payload(item)?.containsKey('waterIntakeMl') ?? false));

  /// A pure water outbox entry must not block hydration of unrelated fields.
  /// Mixed/unknown payloads retain the existing conservative pull protection.
  static bool isWaterOnly(SyncQueueTableData item) {
    final payload = _payload(item);
    return payload != null &&
        payload.containsKey('waterIntakeMl') &&
        payload.keys.every((key) => key == 'waterIntakeMl' || key == 'date');
  }
}

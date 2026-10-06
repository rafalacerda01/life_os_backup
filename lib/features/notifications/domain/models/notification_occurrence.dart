import 'dart:convert';

/// Identity of the three current Central producers, independent of display text.
abstract final class NotificationOccurrence {
  static String? key({
    required String id,
    required String moduleType,
    required DateTime? dueDate,
  }) {
    if (dueDate == null) return null;
    if (!((moduleType == 'habits' && id.startsWith('habit_')) ||
        (moduleType == 'studies' && id.startsWith('exam_')) ||
        (moduleType == 'health' && id.startsWith('health_med_')))) {
      // Future/legacy types need an explicit occurrence contract before dismiss.
      return null;
    }
    return jsonEncode([1, id, moduleType, dueDate.microsecondsSinceEpoch]);
  }

  static DateTime? preciseDueDate(String? key, String id) {
    if (!isKeyForId(key, id)) return null;
    final parts = jsonDecode(key!) as List;
    return parts[3] is int
        ? DateTime.fromMicrosecondsSinceEpoch(parts[3] as int)
        : null;
  }

  static bool isKeyForId(Object? value, String id) {
    if (value is! String) return false;
    try {
      final parts = jsonDecode(value);
      if (parts is! List ||
          parts.length != 4 ||
          parts[0] != 1 ||
          parts[1] != id) {
        return false;
      }
      return parts[3] is int &&
          ((parts[2] == 'habits' && id.startsWith('habit_')) ||
              (parts[2] == 'studies' && id.startsWith('exam_')) ||
              (parts[2] == 'health' && id.startsWith('health_med_')));
    } on FormatException {
      return false;
    }
  }
}

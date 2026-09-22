enum AIInsightIntent {
  dailyOverview('daily_overview'),
  weeklyOverview('weekly_overview'),
  financeMonthSummary('finance_month_summary');

  const AIInsightIntent(this.wireValue);

  final String wireValue;

  static AIInsightIntent? fromWireValue(String? value) {
    for (final intent in values) {
      if (intent.wireValue == value) return intent;
    }
    return null;
  }
}

class AIInsight {
  const AIInsight({
    required this.headline,
    required this.summary,
    required this.recommendation,
  });

  final String headline;
  final String summary;
  final String recommendation;

  static AIInsight? fromResponse(
    Object? response,
    AIInsightIntent expectedIntent,
  ) {
    if (response is! Map<String, dynamic> ||
        response.length != 3 ||
        !response.keys.toSet().containsAll({'version', 'intent', 'insight'}) ||
        response['version'] != 2 ||
        response['intent'] != expectedIntent.wireValue) {
      return null;
    }

    final value = response['insight'];
    if (value is! Map<String, dynamic> ||
        value.length != 3 ||
        !value.keys.toSet().containsAll({
          'headline',
          'summary',
          'recommendation',
        })) {
      return null;
    }

    String? checked(String field, int maximum) {
      final raw = value[field];
      if (raw is! String) return null;
      final text = raw.trim();
      return text.isNotEmpty && text.length <= maximum ? text : null;
    }

    final headline = checked('headline', 120);
    final summary = checked('summary', 800);
    final recommendation = checked('recommendation', 500);
    if (headline == null || summary == null || recommendation == null) {
      return null;
    }
    return AIInsight(
      headline: headline,
      summary: summary,
      recommendation: recommendation,
    );
  }
}

class AICompanionLocalSummary {
  const AICompanionLocalSummary({
    required this.pendingTasks,
    required this.completedHabitsToday,
    required this.activeHabits,
    required this.focusMinutesToday,
    required this.energy,
  });

  final int pendingTasks;
  final int completedHabitsToday;
  final int activeHabits;
  final int focusMinutesToday;
  final double? energy;
}

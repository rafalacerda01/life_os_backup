import 'package:flutter/material.dart';

enum InsightPriority {
  low(0),
  medium(1),
  high(2),
  critical(3);

  final int value;
  const InsightPriority(this.value);
}

enum InsightCategory {
  health(Icons.favorite_rounded, [Color(0xFFFF5252), Color(0xFFD32F2F)]),
  productivity(Icons.rocket_launch_rounded, [
    Color(0xFFBA68C8),
    Color(0xFF7B1FA2),
  ]),
  finance(Icons.account_balance_wallet_rounded, [
    Color(0xFF64B5F6),
    Color(0xFF1976D2),
  ]),
  study(Icons.school_rounded, [Color(0xFFFFB74D), Color(0xFFF57C00)]),
  balance(Icons.self_improvement_rounded, [
    Color(0xFF4DB6AC),
    Color(0xFF00796B),
  ]),
  warning(Icons.warning_amber_rounded, [Color(0xFFFFD54F), Color(0xFFF57F17)]);

  final IconData icon;
  final List<Color> gradientColors;
  const InsightCategory(this.icon, this.gradientColors);
}

class InsightModel {
  final String id;
  final String title;
  final String message;
  final InsightCategory category;
  final InsightPriority priority;

  const InsightModel({
    required this.id,
    required this.title,
    required this.message,
    required this.category,
    required this.priority,
  });
}

/// Agrupa os dados necessários para o motor tomar decisões.
class InsightContext {
  final double productivityScore;
  final double healthScore;
  final double financialScore;
  final int studyStreak;
  final DateTime currentTime;
  final bool isPremium;
  // Adicione outras métricas aqui futuramente (ex: horas de sono, tarefas atrasadas)

  const InsightContext({
    required this.productivityScore,
    required this.healthScore,
    required this.financialScore,
    required this.studyStreak,
    required this.currentTime,
    this.isPremium = false,
  });
}

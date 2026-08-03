import 'dart:math';
import 'package:flutter/material.dart';
// Importa o model que está na mesma pasta
import 'package:life_os/features/dashboard/domain/entities/models/insight_model.dart';

/// Interface Strategy para cada regra de insight
abstract class InsightRule {
  String get id;

  /// Avalia a relevância da regra no momento. Retorna 0.0 (ignorar) a 1.0 (máxima relevância).
  double evaluate(InsightContext context);

  /// Gera o Insight se a regra for a vencedora
  InsightModel generate(InsightContext context);
}

// ============================================================================
// REGRAS DE NEGÓCIO (Sólidas, Contextuais e Humanizadas)
// ============================================================================

class CriticalHealthRule implements InsightRule {
  @override
  String get id => 'critical_health_warning';

  @override
  double evaluate(InsightContext context) {
    if (context.healthScore < 30) return 1.0; // Urgência máxima
    if (context.healthScore < 50) return 0.7;
    return 0.0;
  }

  @override
  InsightModel generate(InsightContext context) {
    final messages = [
      "Sua bateria física está no limite. Faça uma pausa agora, beba água e respire. O trabalho pode esperar.",
      "Seu corpo está pedindo socorro. Que tal reduzir o ritmo hoje para não comprometer a semana inteira?",
    ];
    return InsightModel(
      id: id,
      title: "Atenção Plena",
      message: messages[Random().nextInt(messages.length)],
      category: InsightCategory.warning,
      priority: InsightPriority.critical,
    );
  }
}

class MorningMomentumRule implements InsightRule {
  @override
  String get id => 'morning_momentum';

  @override
  double evaluate(InsightContext context) {
    final hour = context.currentTime.hour;
    if (hour >= 5 && hour <= 11) {
      if (context.productivityScore > 80) return 0.9;
      return 0.5;
    }
    return 0.0;
  }

  @override
  InsightModel generate(InsightContext context) {
    return InsightModel(
      id: id,
      title: "Manhã de Ouro",
      message: context.productivityScore > 80
          ? "Você começou o dia voando! Aproveite esse estado de flow para liquidar a tarefa mais difícil."
          : "Um novo dia, uma nova página em branco. Qual é a sua Única Coisa importante para hoje?",
      category: InsightCategory.productivity,
      priority: InsightPriority.medium,
    );
  }
}

class StudyStreakRule implements InsightRule {
  @override
  String get id => 'study_streak_motivation';

  @override
  double evaluate(InsightContext context) {
    if (context.studyStreak >= 3) {
      return (context.studyStreak * 0.1).clamp(0.0, 0.85);
    }
    return 0.0;
  }

  @override
  InsightModel generate(InsightContext context) {
    return InsightModel(
      id: id,
      title: "Em chamas! 🔥",
      message:
          "${context.studyStreak} dias seguidos de estudo. A consistência é o único atalho verdadeiro para a genialidade.",
      category: InsightCategory.study,
      priority: InsightPriority.high,
    );
  }
}

class BalanceRule implements InsightRule {
  @override
  String get id => 'perfect_balance';

  @override
  double evaluate(InsightContext context) {
    final avg =
        (context.productivityScore +
            context.healthScore +
            context.financialScore) /
        3;
    final variance =
        ((context.productivityScore - avg).abs() +
            (context.healthScore - avg).abs() +
            (context.financialScore - avg).abs()) /
        3;

    if (avg > 75 && variance < 15) return 0.8;
    return 0.0;
  }

  @override
  InsightModel generate(InsightContext context) {
    return InsightModel(
      id: id,
      title: "Harmonia Total",
      message:
          "Saúde, Finanças e Produtividade em sintonia perfeita. Você não está apenas sobrevivendo, está dominando.",
      category: InsightCategory.balance,
      priority: InsightPriority.low,
    );
  }
}

// ============================================================================
// O MOTOR DE PROCESSAMENTO (O Cérebro)
// ============================================================================

class InsightEngine {
  final List<InsightRule> _rules = [
    CriticalHealthRule(),
    MorningMomentumRule(),
    StudyStreakRule(),
    BalanceRule(),
  ];

  String? _lastInsightId;

  InsightModel getBestInsight(InsightContext context) {
    InsightRule? bestRule;
    double bestScore = -1.0;
    InsightPriority highestPriority = InsightPriority.low;

    for (var rule in _rules) {
      final isRecent = rule.id == _lastInsightId;
      double score = rule.evaluate(context);

      if (isRecent) {
        score *= 0.1;
      }

      if (score > 0.0) {
        final tempInsight = rule.generate(context);

        if (tempInsight.priority.value > highestPriority.value ||
            (tempInsight.priority.value == highestPriority.value &&
                score > bestScore)) {
          bestScore = score;
          highestPriority = tempInsight.priority;
          bestRule = rule;
        }
      }
    }

    if (bestRule == null) {
      return const InsightModel(
        id: 'fallback',
        title: "Tudo em Ordem",
        message:
            "Continue mantendo seus registros diários. Aos poucos os padrões da sua vida se revelarão.",
        category: InsightCategory.productivity,
        priority: InsightPriority.low,
      );
    }

    _lastInsightId = bestRule.id;
    return bestRule.generate(context);
  }
}

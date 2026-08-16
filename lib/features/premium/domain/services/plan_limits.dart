import '../entities/premium_status_entity.dart';

enum QuotaResource {
  habits,
  subjects,
  circles,
  medications,
  goals,
  tasks,
  transactions,
  aiRequests,
}

enum QuotaMode { disabled, limited, unlimited, notConfigured }

class QuotaLimit {
  final QuotaMode mode;
  final int? maximum;

  const QuotaLimit.disabled() : mode = QuotaMode.disabled, maximum = 0;

  const QuotaLimit.limited(this.maximum) : mode = QuotaMode.limited;

  const QuotaLimit.unlimited() : mode = QuotaMode.unlimited, maximum = null;

  const QuotaLimit.notConfigured()
    : mode = QuotaMode.notConfigured,
      maximum = null;
}

class PlanLimits {
  final QuotaLimit habits;
  final QuotaLimit subjects;
  final QuotaLimit circles;
  final QuotaLimit medications;
  final QuotaLimit goals;
  final QuotaLimit tasks;
  final QuotaLimit transactions;
  final QuotaLimit aiRequests;
  final bool analyticsAdvanced;

  const PlanLimits({
    required this.habits,
    required this.subjects,
    required this.circles,
    required this.medications,
    required this.goals,
    required this.tasks,
    required this.transactions,
    required this.aiRequests,
    required this.analyticsAdvanced,
  });

  static const free = PlanLimits(
    habits: QuotaLimit.limited(3),
    subjects: QuotaLimit.limited(3),
    circles: QuotaLimit.limited(3),
    medications: QuotaLimit.limited(3),
    goals: QuotaLimit.limited(3),
    tasks: QuotaLimit.limited(3),
    transactions: QuotaLimit.limited(3),
    aiRequests: QuotaLimit.disabled(),
    analyticsAdvanced: false,
  );

  static const premium = PlanLimits(
    habits: QuotaLimit.limited(30),
    subjects: QuotaLimit.limited(30),
    circles: QuotaLimit.limited(30),
    medications: QuotaLimit.limited(30),
    goals: QuotaLimit.limited(30),
    tasks: QuotaLimit.unlimited(),
    transactions: QuotaLimit.unlimited(),

    // Valor comercial ainda não definido.
    // Explicitamente NÃO significa ilimitado.
    aiRequests: QuotaLimit.notConfigured(),

    analyticsAdvanced: true,
  );

  static PlanLimits fromTier(PremiumTier tier) {
    switch (tier) {
      case PremiumTier.free:
        return PlanLimits.free;
      case PremiumTier.monthly:
      case PremiumTier.annual:
        return PlanLimits.premium;
    }
  }

  QuotaLimit limitFor(QuotaResource resource) {
    switch (resource) {
      case QuotaResource.habits:
        return habits;
      case QuotaResource.subjects:
        return subjects;
      case QuotaResource.circles:
        return circles;
      case QuotaResource.medications:
        return medications;
      case QuotaResource.goals:
        return goals;
      case QuotaResource.tasks:
        return tasks;
      case QuotaResource.transactions:
        return transactions;
      case QuotaResource.aiRequests:
        return aiRequests;
    }
  }
}

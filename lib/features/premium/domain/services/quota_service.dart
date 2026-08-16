import 'plan_limits.dart';

class QuotaService {
  const QuotaService();

  bool canCreate({required QuotaLimit limit, required int currentCount}) {
    if (currentCount < 0) {
      return false;
    }

    switch (limit.mode) {
      case QuotaMode.disabled:
        return false;

      case QuotaMode.limited:
        final maximum = limit.maximum;

        if (maximum == null || maximum < 0) {
          return false;
        }

        return currentCount < maximum;

      case QuotaMode.unlimited:
        return true;

      case QuotaMode.notConfigured:
        return false;
    }
  }

  int? remaining({required QuotaLimit limit, required int currentCount}) {
    if (currentCount < 0) {
      return 0;
    }

    switch (limit.mode) {
      case QuotaMode.disabled:
        return 0;

      case QuotaMode.limited:
        final maximum = limit.maximum;

        if (maximum == null || maximum < 0) {
          return 0;
        }

        return (maximum - currentCount).clamp(0, maximum);

      case QuotaMode.unlimited:
        return null;

      case QuotaMode.notConfigured:
        return 0;
    }
  }
}

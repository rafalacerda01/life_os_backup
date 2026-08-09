import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Modelo principal das informações de saúde do usuário.
///
/// O modelo é utilizado tanto para dados locais (Drift) quanto para
/// dados provenientes do Firebase/Firestore.
class HealthModel {
  final String mood;
  final int waterIntakeMl;
  final bool hasTakenPillToday;
  final Map<String, dynamic>? menstrualCycle;
  final DateTime date;

  const HealthModel({
    required this.mood,
    required this.waterIntakeMl,
    required this.hasTakenPillToday,
    this.menstrualCycle,
    required this.date,
  });

  // ===========================================================================
  // FACTORIES
  // ===========================================================================

  /// Cria um HealthModel a partir de dados genéricos.
  ///
  /// Aceita datas nos formatos:
  /// - Timestamp
  /// - DateTime
  /// - String ISO-8601
  ///
  /// Também protege contra tipos inválidos vindos de dados externos.
  factory HealthModel.fromMap(Map<String, dynamic> map) {
    return HealthModel(
      mood: _parseMood(map['mood']),
      waterIntakeMl: _parseWaterIntake(map['waterIntakeMl']),
      hasTakenPillToday: map['hasTakenPillToday'] == true,
      menstrualCycle: _parseMenstrualCycle(map['menstrualCycle']),
      date: _parseDate(map['date']),
    );
  }

  /// Estado inicial seguro do módulo de saúde.
  factory HealthModel.initial() {
    return HealthModel(
      mood: '—',
      waterIntakeMl: 0,
      hasTakenPillToday: false,
      menstrualCycle: null,
      date: DateTime.now(),
    );
  }

  // ===========================================================================
  // SERIALIZATION
  // ===========================================================================

  /// Converte o modelo para um mapa compatível com Firestore.
  Map<String, dynamic> toMap() {
    return {
      'mood': mood,
      'waterIntakeMl': waterIntakeMl,
      'hasTakenPillToday': hasTakenPillToday,
      'menstrualCycle': menstrualCycle,
      'date': Timestamp.fromDate(date),
    };
  }

  // ===========================================================================
  // PARSERS
  // ===========================================================================

  static String _parseMood(dynamic value) {
    if (value == null) {
      return '—';
    }

    final mood = value.toString().trim();

    return mood.isEmpty ? '—' : mood;
  }

  static int _parseWaterIntake(dynamic value) {
    if (value is num) {
      return value.toInt().clamp(0, 1000000);
    }

    final parsed = int.tryParse(value?.toString() ?? '');

    return (parsed ?? 0).clamp(0, 1000000);
  }

  static bool _isSupportedMapValue(dynamic value) {
    return value is String ||
        value is num ||
        value is bool ||
        value is DateTime ||
        value is Timestamp ||
        value == null;
  }

  static Map<String, dynamic>? _parseMenstrualCycle(dynamic value) {
    if (value is! Map) {
      return null;
    }

    final result = <String, dynamic>{};

    for (final entry in value.entries) {
      if (entry.key is! String) {
        continue;
      }

      if (_isSupportedMapValue(entry.value)) {
        result[entry.key as String] = entry.value;
      }
    }

    if (result.isEmpty) {
      return null;
    }

    return result;
  }

  static DateTime _parseDate(dynamic value) {
    if (value is Timestamp) {
      return value.toDate();
    }

    if (value is DateTime) {
      return value;
    }

    if (value is String) {
      final parsed = DateTime.tryParse(value);

      if (parsed != null) {
        return parsed;
      }
    }

    return DateTime.now();
  }

  // ===========================================================================
  // COPY
  // ===========================================================================

  HealthModel copyWith({
    String? mood,
    int? waterIntakeMl,
    bool? hasTakenPillToday,
    Map<String, dynamic>? menstrualCycle,
    DateTime? date,
    bool clearMenstrualCycle = false,
  }) {
    return HealthModel(
      mood: mood ?? this.mood,
      waterIntakeMl: waterIntakeMl ?? this.waterIntakeMl,
      hasTakenPillToday: hasTakenPillToday ?? this.hasTakenPillToday,
      menstrualCycle: clearMenstrualCycle
          ? null
          : menstrualCycle ?? this.menstrualCycle,
      date: date ?? this.date,
    );
  }
}

// ============================================================================
// HEALTH MODEL LOGIC
// ============================================================================

extension HealthModelLogic on HealthModel {
  /// Retorna informações calculadas sobre a fase atual do ciclo.
  ///
  /// Resultado:
  /// {
  ///   day: int,
  ///   totalDays: int,
  ///   name: String,
  ///   message: String,
  ///   color: Color,
  /// }
  ///
  /// Importante:
  /// Este cálculo é uma estimativa baseada exclusivamente nas configurações
  /// informadas pelo usuário. Não representa diagnóstico ou previsão médica.
  Map<String, dynamic> get cyclePhaseInfo {
    final cycleData = menstrualCycle;

    // -------------------------------------------------------------------------
    // CICLO DESABILITADO / NÃO CONFIGURADO
    // -------------------------------------------------------------------------

    final isEnabled = cycleData?['isEnabled'] == true;

    if (!isEnabled) {
      return {
        'day': 0,
        'totalDays': 0,
        'name': 'Ciclo não configurado',
        'message':
            'Ative e configure o acompanhamento do ciclo para visualizar '
            'uma estimativa das fases.',
        'color': Colors.grey,
      };
    }

    // -------------------------------------------------------------------------
    // CONFIGURAÇÕES
    // -------------------------------------------------------------------------

    final cycleLength = _readInt(
      cycleData?['cycleLengthDays'],
      fallback: 28,
      min: 1,
      max: 120,
    );

    final periodLength = _readInt(
      cycleData?['periodLengthDays'],
      fallback: 5,
      min: 1,
      max: cycleLength,
    );

    final lastPeriodStart = _parseCycleDate(cycleData?['lastPeriodStart']);

    // Se não existe uma data válida, não é seguro calcular a fase.
    if (lastPeriodStart == null) {
      return {
        'day': 0,
        'totalDays': cycleLength,
        'name': 'Ciclo não configurado',
        'message':
            'Informe a data de início da última menstruação para '
            'calcular uma estimativa do ciclo.',
        'color': Colors.grey,
      };
    }

    // -------------------------------------------------------------------------
    // NORMALIZAÇÃO DAS DATAS
    // -------------------------------------------------------------------------

    final now = DateTime.now();

    final today = DateTime(now.year, now.month, now.day);

    final startDay = DateTime(
      lastPeriodStart.year,
      lastPeriodStart.month,
      lastPeriodStart.day,
    );

    // Data futura não deve gerar um dia de ciclo artificial.
    if (startDay.isAfter(today)) {
      return {
        'day': 0,
        'totalDays': cycleLength,
        'name': 'Data inválida',
        'message': 'A data de início do ciclo não pode estar no futuro.',
        'color': Colors.orangeAccent,
      };
    }

    final daysSinceStart = today.difference(startDay).inDays;

    // -------------------------------------------------------------------------
    // DIA ATUAL DO CICLO
    // -------------------------------------------------------------------------

    final currentDayOfCycle = (daysSinceStart % cycleLength) + 1;

    // -------------------------------------------------------------------------
    // ESTIMATIVA DA OVULAÇÃO
    // -------------------------------------------------------------------------

    // Estimativa baseada na duração do ciclo.
    //
    // A ovulação costuma ser estimada aproximadamente 14 dias antes
    // da próxima menstruação.
    //
    // Exemplo:
    // ciclo de 28 dias -> dia 14
    // ciclo de 30 dias -> dia 16
    // ciclo de 25 dias -> dia 11
    //
    // Não representa previsão médica.
    final estimatedOvulationDay = (cycleLength - 14).clamp(1, cycleLength);

    // Janela aproximada de ovulação.
    final ovulationStart = (estimatedOvulationDay - 1).clamp(1, cycleLength);

    final ovulationEnd = (estimatedOvulationDay + 1).clamp(1, cycleLength);

    // -------------------------------------------------------------------------
    // IDENTIFICAÇÃO DA FASE
    // -------------------------------------------------------------------------

    String phaseName;
    String aiMessage;
    Color phaseColor;

    if (currentDayOfCycle <= periodLength) {
      phaseName = 'Fase Menstrual 🩸';

      aiMessage =
          'Período associado à menstruação. '
          'Priorize descanso, hidratação e autocuidado '
          'de acordo com como você está se sentindo.';

      phaseColor = Colors.pinkAccent;
    } else if (currentDayOfCycle >= ovulationStart &&
        currentDayOfCycle <= ovulationEnd) {
      phaseName = 'Fase Ovulatória ✨';

      aiMessage =
          'Período próximo da ovulação estimada. '
          'Algumas pessoas relatam maior disposição nessa fase. '
          'Observe como seu corpo responde e organize sua rotina '
          'de acordo com sua energia.';

      phaseColor = Colors.amberAccent;
    } else if (currentDayOfCycle < estimatedOvulationDay) {
      phaseName = 'Fase Folicular 🌱';

      aiMessage =
          'Fase anterior à ovulação estimada. '
          'Pode ser um bom momento para construir hábitos, '
          'organizar prioridades e avançar gradualmente '
          'nas suas atividades.';

      phaseColor = Colors.cyanAccent;
    } else {
      phaseName = 'Fase Lútea 🌙';

      aiMessage =
          'Fase posterior à ovulação estimada. '
          'Observe seus níveis de energia e considere '
          'uma rotina equilibrada entre produtividade, '
          'descanso e autocuidado.';

      phaseColor = Colors.purpleAccent;
    }

    return {
      'day': currentDayOfCycle,
      'totalDays': cycleLength,
      'name': phaseName,
      'message': aiMessage,
      'color': phaseColor,
      'estimatedOvulationDay': estimatedOvulationDay,
      'periodLengthDays': periodLength,
      'isEnabled': true,
    };
  }

  // ===========================================================================
  // PRIVATE HELPERS
  // ===========================================================================

  static int _readInt(
    dynamic value, {
    required int fallback,
    required int min,
    required int max,
  }) {
    int result;

    if (value is num) {
      result = value.toInt();
    } else {
      result = int.tryParse(value?.toString() ?? '') ?? fallback;
    }

    if (result < min) {
      return min;
    }

    if (result > max) {
      return max;
    }

    return result;
  }

  static DateTime? _parseCycleDate(dynamic value) {
    if (value is Timestamp) {
      return value.toDate();
    }

    if (value is DateTime) {
      return value;
    }

    if (value is String) {
      return DateTime.tryParse(value);
    }

    return null;
  }
}

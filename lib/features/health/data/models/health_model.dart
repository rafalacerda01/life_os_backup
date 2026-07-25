import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class HealthModel {
  final String mood;
  final int waterIntakeMl;
  final bool hasTakenPillToday;
  final Map<String, dynamic>? menstrualCycle; // 🩸 Mapa do Ciclo mantido
  final DateTime date;

  HealthModel({
    required this.mood,
    required this.waterIntakeMl,
    required this.hasTakenPillToday,
    this.menstrualCycle, // Opcional
    required this.date,
  });

  factory HealthModel.fromMap(Map<String, dynamic> map) {
    return HealthModel(
      mood: map['mood'] ?? '—',
      waterIntakeMl: map['waterIntakeMl'] ?? 0,
      hasTakenPillToday: map['hasTakenPillToday'] ?? false,
      menstrualCycle: map['menstrualCycle'] as Map<String, dynamic>?,
      date: map['date'] != null
          ? (map['date'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'mood': mood,
      'waterIntakeMl': waterIntakeMl,
      'hasTakenPillToday': hasTakenPillToday,
      'menstrualCycle': menstrualCycle,
      'date': Timestamp.fromDate(date),
    };
  }

  factory HealthModel.initial() {
    return HealthModel(
      mood: '—',
      waterIntakeMl: 0,
      hasTakenPillToday: false,
      menstrualCycle: null,
      date: DateTime.now(),
    );
  }
}

extension HealthModelLogic on HealthModel {
  Map<String, dynamic> get cyclePhaseInfo {
    final cycleData = menstrualCycle;
    final String lastPeriodStr =
        cycleData?['lastPeriodStart'] ?? DateTime.now().toIso8601String();
    final DateTime lastPeriodStart = DateTime.parse(lastPeriodStr);
    final int cycleLength = cycleData?['cycleLengthDays'] ?? 28;
    final int periodLength = cycleData?['periodLengthDays'] ?? 5;

    final now = DateTime.now();
    final daysSinceStart = now.difference(lastPeriodStart).inDays;
    final int currentDayOfCycle = daysSinceStart >= 0
        ? (daysSinceStart % cycleLength) + 1
        : 1;

    String phaseName = "Fase Folicular 🌱";
    String aiMessage =
        "Suas energias e estrogênio estão subindo. Momento propício para focar no desenvolvimento de novos hábitos e acelerar tarefas.";
    Color phaseColor = Colors.cyanAccent;

    if (currentDayOfCycle <= periodLength) {
      phaseName = "Fase Menstrual 🩸";
      aiMessage =
          "Níveis de energia em calibração. O Core sugere reduzir a carga de tarefas pesadas hoje e priorizar o descanso estruturado. Você está no controle e segura. 🌸";
      phaseColor = Colors.pinkAccent;
    } else if (currentDayOfCycle >= 13 && currentDayOfCycle <= 15) {
      phaseName = "Fase Ovulatória ✨";
      aiMessage =
          "Pico hormonal de alta performance detectado. Seu foco, magnetismo e comunicação estão em 100%. Momento perfeito para executar metas complexas!";
      phaseColor = Colors.amberAccent;
    } else if (currentDayOfCycle > 15) {
      phaseName = "Fase Lútea 🌙";
      aiMessage =
          "Período de desaceleração criativa natural. Ótimo momento para revisar seus estudos, organizar o financeiro e planejar seus próximos rituais com calma.";
      phaseColor = Colors.purpleAccent;
    }

    return {
      'day': currentDayOfCycle,
      'totalDays': cycleLength,
      'name': phaseName,
      'message': aiMessage,
      'color': phaseColor,
    };
  }
}

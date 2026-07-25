import 'package:equatable/equatable.dart';

class HabitEntity extends Equatable {
  final String id;
  final String title;
  final String frequency; // ex: "Diário", "3x por semana"
  final int currentStreak;
  final bool isCompletedToday;
  final String reminderTime;

  const HabitEntity({
    required this.id,
    required this.title,
    required this.frequency,
    required this.currentStreak,
    required this.isCompletedToday,
    required this.reminderTime,
  });

  HabitEntity copyWith({
    String? id,
    String? title,
    String? frequency,
    int? currentStreak,
    bool? isCompletedToday,
    String? reminderTime,
  }) {
    return HabitEntity(
      id: id ?? this.id,
      title: title ?? this.title,
      frequency: frequency ?? this.frequency,
      currentStreak: currentStreak ?? this.currentStreak,
      isCompletedToday: isCompletedToday ?? this.isCompletedToday,
      reminderTime: reminderTime ?? this.reminderTime,
    );
  }

  @override
  List<Object?> get props => [id, title, frequency, currentStreak, isCompletedToday, reminderTime];
}
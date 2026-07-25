import 'package:equatable/equatable.dart';

class UserEntity extends Equatable {
  final String uid;
  final String email;
  final String displayName;
  final bool isPremium;
  final String? photoUrl; // <-- Adicionado aqui
  final int xp;
  final int level;
  final int streak;

  const UserEntity({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.isPremium,
    this.photoUrl, // <-- Adicionado aqui (opcional)
    required this.xp,
    required this.level,
    required this.streak,
  });

  UserEntity copyWith({
    String? uid,
    String? email,
    String? displayName,
    bool? isPremium,
    String? photoUrl, // <-- Adicionado aqui
    int? xp,
    int? level,
    int? streak,
  }) {
    return UserEntity(
      uid: uid ?? this.uid,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      isPremium: isPremium ?? this.isPremium,
      photoUrl: photoUrl ?? this.photoUrl, // <-- Adicionado aqui
      xp: xp ?? this.xp,
      level: level ?? this.level,
      streak: streak ?? this.streak,
    );
  }

  @override
  List<Object?> get props => [
    uid,
    email,
    displayName,
    isPremium,
    photoUrl,
    xp,
    level,
    streak,
  ]; // <-- Adicionado aqui
}

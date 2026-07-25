import 'package:equatable/equatable.dart';

class UserEntity extends Equatable {
  final String uid;
  final String email;
  final String displayName;
  final bool isPremium;
  final String? token; // <-- Garantido aqui
  final String? photoUrl;
  final int xp;
  final int level;
  final int streak;

  const UserEntity({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.isPremium,
    this.token, // <-- Adicionado no construtor
    this.photoUrl,
    required this.xp,
    required this.level,
    required this.streak,
  });

  UserEntity copyWith({
    String? uid,
    String? email,
    String? displayName,
    bool? isPremium,
    String? token, // <-- Adicionado no copyWith
    String? photoUrl,
    int? xp,
    int? level,
    int? streak,
  }) {
    return UserEntity(
      uid: uid ?? this.uid,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      isPremium: isPremium ?? this.isPremium,
      token: token ?? this.token, // <-- Adicionado no copyWith
      photoUrl: photoUrl ?? this.photoUrl,
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
    token, // <-- Adicionado no Equatable
    photoUrl,
    xp,
    level,
    streak,
  ];
}

import '../../domain/entities/user_entity.dart';

class UserModel extends UserEntity {
  const UserModel({
    required super.uid,
    required super.email,
    required super.displayName,
    required super.isPremium,
    super.photoUrl,
    required super.xp,
    required super.level,
    required super.streak,
  });

  factory UserModel.fromFirestore(
    Map<String, dynamic> json,
    String documentId,
  ) {
    return UserModel(
      uid: documentId,
      email: json['email'] as String? ?? '',
      displayName: json['displayName'] as String? ?? 'User',
      isPremium: json['isPremium'] as bool? ?? false,
      photoUrl: json['photoUrl'] as String?,
      xp: json['xp'] as int? ?? 0,
      level: json['level'] as int? ?? 1,
      streak: json['streak'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'email': email,
      'displayName': displayName,
      'isPremium': isPremium,
      'photoUrl': photoUrl,
      'xp': xp,
      'level': level,
      'streak': streak,
    };
  }
}

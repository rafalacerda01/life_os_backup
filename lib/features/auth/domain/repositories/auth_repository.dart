import 'package:multiple_result/multiple_result.dart';
import 'package:life_os/core/errors/failure.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';

abstract class AuthRepository {
  Future<Result<UserEntity, Failure>> signInWithEmailAndPassword(
    String email,
    String password,
  );

  Future<Result<void, Failure>> sendPasswordResetEmail(String email);

  Future<Result<UserEntity, Failure>> signUpWithEmailAndPassword(
    String email,
    String password,
    String name,
  );

  Future<Result<void, Failure>> signOut();

  Future<Result<UserEntity, Failure>> getCurrentUser();

  Future<Result<UserEntity, Failure>> signInWithGoogle();

  Future<Result<UserEntity, Failure>> updateProfile(
    String newName, {
    String? newPhotoUrl,
  });

  Future<Result<void, Failure>> deleteAccount();
}

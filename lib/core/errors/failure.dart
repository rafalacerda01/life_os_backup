import 'package:equatable/equatable.dart';

abstract class Failure extends Equatable {
  final String message;
  final String? code;

  const Failure(this.message, {this.code});

  @override
  List<Object?> get props => [message, code];
}

class ServerFailure extends Failure {
  const ServerFailure(super.message, {super.code});

  factory ServerFailure.connection() => const ServerFailure(
    'Falha na conexão com o servidor. Verifique sua conexão com a internet.',
    code: 'NETWORK_ERROR',
  );

  factory ServerFailure.unexpected() => const ServerFailure(
    'Ocorreu um erro inesperado. Tente novamente mais tarde.',
    code: 'UNEXPECTED_ERROR',
  );
}

class AuthFailure extends Failure {
  const AuthFailure(super.message, {super.code});

  factory AuthFailure.invalidCredentials() => const AuthFailure(
    'E-mail ou senha inválidos. Verifique seus dados.',
    code: 'INVALID_CREDENTIALS',
  );

  factory AuthFailure.userNotFound() =>
      const AuthFailure('Usuário não encontrado.', code: 'USER_NOT_FOUND');

  factory AuthFailure.emailAlreadyInUse() => const AuthFailure(
    'Este e-mail já está em uso por outra conta.',
    code: 'EMAIL_ALREADY_IN_USE',
  );
}

class CacheFailure extends Failure {
  const CacheFailure(super.message, {super.code});

  factory CacheFailure.localDataNotFound() => const CacheFailure(
    'Não foi possível carregar os dados locais.',
    code: 'CACHE_NOT_FOUND',
  );
}

class SecurityFailure extends Failure {
  const SecurityFailure(super.message, {super.code});

  factory SecurityFailure.biometricFailed() => const SecurityFailure(
    'Falha na autenticação biométrica. Tente novamente.',
    code: 'BIOMETRIC_FAILURE',
  );

  factory SecurityFailure.unauthorized() =>
      const SecurityFailure('Acesso não autorizado.', code: 'UNAUTHORIZED');
}

class ValidationFailure extends Failure {
  const ValidationFailure(super.message, {super.code});
}

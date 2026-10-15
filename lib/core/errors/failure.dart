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

/// Auth absence or an ambiguous transport result is not a cleanup receipt.
/// Reuses the existing requested barrier; never authorizes local destruction.
class AccountDeletionUnconfirmedFailure extends AuthFailure
    implements Exception {
  static const failureCode = 'ACCOUNT_DELETE_UNCONFIRMED';

  const AccountDeletionUnconfirmedFailure()
    : super(
        'A identidade da conta pode ter sido removida, mas não foi possível '
        'confirmar toda a exclusão. Seus dados não serão apresentados a outra '
        'conta. Procure o suporte para verificar a solicitação.',
        code: failureCode,
      );

  @override
  String toString() => 'AccountDeletionUnconfirmedFailure';
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

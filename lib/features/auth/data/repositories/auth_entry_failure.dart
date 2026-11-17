import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import '../../../../core/errors/failure.dart';
import '../../../../core/services/trusted_account_access.dart';

/// Fixed public messages only. Exception text, JWTs and SDK details never escape.
Failure authEntryFailure(Object error) {
  if (error is AccountDeletionUnconfirmedFailure) return error;
  final code = error is TrustedAccountPending ? error.code
      : error is StateError ? error.message.toString()
      : error is FirebaseException ? error.code
      : error is TimeoutException ? 'AUTH_TIMEOUT' : 'AUTH_SESSION_UNCONFIRMED';
  return switch (code) {
    'invalid-credential' || 'wrong-password' || 'user-not-found' => AuthFailure.invalidCredentials(),
    'APP_CHECK_REQUIRED' || 'APP_CHECK_INVALID' || 'APP_CHECK_TOKEN_UNAVAILABLE' || 'APP_CHECK_TIMEOUT' =>
      const AuthFailure('Não foi possível confirmar a segurança do aplicativo. Tente novamente.', code:'APP_CHECK_UNCONFIRMED'),
    'network-request-failed' || 'unavailable' || 'deadline-exceeded' || 'AUTH_TIMEOUT' || 'EMULATOR_ACCOUNT_NETWORK_UNAVAILABLE' => ServerFailure.connection(),
    'LOCAL_ENVIRONMENT_PENDING_AUTHORIZATION' || 'LOCAL_ENVIRONMENT_MISMATCH' || 'LOCAL_ENVIRONMENT_DEBUG_ONLY' || 'EMULATOR_ACCOUNT_ENVIRONMENT_REQUIRED' || 'TRUSTED_ACCOUNT_CLOSED' || 'TRUSTED_LOCAL_SESSION_CLOSED' =>
      const AuthFailure('Este ambiente ainda não está habilitado para homologação segura.', code:'AUTH_ENVIRONMENT_CLOSED'),
    'TRUSTED_ACCOUNT_REVIEW_REQUIRED' || 'TRUSTED_ACCOUNT_PROVISIONING_PENDING' || 'TRUSTED_ACCOUNT_SERVER_PROOF_REQUIRED' || 'EMULATOR_ACCOUNT_PROVISIONING_UNCONFIRMED' =>
      const AuthFailure('A origem da conta ou o perfil ainda aguardam confirmação do servidor.', code:'AUTH_ORIGIN_OR_PROFILE_PENDING'),
    'LOCAL_DATABASE_UNAVAILABLE' =>
      const AuthFailure('Não foi possível abrir os dados protegidos desta sessão. Tente novamente.', code:'AUTH_LOCAL_DATABASE_UNAVAILABLE'),
    _ => const AuthFailure('Não foi possível confirmar a sessão atual. Entre novamente.', code:'AUTH_SESSION_UNCONFIRMED'),
  };
}

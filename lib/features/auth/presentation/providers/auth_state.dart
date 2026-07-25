import 'package:life_os/features/auth/domain/entities/user_entity.dart';

abstract class AuthState {
  const AuthState();

  // Construtores de fábrica normais e compatíveis com qualquer versão do Dart
  factory AuthState.initial() => const AuthInitial();
  factory AuthState.loading() => const AuthLoading();
  factory AuthState.authenticated(UserEntity user) => AuthAuthenticated(user);
  factory AuthState.unauthenticated() => const AuthUnauthenticated();
  factory AuthState.error(String message) => AuthError(message);

  R maybeWhen<R>({
    R Function()? initial,
    R Function()? loading,
    R Function(UserEntity user)? authenticated,
    R Function()? unauthenticated,
    R Function(String message)? error,
    required R Function() orElse,
  }) {
    final state = this;
    if (state is AuthInitial && initial != null) return initial();
    if (state is AuthLoading && loading != null) return loading();
    if (state is AuthAuthenticated && authenticated != null) return authenticated(state.user);
    if (state is AuthUnauthenticated && unauthenticated != null) return unauthenticated();
    if (state is AuthError && error != null) return error(state.message);
    return orElse();
  }
}

class AuthInitial extends AuthState {
  const AuthInitial();
}

class AuthLoading extends AuthState {
  const AuthLoading();
}

class AuthAuthenticated extends AuthState {
  final UserEntity user;
  const AuthAuthenticated(this.user);
}

class AuthUnauthenticated extends AuthState {
  const AuthUnauthenticated();
}

class AuthError extends AuthState {
  final String message;
  const AuthError(this.message);
}
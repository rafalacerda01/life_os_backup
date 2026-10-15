import 'package:life_os/core/errors/failure.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/router/router.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';

const _user = UserEntity(
  uid: 'user-a',
  email: 'user@example.invalid',
  displayName: 'User',
  isPremium: false,
  xp: 0,
  level: 1,
  streak: 0,
);

void main() {
  const publicError = AuthError(
    'Erro seguro',
    scope: AuthErrorScope.publicEntry,
  );
  for (final location in ['/login', '/register']) {
    test('erro público preserva $location', () {
      expect(
        authRedirectFor(
          authState: publicError,
          hasFirebaseUser: false,
          location: location,
        ),
        isNull,
      );
    });
  }
  test('erro público não autoriza rota privada sem Firebase', () {
    expect(
      authRedirectFor(
        authState: publicError,
        hasFirebaseUser: false,
        location: '/home',
      ),
      '/splash',
    );
  });
  test('erro com Firebase não redireciona sessão privada para entrada', () {
    expect(
      authRedirectFor(
        authState: publicError,
        hasFirebaseUser: true,
        location: '/home',
      ),
      isNull,
    );
  });
  for (final authState in [const AuthInitial(), const AuthLoading()]) {
    for (final location in ['/home', '/tasks', '/health/cycle', '/contact']) {
      test('${authState.runtimeType} desvia $location para splash', () {
        expect(
          authRedirectFor(
            authState: authState,
            hasFirebaseUser: true,
            location: location,
          ),
          '/splash',
        );
      });
    }
    for (final location in [
      '/splash',
      '/onboarding',
      '/login',
      '/register',
      '/privacy-policy',
    ]) {
      test('${authState.runtimeType} preserva rota pública $location', () {
        expect(
          authRedirectFor(
            authState: authState,
            hasFirebaseUser: true,
            location: location,
          ),
          isNull,
        );
      });
    }
  }

  test('usuário deslogado pode abrir a política', () {
    expect(
      authRedirectFor(
        authState: const AuthUnauthenticated(),
        hasFirebaseUser: false,
        location: '/privacy-policy',
      ),
      isNull,
    );
  });

  test('usuário autenticado pode abrir a política', () {
    expect(
      authRedirectFor(
        authState: const AuthAuthenticated(_user),
        hasFirebaseUser: true,
        location: '/privacy-policy',
      ),
      isNull,
    );
  });

  test('usuário deslogado é redirecionado de rota protegida', () {
    expect(
      authRedirectFor(
        authState: const AuthUnauthenticated(),
        hasFirebaseUser: false,
        location: '/home',
      ),
      '/login',
    );
  });

  test('usuário autenticado é redirecionado da entrada de Auth', () {
    expect(
      authRedirectFor(
        authState: const AuthAuthenticated(_user),
        hasFirebaseUser: true,
        location: '/login',
      ),
      '/home',
    );
  });

  test('usuário autenticado permanece em rota protegida', () {
    expect(
      authRedirectFor(
        authState: const AuthAuthenticated(_user),
        hasFirebaseUser: true,
        location: '/home',
      ),
      isNull,
    );
  });

  test('erro sem sessão Firebase sai da rota protegida para o splash', () {
    expect(
      authRedirectFor(
        authState: const AuthError('falha de isolamento'),
        hasFirebaseUser: false,
        location: '/home',
      ),
      '/splash',
    );
  });

  test('erro com sessão Firebase preserva rota protegida', () {
    expect(
      authRedirectFor(
        authState: const AuthError('falha recuperável'),
        hasFirebaseUser: true,
        location: '/home',
      ),
      isNull,
    );
  });

  test('erro sem sessão Firebase preserva rota pública', () {
    expect(
      authRedirectFor(
        authState: const AuthError('falha de isolamento'),
        hasFirebaseUser: false,
        location: '/privacy-policy',
      ),
      isNull,
    );
  });
  for (final hasUser in [false, true]) {
    test(
      'D2-B pending deletion isolates private routes with cached Auth=$hasUser',
      () {
        final pending = AuthState.error(
          const AccountDeletionUnconfirmedFailure().message,
          code: AccountDeletionUnconfirmedFailure.failureCode,
          scope: AuthErrorScope.publicEntry,
        );
        expect(
          authRedirectFor(
            authState: pending,
            hasFirebaseUser: hasUser,
            location: '/home',
          ),
          '/splash',
        );
        expect(
          authRedirectFor(
            authState: pending,
            hasFirebaseUser: hasUser,
            location: '/login',
          ),
          isNull,
        );
        expect(
          authRedirectFor(
            authState: pending,
            hasFirebaseUser: hasUser,
            location: '/privacy-policy',
          ),
          isNull,
        );
      },
    );
  }
}

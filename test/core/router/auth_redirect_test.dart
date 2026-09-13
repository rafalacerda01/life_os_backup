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
  test('usuário deslogado pode abrir a política', () {
    expect(
      authRedirectFor(
        authState: const AuthUnauthenticated(),
        location: '/privacy-policy',
      ),
      isNull,
    );
  });

  test('usuário autenticado pode abrir a política', () {
    expect(
      authRedirectFor(
        authState: const AuthAuthenticated(_user),
        location: '/privacy-policy',
      ),
      isNull,
    );
  });

  test('usuário deslogado é redirecionado de rota protegida', () {
    expect(
      authRedirectFor(
        authState: const AuthUnauthenticated(),
        location: '/home',
      ),
      '/login',
    );
  });

  test('usuário autenticado é redirecionado da entrada de Auth', () {
    expect(
      authRedirectFor(
        authState: const AuthAuthenticated(_user),
        location: '/login',
      ),
      '/home',
    );
  });
}

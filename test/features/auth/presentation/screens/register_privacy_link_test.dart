import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/core/errors/failure.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/domain/repositories/auth_repository.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/screens/register_screen.dart';
import 'package:life_os/features/settings/presentation/screens/privacy_policy_screen.dart';
import 'package:multiple_result/multiple_result.dart';

class _FirebaseAuth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => null;

  @override
  Stream<User?> authStateChanges() => const Stream<User?>.empty();
}

class _AuthRepository extends Fake implements AuthRepository {
  @override
  Future<Result<UserEntity, Failure>> getCurrentUser() =>
      Completer<Result<UserEntity, Failure>>().future;
}

void main() {
  testWidgets('cadastro abre a Política de Privacidade e permite voltar', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/register',
      routes: [
        GoRoute(path: '/register', builder: (_, _) => const RegisterScreen()),
        GoRoute(
          path: '/privacy-policy',
          builder: (_, _) => const PrivacyPolicyScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          firebaseAuthProvider.overrideWithValue(_FirebaseAuth()),
          authRepositoryProvider.overrideWithValue(_AuthRepository()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RegisterScreen), findsOneWidget);
    expect(find.text('Política de Privacidade'), findsOneWidget);

    await tester.tap(find.text('Política de Privacidade'));
    await tester.pumpAndSettle();

    expect(find.byType(PrivacyPolicyScreen), findsOneWidget);
    expect(router.canPop(), isTrue);

    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(RegisterScreen), findsOneWidget);
  });
}

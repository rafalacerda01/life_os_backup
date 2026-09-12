import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/errors/failure.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/domain/repositories/auth_repository.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/screens/login_screen.dart';
import 'package:multiple_result/multiple_result.dart';

class _FirebaseAuth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => null;

  @override
  Stream<User?> authStateChanges() => const Stream<User?>.empty();
}

class _AuthRepository extends Fake implements AuthRepository {
  Result<void, Failure> passwordResetResult = const Success(null);
  int passwordResetCalls = 0;

  @override
  Future<Result<UserEntity, Failure>> getCurrentUser() =>
      Completer<Result<UserEntity, Failure>>().future;

  @override
  Future<Result<void, Failure>> sendPasswordResetEmail(String email) async {
    passwordResetCalls += 1;
    return passwordResetResult;
  }
}

Future<void> _pumpLogin(WidgetTester tester, _AuthRepository repository) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        firebaseAuthProvider.overrideWithValue(_FirebaseAuth()),
        authRepositoryProvider.overrideWithValue(repository),
      ],
      child: const MaterialApp(home: LoginScreen()),
    ),
  );
  await tester.pump();
}

Future<void> _openAndSubmitReset(WidgetTester tester) async {
  await tester.tap(find.text('Esqueceu a senha?'));
  await tester.pumpAndSettle();
  final resetEmailField = find.byWidgetPredicate(
    (widget) =>
        widget is TextField && widget.decoration?.hintText == 'Seu e-mail',
  );
  await tester.enterText(resetEmailField, 'user@example.invalid');
  await tester.tap(find.text('Enviar'));
  await tester.pumpAndSettle();
}

void main() {
  const neutralMessage =
      'Se houver uma conta para este e-mail, você receberá as instruções de recuperação.';

  testWidgets('falha mantém diálogo aberto e não mostra confirmação neutra', (
    tester,
  ) async {
    final repository = _AuthRepository()
      ..passwordResetResult = const Error(
        AuthFailure(
          'Não foi possível solicitar a recuperação de senha. Tente novamente.',
          code: 'PASSWORD_RESET_FAILED',
        ),
      );
    await _pumpLogin(tester, repository);

    await _openAndSubmitReset(tester);

    expect(repository.passwordResetCalls, 1);
    expect(find.text('Recuperar senha'), findsOneWidget);
    expect(find.text(neutralMessage), findsNothing);
  });

  testWidgets('sucesso fecha diálogo e mostra confirmação neutra', (
    tester,
  ) async {
    final repository = _AuthRepository();
    await _pumpLogin(tester, repository);

    await _openAndSubmitReset(tester);

    expect(repository.passwordResetCalls, 1);
    expect(find.text('Recuperar senha'), findsNothing);
    expect(find.text(neutralMessage), findsOneWidget);
  });
}

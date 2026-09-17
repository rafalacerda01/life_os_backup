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
import 'package:life_os/features/auth/presentation/screens/register_screen.dart';
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

const _validEmails = <String>[
  'usuario@example.com',
  'usuario@empresa.technology',
];

const _invalidEmails = <String>[
  'email-sem-arroba',
  '@dominio.com',
  'usuario@',
  'usuario@dominio',
];

Future<FormFieldValidator<String>> _pumpEmailValidator(
  WidgetTester tester,
  Widget screen,
  int emailFieldIndex,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        firebaseAuthProvider.overrideWithValue(_FirebaseAuth()),
        authRepositoryProvider.overrideWithValue(_AuthRepository()),
      ],
      child: MaterialApp(home: screen),
    ),
  );
  await tester.pump();

  final emailField = tester.widget<TextFormField>(
    find.byType(TextFormField).at(emailFieldIndex),
  );
  return emailField.validator!;
}

void _expectEmailContract(FormFieldValidator<String> validator) {
  for (final email in _validEmails) {
    expect(validator(email), isNull, reason: email);
  }
  for (final email in _invalidEmails) {
    expect(validator(email), isNotNull, reason: email);
  }
}

void main() {
  testWidgets('login aceita TLD longo e rejeita estruturas inválidas', (
    tester,
  ) async {
    final validator = await _pumpEmailValidator(tester, const LoginScreen(), 0);

    _expectEmailContract(validator);
  });

  testWidgets('cadastro aceita TLD longo e rejeita estruturas inválidas', (
    tester,
  ) async {
    final validator = await _pumpEmailValidator(
      tester,
      const RegisterScreen(),
      1,
    );

    _expectEmailContract(validator);
  });
}

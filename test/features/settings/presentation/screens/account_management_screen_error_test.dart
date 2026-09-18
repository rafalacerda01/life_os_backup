import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/settings/presentation/screens/account_management_screen.dart';

class _ErrorAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => AuthState.error('technical-auth-internal-error');
}

void main() {
  test('diálogo preserva senha opaca e rejeita somente string vazia', () {
    final source = File(
      'lib/features/settings/presentation/screens/account_management_screen.dart',
    ).readAsStringSync();
    final confirmStart = source.indexOf('void _confirm()');
    final confirmEnd = source.indexOf('@override', confirmStart);

    expect(confirmStart, greaterThanOrEqualTo(0));
    expect(confirmEnd, greaterThan(confirmStart));

    final confirmSource = source.substring(confirmStart, confirmEnd);
    expect(
      confirmSource,
      contains('final password = _passwordController.text;'),
    );
    expect(confirmSource, isNot(contains('_passwordController.text.trim()')));
    expect(confirmSource, contains('password.isEmpty'));
    expect(
      confirmSource,
      contains('password: widget.usesPasswordProvider ? password : null'),
    );
  });

  testWidgets('erro de conta não expõe mensagem técnica do Auth', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authNotifierProvider.overrideWith(_ErrorAuthNotifier.new)],
        child: const MaterialApp(home: AccountManagementScreen()),
      ),
    );
    await tester.pump();

    expect(
      find.text('Não foi possível carregar os dados da sua conta.'),
      findsOneWidget,
    );
    expect(find.text('Volte e tente novamente em instantes.'), findsOneWidget);
    expect(find.textContaining('technical-auth-internal-error'), findsNothing);
  });
}

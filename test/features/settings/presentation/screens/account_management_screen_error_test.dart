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

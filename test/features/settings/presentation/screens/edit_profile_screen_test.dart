import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/settings/presentation/screens/edit_profile_screen.dart';

const _user = UserEntity(
  uid: 'user-a',
  email: 'user@example.invalid',
  displayName: 'Nome original',
  isPremium: false,
  xp: 0,
  level: 1,
  streak: 0,
);

class _ProfileAuthNotifier extends AuthNotifier {
  _ProfileAuthNotifier({required this.result, this.error});

  final AuthState result;
  final Object? error;
  int updateCalls = 0;

  @override
  AuthState build() => AuthState.authenticated(_user);

  @override
  Future<void> updateProfile({String? newName, String? newPhotoUrl}) async {
    updateCalls += 1;
    if (error != null) throw error!;
    state = result;
  }
}

class _NavigatorObserver extends NavigatorObserver {
  int popCalls = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCalls += 1;
    super.didPop(route, previousRoute);
  }
}

Future<void> _pumpEditProfile(
  WidgetTester tester,
  _ProfileAuthNotifier notifier,
  _NavigatorObserver observer,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authNotifierProvider.overrideWith(() => notifier)],
      child: MaterialApp(
        navigatorObservers: [observer],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const EditProfileScreen(),
                ),
              ),
              child: const Text('Abrir perfil'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Abrir perfil'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('falha mantém a tela aberta e mostra mensagem amigável', (
    tester,
  ) async {
    final notifier = _ProfileAuthNotifier(
      result: AuthState.error(
        'Não foi possível atualizar o perfil. Tente novamente.',
      ),
    );
    final observer = _NavigatorObserver();
    await _pumpEditProfile(tester, notifier, observer);

    await tester.tap(find.text('Salvar Alterações'));
    await tester.pumpAndSettle();

    expect(notifier.updateCalls, 1);
    expect(find.text('Editar Perfil'), findsOneWidget);
    expect(find.text('Perfil atualizado com sucesso!'), findsNothing);
    expect(
      find.text('Não foi possível atualizar o perfil. Tente novamente.'),
      findsOneWidget,
    );
    expect(find.textContaining('technical-profile-marker'), findsNothing);
    expect(observer.popCalls, 0);
  });

  testWidgets('sucesso mostra confirmação e fecha a tela', (tester) async {
    final notifier = _ProfileAuthNotifier(
      result: AuthState.authenticated(
        const UserEntity(
          uid: 'user-a',
          email: 'user@example.invalid',
          displayName: 'Nome atualizado',
          isPremium: false,
          xp: 0,
          level: 1,
          streak: 0,
        ),
      ),
    );
    final observer = _NavigatorObserver();
    await _pumpEditProfile(tester, notifier, observer);

    await tester.tap(find.text('Salvar Alterações'));
    await tester.pumpAndSettle();

    expect(notifier.updateCalls, 1);
    expect(find.text('Editar Perfil'), findsNothing);
    expect(find.text('Perfil atualizado com sucesso!'), findsOneWidget);
    expect(observer.popCalls, 1);
  });

  testWidgets('exceção técnica mostra erro fixo sem expor detalhes', (
    tester,
  ) async {
    final notifier = _ProfileAuthNotifier(
      result: AuthState.authenticated(_user),
      error: StateError('technical-profile-marker'),
    );
    final observer = _NavigatorObserver();
    await _pumpEditProfile(tester, notifier, observer);

    await tester.tap(find.text('Salvar Alterações'));
    await tester.pumpAndSettle();

    expect(find.text('Editar Perfil'), findsOneWidget);
    expect(find.text('Perfil atualizado com sucesso!'), findsNothing);
    expect(
      find.text('Não foi possível atualizar o perfil. Tente novamente.'),
      findsOneWidget,
    );
    expect(find.textContaining('technical-profile-marker'), findsNothing);
    expect(observer.popCalls, 0);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/settings/presentation/settings_screen.dart';

void main() {
  testWidgets('Settings configura somente entradas disponíveis', (
    tester,
  ) async {
    late Scaffold screen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            screen = const SettingsScreen().build(context) as Scaffold;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final appBar = screen.appBar! as AppBar;
    final listView = screen.body! as ListView;
    final children =
        (listView.childrenDelegate as SliverChildListDelegate).children;
    final visibleTexts = <String>{(appBar.title! as Text).data!};
    for (final child in children) {
      final tile = (child as Container).child! as ListTile;
      visibleTexts.add((tile.title! as Text).data!);
      visibleTexts.add((tile.subtitle! as Text).data!);
    }

    for (final text in <String>[
      'Ajustes',
      'Gerenciamento da Conta',
      'Segurança & Privacidade',
      'Minha Assinatura',
      'Planos Premium e Valores',
      'Notificações Inteligentes',
      'Política de Privacidade',
      'Suporte & Reporte de Bugs',
      'Estudos, hábitos e medicamentos',
      'Biometria e preferências de privacidade',
    ]) {
      expect(visibleTexts, contains(text));
    }

    expect(visibleTexts, isNot(contains('Aparência (Interface)')));
    expect(visibleTexts, isNot(contains('Alertas e revisões do Anki')));
    expect(visibleTexts, isNot(contains('Painel Operacional')));
  });
}

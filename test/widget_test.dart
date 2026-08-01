import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/main.dart'; // Certifique-se de que o caminho do import está correto

void main() {
  testWidgets('LifeOSApp smoke test', (WidgetTester tester) async {
    // É necessário envolver com ProviderScope para o Riverpod funcionar nos testes de widget
    await tester.pumpWidget(const ProviderScope(child: LifeOSApp()));

    // Adicione aqui as validações correspondentes à tela inicial real do seu Life OS
    // Exemplo básico para garantir que o app renderiza sem crashar:
    await tester.pumpAndSettle();
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'; // 1. Importe o Riverpod
import 'package:life_os/main.dart';

void main() {
  testWidgets('LifeOSApp smoke test', (WidgetTester tester) async {
    // Configura a resolução para evitar overflow
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 2. Envolva o LifeOSApp com o ProviderScope
    await tester.pumpWidget(const ProviderScope(child: LifeOSApp()));

    // 3. Agora o app vai construir com sucesso e encontrar o MaterialApp
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}

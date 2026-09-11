import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';
import 'package:life_os/features/notifications/presentation/screens/notification_screen.dart';

class _ErrorNotificationEngine extends NotificationEngine {
  _ErrorNotificationEngine(this.onBuild);

  final VoidCallback onBuild;

  @override
  Stream<List<NotificationModel>> build() {
    onBuild();
    return Stream<List<NotificationModel>>.error(
      StateError('technical-notification-stream-error'),
    );
  }
}

void main() {
  testWidgets('erro de notificações é sanitizado e permite tentar novamente', (
    tester,
  ) async {
    var streamBuilds = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationEngineProvider.overrideWith(
            () => _ErrorNotificationEngine(() => streamBuilds++),
          ),
        ],
        child: const MaterialApp(home: NotificationScreen()),
      ),
    );
    await tester.pump();

    expect(
      find.text('Não foi possível carregar suas notificações.'),
      findsOneWidget,
    );
    expect(find.text('Tentar novamente'), findsOneWidget);
    expect(
      find.textContaining('technical-notification-stream-error'),
      findsNothing,
    );

    final buildsBeforeRetry = streamBuilds;
    await tester.tap(find.text('Tentar novamente'));
    await tester.pump();

    expect(streamBuilds, greaterThan(buildsBeforeRetry));
  });
}

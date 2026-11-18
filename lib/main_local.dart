import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/local_device_session.dart';
import 'package:life_os/core/database/local_installation_identity_provider.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';
import 'package:life_os/core/runtime/app_runtime_mode.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/tasks/presentation/tasks_screen.dart';
import 'package:life_os/features/finance/presentation/finance_screen.dart';
import 'package:life_os/features/habits/presentation/habits_screen.dart';

const localLabChannel = MethodChannel('lifeos.local_lab');

/// Development entrypoint only. The default main.dart remains unchanged.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(_start());
}

Future<LocalDeviceSession> prepareLocalDevelopmentSession() async {
  if (!Platform.isAndroid || kReleaseMode) {
    throw StateError('LOCAL_DEVELOPMENT_ANDROID_HOST_REQUIRED');
  }
  // Check the native host BEFORE any identity, key or database operation.
  final audit = await localLabChannel.invokeMapMethod<String, Object?>('audit');
  if (audit?['package'] != 'com.rafalacerda.lifeos.localdev' ||
      audit?['firebaseApps'] != 0 ||
      (audit?['forbiddenPluginsRegistered'] as List?)?.isEmpty != true) {
    throw StateError('LOCAL_DEVELOPMENT_ANDROID_HOST_REQUIRED');
  }
  await initializeDateFormatting('pt_BR');
  final container = ProviderContainer();
  final session = LocalDeviceSession(
    identityService: container.read(localInstallationIdentityServiceProvider),
    clearKeyCache: UserDbKeyManager.instance.clearCache,
  );
  try {
    await session.open();
    return session;
  } catch (_) {
    await session.dispose();
    rethrow;
  } finally {
    container.dispose();
  }
}

Future<void> _start() async {
  runApp(const _LocalMessageApp(loading: true));
  try {
    final session = await prepareLocalDevelopmentSession();
    runApp(LocalFirstDevelopmentApp(session: session));
  } catch (error, stack) {
    AppLogger.e(
      'Abertura local recusada; armazenamento preservado.',
      error,
      stack,
    );
    runApp(const _LocalMessageApp(loading: false));
  }
}

ThemeData _theme() => ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xFF070B14),
  useMaterial3: true,
);

class LocalFirstDevelopmentApp extends StatefulWidget {
  const LocalFirstDevelopmentApp({required this.session, super.key});
  final LocalDeviceSession session;
  @override
  State<LocalFirstDevelopmentApp> createState() =>
      _LocalFirstDevelopmentAppState();
}

class _LocalFirstDevelopmentAppState extends State<LocalFirstDevelopmentApp> {
  int _selectedModule = 0;
  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(widget.session.requirePrepared()),
      appRuntimeModeProvider.overrideWithValue(AppRuntimeMode.localFirst),
    ],
    child: MaterialApp(
      title: 'Life OS Local',
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      locale: const Locale('pt', 'BR'),
      supportedLocales: const [Locale('pt', 'BR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: switch (_selectedModule) {
          0 => const TasksScreen(showFocusShortcut: false),
          1 => const FinanceScreen(),
          _ => const HabitsScreen(),
        },
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedModule,
          onDestinationSelected: (index) =>
              setState(() => _selectedModule = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.checklist_rounded),
              label: 'Tarefas',
            ),
            NavigationDestination(
              icon: Icon(Icons.account_balance_wallet_outlined),
              label: 'Finanças',
            ),
            NavigationDestination(
              icon: Icon(Icons.repeat_rounded),
              label: 'Hábitos',
            ),
          ],
        ),
      ),
    ),
  );

  @override
  void dispose() {
    unawaited(widget.session.dispose());
    super.dispose();
  }
}

class _LocalMessageApp extends StatelessWidget {
  const _LocalMessageApp({required this.loading});
  final bool loading;
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: _theme(),
    home: Scaffold(
      body: Center(
        child: loading
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Não foi possível abrir o armazenamento local.'),
                    const SizedBox(height: 12),
                    const Text(
                      'Seus arquivos e chaves foram preservados. Uma instalação anterior pode precisar de migração verificada.',
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => unawaited(_start()),
                      child: const Text('Tentar novamente'),
                    ),
                  ],
                ),
              ),
      ),
    ),
  );
}

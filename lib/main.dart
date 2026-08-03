import 'dart:async';
import 'dart:ui';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:life_os/core/router/router.dart';
import 'package:life_os/firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Inicialização síncrona obrigatória do núcleo do Firebase
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // 🚀 CÓDIGO ALTERADO: App Check agora é aguardado ANTES de construir a UI.
  // Isso garante que nenhuma requisição do Riverpod bata no Firebase sem o token de segurança.
  await _initAppCheckInBackground();

  // 2. Configuração de coleta do Crashlytics
  await FirebaseCrashlytics.instance
      .setCrashlyticsCollectionEnabled(!kDebugMode)
      .catchError((_) {});

  // 3. Inicialização de localidade de datas
  await initializeDateFormatting('pt_BR', null).catchError((_) {});

  // Execução do aplicativo com tratamento global de erros
  runZonedGuarded(
    () {
      FlutterError.onError = (errorDetails) {
        if (kDebugMode) {
          FlutterError.dumpErrorToConsole(errorDetails);
        } else {
          FirebaseCrashlytics.instance.recordFlutterFatalError(errorDetails);
        }
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        if (kDebugMode) {
          debugPrint('Erro assíncrono não tratado: $error');
        } else {
          FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        }
        return true;
      };

      // Inicia a interface de forma segura, com o App Check já ativo e validado
      runApp(const ProviderScope(child: LifeOSApp()));
    },
    (error, stack) {
      if (kDebugMode) {
        debugPrint('Erro crítico capturado no Zone Guard: $error');
      } else {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      }
    },
  );
}

Future<void> _initAppCheckInBackground() async {
  try {
    await FirebaseAppCheck.instance.activate(
      androidProvider: kDebugMode
          ? AndroidProvider.debug
          : AndroidProvider.playIntegrity,
      appleProvider: kDebugMode
          ? AppleProvider.debug
          : AppleProvider.deviceCheck,
    );
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Aviso App Check (Ignorado em Debug): $e');
    }
  }
}

class LifeOSApp extends ConsumerWidget {
  const LifeOSApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Life OS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF070B14),
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}

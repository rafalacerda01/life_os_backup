import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart'; // Import necessário
import 'package:life_os/core/router/router.dart';
import 'package:life_os/firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicialização da formatação de datas globalmente
  await initializeDateFormatting('pt_BR', null);

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(const ProviderScope(child: LifeOSApp()));
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

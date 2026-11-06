import 'dart:async';
import '../services/emulator_account_runtime.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_app_check/firebase_app_check.dart';
import '../database/database_provider.dart';
import '../database/local_account_session.dart';
import '../services/firebase_auth_provider.dart';
import 'generational_http_store.dart';
import 'generational_http_transport.dart';

/// Dormant while R1 Auth/session admission is CLOSED. No cohort activation.
final generationalHttpTransportProvider = Provider<GenerationalHttpTransport?>((
  ref,
) {
  final snapshot = ref.watch(localAccountSessionProvider);
  if (snapshot.identity?.isBound != true) return null;
  final database = ref.watch(databaseProvider);
  ref.watch(localAccountSessionProvider);
  final lease = ref.read(localAccountSessionProvider.notifier).capture();
  final client = http.Client();
  ref.onDispose(client.close);
  final auth = ref.watch(firebaseAuthProvider);
  final localRuntime = ref.watch(emulatorAccountRuntimeProvider);
  final transport = GenerationalHttpTransport(
    store: GenerationalHttpStore(database),
    lease: lease,
    auth: auth,
    client: localRuntime?.client ?? client,
    appCheckToken: localRuntime?.appCheckToken ?? () => FirebaseAppCheck.instanceFor(app: auth.app).getToken(),
    baseUri: localRuntime?.baseUri ?? Uri.parse(
      const String.fromEnvironment(
        'LIFE_OS_TRUSTED_HTTP_BASE_URL',
        defaultValue: 'https://life-os-backend-gray.vercel.app',
      ),
    ),
  );
  ref.onDispose(() => unawaited(transport.close()));
  return transport;
});

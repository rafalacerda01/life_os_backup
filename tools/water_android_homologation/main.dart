// Debug-only entry point, compiled only by gradle.init.gradle. Never import from lib/.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
import 'package:life_os/core/router/router.dart';
import 'package:life_os/core/security/biometric_app_gate.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/core/services/water_v2_configuration.dart';
import 'package:life_os/core/services/water_v2_provider.dart';
import 'package:life_os/core/services/water_v2_remote_data_source.dart';
import 'package:life_os/features/auth/data/remote/account_remote_data_source.dart';
import 'package:life_os/features/auth/data/local/auth_cleanup_barrier.dart';
import 'package:life_os/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/auth/presentation/screens/login_screen.dart';
import 'package:life_os/features/auth/presentation/screens/register_screen.dart';
import 'package:life_os/features/health/presentation/health_screen.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';

const _syntheticAttestation = 'isolated-emulator-only';
const _native = MethodChannel('life_os/isolated_water');

// This adapter is not linked by the production entry point. It accepts exactly
// the already-validated production request and sends only to a fixed emulator.
// No URL comes from users, remote config, environment, or release definitions.
final class LocalOnlyClient extends http.BaseClient {
  final _delegate = IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 3));
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!kDebugMode || request.method != 'POST' ||
        request.url.toString() != 'https://life-os-backend-gray.vercel.app/api/sync') {
      throw StateError('LOCAL_TRANSPORT_BLOCKED');
    }
    final bytes = await request.finalize().toBytes();
    final local = http.Request('POST', Uri.parse('http://10.0.2.2:8789/api/sync'))
      ..followRedirects = false
      ..headers.addAll(request.headers)
      ..bodyBytes = bytes;
    return _delegate.send(local);
  }
  @override
  void close() => _delegate.close();
}

final class NoAccountDeletionClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future.error(StateError('ACCOUNT_DELETION_DISABLED_IN_HOMOLOGATION'));
}

final class LocalAnalytics implements AnalyticsPlatform {
  @override Future<void> setCollectionEnabled(bool value) async {}
  @override Future<void> resetAnalyticsData() async {}
  @override Future<void> logAnalyticsOptIn() async {}
  @override Future<void> logOnboardingCompleted() async {}
  @override Future<void> logLogin(AnalyticsAuthMethod method) async {}
  @override Future<void> logSignUp(AnalyticsAuthMethod method) async {}
  @override Future<void> logTaskCompleted() async {}
  @override Future<void> logHabitCompleted() async {}
  @override Future<void> logFocusCompleted(int minutes) async {}
  @override Future<void> logSupportOpened() async {}
}

// Billing is outside this test. No purchase repository or native plugin starts.
final class LocalFreePlan extends PremiumNotifier {
  @override
  PremiumStatusEntity build() => const PremiumStatusEntity(
    isPremium: false, tier: PremiumTier.free, activatedFeatures: [],
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (!kDebugMode || WaterV2Configuration.enabled) throw StateError('DEBUG_ONLY');
    final native = await _native.invokeMapMethod<String, dynamic>('configuration');
    if (native?['ready'] != true || native?['project'] != 'demo-life-os' ||
        native?['package'] != 'com.rafalacerda.lifeos.waterhomologation' ||
        native?['host'] != '10.0.2.2' || native?['authPort'] != 9099 ||
        native?['firestorePort'] != 8089 || native?['telemetry'] != 'excluded') {
      throw StateError('NATIVE_ISOLATION_NOT_PROVEN');
    }
    // Providers are not constructed until all local services are reachable.
    for (final port in [9099, 8089, 8789]) {
      final socket = await Socket.connect('10.0.2.2', port, timeout: const Duration(seconds: 3));
      socket.destroy();
    }
    final check = IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 3));
    try {
      final response = await check.get(Uri.parse('http://10.0.2.2:8789/__health')).timeout(const Duration(seconds: 3));
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200 || body['projectId'] != 'demo-life-os' || body['isolated'] != true) {
        throw StateError('LOCAL_SERVER_NOT_PROVEN');
      }
    } finally { check.close(); }
    final app = await Firebase.initializeApp();
    if (app.options.projectId != 'demo-life-os') throw StateError('PROJECT_BLOCKED');
    final auth = FirebaseAuth.instance;
    await auth.useAuthEmulator('10.0.2.2', 9099);
    final fs = FirebaseFirestore.instance;
    fs.settings = const Settings(host: '10.0.2.2:8089', sslEnabled: false, persistenceEnabled: false);
    await initializeDateFormatting('pt_BR');

    WaterV2RemoteDataSource remote(RemoteSendPermit Function(String) permit) =>
        WaterV2RemoteDataSource.enabledForLocalTests(auth,
          captureRemoteSend: permit, clientFactory: LocalOnlyClient.new,
          idTokenProvider: (user, refresh) => user.getIdToken(refresh),
          appCheckTokenProvider: () async => _syntheticAttestation,
          requestTimeout: const Duration(seconds: 5));
    final bootstrap = remote((uid) => RemoteSendPermit(() => auth.currentUser?.uid == uid));
    final container = ProviderContainer(overrides: [
      firebaseAuthProvider.overrideWithValue(auth),
      firestoreProvider.overrideWithValue(fs),
      premiumProvider.overrideWith(LocalFreePlan.new),
      analyticsServiceProvider.overrideWithValue(AnalyticsService(platform: LocalAnalytics())),
      accountRemoteDataSourceProvider.overrideWith((ref) => AccountRemoteDataSource(client: NoAccountDeletionClient())),
      authRepositoryProvider.overrideWith((ref) => AuthRepositoryImpl(auth, fs,
        ref.watch(accountRemoteDataSourceProvider), waterProfileProvisioner: (user) async {
          final result = await bootstrap.bootstrap(user.uid, DateTime.now().timeZoneOffset.inMinutes,
            RemoteSendPermit(() => auth.currentUser?.uid == user.uid));
          if (result.value?.state == 'READY') return;
          // The existing repository performs bounded server profile reads and
          // returns WATER_PROVISIONING_PENDING without recreating the profile.
          if (result.error?.code == 'WATER_PROVISIONING_PENDING') return;
          throw StateError(result.error?.code ?? 'LOCAL_BOOTSTRAP_REJECTED');
        })),
      waterV2RemoteProvider.overrideWith((ref) => remote((uid) =>
        ref.read(databaseProvider).localMutations.captureRemoteSend(expectedUid: uid))),
      waterAdmissionProvider.overrideWith((ref) async* {
        final controller = ref.watch(waterV2ControllerProvider);
        yield controller.state;
        yield* controller.states;
      }),
      waterGoalProvider.overrideWith((ref) => ref.watch(waterV2ControllerProvider).watchGoal()),
      syncManagerProvider.overrideWith((ref) {
        final db = ref.watch(databaseProvider);
        final manager = SyncManager(waterV2Processor: ref.watch(waterV2ProcessorProvider),
          queueStore: AppDatabaseSyncQueueStore(db), currentUserId: () => auth.currentUser?.uid,
          remoteDataSource: FirestoreSyncRemoteDataSource(fs, auth,
            captureRemoteSend: (uid) => db.localMutations.captureRemoteSend(expectedUid: uid),
            clientFactory: LocalOnlyClient.new,
            appCheckTokenProvider: () async => _syntheticAttestation));
        ref.onDispose(manager.dispose);
        return manager;
      }),
      routerProvider.overrideWith((ref) {
        final refresh = AuthRefreshListenable(ref);
        ref.onDispose(refresh.dispose);
        return GoRouter(initialLocation: '/login', refreshListenable: refresh,
          redirect: (_, state) => authRedirectFor(authState: ref.read(authNotifierProvider),
            hasFirebaseUser: auth.currentUser != null, location: state.matchedLocation),
          routes: [
            GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
            GoRoute(path: '/register', builder: (_, _) => const RegisterScreen()),
            GoRoute(path: '/splash', builder: (_, _) => const LoginScreen()),
            GoRoute(path: '/home', builder: (_, _) => const DemoHealth()),
            GoRoute(path: '/health', builder: (_, _) => const DemoHealth()),
            GoRoute(path: '/privacy-policy', builder: (_, _) => const Scaffold(body: Center(child: Text('Ambiente sintético local.')))),
          ]);
      }),
    ]);
    // Sanitized debug-only lifecycle evidence; no tokens or queue contents.
    container.listen<AuthState>(authNotifierProvider, (_, next) {
      debugPrint('R4_AUTH state=${next.runtimeType}');
    });
    developer.registerExtension('ext.lifeos.waterInspect', (_, params) async {
      final state = container.read(authNotifierProvider);
      final info = <String, Object?>{'projectId': app.options.projectId, 'uid': auth.currentUser?.uid,
        'authState': state.runtimeType.toString(), if (state is AuthError) 'authError': state.code};
      final session = container.read(sessionDatabaseCoordinatorProvider).snapshot;
      final pending = await container.read(authCleanupBarrierProvider).readPending();
      info['databasePhase'] = session.phase.name;
      info['databaseUid'] = session.identity?.uid;
      info['cleanupPending'] = pending != null;
      if (state is AuthAuthenticated) {
        final db = container.read(databaseProvider);
        info['queue'] = (await db.select(db.syncQueueTable).get()).map((r) =>
          {'id': r.id, 'ownerUid': r.ownerUid, 'status': r.status, 'collection': r.collection, 'operation': r.operationType}).toList();
        info['daily'] = (await db.select(db.waterV2DailyStates).get()).map((r) => r.toJson()).toList();
        info['waterState'] = container.read(waterV2ControllerProvider).state.name;
      }
      return developer.ServiceExtensionResponse.result(jsonEncode(info));
    });
    debugPrint('DART_READY project=demo-life-os providers=isolated');
    runApp(UncontrolledProviderScope(container: container, child: const DemoApp()));
  } catch (error) {
    debugPrint('ISOLATION_BLOCKED ${error.runtimeType}');
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('BLOCKED — emuladores/configuração isolada indisponíveis.')))));
  }
}

class DemoApp extends ConsumerWidget {
  const DemoApp({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: 'Life OS DEMO ONLY', theme: ThemeData.dark(useMaterial3: true),
    routerConfig: ref.watch(routerProvider),
    builder: (_, child) => BiometricAppGate(child: child ?? const SizedBox.shrink()),
  );
}

class DemoHealth extends ConsumerWidget {
  const DemoHealth({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('DEMO · Water V2'), actions: [
      IconButton(tooltip: 'Atualizar Water', icon: const Icon(Icons.refresh), onPressed: () => ref.read(waterV2ControllerProvider).refresh()),
      IconButton(tooltip: 'Sair', icon: const Icon(Icons.logout), onPressed: () async {
        debugPrint('R4_LOGOUT_UI begin');
        await ref.read(authNotifierProvider.notifier).logout();
        debugPrint('R4_LOGOUT_UI done');
      }),
    ]),
    body: const HealthScreen(),
  );
}

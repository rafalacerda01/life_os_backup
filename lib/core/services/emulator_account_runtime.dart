import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../../features/auth/data/remote/account_deletion_recovery.dart';
import '../database/local_database_identity.dart';
import 'trusted_account_access.dart';
import 'local_homologation_environment.dart';

// Default is CLOSED. Only an explicitly configured loopback runtime enables
// the explicitly reviewed local module slices; never a production grant.
final emulatorAccountRuntimeProvider = Provider<EmulatorAccountRuntime?>((ref) => null);

/// Explicit local SDK configuration, never a build flag or production grant.
/// Only explicitly selected module slices are enabled after R1 admission.
/// Unreviewed consumers, deletion and production Auth remain CLOSED.
final class EmulatorAccountRuntime {
  EmulatorAccountRuntime._(this.auth, this.store, this.baseUri, this.client,
      this.appCheckToken, Set<String> modules, this.environment) : enabledModules = Set.unmodifiable(modules);
  final LocalHomologationEnvironment environment;
  static final _configured = Expando<EmulatorAccountRuntime>();
  static String? configuredProject(FirebaseAuth auth, FirebaseFirestore store) {
    final runtime = _configured[auth];
    if (runtime == null) return null;
    runtime.requireClients(auth, store);
    return runtime.environment.projectId;
  }
  // Explicit capabilities of this isolated runtime; production still has no runtime.
  final Set<String> enabledModules;
  static const moduleCollections = <String, Set<String>>{
    'tasks': {'tasks'}, 'habits': {'habits', 'batch'},
    'finance': {'transactions'}, 'goals': {'goals'},
    'study': {'subjects', 'review_queue', 'study_activity', 'study_progress_reset'},
    'health': {'medications'}, 'checkin': {'checkins'},
    'notifications': {'notifications'}, 'focus': <String>{},
  };
  Set<String> get allowedCollections => Set.unmodifiable(
    enabledModules.expand((module) => moduleCollections[module]!));
  bool allowsRoute(String route) {
    if (const {'/splash','/onboarding','/login','/register','/privacy-policy','/home','/module-closed'}.contains(route)) return true;
    return enabledModules.any((module) => route == '/$module');
  }
  final FirebaseAuth auth;
  final FirebaseFirestore store;
  final Uri baseUri;
  final http.Client client;
  final Future<String?> Function() appCheckToken;

  static Future<EmulatorAccountRuntime> configure({
    Set<String> enabledModules = const {'tasks'},
    LocalHomologationEnvironment environment = LocalHomologationEnvironment.demo,
    required FirebaseAuth auth,
    required FirebaseFirestore store,
    required int authPort,
    required int firestorePort,
    required Uri baseUri,
    required http.Client client,
    required Future<String?> Function() appCheckToken,
  }) async {
    environment.requireApp(auth.app);
    environment.requireApp(store.app);
    if (identical(environment, LocalHomologationEnvironment.nominal) &&
        (authPort != 45099 || firestorePort != 45089 || baseUri.toString() != 'http://127.0.0.1:45789')) {
      throw StateError('LOCAL_ENVIRONMENT_MISMATCH');
    }
    final modules = Set<String>.unmodifiable(enabledModules);
    if (modules.isEmpty || !moduleCollections.keys.toSet().containsAll(modules) ||
        auth.app.options.projectId != environment.projectId ||
        store.app.options.projectId != environment.projectId ||
        auth.app.name != store.app.name || store.databaseId != '(default)' ||
        auth.tenantId != null || baseUri.scheme != 'http' ||
        baseUri.host != '127.0.0.1' || baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery || baseUri.hasFragment || baseUri.path.isNotEmpty ||
        [authPort, firestorePort, baseUri.port].any((p) => p < 1 || p > 65535)) {
      throw StateError('EMULATOR_ACCOUNT_ENVIRONMENT_REQUIRED');
    }
    // SDK endpoints are selected before Auth IO. No Cloud credentials/config.
    await auth.useAuthEmulator('127.0.0.1', authPort, automaticHostMapping: false);
    store.useFirestoreEmulator('127.0.0.1', firestorePort, automaticHostMapping: false);
    final runtime = EmulatorAccountRuntime._(auth, store, baseUri, _LocalBackendClient(client, baseUri), appCheckToken, modules, environment);
    _configured[auth] = runtime;
    return runtime;
  }

  void requireClients(FirebaseAuth candidate, FirebaseFirestore database) {
    environment.requireApp(auth.app);
    environment.requireApp(store.app);
    if (!identical(candidate, auth) || !identical(database, store) ||
        auth.tenantId != null || auth.app.options.projectId != environment.projectId ||
        store.app.options.projectId != environment.projectId ||
        store.databaseId != '(default)') {
      throw StateError('EMULATOR_ACCOUNT_CLIENT_CHANGED');
    }
  }

  AccountDeletionRecovery deletionRecovery(
    LocalDatabaseIdentity identity,
    FlutterSecureStorage storage,
  ) {
    requireClients(auth, store);
    if (identity.projectId != environment.projectId || identity.databaseId != store.databaseId) {
      throw StateError('DELETION_RECOVERY_BINDING_INVALID');
    }
    return AccountDeletionRecovery(
      identity: identity,
      baseUri: baseUri,
      storage: storage,
      client: client,
      appCheckToken: appCheckToken,
      isSignedOut: () => auth.currentUser == null,
      authChanges: auth.authStateChanges,
      isOriginalSession: () async {
        final user = auth.currentUser;
        if (user == null || user.uid != identity.uid) return false;
        final claims = (await user.getIdTokenResult().timeout(const Duration(seconds: 15))).claims;
        return auth.currentUser?.uid == identity.uid &&
            claims?['sub'] == identity.uid && claims?['aud'] == identity.projectId &&
            claims?['iss'] == 'https://securetoken.google.com/${identity.projectId}' &&
            claims?['lifeos_generation'] == identity.generation;
      },
    );
  }

  Future<LocalDatabaseIdentity> admit(
    String uid, {
    Future<void> Function(LocalDatabaseIdentity)? beforeBootstrap,
  }) async {
    requireClients(auth, store);
    var current = true;
    var first = true;
    final subscription = auth.authStateChanges().listen((user) {
      if (!first || user?.uid != uid) current = false;
      first = false;
    }, onError: (Object _) {current = false;});
    void check() {
      requireClients(auth, store);
      if (!current || auth.currentUser?.uid != uid) {
        throw StateError('EMULATOR_ACCOUNT_SESSION_CHANGED');
      }
    }
    try {
      check();
      final original = auth.currentUser!;
      final claims = (await original.getIdTokenResult().timeout(const Duration(seconds:15))).claims;
      final generation = claims?['lifeos_generation'];
      check();
      if (claims?['sub'] != uid || claims?['aud'] != environment.projectId ||
          claims?['iss'] != 'https://securetoken.google.com/${environment.projectId}' ||
          generation is! String ||
          !RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$').hasMatch(generation)) {
        throw StateError('EMULATOR_ACCOUNT_TOKEN_BINDING_REQUIRED');
      }
      final identity = LocalDatabaseIdentity.bound(
        projectId: environment.projectId,
        databaseId: '(default)',
        uid: uid,
        generation: generation,
      );
      if (beforeBootstrap != null) {
        try {
          // This read may block admission. Token claims alone cannot grant it.
          await beforeBootstrap(identity);
        } finally {
          check();
        }
      }
      // RESERVED genesis cannot be read under ACTIVE-only prototype Rules.
      // Authenticate to the real bootstrap FIRST; it verifies R1 independently.
      // Decoded claims above are consistency checks and grant no admission.
      final token = await original.getIdToken().timeout(const Duration(seconds:15));
      String? appCheck;
      try { appCheck = await appCheckToken().timeout(const Duration(seconds:15)); }
      on TimeoutException { throw const TrustedAccountPending('APP_CHECK_TIMEOUT'); }
      catch (_) { throw const TrustedAccountPending('APP_CHECK_INVALID'); }
      check();
      if (token == null || token.isEmpty) throw const TrustedAccountPending('UNAUTHENTICATED');
      if (appCheck == null || appCheck.isEmpty) throw const TrustedAccountPending('APP_CHECK_REQUIRED');
      http.Response response;
      try { response = await client.post(baseUri.resolve('/api/account/bootstrap'),
          headers: {'Authorization':'Bearer $token','X-Firebase-AppCheck':appCheck,
            'Content-Type':'application/json'},body:'{}').timeout(const Duration(seconds:15));
      } on Exception { throw const TrustedAccountPending('EMULATOR_ACCOUNT_NETWORK_UNAVAILABLE'); }
      check();
      final body = jsonDecode(response.body);
      if (response.statusCode == 401) {
        final code = body is Map ? body['code'] : null;
        if (code == 'APP_CHECK_REQUIRED' || code == 'APP_CHECK_INVALID') {
          throw TrustedAccountPending(code as String);
        }
        throw const TrustedAccountPending('UNAUTHENTICATED');
      }
      if (response.statusCode != 200 || body is! Map ||
          body['state'] != 'READY' || body['generation'] != generation) {
        throw StateError('EMULATOR_ACCOUNT_PROVISIONING_UNCONFIRMED');
      }
      final confirmed = await TrustedAccountAccess.ensureReady(auth, store, uid,
          allowBootstrap:false);
      check();
      if (confirmed != generation) throw StateError('EMULATOR_ACCOUNT_GENERATION_CHANGED');
      return identity;
    } finally {
      await subscription.cancel();
    }
  }
}

// Every runtime request is loopback-bound and refuses redirects, including 307.
final class _LocalBackendClient extends http.BaseClient {
  _LocalBackendClient(this.inner, this.base);
  final http.Client inner;
  final Uri base;
  @override Future<http.StreamedResponse> send(http.BaseRequest request) {
    final uri=request.url;
    if(uri.scheme!='http'||uri.host!='127.0.0.1'||uri.port!=base.port||uri.userInfo.isNotEmpty||uri.hasQuery||uri.hasFragment||!uri.path.startsWith('/api/')) {
      throw StateError('LOCAL_ENVIRONMENT_MISMATCH');
    }
    request.followRedirects=false;
    return inner.send(request);
  }
  @override void close() => inner.close();
}

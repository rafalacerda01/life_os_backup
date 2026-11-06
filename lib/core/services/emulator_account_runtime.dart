import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import '../database/local_database_identity.dart';
import 'trusted_account_access.dart';

// Default is CLOSED. Only an explicitly configured loopback runtime enables
// the explicitly reviewed local module slices; never a production grant.
final emulatorAccountRuntimeProvider = Provider<EmulatorAccountRuntime?>((ref) => null);

/// Explicit local SDK configuration, never a build flag or production grant.
/// Only explicitly selected module slices are enabled after R1 admission.
/// Unreviewed consumers, deletion and production Auth remain CLOSED.
final class EmulatorAccountRuntime {
  EmulatorAccountRuntime._(this.auth, this.store, this.baseUri, this.client,
      this.appCheckToken, Set<String> modules) : enabledModules = Set.unmodifiable(modules);
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
    required FirebaseAuth auth,
    required FirebaseFirestore store,
    required int authPort,
    required int firestorePort,
    required Uri baseUri,
    required http.Client client,
    required Future<String?> Function() appCheckToken,
  }) async {
    final modules = Set<String>.unmodifiable(enabledModules);
    if (modules.isEmpty || !moduleCollections.keys.toSet().containsAll(modules) ||
        auth.app.options.projectId != 'demo-life-os' ||
        store.app.options.projectId != 'demo-life-os' ||
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
    return EmulatorAccountRuntime._(auth, store, baseUri, client, appCheckToken, modules);
  }

  void requireClients(FirebaseAuth candidate, FirebaseFirestore database) {
    if (!identical(candidate, auth) || !identical(database, store) ||
        auth.tenantId != null || auth.app.options.projectId != 'demo-life-os' ||
        store.app.options.projectId != 'demo-life-os' ||
        store.databaseId != '(default)') {
      throw StateError('EMULATOR_ACCOUNT_CLIENT_CHANGED');
    }
  }

  Future<LocalDatabaseIdentity> admit(String uid) async {
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
      final claims = (await original.getIdTokenResult()).claims;
      final generation = claims?['lifeos_generation'];
      check();
      if (claims?['sub'] != uid || claims?['aud'] != 'demo-life-os' ||
          claims?['iss'] != 'https://securetoken.google.com/demo-life-os' ||
          generation is! String ||
          !RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$').hasMatch(generation)) {
        throw StateError('EMULATOR_ACCOUNT_TOKEN_BINDING_REQUIRED');
      }
      // RESERVED genesis cannot be read under ACTIVE-only prototype Rules.
      // Authenticate to the real bootstrap FIRST; it verifies R1 independently.
      // Decoded claims above are consistency checks and grant no admission.
      final token = await original.getIdToken();
      final appCheck = await appCheckToken();
      check();
      if (token == null || appCheck == null) throw StateError('EMULATOR_ACCOUNT_TOKEN_REQUIRED');
      final response = await client.post(baseUri.resolve('/api/account/bootstrap'),
          headers: {'Authorization':'Bearer $token','X-Firebase-AppCheck':appCheck,
            'Content-Type':'application/json'},body:'{}').timeout(const Duration(seconds:15));
      check();
      final body = jsonDecode(response.body);
      if (response.statusCode != 200 || body is! Map ||
          body['state'] != 'READY' || body['generation'] != generation) {
        throw StateError('EMULATOR_ACCOUNT_PROVISIONING_UNCONFIRMED');
      }
      final confirmed = await TrustedAccountAccess.ensureReady(auth, store, uid,
          allowBootstrap:false);
      check();
      if (confirmed != generation) throw StateError('EMULATOR_ACCOUNT_GENERATION_CHANGED');
      return LocalDatabaseIdentity.bound(projectId:'demo-life-os',databaseId:'(default)',
          uid:uid,generation:generation);
    } finally {
      await subscription.cancel();
    }
  }
}

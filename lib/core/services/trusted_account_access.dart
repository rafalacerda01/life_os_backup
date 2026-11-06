import 'package:life_os/core/database/local_database_identity.dart';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class TrustedAccountPending implements Exception {
  const TrustedAccountPending(this.code);
  final String code;
  @override
  String toString() => code;
}

/// The token claim comes from Auth blocking creation. A UID or cached profile
/// never creates admission. Production configuration remains CLOSED.
abstract final class TrustedAccountAccess {
  // Requires verified SDK queue/session custody and the real cleanup bridge.
  // Namespaced local state alone grants no admission. No build flag opens this.
  static const localSessionClosed = true;
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static const _bootstrapUrl = String.fromEnvironment(
    'LIFE_OS_TRUSTED_BOOTSTRAP_URL',
  );

  static bool matchesReceipt(
    Map<String, dynamic>? value,
    String project,
    String uid,
    String generation,
  ) =>
      _uuid.hasMatch(generation) &&
      value?['version'] == 1 &&
      value?['projectId'] == project &&
      value?['databaseId'] == '(default)' &&
      value?['uid'] == uid &&
      value?['generation'] == generation &&
      value?['policy'] == 'AUTH_BLOCKING_GENESIS_V1' &&
      value?['state'] == 'ACTIVE';

  static Future<LocalDatabaseIdentity> admittedIdentity(
    FirebaseAuth auth,
    FirebaseFirestore store,
    String uid, {bool allowBootstrap = true}
  ) async {
    final generation = await ensureReady(auth, store, uid, allowBootstrap:allowBootstrap);
    return LocalDatabaseIdentity.bound(
      projectId: auth.app.options.projectId,
      databaseId: store.databaseId,
      uid: uid,
      generation: generation,
    );
  }

  static Future<String> ensureReady(
    FirebaseAuth auth,
    FirebaseFirestore store,
    String expectedUid, {
    bool allowBootstrap = true,
  }) async {
    final user = auth.currentUser;
    if (user == null || user.uid != expectedUid) {
      throw const TrustedAccountPending('UNAUTHENTICATED');
    }
    final project = auth.app.options.projectId;
    if (project != 'demo-life-os' ||
        store.app.options.projectId != project ||
        store.app.name != auth.app.name ||
        store.databaseId != '(default)') {
      throw const TrustedAccountPending('TRUSTED_ACCOUNT_CLOSED');
    }
    final token = await user.getIdTokenResult();
    final firebaseClaims = token.claims?['firebase'];
    if (token.claims?['aud'] != project ||
        token.claims?['iss'] != 'https://securetoken.google.com/$project' ||
        firebaseClaims is! Map ||
        firebaseClaims['tenant'] != null) {
      throw const TrustedAccountPending('TRUSTED_ACCOUNT_REVIEW_REQUIRED');
    }
    final generation = token.claims?['lifeos_generation'];
    if (generation is! String || !_uuid.hasMatch(generation)) {
      throw const TrustedAccountPending('TRUSTED_ACCOUNT_REVIEW_REQUIRED');
    }
    final origin = store.collection('trusted_account_origins').doc(expectedUid);
    DocumentSnapshot<Map<String, dynamic>> receipt;
    receipt = await _confirmedServerReceipt(origin);
    if (!matchesReceipt(receipt.data(), project, expectedUid, generation)) {
      if (!allowBootstrap) {
        throw const TrustedAccountPending('TRUSTED_ACCOUNT_REVIEW_REQUIRED');
      }
      final uri = Uri.tryParse(_bootstrapUrl);
      if (uri == null ||
          uri.scheme != 'http' ||
          !{'127.0.0.1', 'localhost', '10.0.2.2'}.contains(uri.host) ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          uri.hasQuery) {
        throw const TrustedAccountPending('TRUSTED_ACCOUNT_CLOSED');
      }
      final idToken = await user.getIdToken();
      final appCheck = await FirebaseAppCheck.instance.getToken();
      if (idToken == null || appCheck == null) {
        throw const TrustedAccountPending(
          'TRUSTED_ACCOUNT_PROVISIONING_PENDING',
        );
      }
      final response = await http
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $idToken',
              'X-Firebase-AppCheck': appCheck,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw const TrustedAccountPending(
          'TRUSTED_ACCOUNT_PROVISIONING_PENDING',
        );
      }
      receipt = await _confirmedServerReceipt(origin);
      if (!matchesReceipt(receipt.data(), project, expectedUid, generation)) {
        throw const TrustedAccountPending('TRUSTED_ACCOUNT_REVIEW_REQUIRED');
      }
    }
    final current = auth.currentUser;
    if (current == null ||
        current.uid != expectedUid ||
        (await current.getIdTokenResult()).claims?['lifeos_generation'] !=
            generation) {
      throw const TrustedAccountPending('UNAUTHENTICATED');
    }
    return generation;
  }

  static Future<DocumentSnapshot<Map<String, dynamic>>> _confirmedServerReceipt(
    DocumentReference<Map<String, dynamic>> origin,
  ) async {
    // An SDK cache entry is never a positive remote-admission proof. Offline
    // Drift work remains in its original generation; failure grants no ACK.
    final receipt = await origin.get(const GetOptions(source: Source.server));
    if (receipt.metadata.isFromCache || receipt.metadata.hasPendingWrites) {
      throw const TrustedAccountPending(
        'TRUSTED_ACCOUNT_SERVER_PROOF_REQUIRED',
      );
    }
    return receipt;
  }
}

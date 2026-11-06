import 'package:life_os/core/services/generational_read_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_account_session.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/core/storage/ai_consent_local_cache.dart';

typedef AiConsentUserIdProvider = String? Function();
typedef AiConsentDocumentProvider =
    DocumentReference<Map<String, dynamic>> Function(String userId);
typedef AiConsentCacheWrite = Future<bool> Function(String key, bool value);
typedef AiConsentCacheRemove = Future<bool> Function(String key);

class AiConsentNotifier extends AsyncNotifier<bool> {
  static const String _storageKeyPrefix = 'ai_consent_accepted_';
  static const String _consentVersion = '2.0';
  static const String _source = 'life_os_app';

  final bool _defaultWrite, _defaultRemove;
  final bool Function() _sessionCurrent;
  final AiConsentUserIdProvider _userIdProvider;
  final AiConsentDocumentProvider _documentProvider;
  final AiConsentCacheWrite _cacheWrite;
  final AiConsentCacheRemove _cacheRemove;

  AiConsentNotifier({
    LocalDatabaseIdentity? identity,
    bool Function()? sessionCurrent,
    AiConsentUserIdProvider? userIdProvider,
    AiConsentDocumentProvider? documentProvider,
    AiConsentCacheWrite? cacheWrite,
    AiConsentCacheRemove? cacheRemove,
  }) : _defaultWrite = cacheWrite == null && identity == null,
       _defaultRemove = cacheRemove == null && identity == null,
       _sessionCurrent = sessionCurrent ?? (() => true),
       _userIdProvider = userIdProvider ?? _firebaseUserId,
       _documentProvider = documentProvider ?? _firestoreConsentDocument,
       _cacheWrite =
           cacheWrite ??
           (identity == null
               ? _writeSharedPreferences
               : (key, value) => AiConsentLocalCache.instance.write(
                   key.substring(AiConsentLocalCache.keyPrefix.length),
                   identity: identity,
                 )),
       _cacheRemove =
           cacheRemove ??
           (identity == null
               ? _removeSharedPreferences
               : (key) => AiConsentLocalCache.instance.remove(
                   key.substring(AiConsentLocalCache.keyPrefix.length),
                   identity: identity,
                 ));

  String? get _currentUserId {
    final userId = _userIdProvider();

    if (userId == null || userId.isEmpty) {
      return null;
    }

    return userId;
  }

  void _requireSession(String userId, LocalAccountSessionSnapshot captured) {
    if (ref.read(localAccountSessionProvider).revision != captured.revision ||
        !_sessionCurrent() ||
        (captured.identity != null && captured.identity!.uid != userId))
      throw StateError('AI_CONSENT_SESSION_CHANGED');
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> _readConsent(
    DocumentReference<Map<String, dynamic>> document,
    LocalAccountSessionSnapshot captured,
  ) async {
    final identity = captured.identity;
    if (identity == null) return document.get();
    final snapshot = await document.get(
      GenerationalReadPolicy.options(identity, document.firestore),
    );
    if (!GenerationalReadPolicy.accepts(
      identity,
      fromCache: snapshot.metadata.isFromCache,
      pendingWrites: snapshot.metadata.hasPendingWrites,
    )) {
      throw StateError('GENERATIONAL_CONSENT_UNCONFIRMED');
    }
    return snapshot;
  }

  String _storageKeyFor(String userId) => '$_storageKeyPrefix$userId';

  @override
  Future<bool> build() async {
    final localSnapshot = ref.watch(localAccountSessionProvider);
    final userId = _currentUserId;

    // Sem usuário autenticado, não existe consentimento válido.
    if (userId == null) {
      return false;
    }
    final key = _storageKeyFor(userId);

    try {
      // O Firestore é a fonte oficial do consentimento.
      final snapshot = await _readConsent(
        _documentProvider(userId),
        localSnapshot,
      );
      _requireSession(userId, localSnapshot);

      if (snapshot.exists) {
        final data = snapshot.data();

        if (data?['accepted'] == true &&
            data?['consentVersion'] == _consentVersion) {
          _requireSession(userId, localSnapshot);
          await _writeLocalCache(key, identity: localSnapshot.identity);
          _requireSession(userId, localSnapshot);

          return true;
        }
      }

      // Se não existe consentimento válido no servidor,
      // o consentimento local também não deve ser considerado válido.
      _requireSession(userId, localSnapshot);
      await _removeLocalCache(key, identity: localSnapshot.identity);
      _requireSession(userId, localSnapshot);

      return false;
    } catch (_) {
      // Não confiar em um consentimento local caso o servidor
      // não possa ser consultado.
      throw Exception(
        'Não foi possível verificar o consentimento para uso da IA.',
      );
    }
  }

  Future<void> acceptConsent() async {
    final localSnapshot = ref.read(localAccountSessionProvider);
    state = const AsyncLoading();

    try {
      final userId = _currentUserId;

      if (userId == null) {
        throw Exception(
          'Não foi possível registrar o consentimento sem um usuário autenticado.',
        );
      }
      final key = _storageKeyFor(userId);

      final consentDocument = _documentProvider(userId);
      final snapshot = await _readConsent(consentDocument, localSnapshot);
      _requireSession(userId, localSnapshot);

      // ------------------------------------------------------------------
      // FIRESTORE — FONTE OFICIAL
      // ------------------------------------------------------------------
      //
      // O backend Vercel consulta exatamente este documento antes
      // de permitir que qualquer dado seja enviado para a IA.
      //
      if (snapshot.exists) {
        if (snapshot.data()?['accepted'] == true &&
            snapshot.data()?['consentVersion'] == _consentVersion) {
          _requireSession(userId, localSnapshot);
          await _writeLocalCache(key, identity: localSnapshot.identity);
          _requireSession(userId, localSnapshot);
          state = const AsyncData(true);
          return;
        }

        final now = FieldValue.serverTimestamp();
        await consentDocument.update({
          'accepted': true,
          'consentVersion': _consentVersion,
          'acceptedAt': now,
          'revokedAt': null,
          'updatedAt': now,
          'source': _source,
        });
      } else {
        final now = FieldValue.serverTimestamp();
        await consentDocument.set({
          'accepted': true,
          'userId': userId,
          'consentVersion': _consentVersion,
          'acceptedAt': now,
          'revokedAt': null,
          'updatedAt': now,
          'source': _source,
        });
      }

      // ------------------------------------------------------------------
      // STORAGE LOCAL — CACHE DA INTERFACE
      // ------------------------------------------------------------------

      _requireSession(userId, localSnapshot);
      await _writeLocalCache(key, identity: localSnapshot.identity);
      _requireSession(userId, localSnapshot);
      state = const AsyncData(true);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> revokeConsent() async {
    final localSnapshot = ref.read(localAccountSessionProvider);
    state = const AsyncLoading();

    try {
      final userId = _currentUserId;
      if (userId == null) {
        throw Exception(
          'Não foi possível revogar o consentimento sem um usuário autenticado.',
        );
      }
      final key = _storageKeyFor(userId);

      final consentDocument = _documentProvider(userId);
      final snapshot = await _readConsent(consentDocument, localSnapshot);
      _requireSession(userId, localSnapshot);
      if (!snapshot.exists) {
        throw Exception('Não existe consentimento ativo para revogar.');
      }

      final accepted = snapshot.data()?['accepted'];
      if (accepted == false) {
        _requireSession(userId, localSnapshot);
        await _removeLocalCache(key, identity: localSnapshot.identity);
        _requireSession(userId, localSnapshot);
        state = const AsyncData(false);
        return;
      }
      if (accepted != true) {
        throw Exception('Não existe consentimento ativo para revogar.');
      }

      final now = FieldValue.serverTimestamp();
      await consentDocument.update({
        'accepted': false,
        'revokedAt': now,
        'updatedAt': now,
      });

      _requireSession(userId, localSnapshot);
      await _removeLocalCache(key, identity: localSnapshot.identity);
      _requireSession(userId, localSnapshot);
      state = const AsyncData(false);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _writeLocalCache(
    String key, {
    LocalDatabaseIdentity? identity,
  }) async {
    try {
      final written = identity != null && _defaultWrite
          ? await AiConsentLocalCache.instance.write(
              identity.uid,
              identity: identity,
            )
          : await _cacheWrite(key, true);
      if (!written) {
        AppLogger.w('Falha ao atualizar cache local do consentimento da IA.');
      }
    } catch (_) {
      AppLogger.w('Falha ao atualizar cache local do consentimento da IA.');
    }
  }

  Future<void> _removeLocalCache(
    String key, {
    LocalDatabaseIdentity? identity,
  }) async {
    try {
      final removed = identity != null && _defaultRemove
          ? await AiConsentLocalCache.instance.remove(
              identity.uid,
              identity: identity,
            )
          : await _cacheRemove(key);
      if (!removed) {
        AppLogger.w('Falha ao remover cache local do consentimento da IA.');
      }
    } catch (_) {
      AppLogger.w('Falha ao remover cache local do consentimento da IA.');
    }
  }
}

String? _firebaseUserId() => FirebaseAuth.instance.currentUser?.uid;

DocumentReference<Map<String, dynamic>> _firestoreConsentDocument(
  String userId,
) => FirebaseFirestore.instance
    .collection('users')
    .doc(userId)
    .collection('privacy')
    .doc('ai_consent');

Future<bool> _writeSharedPreferences(String key, bool value) async {
  return AiConsentLocalCache.instance.write(
    key.substring(AiConsentLocalCache.keyPrefix.length),
  );
}

Future<bool> _removeSharedPreferences(String key) async {
  return AiConsentLocalCache.instance.remove(
    key.substring(AiConsentLocalCache.keyPrefix.length),
  );
}

final aiConsentProvider = AsyncNotifierProvider<AiConsentNotifier, bool>(
  () => AiConsentNotifier(),
);

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef AiConsentUserIdProvider = String? Function();
typedef AiConsentDocumentProvider =
    DocumentReference<Map<String, dynamic>> Function(String userId);
typedef AiConsentCacheWrite = Future<bool> Function(String key, bool value);
typedef AiConsentCacheRemove = Future<bool> Function(String key);

class AiConsentNotifier extends AsyncNotifier<bool> {
  static const String _storageKeyPrefix = 'ai_consent_accepted_';
  static const String _consentVersion = '1.0';
  static const String _source = 'life_os_app';

  final AiConsentUserIdProvider _userIdProvider;
  final AiConsentDocumentProvider _documentProvider;
  final AiConsentCacheWrite _cacheWrite;
  final AiConsentCacheRemove _cacheRemove;

  AiConsentNotifier({
    AiConsentUserIdProvider? userIdProvider,
    AiConsentDocumentProvider? documentProvider,
    AiConsentCacheWrite? cacheWrite,
    AiConsentCacheRemove? cacheRemove,
  }) : _userIdProvider = userIdProvider ?? _firebaseUserId,
       _documentProvider = documentProvider ?? _firestoreConsentDocument,
       _cacheWrite = cacheWrite ?? _writeSharedPreferences,
       _cacheRemove = cacheRemove ?? _removeSharedPreferences;

  String? get _currentUserId {
    final userId = _userIdProvider();

    if (userId == null || userId.isEmpty) {
      return null;
    }

    return userId;
  }

  String _storageKeyFor(String userId) => '$_storageKeyPrefix$userId';

  @override
  Future<bool> build() async {
    final userId = _currentUserId;

    // Sem usuário autenticado, não existe consentimento válido.
    if (userId == null) {
      return false;
    }
    final key = _storageKeyFor(userId);

    try {
      // O Firestore é a fonte oficial do consentimento.
      final snapshot = await _documentProvider(userId).get();

      if (snapshot.exists) {
        final data = snapshot.data();

        if (data?['accepted'] == true) {
          await _writeLocalCache(key);

          return true;
        }
      }

      // Se não existe consentimento válido no servidor,
      // o consentimento local também não deve ser considerado válido.
      await _removeLocalCache(key);

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
      final snapshot = await consentDocument.get();

      // ------------------------------------------------------------------
      // FIRESTORE — FONTE OFICIAL
      // ------------------------------------------------------------------
      //
      // O backend Vercel consulta exatamente este documento antes
      // de permitir que qualquer dado seja enviado para a IA.
      //
      if (snapshot.exists) {
        if (snapshot.data()?['accepted'] == true) {
          await _writeLocalCache(key);
          state = const AsyncData(true);
          return;
        }

        final now = FieldValue.serverTimestamp();
        await consentDocument.update({
          'accepted': true,
          'acceptedAt': now,
          'revokedAt': null,
          'updatedAt': now,
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

      await _writeLocalCache(key);
      state = const AsyncData(true);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> revokeConsent() async {
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
      final snapshot = await consentDocument.get();
      if (!snapshot.exists) {
        throw Exception('Não existe consentimento ativo para revogar.');
      }

      final accepted = snapshot.data()?['accepted'];
      if (accepted == false) {
        await _removeLocalCache(key);
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

      await _removeLocalCache(key);
      state = const AsyncData(false);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _writeLocalCache(String key) async {
    try {
      final written = await _cacheWrite(key, true);
      if (!written) {
        AppLogger.w('Falha ao atualizar cache local do consentimento da IA.');
      }
    } catch (_) {
      AppLogger.w('Falha ao atualizar cache local do consentimento da IA.');
    }
  }

  Future<void> _removeLocalCache(String key) async {
    try {
      final removed = await _cacheRemove(key);
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
  final prefs = await SharedPreferences.getInstance();
  return prefs.setBool(key, value);
}

Future<bool> _removeSharedPreferences(String key) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.remove(key);
}

final aiConsentProvider = AsyncNotifierProvider<AiConsentNotifier, bool>(
  AiConsentNotifier.new,
);

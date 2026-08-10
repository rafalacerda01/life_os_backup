import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AiConsentNotifier extends AsyncNotifier<bool> {
  static const String _storageKeyPrefix = 'ai_consent_accepted_';

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String? get _currentUserId {
    final user = _auth.currentUser;

    if (user == null || user.uid.isEmpty) {
      return null;
    }

    return user.uid;
  }

  String? get _storageKey {
    final userId = _currentUserId;

    if (userId == null) {
      return null;
    }

    return '$_storageKeyPrefix$userId';
  }

  DocumentReference<Map<String, dynamic>>? get _consentDocument {
    final userId = _currentUserId;

    if (userId == null) {
      return null;
    }

    return _firestore
        .collection('users')
        .doc(userId)
        .collection('privacy')
        .doc('ai_consent');
  }

  @override
  Future<bool> build() async {
    final userId = _currentUserId;
    final key = _storageKey;
    final consentDocument = _consentDocument;

    // Sem usuário autenticado, não existe consentimento válido.
    if (userId == null || key == null || consentDocument == null) {
      return false;
    }

    try {
      // O Firestore é a fonte oficial do consentimento.
      final snapshot = await consentDocument.get();

      if (snapshot.exists) {
        final data = snapshot.data();

        if (data?['accepted'] == true) {
          // Mantém o estado local sincronizado.
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(key, true);

          return true;
        }
      }

      // Se não existe consentimento válido no servidor,
      // o consentimento local também não deve ser considerado válido.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);

      return false;
    } catch (e) {
      // Não confiar em um consentimento local caso o servidor
      // não possa ser consultado.
      throw Exception(
        'Não foi possível verificar o consentimento para uso da IA.',
      );
    }
  }

  Future<void> acceptConsent() async {
    state = const AsyncLoading();

    state = await AsyncValue.guard(() async {
      final user = _auth.currentUser;
      final key = _storageKey;
      final consentDocument = _consentDocument;

      if (user == null ||
          user.uid.isEmpty ||
          key == null ||
          consentDocument == null) {
        throw Exception(
          'Não foi possível registrar o consentimento sem um usuário autenticado.',
        );
      }

      final now = FieldValue.serverTimestamp();

      // ------------------------------------------------------------------
      // FIRESTORE — FONTE OFICIAL
      // ------------------------------------------------------------------
      //
      // O backend Vercel consulta exatamente este documento antes
      // de permitir que qualquer dado seja enviado para a IA.
      //
      await consentDocument.set({
        'accepted': true,
        'userId': user.uid,
        'consentVersion': '1.0',
        'acceptedAt': now,
        'updatedAt': now,
        'source': 'life_os_app',
      }, SetOptions(merge: true));

      // ------------------------------------------------------------------
      // STORAGE LOCAL — CACHE DA INTERFACE
      // ------------------------------------------------------------------

      final prefs = await SharedPreferences.getInstance();

      final success = await prefs.setBool(key, true);

      if (!success) {
        throw Exception(
          'O consentimento foi registrado no servidor, '
          'mas não foi possível atualizar o armazenamento local.',
        );
      }

      return true;
    });
  }
}

final aiConsentProvider = AsyncNotifierProvider<AiConsentNotifier, bool>(
  AiConsentNotifier.new,
);

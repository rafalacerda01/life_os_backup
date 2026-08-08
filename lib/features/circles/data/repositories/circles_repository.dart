import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/circles/domain/entities/circle_entity.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';

final circlesRepositoryProvider = Provider(
  (ref) => CirclesRepository(FirebaseFirestore.instance, FirebaseAuth.instance),
);

class CirclesRepository {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  CirclesRepository(this._firestore, this._auth);

  Future<String?> getUserActiveCircleId() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    final doc = await _firestore.collection('users').doc(user.uid).get();
    return doc.data()?['activeCircleId'] as String?;
  }

  Stream<CircleEntity?> getCircleStream(String circleId) {
    return _firestore.collection('circles').doc(circleId).snapshots().asyncMap((
      doc,
    ) async {
      if (!doc.exists) return null;
      final data = doc.data() as Map<String, dynamic>;
      final currentUserUid = _auth.currentUser?.uid;

      // Busca Ranking - ORDENADO por XP (do maior pro menor)
      final rankingSnapshot = await _firestore
          .collection('circles')
          .doc(circleId)
          .collection('ranking')
          .orderBy('totalXp', descending: true)
          .get();

      // Mapeia o ranking usando o índice (index) para gerar a posição dinamicamente
      final ranking = rankingSnapshot.docs.asMap().entries.map((entry) {
        final index = entry.key;
        final d = entry.value;
        final r = d.data();

        return RankingMemberEntity(
          userId: d.id,
          name: r['name'] ?? 'Usuário',
          totalXp: r['totalXp'] ?? 0,
          rankPosition: index + 1,
          isCurrentUser: d.id == currentUserUid,
          photoUrl: r['photoUrl'],
        );
      }).toList();

      // Busca Desafios
      final challengesSnapshot = await _firestore
          .collection('circles')
          .doc(circleId)
          .collection('challenges')
          .get();

      final challenges = challengesSnapshot.docs.map((d) {
        final c = d.data();
        return ChallengeEntity(
          id: d.id,
          title: c['title'] ?? '',
          targetXp: c['targetXp'] ?? 0,
          currentXpContributed: c['currentXpContributed'] ?? 0,
          createdBy: c['createdBy'] ?? '',
        );
      }).toList();

      return CircleEntity(
        id: doc.id,
        name: data['name'] ?? '',
        description: data['description'] ?? '',
        adminId: data['adminId'] ?? '',
        memberCount: data['memberCount'] ?? 0,
        ranking: ranking,
        activeChallenges: challenges,
      );
    });
  }

  Future<void> createChallenge({
    required String circleId,
    required String title,
    required int targetXp,
    required String adminId,
  }) async {
    final batch = _firestore.batch();

    final challengeRef = _firestore
        .collection('circles')
        .doc(circleId)
        .collection('challenges')
        .doc();

    final circleRef = _firestore.collection('circles').doc(circleId);

    batch.set(challengeRef, {
      'title': title,
      'targetXp': targetXp,
      'currentXpContributed': 0,
      'createdBy': adminId,
      'createdAt': FieldValue.serverTimestamp(),
    });

    batch.update(circleRef, {'updatedAt': FieldValue.serverTimestamp()});

    await batch.commit();
  }

  Future<void> contributeXp(
    String circleId,
    String challengeId,
    int xpAmount,
  ) async {
    final userId = _auth.currentUser?.uid;

    // CORREÇÃO: Usando Exception nativa do Dart para não quebrar por falta de import
    if (userId == null) throw Exception('Unauthorized: User not logged in');

    final batch = _firestore.batch();

    final rankingRef = _firestore
        .collection('circles')
        .doc(circleId)
        .collection('ranking')
        .doc(userId);
    final challengeRef = _firestore
        .collection('circles')
        .doc(circleId)
        .collection('challenges')
        .doc(challengeId);

    // 1. Atualiza XP no Ranking do Membro
    batch.update(rankingRef, {
      'totalXp': FieldValue.increment(xpAmount),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    // 2. Atualiza XP no Challenge
    batch.update(challengeRef, {
      'currentXpContributed': FieldValue.increment(xpAmount),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    // ========================================================================
    // CORREÇÃO DE SEGURANÇA MANTIDA:
    // A atualização do documento raiz do Circle continua REMOVIDA deste batch
    // para não causar bloqueio de permissão para membros comuns.
    // ========================================================================

    await batch.commit();
  }

  Future<String> createCircle(String name, String description) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception("Usuário não autenticado");

    // Busca o nome real do usuário no Firestore para evitar salvar vazio
    final userDoc = await _firestore.collection('users').doc(user.uid).get();
    final userName =
        userDoc.data()?['displayName'] ?? user.displayName ?? 'Usuário';

    final batch = _firestore.batch();
    final circleRef = _firestore.collection('circles').doc();
    final userRef = _firestore.collection('users').doc(user.uid);

    batch.set(circleRef, {
      'name': name,
      'description': description,
      'adminId': user.uid,
      'memberCount': 1,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    batch.set(circleRef.collection('ranking').doc(user.uid), {
      'name': userName,
      'totalXp': 0,
      'photoUrl': user.photoURL,
    });

    batch.set(userRef, {
      'activeCircleId': circleRef.id,
    }, SetOptions(merge: true));

    await batch.commit();
    return circleRef.id;
  }

  Future<void> deleteCircle(String circleId) async {
    final batch = _firestore.batch();
    final circleRef = _firestore.collection('circles').doc(circleId);

    final rankingSnapshot = await circleRef.collection('ranking').get();
    for (var doc in rankingSnapshot.docs) batch.delete(doc.reference);

    final challengesSnapshot = await circleRef.collection('challenges').get();
    for (var doc in challengesSnapshot.docs) batch.delete(doc.reference);

    batch.delete(circleRef);

    final user = _auth.currentUser;
    if (user != null) {
      final userRef = _firestore.collection('users').doc(user.uid);
      batch.set(userRef, {'activeCircleId': null}, SetOptions(merge: true));
    }

    await batch.commit();
  }

  Future<void> leaveCircle(String circleId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final batch = _firestore.batch();
    final circleRef = _firestore.collection('circles').doc(circleId);
    final rankingRef = circleRef.collection('ranking').doc(user.uid);
    final userRef = _firestore.collection('users').doc(user.uid);

    batch.delete(rankingRef);

    batch.update(circleRef, {
      'memberCount': FieldValue.increment(-1),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    batch.update(userRef, {'activeCircleId': null});

    await batch.commit();
  }

  Future<void> joinCircleByCode(String circleId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception("Usuário não autenticado");

    final cleanCircleId = circleId.trim();

    // 1. Buscamos as informações do usuário atual (Fora da transação para otimizar velocidade)
    final userDoc = await _firestore.collection('users').doc(user.uid).get();
    final bool isPremium = userDoc.data()?['isPremium'] ?? false;
    final userName =
        userDoc.data()?['displayName'] ?? user.displayName ?? 'Usuário';

    final circleRef = _firestore.collection('circles').doc(cleanCircleId);
    final rankingRef = circleRef.collection('ranking').doc(user.uid);
    final userRef = _firestore.collection('users').doc(user.uid);

    // 🚀 CÓDIGO ALTERADO: Executando dentro de uma Transação Atômica do Firestore
    await _firestore.runTransaction((transaction) async {
      // 2. Lê o círculo DE DENTRO da transação (Garante que estamos vendo o dado mais recente)
      final circleSnap = await transaction.get(circleRef);

      if (!circleSnap.exists) {
        throw Exception("Círculo não encontrado! Verifique o código.");
      }

      final data = circleSnap.data() as Map<String, dynamic>;
      final int currentMemberCount = data['memberCount'] ?? 0;
      final int limit = isPremium ? 10 : 3;

      // 3. Validação de bloqueio. Se a regra quebrar, a transação é cancelada.
      if (currentMemberCount >= limit) {
        throw Exception(
          isPremium
              ? "Este círculo atingiu o limite de 10 membros."
              : "Limite de 3 membros atingido. Assine o Premium para expandir para 10!",
        );
      }

      // 4. Executamos as escritas garantindo a integridade dos dados
      transaction.set(rankingRef, {
        'name': userName,
        'totalXp': 0,
        'photoUrl': user.photoURL,
      });

      // Como estamos numa transação, podemos somar matematicamente com precisão
      transaction.update(circleRef, {
        'memberCount': currentMemberCount + 1,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      transaction.set(userRef, {
        'activeCircleId': cleanCircleId,
      }, SetOptions(merge: true));
    });
  }
}

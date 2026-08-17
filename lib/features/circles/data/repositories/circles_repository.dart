import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';
import 'package:life_os/features/circles/domain/entities/circle_entity.dart';

final circlesRepositoryProvider = Provider(
  (ref) => CirclesRepository(FirebaseFirestore.instance, FirebaseAuth.instance),
);

class CirclesRepository {
  static const int _schemaVersion = 2;
  static const int _freeMemberLimit = 3;
  static const int _premiumMemberLimit = 10;
  static const int _maxCircleNameLength = 100;
  static const int _maxCircleDescriptionLength = 500;
  static const int _maxChallengeTitleLength = 200;
  static const int _maxChallengeTargetValue = 1000000;
  static const int _maxMemberNameLength = 50;
  static const int _maxPhotoUrlLength = 2048;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  CirclesRepository(this._firestore, this._auth);

  String _normalizeMemberName(Object? value, String? fallbackValue) {
    final normalized = value is String ? value.trim() : '';
    final fallback = fallbackValue?.trim() ?? '';
    final selected = normalized.isNotEmpty
        ? normalized
        : fallback.isNotEmpty
        ? fallback
        : 'Usuário';

    return selected.length <= _maxMemberNameLength
        ? selected
        : selected.substring(0, _maxMemberNameLength);
  }

  String? _normalizePhotoUrl(Object? value, String? fallbackValue) {
    final selected = value is String ? value.trim() : fallbackValue?.trim();
    if (selected == null || selected.isEmpty) return null;
    return selected.length <= _maxPhotoUrlLength
        ? selected
        : selected.substring(0, _maxPhotoUrlLength);
  }

  DateTime? _readTimestamp(Object? value) {
    return value is Timestamp ? value.toDate() : null;
  }

  Future<String?> getUserActiveCircleId() async {
    final user = _auth.currentUser;
    if (user == null) return null;

    final doc = await _firestore.collection('users').doc(user.uid).get();
    final activeCircleId = doc.data()?['activeCircleId'];
    return activeCircleId is String && activeCircleId.isNotEmpty
        ? activeCircleId
        : null;
  }

  Stream<CircleEntity?> getCircleStream(String circleId) {
    final circleRef = _firestore.collection('circles').doc(circleId);
    StreamSubscription? circleSubscription;
    StreamSubscription? membersSubscription;
    StreamSubscription? challengesSubscription;
    final progressSubscriptions = <String, StreamSubscription>{};
    var isReloading = false;
    var reloadPending = false;

    late final StreamController<CircleEntity?> controller;

    void emitError(Object error, StackTrace stackTrace) {
      if (!controller.isClosed) {
        controller.addError(error, stackTrace);
      }
    }

    Future<void> reload() async {
      if (isReloading) {
        reloadPending = true;
        return;
      }

      isReloading = true;
      try {
        do {
          reloadPending = false;
          final circle = await _loadCircle(circleId);
          if (!controller.isClosed) controller.add(circle);
        } while (reloadPending && !controller.isClosed);
      } catch (error, stackTrace) {
        emitError(error, stackTrace);
      } finally {
        isReloading = false;
      }
    }

    Future<void> cancelNestedSubscriptions() async {
      await membersSubscription?.cancel();
      await challengesSubscription?.cancel();
      membersSubscription = null;
      challengesSubscription = null;

      for (final subscription in progressSubscriptions.values) {
        await subscription.cancel();
      }
      progressSubscriptions.clear();
    }

    Future<void> syncProgressSubscriptions(
      QuerySnapshot<Map<String, dynamic>> snapshot,
    ) async {
      final challengeIds = snapshot.docs.map((doc) => doc.id).toSet();
      final removedIds = progressSubscriptions.keys
          .where((id) => !challengeIds.contains(id))
          .toList();

      for (final id in removedIds) {
        await progressSubscriptions.remove(id)?.cancel();
      }

      for (final challengeDoc in snapshot.docs) {
        if (progressSubscriptions.containsKey(challengeDoc.id)) continue;

        progressSubscriptions[challengeDoc.id] = challengeDoc.reference
            .collection('progress')
            .snapshots()
            .listen(
              (_) => reload(),
              onError: (Object error, StackTrace stackTrace) {
                emitError(error, stackTrace);
              },
            );
      }

      await reload();
    }

    Future<void> ensureNestedSubscriptions() async {
      if (membersSubscription != null) return;

      membersSubscription = circleRef
          .collection('members')
          .snapshots()
          .listen(
            (_) => reload(),
            onError: (Object error, StackTrace stackTrace) {
              emitError(error, stackTrace);
            },
          );

      challengesSubscription = circleRef
          .collection('challenges')
          .snapshots()
          .listen(
            (snapshot) async {
              await syncProgressSubscriptions(snapshot);
            },
            onError: (Object error, StackTrace stackTrace) {
              emitError(error, stackTrace);
            },
          );
    }

    controller = StreamController<CircleEntity?>(
      onListen: () {
        circleSubscription = circleRef.snapshots().listen(
          (snapshot) async {
            final data = snapshot.data();
            if (!snapshot.exists ||
                data == null ||
                data['schemaVersion'] != _schemaVersion) {
              await cancelNestedSubscriptions();
              if (snapshot.exists) {
                AppLogger.w(
                  'Circle $circleId ignorado: schemaVersion incompatível.',
                );
              }
              if (!controller.isClosed) controller.add(null);
              return;
            }

            await ensureNestedSubscriptions();
            await reload();
          },
          onError: (Object error, StackTrace stackTrace) {
            emitError(error, stackTrace);
          },
        );
      },
      onCancel: () async {
        await circleSubscription?.cancel();
        await cancelNestedSubscriptions();
      },
    );

    return controller.stream;
  }

  Future<CircleEntity?> _loadCircle(String circleId) async {
    final circleRef = _firestore.collection('circles').doc(circleId);
    final doc = await circleRef.get();
    final data = doc.data();
    if (!doc.exists || data == null) return null;

    if (data['schemaVersion'] != _schemaVersion) {
      AppLogger.w('Circle $circleId ignorado: schemaVersion incompatível.');
      return null;
    }

    final name = data['name'];
    final description = data['description'];
    final adminId = data['adminId'];
    final memberCount = data['memberCount'];
    final memberLimit = data['memberLimit'];
    if (name is! String ||
        description is! String ||
        adminId is! String ||
        memberCount is! int ||
        memberLimit is! int) {
      AppLogger.w('Circle $circleId ignorado: dados inválidos.');
      return null;
    }

    final membersSnapshot = await circleRef.collection('members').get();
    final members = <CircleMemberEntity>[];

    for (final memberDoc in membersSnapshot.docs) {
      final memberData = memberDoc.data();
      final role = CircleMemberRole.fromValue(memberData['role']);
      final joinedAt = _readTimestamp(memberData['joinedAt']);
      final displayName = memberData['displayNameSnapshot'];
      final photoUrl = memberData['photoUrlSnapshot'];

      if (role == null ||
          joinedAt == null ||
          displayName is! String ||
          (photoUrl != null && photoUrl is! String)) {
        AppLogger.w(
          'Membro ${memberDoc.id} ignorado no Circle $circleId: dados inválidos.',
        );
        continue;
      }

      members.add(
        CircleMemberEntity(
          userId: memberDoc.id,
          displayName: displayName,
          photoUrl: photoUrl as String?,
          role: role,
          joinedAt: joinedAt,
        ),
      );
    }

    final challengesSnapshot = await circleRef.collection('challenges').get();
    final challenges = <ChallengeEntity>[];

    for (final challengeDoc in challengesSnapshot.docs) {
      final challengeData = challengeDoc.data();
      if (challengeData['schemaVersion'] != _schemaVersion) {
        AppLogger.w(
          'Challenge ${challengeDoc.id} ignorado: schemaVersion incompatível.',
        );
        continue;
      }

      final type = ChallengeType.fromValue(challengeData['type']);
      final title = challengeData['title'];
      final targetValue = challengeData['targetValue'];
      final startAt = _readTimestamp(challengeData['startAt']);
      final endAt = _readTimestamp(challengeData['endAt']);
      final createdBy = challengeData['createdBy'];
      final createdAt = _readTimestamp(challengeData['createdAt']);
      final updatedAt = _readTimestamp(challengeData['updatedAt']);

      if (type == null ||
          title is! String ||
          targetValue is! int ||
          startAt == null ||
          endAt == null ||
          createdBy is! String ||
          createdAt == null ||
          updatedAt == null) {
        AppLogger.w('Challenge ${challengeDoc.id} ignorado: dados inválidos.');
        continue;
      }

      final progressSnapshot = await challengeDoc.reference
          .collection('progress')
          .get();
      final progress = <ChallengeProgressEntity>[];

      for (final progressDoc in progressSnapshot.docs) {
        final progressData = progressDoc.data();
        final value = progressData['value'];
        final updatedAt = _readTimestamp(progressData['updatedAt']);
        final lastEventAt = _readTimestamp(progressData['lastEventAt']);

        if (value is! int || value < 0) {
          AppLogger.w(
            'Progresso ${progressDoc.id} ignorado no Challenge ${challengeDoc.id}.',
          );
          continue;
        }

        progress.add(
          ChallengeProgressEntity(
            userId: progressDoc.id,
            value: value,
            updatedAt: updatedAt,
            lastEventAt: lastEventAt,
          ),
        );
      }

      challenges.add(
        ChallengeEntity(
          id: challengeDoc.id,
          type: type,
          title: title,
          targetValue: targetValue,
          startAt: startAt,
          endAt: endAt,
          createdBy: createdBy,
          createdAt: createdAt,
          updatedAt: updatedAt,
          schemaVersion: _schemaVersion,
          progress: progress,
        ),
      );
    }

    challenges.sort((a, b) => b.startAt.compareTo(a.startAt));

    return CircleEntity(
      id: doc.id,
      name: name,
      description: description,
      adminId: adminId,
      memberCount: memberCount,
      memberLimit: memberLimit,
      schemaVersion: _schemaVersion,
      members: members,
      challenges: challenges,
    );
  }

  Future<void> createChallenge({
    required String circleId,
    required String title,
    required ChallengeType type,
    required int targetValue,
    required DateTime endAt,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuário não autenticado');

    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty || cleanTitle.length > _maxChallengeTitleLength) {
      throw ArgumentError('Título do desafio inválido');
    }
    if (targetValue <= 0 || targetValue > _maxChallengeTargetValue) {
      throw ArgumentError('Meta do desafio inválida');
    }

    final now = DateTime.now();
    if (!endAt.isAfter(now) ||
        endAt.isAfter(now.add(const Duration(days: 365)))) {
      throw ArgumentError('Data final do desafio inválida');
    }

    final batch = _firestore.batch();
    final circleRef = _firestore.collection('circles').doc(circleId);
    final challengeRef = circleRef.collection('challenges').doc();

    batch.set(challengeRef, {
      'type': type.value,
      'title': cleanTitle,
      'targetValue': targetValue,
      'startAt': FieldValue.serverTimestamp(),
      'endAt': Timestamp.fromDate(endAt),
      'createdBy': user.uid,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'schemaVersion': _schemaVersion,
    });

    batch.update(circleRef, {'updatedAt': FieldValue.serverTimestamp()});
    await batch.commit();
  }

  Future<String> createCircle(String name, String description) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuário não autenticado');

    final cleanName = name.trim();
    final cleanDescription = description.trim();
    if (cleanName.isEmpty || cleanName.length > _maxCircleNameLength) {
      throw ArgumentError('Nome do círculo inválido');
    }
    if (cleanDescription.isEmpty ||
        cleanDescription.length > _maxCircleDescriptionLength) {
      throw ArgumentError('Descrição do círculo inválida');
    }

    final userDoc = await _firestore.collection('users').doc(user.uid).get();
    final userData = userDoc.data();
    if (userData == null) throw StateError('Perfil do usuário não encontrado');
    if (userData['activeCircleId'] != null) {
      throw StateError('Usuário já participa de um círculo');
    }

    final memberLimit = userData['isPremium'] == true
        ? _premiumMemberLimit
        : _freeMemberLimit;
    final displayName = _normalizeMemberName(
      userData['displayName'],
      user.displayName,
    );
    final photoUrl = _normalizePhotoUrl(userData['photoUrl'], user.photoURL);

    final batch = _firestore.batch();
    final circleRef = _firestore.collection('circles').doc();
    final userRef = _firestore.collection('users').doc(user.uid);
    final memberRef = circleRef.collection('members').doc(user.uid);

    batch.set(circleRef, {
      'name': cleanName,
      'description': cleanDescription,
      'adminId': user.uid,
      'memberCount': 1,
      'memberLimit': memberLimit,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'schemaVersion': _schemaVersion,
    });

    batch.set(memberRef, {
      'role': CircleMemberRole.admin.value,
      'displayNameSnapshot': displayName,
      'photoUrlSnapshot': photoUrl,
      'joinedAt': FieldValue.serverTimestamp(),
    });

    batch.update(userRef, {'activeCircleId': circleRef.id});

    await batch.commit();
    return circleRef.id;
  }

  Future<void> deleteCircle(String circleId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuário não autenticado');

    final circleRef = _firestore.collection('circles').doc(circleId);
    final challengesSnapshot = await circleRef.collection('challenges').get();
    final batch = _firestore.batch();

    for (final doc in challengesSnapshot.docs) {
      batch.delete(doc.reference);
    }

    batch.delete(circleRef.collection('members').doc(user.uid));
    batch.delete(circleRef);
    batch.update(_firestore.collection('users').doc(user.uid), {
      'activeCircleId': null,
    });

    await batch.commit();
  }

  Future<void> leaveCircle(String circleId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuário não autenticado');

    final batch = _firestore.batch();
    final circleRef = _firestore.collection('circles').doc(circleId);

    batch.delete(circleRef.collection('members').doc(user.uid));
    batch.update(circleRef, {
      'memberCount': FieldValue.increment(-1),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    batch.update(_firestore.collection('users').doc(user.uid), {
      'activeCircleId': null,
    });

    await batch.commit();
  }

  Future<void> joinCircleByCode(String circleId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuário não autenticado');

    final cleanCircleId = circleId.trim();
    if (cleanCircleId.isEmpty) {
      throw ArgumentError('Código do círculo inválido');
    }

    final userDoc = await _firestore.collection('users').doc(user.uid).get();
    final userData = userDoc.data();
    if (userData == null) throw StateError('Perfil do usuário não encontrado');
    if (userData['activeCircleId'] != null) {
      throw StateError('Usuário já participa de um círculo');
    }

    final displayName = _normalizeMemberName(
      userData['displayName'],
      user.displayName,
    );
    final photoUrl = _normalizePhotoUrl(userData['photoUrl'], user.photoURL);
    final circleRef = _firestore.collection('circles').doc(cleanCircleId);
    final memberRef = circleRef.collection('members').doc(user.uid);
    final userRef = _firestore.collection('users').doc(user.uid);

    await _firestore.runTransaction((transaction) async {
      final circleSnap = await transaction.get(circleRef);
      final memberSnap = await transaction.get(memberRef);

      if (!circleSnap.exists) {
        throw Exception('Círculo não encontrado! Verifique o código.');
      }
      if (memberSnap.exists) {
        throw StateError('Usuário já participa deste círculo');
      }

      final data = circleSnap.data() as Map<String, dynamic>;
      if (data['schemaVersion'] != _schemaVersion) {
        throw StateError('Este círculo usa uma versão incompatível');
      }

      final memberCount = data['memberCount'];
      final memberLimit = data['memberLimit'];
      if (memberCount is! int ||
          memberCount < 1 ||
          memberLimit is! int ||
          (memberLimit != _freeMemberLimit &&
              memberLimit != _premiumMemberLimit)) {
        throw StateError('Dados de capacidade do círculo inválidos');
      }
      if (memberCount >= memberLimit) {
        throw StateError(
          'Este círculo atingiu o limite de $memberLimit membros.',
        );
      }

      transaction.set(memberRef, {
        'role': CircleMemberRole.member.value,
        'displayNameSnapshot': displayName,
        'photoUrlSnapshot': photoUrl,
        'joinedAt': FieldValue.serverTimestamp(),
      });
      transaction.update(circleRef, {
        'memberCount': memberCount + 1,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      transaction.update(userRef, {'activeCircleId': cleanCircleId});
    });
  }
}

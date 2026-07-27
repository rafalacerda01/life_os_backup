import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../data/models/notification_model.dart';

/// Provider reativo para listar notificações em tempo real com segurança
final notificationsProvider = StreamProvider.autoDispose<List<NotificationModel>>((
  ref,
) {
  final user = FirebaseAuth.instance.currentUser;

  // Se o usuário não estiver autenticado, retorna uma lista vazia de forma segura
  if (user == null) {
    return Stream.value([]);
  }

  try {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((doc) => NotificationModel.fromFirestore(doc))
              .toList(),
        )
        .handleError((error, stackTrace) {
          // Em ambiente de produção, aqui você pode integrar com Crashlytics
          // Retorna lista vazia em caso de falha na stream para não quebrar a UI
          return <NotificationModel>[];
        });
  } catch (e) {
    return Stream.value([]);
  }
});

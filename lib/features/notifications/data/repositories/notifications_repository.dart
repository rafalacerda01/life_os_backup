import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/notifications/data/models/notification_model.dart';

class NotificationsRepository {
  final FirebaseFirestore firestore;

  NotificationsRepository({FirebaseFirestore? firestore})
    : firestore = firestore ?? FirebaseFirestore.instance;

  Stream<List<NotificationModel>> getNotificationsStream() {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Stream.value([]);
    }

    try {
      return firestore
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
            AppLogger.e('Erro na stream de notificações', error, stackTrace);
            return <NotificationModel>[];
          });
    } catch (e, stack) {
      AppLogger.e('Erro ao inicializar stream de notificações', e, stack);
      return Stream.value([]);
    }
  }
}

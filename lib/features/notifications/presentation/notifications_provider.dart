import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../data/models/notification_model.dart';

final notificationsProvider =
    StreamProvider.autoDispose<List<NotificationModel>>((ref) {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return Stream.value([]);

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
          );
    });

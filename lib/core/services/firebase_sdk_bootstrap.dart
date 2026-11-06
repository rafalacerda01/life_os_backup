import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

/// Bootstrap-only configuration, before providers/Firestore IO exist.
/// Memory cache still has a mutation queue. This grants no generation authority,
/// cancels no pending writes and never clears a legacy persistent store.
FirebaseFirestore configureFirestoreMemoryCache(FirebaseApp app) {
  final store = FirebaseFirestore.instanceFor(app: app);
  store.settings = const Settings(persistenceEnabled: false);
  return store;
}

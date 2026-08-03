import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Opções padrão do Firebase geradas para inicialização multiplataforma.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions não estão configuradas para esta plataforma.',
        );
    }
  }

  // Bloco WEB 100% Real conectado ao seu projeto oficial 'life-os-27b92'
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: "AIzaSyAemf8DzhrfvuKv72ic1cwTY_hgT59fehI",
    appId: "1:278760083864:web:949001021a4b0d812d1bed",
    messagingSenderId: "278760083864",
    projectId: "life-os-27b92",
    storageBucket: "life-os-27b92.firebasestorage.app",
    authDomain: 'life-os-27b92.firebaseapp.com',
    measurementId: "G-P30SKNLBY7",
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: "AIzaSyBHYIOQyexSnM-HIMoD-RhFvHZorPJy15M",
    appId: "1:278760083864:android:3e698113400113022d1bed",
    messagingSenderId: "278760083864",
    projectId: "life-os-27b92",
    storageBucket: "life-os-27b92.firebasestorage.app",
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: "AIzaSyMockKey_iOS_LifeOS_2026",
    appId: "1:1234567890:ios:abcdef1234567890",
    messagingSenderId: "278760083864",
    projectId: "life-os-27b92",
    storageBucket: "life-os-27b92.firebasestorage.app",
    iosBundleId: "com.example.lifeOs",
  );
}

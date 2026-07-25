import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../domain/entities/premium_status_entity.dart';
import '../../domain/repositories/i_premium_repository.dart';

class MockPremiumRepository implements IPremiumRepository {
  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  @override
  Stream<PremiumStatusEntity> watchPremiumStatus() {
    final user = _auth.currentUser;
    if (user == null) {
      return Stream.value(_getFreeTier());
    }

    return _firestore.collection('users').doc(user.uid).snapshots().map((
      snapshot,
    ) {
      final data = snapshot.data();
      final isPremium = data?['isPremium'] ?? false;

      // No futuro, o banco/RevenueCat dirá qual é o plano exato.
      // Por enquanto, simulamos o anual se for premium.
      return PremiumStatusEntity(
        isPremium: isPremium,
        tier: isPremium ? PremiumTier.annual : PremiumTier.free,
        expirationDate: null,
        activatedFeatures: isPremium
            ? ["IA Ilimitada", "Círculos Estendidos", "Métricas Avançadas"]
            : ["Tarefas Básicas"],
      );
    });
  }

  @override
  Future<bool> purchasePlan(PremiumTier tier) async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      // Quando for colocar na Play Store, aqui entrará o código:
      // await Purchases.purchasePackage(package);
      await _firestore.collection('users').doc(user.uid).update({
        'isPremium': true,
      });
      return true;
    } catch (e) {
      print("ERRO DE CHECKOUT: $e");
      return false;
    }
  }

  @override
  Future<bool> restorePurchases() async {
    // Aqui entrará: await Purchases.restorePurchases();
    return true; // Mock para UI não quebrar
  }

  PremiumStatusEntity _getFreeTier() {
    return const PremiumStatusEntity(
      isPremium: false,
      tier: PremiumTier.free,
      activatedFeatures: ["Tarefas Básicas"],
    );
  }
}

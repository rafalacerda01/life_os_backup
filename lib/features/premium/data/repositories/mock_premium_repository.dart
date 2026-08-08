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
    // ========================================================================
    // CORREÇÃO DE SEGURANÇA (FASES 8 E 11):
    // O cliente não pode forçar 'isPremium = true' no banco de dados.
    // O faturamento real (Google Play/RevenueCat) será implementado e
    // validado pelo backend futuramente.
    // ========================================================================
    throw UnimplementedError(
      'Google Play Billing pendente de implementação. Compra bloqueada por segurança.',
    );
  }

  @override
  Future<bool> restorePurchases() async {
    // ========================================================================
    // CORREÇÃO DE SEGURANÇA (FASE 12):
    // Retornar 'true' sem validar uma compra real cria uma brecha em produção.
    // Retornando 'false' de forma segura até a implementação do sistema real.
    // ========================================================================
    return false;
  }

  PremiumStatusEntity _getFreeTier() {
    return const PremiumStatusEntity(
      isPremium: false,
      tier: PremiumTier.free,
      activatedFeatures: ["Tarefas Básicas"],
    );
  }
}

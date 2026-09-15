import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:life_os/features/premium/data/repositories/google_play_premium_repository.dart';
import 'package:life_os/features/premium/domain/entities/premium_plan_offer_entity.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';

class PremiumScreen extends ConsumerWidget {
  const PremiumScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final premiumState = ref.watch(premiumProvider);
    final catalog = ref.watch(premiumCatalogProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          "Acesso Premium",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: premiumState.isPremium
                ? () => _manageSubscription(context, ref)
                : () => _restorePurchase(context, ref),
            child: Text(
              premiumState.isPremium ? 'Gerenciar' : 'Restaurar',
              style: const TextStyle(color: Colors.white54),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // CARD DE STATUS ATUAL
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF5D0EFF), Color(0xFFB026FF)],
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    premiumState.isPremium
                        ? 'ASSINATURA ATIVA'
                        : 'ACESSO ATUAL: GRATUITO',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    premiumState.isPremium
                        ? _activePlanDescription(premiumState)
                        : 'Escolha um plano da Google Play para ampliar limites e análises.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 30),
            const Text(
              'Comparativo de recursos',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),

            // TABELA COMPARATIVA ATRIBUTOS
            _buildComparisonRow(
              'Companion IA',
              'Indisponível',
              'Disponível com limites de uso',
              true,
            ),
            _buildComparisonRow(
              'Análises da sua evolução',
              'Básicas',
              'Avançadas',
              false,
            ),
            _buildComparisonRow(
              'Criação de itens',
              'Limites básicos',
              'Limites ampliados',
              false,
            ),
            _buildComparisonRow(
              'Focus e check-ins',
              'Incluídos',
              'Incluídos',
              false,
            ),

            const SizedBox(height: 35),

            // BOTÕES DE CHECKOUT PROTEGIDO
            if (!premiumState.isPremium) ...[
              catalog.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => Center(
                  child: Column(
                    children: [
                      const Text(
                        'Não foi possível carregar os planos da Google Play.',
                        style: TextStyle(color: Colors.white70),
                      ),
                      TextButton(
                        onPressed: () => ref.invalidate(premiumCatalogProvider),
                        child: const Text('Tentar novamente'),
                      ),
                    ],
                  ),
                ),
                data: (offers) => Column(
                  children: offers
                      .map((offer) {
                        final annual = offer.tier == PremiumTier.annual;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _buildCheckoutButton(
                            context,
                            ref,
                            offer: offer,
                            title: annual
                                ? 'Assinar plano anual'
                                : 'Assinar plano mensal',
                            backgroundColor: annual
                                ? const Color(0xFFB026FF)
                                : const Color(0xFF1E2640),
                            borderColor: annual
                                ? Colors.transparent
                                : Colors.white24,
                          ),
                        );
                      })
                      .toList(growable: false),
                ),
              ),
            ] else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.greenAccent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.greenAccent.withOpacity(0.4),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.verified, color: Colors.greenAccent),
                    SizedBox(width: 8),
                    Text(
                      'Sua assinatura está ativa e validada',
                      style: TextStyle(
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => _manageSubscription(context, ref),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Gerenciar assinatura na Google Play'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showProcessingDialog(BuildContext context, String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF11182E),
        content: Row(
          children: [
            const CircularProgressIndicator(color: Color(0xFF5D0EFF)),
            const SizedBox(width: 20),
            Text(message, style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }

  Widget _buildComparisonRow(
    String feature,
    String freeVal,
    String premiumVal,
    bool highlight,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            feature,
            style: TextStyle(
              color: highlight ? const Color(0xFFB026FF) : Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Gratuito: $freeVal",
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              Text(
                "Premium: $premiumVal",
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const Divider(color: Colors.white10, height: 20),
        ],
      ),
    );
  }

  Widget _buildCheckoutButton(
    BuildContext context,
    WidgetRef ref, {
    required PremiumPlanOfferEntity offer,
    required String title,
    required Color backgroundColor,
    required Color borderColor,
  }) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: backgroundColor,
        minimumSize: const Size(double.infinity, 64),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: borderColor),
        ),
        elevation: offer.tier == PremiumTier.annual ? 4 : 0,
      ),
      onPressed: () async {
        _showProcessingDialog(context, 'Processando assinatura...');

        try {
          final success = await ref
              .read(premiumProvider.notifier)
              .processSecureCheckout(offer.tier);

          if (context.mounted) {
            if (success) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Assinatura confirmada com segurança.'),
                  backgroundColor: Colors.green,
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('A compra não foi concluída.'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }
        } on PremiumPurchaseException catch (error) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(error.message)));
          }
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Não foi possível concluir a compra.'),
              ),
            );
          }
        } finally {
          if (context.mounted) {
            Navigator.of(context, rootNavigator: true).pop();
          }
        }
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            offer.formattedPrice,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Future<void> _restorePurchase(BuildContext context, WidgetRef ref) async {
    _showProcessingDialog(context, 'Restaurando compras...');
    try {
      final restored = await ref
          .read(premiumProvider.notifier)
          .restorePurchase();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            restored
                ? 'Assinatura restaurada com segurança.'
                : 'Nenhuma assinatura ativa foi encontrada.',
          ),
        ),
      );
    } on PremiumPurchaseException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Não foi possível restaurar as compras.'),
          ),
        );
      }
    } finally {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<void> _manageSubscription(BuildContext context, WidgetRef ref) async {
    final opened = await ref.read(subscriptionManagementLauncherProvider)();
    if (context.mounted && !opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível abrir a Google Play.')),
      );
    }
  }

  String _activePlanDescription(PremiumStatusEntity status) {
    final plan = status.tier == PremiumTier.annual ? 'anual' : 'mensal';
    final expiry = status.expirationDate;
    if (expiry == null) return 'Plano Premium $plan validado pela Google Play.';
    return 'Plano Premium $plan válido até '
        '${DateFormat('dd/MM/yyyy').format(expiry.toLocal())}.';
  }
}

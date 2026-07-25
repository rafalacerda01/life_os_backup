import 'package:flutter/material.dart';
import 'package:life_os/core/theme/app_colors.dart'; // <--- O IMPORT CORRETO

class SectionTitle extends StatelessWidget {
  final String title;
  const SectionTitle(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: AppColors.textMain,
        fontSize: 18,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

class MiniCard extends StatelessWidget {
  final String title;
  final String value;
  final Color color;
  final VoidCallback onTap;

  const MiniCard({
    super.key,
    required this.title,
    required this.value,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.cardBackground,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Text(
                value,
                style: TextStyle(
                  color: color,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                title,
                style: const TextStyle(color: AppColors.textHint, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class InfoCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String value;
  final Color? color;
  final IconData? icon; // <-- Novo parâmetro para o ícone
  final VoidCallback onTap;

  const InfoCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    this.color,
    this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cardColor = color ?? AppColors.textMain;

    return Material(
      color: Colors.transparent, // Transparente para o Container desenhar
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.cardBackground,
            borderRadius: BorderRadius.circular(20),
            border: Border(left: BorderSide(color: cardColor, width: 4)),
          ),
          child: Container(
            // Leve brilho de fundo (3% de opacidade) com a cor da categoria
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: cardColor.withOpacity(0.03),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      // Ícone arredondado com fundo da cor da categoria (15% opacidade)
                      if (icon != null) ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: cardColor.withOpacity(0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(icon, color: cardColor, size: 22),
                        ),
                        const SizedBox(width: 16),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: AppColors.textMain,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subtitle,
                              style: const TextStyle(
                                color: AppColors.textHint,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Row(
                  children: [
                    Text(
                      value,
                      style: TextStyle(
                        color: cardColor,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.arrow_forward_ios,
                      color: AppColors.textDisabled,
                      size: 14,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:life_os/core/theme/app_colors.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          "Política de Privacidade",
          style: TextStyle(
            color: AppColors.textMain,
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textMain),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Última atualização: Agosto de 2026",
              style: TextStyle(
                color: AppColors.textHint,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 20),
            _buildSection(
              "1. Visão Geral",
              "O Life OS foi construído sob uma arquitetura de privacidade em primeiro lugar. Seus dados de rotina, finanças, saúde, hábitos e estudos são tratados com rigor técnico de segurança, combinando armazenamento local criptografado e sincronização opcional em nuvem.",
            ),
            _buildSection(
              "2. Dados Coletados",
              "• **Dados de Autenticação:** E-mail e nome fornecidos no cadastro via Firebase Auth ou Google Sign-In.\n"
                  "• **Dados de Produtividade e Hábitos:** Tarefas, metas, registros de foco e histórico de hábitos.\n"
                  "• **Dados Financeiros:** Transações (entradas e saídas) inseridas manualmente no módulo financeiro.\n"
                  "• **Dados de Saúde e Bem-Estar:** Registro de humor, hidratação, medicamentos ativos e matriz de ciclo menstrual (quando ativada pelo usuário).\n"
                  "• **Contexto para IA (Companion):** Informações resumidas de performance enviadas de forma temporária e segura via token criptografado para processamento do assistente de inteligência artificial.",
            ),
            _buildSection(
              "3. Armazenamento e Criptografia Local",
              "Os dados do aplicativo são salvos localmente no dispositivo utilizando o banco de dados Drift protegido por **SQLCipher**. A chave de criptografia é gerada de forma única e isolada no Hardware Secure Storage do seu smartphone (`FlutterSecureStorage`), impedindo o acesso não autorizado por terceiros ou root.",
            ),
            _buildSection(
              "4. Sincronização em Nuvem (Firebase)",
              "Para garantir a portabilidade entre dispositivos (Offline-First), o Life OS sincroniza cópias criptografadas dos registros com o ecossistema Firebase (Firestore). Todas as regras de segurança do banco de dados isolam estritamente os documentos por ID de usuário (`uid`), garantindo que nenhum outro usuário tenha acesso às suas informações.",
            ),
            _buildSection(
              "5. Exclusão de Conta e Dados",
              "Você possui controle total sobre suas informações. Ao acionar a opção de deletar a conta nas configurações do aplicativo, o Life OS executa uma limpeza atômica em lote (*Batch Commit*), removendo permanentemente todas as suas subcoleções na nuvem (finanças, saúde, check-ins, círculos) e apagando integralmente o banco de dados local do dispositivo.",
            ),
            _buildSection(
              "6. Contato",
              "Se tiver dúvidas sobre esta Política de Privacidade ou sobre o tratamento de seus dados, entre em contato com a equipe de engenharia e suporte do Life OS através do painel de configurações.",
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(String title, String content) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textMain,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            content,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

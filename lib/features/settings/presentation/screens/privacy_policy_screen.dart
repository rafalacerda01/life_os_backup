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
              "O Life OS utiliza armazenamento local criptografado, autenticação, comunicações protegidas por HTTPS e controles de acesso para tratar dados de rotina, finanças, saúde, hábitos e estudos. Quando você está autenticado, a sincronização em nuvem de dados compatíveis pode ocorrer.",
            ),
            _buildSection(
              "2. Dados Coletados",
              "• **Dados de Autenticação:** E-mail e nome fornecidos no cadastro via Firebase Auth ou Google Sign-In.\n"
                  "• **Dados de Produtividade e Hábitos:** Tarefas, metas, registros de foco e histórico de hábitos.\n"
                  "• **Dados Financeiros:** Transações (entradas e saídas) inseridas manualmente no módulo financeiro.\n"
                  "• **Dados de Saúde e Bem-Estar:** Registro de humor, hidratação, registros de medicamentos e dados relacionados ao ciclo, quando o recurso é utilizado.\n"
                  "• **Contexto para IA (Companion):** Quando o consentimento do Companion IA está ativo e você utiliza o recurso, sua mensagem e somente o contexto relevante para a solicitação podem ser enviados para processamento. Dependendo do assunto, esse contexto pode incluir informações financeiras agregadas, hidratação, humor, quantidade de medicamentos ativos ou fase do ciclo. O Life OS não adiciona o identificador da conta ao contexto enviado ao Gemini. O envio usa requisições autenticadas e protegidas por HTTPS.",
            ),
            _buildSection(
              "3. Armazenamento e Criptografia Local",
              "Os dados do aplicativo são salvos localmente no dispositivo em um banco de dados criptografado. A chave de criptografia é gerada aleatoriamente e mantida no armazenamento seguro oferecido pelo sistema operacional.",
            ),
            _buildSection(
              "4. Uso Offline e Sincronização em Nuvem",
              "Vários recursos principais mantêm dados localmente e podem continuar disponíveis sem conexão. Quando a conexão estiver disponível e você estiver autenticado, dados compatíveis podem ser sincronizados com o Firebase (Cloud Firestore). Recursos como autenticação, Companion IA, Círculos e exclusão de conta dependem de conexão. Dados compatíveis que já tenham sido sincronizados podem ser recuperados em outro dispositivo ao entrar na mesma conta. Algumas preferências, agendamentos do sistema e alterações ainda não sincronizadas podem permanecer somente no dispositivo. As comunicações são protegidas por HTTPS, e o Firestore protege os dados armazenados com os mecanismos de segurança do provedor. Controles de acesso vinculam os dados privados à conta autenticada, enquanto recursos compartilhados, como Círculos, seguem as permissões próprias do recurso.",
            ),
            _buildSection(
              "5. Serviços Técnicos, Métricas e Relatórios",
              "O Life OS utiliza Firebase Authentication e Google Sign-In para autenticação, Cloud Firestore para armazenar e sincronizar dados compatíveis, Firebase App Check para ajudar a proteger o acesso às APIs e infraestrutura da Vercel para processar requisições do backend. Quando o Companion IA é utilizado com consentimento ativo, a solicitação é processada pelo Gemini, serviço de IA do Google. Quando o Firebase Analytics estiver habilitado na plataforma e na configuração do serviço, o Life OS pode coletar métricas de uso para compreender o funcionamento do aplicativo. Em versões de produção, o Firebase Crashlytics pode receber relatórios técnicos de falhas para diagnóstico e estabilidade. O aplicativo sanitiza o conteúdo dos erros que registra, evitando o envio da mensagem bruta da exceção.",
            ),
            _buildSection(
              "6. Exclusão de Conta e Dados",
              "Você pode gerenciar seus dados e as configurações disponíveis no Life OS, revogar o consentimento do Companion IA e solicitar a exclusão da conta. A exclusão é processada em etapas pelo servidor para remover a conta, os dados principais associados a ela e referências aplicáveis em recursos compartilhados, como Círculos. Após a confirmação do servidor, o aplicativo remove os dados locais associados à conta e encerra a sessão.",
            ),
            _buildSection(
              "7. Contato",
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

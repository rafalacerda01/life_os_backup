# Life OS — Plano controlado de migração Local-First + Premium Híbrido
Data: 2026-11-16
Estado: PLANEJAMENTO, sem implementação, testes ou homologação aprovados.
Branch isolada: refactor/offline-first-premium-hybrid-20261116
Fonte inicial: security-audit-before-circles-fix

## Objetivo
Todos os registros funcionais do Life OS (saúde, finanças, tarefas, hábitos, estudos, metas, foco, check-ins, notificações, Mercado e análises) devem operar e persistir localmente, sem autenticação Firebase, Firestore ou fila de sincronização com servidor.
Internet fica limitada a serviços declarados e opcionais, sobretudo Google Play Billing, por backend Vercel mínimo. Não ativar IA no lançamento. Círculos colaborativos ficam desativados até arquitetura separada.

## Regras invioláveis
- NÃO apagar projetos Firebase/Google Cloud, dados, serviço Vercel, credenciais ou configurações antes de prova funcional e checklist de desligamento.
- NÃO fazer deploy, merge na main ou release sem testes e aprovação específica.
- NÃO misturar a branch main do app com security-audit-before-circles-fix: GitHub não apresenta ancestral comum entre elas. Confirmar primeiro se a cópia local do desenvolvedor contém mudanças mais recentes.
- NÃO trocar IDs ou nomes de arquivos de bancos existentes sem migração/recuperação; preservar WAL/SHM, chaves de criptografia e dados. Limpeza local segura exige tratar sidecars, arquivos alternativos e armazenamento seguro.
- NÃO converter a remoção do P1 remoto em PASS de exclusão local sem teste real.
- Em falha de verificação Premium, não conceder acesso indevido, mas nunca apagar dados do usuário.

## Inventário preliminar confirmado em GitHub (não equivale a auditoria exaustiva)
- lib/main.dart inicializa Firebase, App Check e Crashlytics antes da interface.
- lib/core/router/router.dart usa authNotifierProvider e firebaseAuthProvider para redirects.
- lib/core/database/app_database.dart inclui SyncQueueTable, dados locais e mecanismos de identidade/sessão.
- lib/core/database/user_database_factory.dart deriva arquivo criptografado da LocalDatabaseIdentity baseada em UID; exigir migração cuidadosa antes de remover UIDs.
- lib/features/premium/data/remote/billing_remote_data_source.dart obtém ID token Firebase e App Check.
- No repo backend, api/billing/google/_shared.js valida Firebase ID token e App Check; _reconciliation.js usa coleções e transações Firestore.
- Android possui regras de exclusão de backup/transferência, sujeitas a confirmação em dispositivo.

## Fase 0 — Baseline e preservação
1. Comparar cópia C:\life_os em uso com a branch de auditoria, salvar commits e hashes.
2. Fazer backup seguro do código, configurações não secretas e dados de teste/necessários, sem incluir segredos em commits.
3. Mapear imports Firebase, caminhos de rede, filas, tarefas de fundo, providers de autenticação, efeitos colaterais e Hive/SharedPreferences/SecureStorage.
4. Listar módulos dependentes de UID e políticas de exclusão. Produção segue intocada.
Gate: baseline reproduzível, mapa de dependências, nenhuma perda de dados.

## Fase 1 — Núcleo local
1. Criar LocalSession/LocalProfile sem Firebase; perfil inicial pode não ter conta, mas deve manter identidade local estável.
2. Migrar dados criptografados existentes de namespace UID para perfil local sem perder chaves, WAL/SHM ou históricos. Se migração não for verificável, bloquear e preservar dados.
3. Alterar startup/splash/rotas para não exigir autenticação ou App Check.
4. Desativar redes de módulos e SyncQueue na execução; preservar o código anterior na história Git para reversão.
5. Certificar que todos os módulos listados persistem e reabrem após cold boot e modo avião.
Gate: abrir app novo/atualizado, CRUD offline de todos os módulos, sem chamadas remotas, sem travamento.

## Fase 2 — Proteção, privacidade, exclusão e backup
1. Proteger banco/armazenamento local com criptografia e gestão de chave existente compatível.
2. Projetar exportação/importação criptografada controlada pelo usuário; sem upload automático.
3. Garantir exclusão local com congelamento de tarefas, interrupção de timers e operações concorrentes, fechamento DB, deleção de dados e chaves, e prova de não recriação.
4. Checar backup_rules.xml e data_extraction_rules.xml na versão Android real, histórico de dados e sidecars.
Gate: testes reais de exclusão/reabertura, reinstalação, modo avião e migração; nenhum dado de outro perfil reaparece.

## Fase 3 — Premium híbrido, sem Firebase
1. Manter Google Play Billing no Flutter e verificar compras no backend Vercel.
2. Substituir Firebase Auth/App Check/Firestore no Billing por autenticação/aprovação de compra e proteção contra replay/uso duplicado, persistência durável mínima e rate limit, sem confiar em identidade local ou campos enviados pelo cliente.
3. Definir compra, acknowledgement, renovação, cancelamento, reembolso, restauração em novo aparelho, expiração e funcionamento offline com autorização verificável e duração limitada.
4. Confirmar requisitos atuais Google Play Developer API, credenciais, escopo e eventual projeto Google Cloud mínimo: não prometer operação Play Billing sem GCP.
5. Nunca incluir dados de saúde, finanças, tarefas ou estudos na requisição de Billing.
Gate: testes negativos e positivos, revogação, troca de aparelho, modo avião, restauração, ausência de privilégios indevidos.

## Fase 4 — Homologação e desligamento
1. Executar testes Flutter, integração Android em emulador e dispositivo, regressões, controles de privacidade, Billing em trilha de testes.
2. Confirmar nenhum endpoint antigo é chamado; distinguir Telemetria/serviços de sistema da API própria.
3. Aprovar política de dados Google Play, descrever comportamento sem conta e perda de dispositivo.
4. Publicar somente com autorização de release; executar checklist de desligamento Firebase/Cloud após prova de independência e backup de configurações.
5. Apagar recursos remotos somente com autorização específica por projeto, dependência e evidência.

## Status de gates
- App local: NOT_VERIFIED
- Sem chamadas Firebase: NOT_VERIFIED
- Migração segura de dados/chaves: NOT_VERIFIED
- Exclusão local: NOT_VERIFIED
- Vercel Billing independente Firebase: NOT_VERIFIED
- Google Play Billing end-to-end: NOT_VERIFIED
- Firebase/Cloud deletion: NOT_AUTHORIZED_UNTIL_GATES
- Publicação: CLOSED

Este plano não é evidência de implementação.
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

## Progresso da implementação isolada — 16/11/2026
- Branch original preservada; nenhuma alteração na main, no Firebase, em IAM ou deploys.
- `lib/core/database/local_installation_identity_service.dart`: bootstrap para novo ID por instalação, com marcador persistido e bloqueio de artefatos SQLite antigos/desconhecidos antes de provisionar perfil.
- `lib/core/database/local_installation_identity_provider.dart`: adapter FlutterSecureStorage/UUID (AINDA NÃO CONECTADO AO STARTUP).
- `lib/core/database/local_device_session.dart`: prepara o banco por identidade local usando o coordenador e a fábrica criptografada existentes, sem depender de Firebase Auth (AINDA NÃO CONECTADO AO STARTUP).
- `test/core/database/local_installation_identity_service_test.dart`: 9 cenários definidos, NOT_RUN.
- `test/core/database/local_device_session_test.dart`: 4 cenários definidos, NOT_RUN.
- Backend: branch isolada `refactor/premium-without-firebase-20261116` com proposta de desenho de Billing, sem alterações nos endpoints de produção.
- Vercel: projeto `life-os-backend` consultado somente em leitura; NENHUM deploy executado.

### Riscos ainda não resolvidos
- A inicialização principal, o roteador, a hidratação/sincronização e vários módulos continuam ligados à autenticação Firebase.
- Antes de substituir os providers atuais, mapear armazenamento adicional fora do banco (Hive, SharedPreferences, SecureStorage), aliases legados e eventuais configurações locais.
- Não há migração automática de UID para local: o bootstrap recusa instalações com arquivos SQLite legados. Migrador criptografado e reversível é requisito antes do corte.
- O novo serviço de identidade precisa de `dart format`, `flutter analyze`, testes unitários e testes de dispositivo; ainda não está homologado.
- A especificação do Billing não autoriza consumo de APIs faturáveis nem elimina o requisito potencial de projeto Google Cloud mínimo.

### Gate imediatamente seguinte
1. Executar formatação e testes focais dos dois novos componentes.
2. Inventariar todos os dados locais fora do Drift e implementar fluxo explícito de migração segura.
3. Desacoplar router/splash e repositórios de Firebase com testes; somente depois ativar o novo caminho no app.
4. Verificar em Android físico/emulador cold boot, modo avião e ausência de chamadas remotas.

**Status: LOCAL_PROFILE_SCAFFOLD_CREATED · TESTS_NOT_RUN · NO_RUNTIME_CUTOVER · NO_DEPLOY.**


### Atualização do gate local — 16/11/2026 (continuação)
- O bootstrap local agora exige `assertFreshInstall` antes de gerar qualquer novo identificador de instalação; o guard verifica sinais legados fora do SQLite.
- O adapter de produção ainda não ativado verifica chaves de segurança legadas `auth_access_token`, `db_encryption_key`, `db_encryption_key_v2_*`, `life_os_*` e a preferência `life_os_onboarding_completed_v1`.
- Testes de legado sem banco e reuso de identidade existente adicionados (total: 15 cenários de testes focais escritos, NÃO EXECUTADOS).
- Missão focal de execução/revisão do Codex: `docs/CODEX_LOCAL_FIRST_FOCAL_GATE_2026-11-16.md`.
- Nenhum módulo, router ou boot foi reconfigurado; dependências Firebase e Billing antigos permanecem ativos na versão atual.
- Continua proibido apagar Firebase/Cloud e realizar deploy enquanto não houver migração de dados e provas funcionais.

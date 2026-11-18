# Lançamento Local-First — etapa8: Metas

Fonte oficial C:/life_os, branch refactor/launch-local-first-20261117; base97d49b11437aedaa9d3d9f2314bd2f1df521be10. Checkpoint byte a byte fora de build em stage8-before/, stage8-before.json e stage8-before-extra.jsonl. Backend independente b316df4302e8ae88e5d17af01780d831c0896ab9 permanece limpo e inalterado. Seis configurações protegidas verificadas, todas idênticas.

## Integração

GoalRepository.local aceita somente banco localOnly. Provider escolhe esse ramo antes de Auth/Firestore/custódia de conta; UID vem da identidade permanente local, sem FirebaseUser. Pull remoto fica inerte. Criação aplica quota Free3 sobre todos os ciclos dentro da mesma transação. Nenhuma nova SyncQueue é criada ou enviada; proteções e caminho remoto anterior permanecem.

Botões locais ajustam progresso a partir da linha admitida dentro da transação, em passos de1 e entre zero e alvo. Concorrência não perde incrementos por snapshot desatualizado. Reset automático revalida vencimento do ciclo dentro da transação: callbacks atrasados da tela não podem zerar progresso já iniciado no ciclo novo. Regras diária/semanal/mensal continuam baseadas no calendário civil existente. APIs de ajuste absoluto e reset explícito continuam disponíveis. Tela local não drena/agenta sync e mantém formulário em corrida de quota.

Host de desenvolvimento main_local agora navega entre Tarefas, Finanças, Hábitos e Metas na mesma sessão/banco criptografado. Pacote padrão/main.dart não ativados para Local-First. A guarda Gradle continua simétrica para pacote e target.

Arquivos alterados: goal_repository.dart, goals_provider.dart, goals_screen.dart, main_local.dart e android/app/build.gradle.kts. Novos: goal_repository_local_test.dart, local_goals_native_test.dart, run-goals.ps1, assert-goals.ps1 e este relatório. Sem mudança de schema11, migração UID, chaves ou aliases.

## Testes e builds

- stage8-goals-tests.log:50/50PASS, incluindo11 novas regressões locais com SQLite real. CRUD/stream, provider sem SDKs, pull inerte, quota concorrente, progresso concorrente limitado, vencimento dos três ciclos e reset atrasado, entradas inválidas, sessão destacada e construtor recusando banco remoto.
- stage8-regressions.log:154/154PASS, incluindo regressões compartilhadas de Tarefas/Finanças/Hábitos. O teste remoto de Hábitos com falha preexistente permanece documentado na etapa7/baseline; não faz parte desta seleção verde nem foi removido.
- stage8-analyze.log e stage8-analyze-native.log:0 issues sob a configuração vigente. Supressões globais herdadas e warnings Gradle/KGP ainda pendentes, sem nova supressão.
- Profile AOT447tasks PASS2m13; padrão debug ARMv7/ARM64/x86_64,448tasks PASS1m34. Pacote real não instalado.

## Android e preservação

stage8-native-goals/goals-decision.json: **LOCAL_GOALS_ANDROID=PASS;84checks**. Seed32, novo processo26, cold boot real26. Mesmo AVD sintético preservado, sem pm clear. Uma única versão do APK/harness qualificou as três execuções; hash registrado antes da instalação.

Tela real criou metas diária, semanal e mensal via eventos de entrada Android. Conferidos incremento/decremento, alvo semanal, exclusão da meta semanal correta, quota nativa, reset mensal vencido e primeiro progresso do ciclo novo. Apenas o estado mensal sintético foi preparado com data antiga para testar vencimento; nenhuma data/credencial real ou relógio do sistema foi alterado. Somente registro temporário sintético da prova de quota foi removido pelo repositório.

Duas metas restantes, IDs, alvos, progresso e timestamps permaneceram iguais entre processos e reboot, com fingerprint canônico das linhas e hash do banco fechado idênticos. Conteúdo/status da tarefa, despesa25.5 e hábito com duas datas preservados e conferidos também pela navegação real. Verificador compara taskId/transactionId/habitId/profileId/keyFingerprint com a homologação anterior de Hábitos. integrity_check=ok; arquivo pessoal criptografado; chave nativa legível; journal READY; nenhuma fila remota; FirebaseApps0; plugins remotos não registrados; INTERNET negada; modo avião1 antes/depois; boot_id diferente.

Dados exclusivamente sintéticos em LifeOSRecovery17 API34/x86_64. Limitações da etapa4 permanecem: SwiftShader, Vulkan desativado, Skia somente no lab com opt-out depreciado. Renderer padrão, hardware físico/StrongBox e outras APIs não homologados. VM service de profile não consegue criar servidor com INTERNET negada; isso não bloqueou binding/teste nem levou à liberação da permissão.

## Critério

GO focal para Metas Free neste host Android isolado. Seguem Check-in e demais módulos, notifications ownership, migração UID, segurança/perfil/configurações e Premium híbrido verificável. Sem alterações em produção, landing, credenciais, Firebase/Google Cloud, Billing, serviços faturáveis; sem push/deploy/publicação.

LOCAL_GOALS_ANDROID=PASS; APP_WIDE_OFFLINE=NOT_VERIFIED; PREMIUM_HYBRID=NOT_IMPLEMENTED; LOCAL_IDENTITY_GATE=BLOCKED; lançamento NO-GO; ROLLOUT=CLOSED.

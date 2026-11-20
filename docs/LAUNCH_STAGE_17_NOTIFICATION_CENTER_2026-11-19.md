# Lançamento Local-First — etapa 17 · Central de Notificações

O botão Notificações no Início abre a Central no host Android `.localdev`. A Central usa as regras existentes para provas, hábitos e tratamentos. Ler, concluir e dispensar alteram somente o banco do perfil em uso. A dispensa é gravada por ocorrência e permanece válida após atualizar ou reabrir a Central. Uma nova ocorrência do mesmo hábito pode ser exibida, e uma ação sobre um cartão cuja ocorrência mudou é recusada.

`NotificationModuleReconciler` passou a depender das três operações de derivação de que precisa. O repositório conectado continua implementando essas operações. O repositório local exige `AppDatabase.isLocalOnly`, usa o DAO existente e combina a atualização das ocorrências em uma transação. Ele não inicializa Firebase, não usa preferências de outra conta e não cria alarmes. Os cartões geram conteúdo no aplicativo. O usuário ainda pode desativar separadamente o lembrete de tarefas em Perfil e Ajustes.

176 testes focais passaram, incluindo os testes legados do motor e do repositório. A regressão do repositório local verificou geração concorrente, leitura, conclusão, dispensa, nova ocorrência no dia seguinte, ação obsoleta e preservação exata de uma entrada histórica em `SyncQueue`. A análise retornou zero issues. O build debug padrão passou em 1m36s em ARMv7, ARM64 e x86_64.

A primeira rodada Android criou os cartões sintéticos e abriu Estudos através da Central. O harness interrompeu a rodada ao tentar localizar um botão de retorno que não está na árvore de widgets dessa tela. O banco foi preservado com as três ocorrências e a leitura da prova registrada. O teste corrigido exercita o handler de retorno do sistema usado pelo app e valida a retomada a partir do conjunto existente, com SHA-256 conferido antes da substituição do APK de laboratório.

## Resultado Android

`LOCAL_NOTIFICATION_CENTER_ANDROID=PASS` em API 34 x86_64, modo avião, no AVD descartável `LifeOSLocalReminder16`. Foram 23 verificações na retomada, 18 na reabertura em outro processo e 18 após reboot, sem falhas. O Android manteve o agendamento do proprietário sintético da etapa anterior. A fila do AVD permaneceu vazia, a tarefa anterior continuou acessível e `PRAGMA integrity_check` retornou `ok` no banco cifrado. Perfil e fingerprint da chave coincidiram com a etapa 16. O SHA-256 do banco após as gravações legítimas da Central, em `864677e3ea833cc82ccacb3774393235341f29ac27d45338a79c27fe659e822e`, permaneceu igual nas três verificações finais.

O APK profile corrigido compilou em 2m. `stage17-native-central` preserva a primeira rodada. `stage17-native-central-system-back` preserva as três rodadas aprovadas, os IDs de boot e o hash do APK. `stage17-native-proof-hashes.json` registra o SHA-256 de 21 arquivos de evidência. Os seis hashes dos arquivos protegidos coincidiram com o checkpoint.

## Arquivos desta etapa

- `lib/features/notifications/domain/services/notification_module_reconciler.dart`, `lib/features/notifications/domain/providers/notification_engine.dart` e `lib/features/notifications/data/repositories/notifications_repository.dart`.
- `lib/features/notifications/data/repositories/local_notification_inbox.dart`, `lib/features/notifications/presentation/screens/local_notification_center_screen.dart`, `lib/features/home/presentation/screens/home_screen.dart` e `lib/main_local.dart`.
- `test/features/notifications/data/repositories/local_notification_inbox_test.dart`, `integration_test/local_notification_center_native_test.dart` e `android/app/build.gradle.kts`.

Nenhum arquivo foi removido. O startup padrão em `lib/main.dart` permanece legado. Os outros lembretes nativos, a migração UID, exclusão local, restauração e o Premium com Google Play ainda aguardam homologação. `LOCAL_IDENTITY_GATE=BLOCKED · P1 RED · ROLLOUT CLOSED` e lançamento `NO-GO`.

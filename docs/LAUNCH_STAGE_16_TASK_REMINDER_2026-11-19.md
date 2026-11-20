# Lançamento Local-First — etapa 16 · Lembrete de tarefas

O aplicativo oficial `C:/life_os`, na branch `refactor/launch-local-first-20261117`, passou a oferecer um lembrete diário em Perfil e Ajustes. A configuração começa desativada. O usuário escolhe o horário, confirma a permissão do Android e pode remover o próprio lembrete. O alerta nativo mostra texto genérico e o payload contém a hora do lembrete, sem título ou conteúdo das tarefas.

O registry local `life_os_local_native_ownership_v1.sqlite` mantém ID, tag, digest, owner e estado. A reserva em SQLite admite um único registro vivo por ID lógico do dono. O cancelamento confere a tag e o digest antes de atuar sobre o Android. A permissão só é solicitada após ação na tela. O perfil usa os plugins locais de notificação e timezone, e o receiver de boot fica habilitado no APK `.localdev`.

Na primeira prova, o Android aceitou a permissão e registrou os dois alarmes sintéticos. A primeira implementação usou o nome do registry anterior, que a inspeção de startup recusou ao reabrir. O SHA-256 do banco de Mercado, o perfil e a chave foram preservados. Os alarmes e arquivos dessa primeira instalação foram retidos no AVD original. A correção criou um registry exclusivo e reconhece apenas sua família de arquivos em `files/` e as duas preferências conhecidas do plugin no host de teste. A presença dessas preferências continua impedindo inferir instalação nova sem identidade existente. O registry anterior continua sujeito ao binding e à recusa de startup local.

Uma instalação nova em modo profile revelou que o AndroidX ProfileInstaller grava `files/profileInstalled` antes do bootstrap. O host isolado passou a reconhecer o formato de 24 bytes confirmado no AndroidX 1.4.0. O teste de regressão recusa um arquivo com schema inválido e confere que seus bytes foram preservados.

O conjunto focal do código corrigido passou em 166 testes. A suíte ampla inicial teve 325 aprovados e 34 falhos no fluxo remoto `notification_dismissal_test`. Uma worktree do commit anterior, `436d0561b5b121d37f463b53098ee84683751dd3`, repetiu as mesmas 34 falhas por nome e teve 322 aprovados. A análise do código e do harness retornou zero issues. O build debug padrão compilou ARMv7, ARM64 e x86_64. O build profile final do harness Android compilou em 1m01s.

O primeiro APK profile ainda desabilitava o receptor no manifesto `localLabProfile`. O Android reteve as preferências dos alarmes, e restaurar a autorização de alarme exato por si só não reativou os agendamentos. O APK corrigido remove a desativação no overlay. No AVD `LifeOSLocalReminder16`, com API 34 x86_64 e modo avião, o Android entregou `BOOT_COMPLETED` ao receptor e restaurou dois alarmes em `AlarmManager` antes da abertura do app. A autorização de alarme exato foi preparada somente nesse ambiente sintético. A permissão de notificação foi aceita no diálogo Android normal.

## Resultado Android

`LOCAL_TASK_REMINDER_ANDROID=PASS` com 67 verificações. A criação e a reabertura em outro processo tiveram 17 e 15 verificações. A reabertura após boot teve 15. A entrega efetiva e o cancelamento tiveram 20, incluindo a preservação do agendamento do segundo proprietário. O mesmo identificador de perfil, o fingerprint da chave e o SHA-256 do banco criptografado foram confirmados nas quatro rodadas. O hash do banco sintético foi `7474cdbb7a1cf555ff43b8f31e1d310029b552ac55097cc2d739bc1759805267`.

Os relatórios `stage16-native-reminder-profile-cache` e `stage16-native-reminder-boot-resolved` contêm os resultados Dart, as evidências do `AlarmManager`, os IDs do boot, a entrega do broadcast e os hashes dos APKs. O manifesto `stage16-native-proof-hashes.json` registra os SHA-256 de 28 arquivos de evidência. Os seis hashes de configuração protegida coincidiram com o checkpoint. O backend independente permanece em `b316df4302e8ae88e5d17af01780d831c0896ab9`.

## Arquivos integrados

- `android/app/build.gradle.kts`, `android/app/src/localLab/AndroidManifest.xml`, `android/app/src/localLabProfile/AndroidManifest.xml` e `android/app/src/main/kotlin/com/rafalacerda/lifeos/LocalLabHost.kt`.
- `lib/core/database/local_installation_storage_inspector.dart`, `lib/core/services/native_notification_registry.dart` e `lib/core/services/owned_notification_service.dart`.
- `lib/features/tasks/data/services/local_task_reminder.dart`, `lib/features/tasks/presentation/local_task_reminder_screen.dart`, `lib/features/settings/presentation/local_profile_screen.dart` e `lib/main_local.dart`.
- `integration_test/local_task_reminder_native_test.dart`, `test/core/database/local_installation_storage_inspector_test.dart`, `test/core/services/generational_local_state_test.dart` e este relatório.

A etapa tem GO focal para o lembrete no `.localdev`. Entrega em modo inexato, Central de Notificações, lembretes dos demais módulos, biometria por sensor, migração UID, exclusão local e Premium com Google Play continuam pendentes de homologação. O `lib/main.dart` permanece no fluxo legado. Lançamento `NO-GO`, `LOCAL_IDENTITY_GATE=BLOCKED`, `P1 RED` e `ROLLOUT=CLOSED`.

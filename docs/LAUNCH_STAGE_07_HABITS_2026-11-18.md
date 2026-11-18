# Lançamento Local-First — etapa7: Hábitos

Fonte oficial C:/life_os, branch refactor/launch-local-first-20261117, base ef36f84959230e508bd14daa727473c264af53e5. Checkpoint byte a byte e hashes fora de build em stage7-before/, stage7-before.json e stage7-before-extra.jsonl. Backend independente permanece b316df4302e8ae88e5d17af01780d831c0896ab9, sem alterações. Seis configurações protegidas conferidas e idênticas.

## Comportamento integrado

HabitsRepository.local aceita apenas banco localOnly. Owner vem da identidade local; não fabrica FirebaseUser nem acessa Auth/Firestore. Criação aplica Free3 dentro da transação, sem depender do contador da tela. Exclusão continua usando IDs exatos para hábito e registros locais relacionados de notificações. Nenhum novo envio remoto é enfileirado; pull remoto é inerte neste modo.

Toggle de hoje e da matriz semanal derivam as datas da linha lida na transação admitida. Dois cliques concorrentes não substituem o histórico usando o mesmo snapshot antigo. Datas locais inválidas são recusadas; datas duplicadas são normalizadas. A API de substituição explícita de datas permanece disponível. Fluxo remoto mantém a política anterior e suas proteções de sessão.

Providers desviam antes de Auth/Firestore/analytics. Tela local não drena fila nem agenda sincronização e trata conflito de quota mantendo o formulário. O host main_local inclui a tela real Hábitos ao lado de Tarefas/Finanças, com uma única sessão e conexão criptografada. Startup padrão não foi ativado; a guarda simétrica Gradle continua exigindo pacote/target de laboratório compatíveis.

Arquivos: habits_repository.dart, habits_provider.dart, habits_screen.dart, main_local.dart, android/app/build.gradle.kts; novos habits_repository_local_test.dart, local_habits_native_test.dart, run-habits.ps1, assert-habits.ps1 e este relatório. Sem mudança de schema11, migração de UID, aliases ou chaves. Formatação incidental de dois models foi revertida antes da integração, com cópia preservada; não há alteração funcional nesses models.

## Verificação Flutter e compatibilidade

- Nove regressões locais com SQLite real: CRUD/stream; ausência de SDKs e analytics; pull inerte; concorrência de criação/quota; toggle duplo; dois dias concorrentes; datas/título inválidos; sessão destacada recusando leitura/escrita; construtor recusando banco remoto.
- stage7-focal-tests.log:104/104PASS, incluindo novos testes de Hábitos e regressões de apresentação/providores de Tarefas e Finanças.
- Suíte completa de Hábitos:46PASS/1FAIL. A falha remota `confirmed habit delete survives detach/relogin and leaves B isolated` foi reproduzida na baseline ec83689, mesma linha362 e TRUSTED_LOCAL_SESSION_CLOSED. Teste e guard preservados; não é considerado PASS. Há também um comando inicial com caminho de teste Tasks inexistente; comando corrigido, log mantido.
- Análise geral e análise do harness após correção:0 issues na configuração vigente. Supressões globais antigas continuam pendentes de auditoria.
- Profile AOT447tasks PASS2m24; recompilação do harness PASS2m34. Build padrão debug ARMv7/ARM64/x86_64 PASS2m09,448tasks; pacote real não instalado.

## Android real e preservação

stage7-native-habits-final/habits-decision.json: **LOCAL_HABITS_ANDROID=PASS;71checks**. Seed27, reabertura22 e cold boot22; SDK integration_test real com resultado do binding, entrada de texto por eventos Android, sem mocks de armazenamento ou FirebaseUser.

Seed aprovado permanece no caminho original stage7-native-habits/native-results/habits-seed.json. A primeira reabertura falhou no harness: drag em CustomScrollView inexistente nessa tela; UI já mostrava hábito e duas datas. A tentativa incompleta foi preservada e não contada. Corrigido apenas o seletor do teste, recompilado/instalado sem pm clear. Reabertura e cold boot finais permanecem em stage7-native-habits-final/. O verificador recebe SeedGateDirectory explícito e registra os dois caminhos, sem copiar relatórios como novas execuções. Hashes dos dois APKs foram registrados separadamente; não houve mudança do código do aplicativo entre essas compilações.

UI criou dois hábitos sintéticos, marcou hoje e outro dia da semana, excluiu a linha correta. Quota Free3 conferida na conexão nativa; somente linhas temporárias sintéticas de quota foram removidas. Persistem hábito, ID e duas datas em nova abertura e reboot real, com hashes do banco fechado idênticos entre os três relatórios. Mesmos taskId, transactionId, profileId e fingerprint da chave que a homologação de Finanças anterior, que por sua vez preservava Tarefas. Conteúdo/status da tarefa e despesa25.5 conferidos no banco e na navegação real. Instalação e userdata nunca foram limpas.

SQLite integrity_check=ok, header pessoal criptografado, journal bootstrap READY, fila vazia, FirebaseApps0, plugins remotos não registrados, INTERNET negada, modo avião1 antes/depois, boot_id mudou. Dados exclusivamente sintéticos no AVD LifeOSRecovery17, API34/x86_64. Mesmas limitações gráficas/hardware da etapa4: SwiftShader, Vulkan desativado e Skia apenas laboratório; opt-out depreciado, renderer padrão/hardware/StrongBox/outras APIs não homologados. Warnings Gradle/KGP herdados permanecem registrados, sem upgrade de infraestrutura nesta etapa.

## Critério e próximo passo

GO focal para Hábitos Free nesse host isolado; seguem Metas e demais módulos. Notificações nativas de Hábitos não foram ativadas nem homologadas: apenas exclusão dos registros locais relacionados mantém a semântica anterior. Premium híbrido e migração UID ainda não implementados. Nenhuma mudança em dados reais, credenciais, produção, landing, Firebase/Google Cloud, Billing, serviços faturáveis, push/deploy/publicação.

LOCAL_HABITS_ANDROID=PASS; APP_WIDE_OFFLINE=NOT_VERIFIED; PREMIUM_HYBRID=NOT_IMPLEMENTED; LOCAL_IDENTITY_GATE=BLOCKED; lançamento NO-GO; ROLLOUT=CLOSED.

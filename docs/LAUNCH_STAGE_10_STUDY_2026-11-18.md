# Lançamento Local-First — etapa10: Estudos

Fonte oficial C:/life_os, branch refactor/launch-local-first-20261117; base6fa9a7723182054c1ac2db6ca66128ee11b486cf. Checkpoint byte a byte fora de build em stage10-before/, stage10-before.json e stage10-before-extra.jsonl. Seis configurações protegidas idênticas; backend independente b316df4302e8ae88e5d17af01780d831c0896ab9 permanece limpo e inalterado.

## Integração e correções comprovadas

StudyRepository.local aceita somente banco localOnly; provider desvia antes de Auth/Firestore/SyncManager/custódia. UID da identidade permanente, sem FirebaseUser. Captura de admissão local permanece obrigatória. Criação/revisão de flashcards, matéria, sessão e reset não criam nem alteram SyncQueue; pull/drain/retry ficam inertes. A visibilidade de criação remota no modo local não fabrica recibo, envio ou confirmação. Histórico de fila permanece protegido pela política SQL global; nenhuma migração de filas UID foi realizada.

Quota Free3 disciplinas dentro da transação. Validação local de título, conteúdo e prova sem data; duração inválida ou matéria inexistente não recebe o fallback legado de1500segundos. Sessão local calcula stats a partir da linha admitida, preservando contadores contra snapshots desatualizados; falha local de reset é propagada.

Regressões iniciais deram8PASS/2FAIL: após virada do dia o contador gravava1 onde a projeção mostrava2; ao remover matéria com cartão já revisado, contador de outra matéria era zerado. Corrigidos apenas os cálculos locais: contam cartões vencidos por dia civil dentro da mesma transação ao criar/revisar/remover. Dez regressões locais agora passam. Caminho remoto e sua aritmética P1 preservados.

Tela trata corrida de quota mantendo formulário. showFocusShortcut=true preserva atalho legado; host local usa false até Foco ser adaptado/homologado. main_local permite seis módulos na mesma sessão/banco: Tarefas/Finanças/Hábitos/Metas/Check-in/Estudos. Startup padrão e pacote real não foram ativados para Local-First. Sem mudança de schema11, aliases/chaves ou migração UID.

Arquivos alterados: study_repository.dart, study_provider.dart, study_screen.dart, main_local.dart, android/app/build.gradle.kts. Novos: study_repository_local_test.dart, local_study_native_test.dart, run-study.ps1, assert-study.ps1 e este relatório.

## Flutter, baseline e build

- stage10-regressions.log:260/260PASS, incluindo10 novas regressões locais, testes de apresentação de Estudos e regressões dos cinco módulos anteriores. SQLite real nos testes do repositório; relógio injetado para reproduzir virada de dia na lógica.
- Suíte completa Estudos:221PASS/4FAIL. As quatro falhas remotas F01 actual transport and Manager stop (STUDY_REVIEW_QUEUE_STATE_INVALID/STUDY_REVIEW_STATE_INVALID) e validated HTTP ACK APPLIED/REPLAYED removes visibility through actual Manager foram reproduzidas com mesmos nomes na baseline ec83689. stage10-baseline-comparison.json confirma igualdade. Testes e guards não removidos; não declarar suíte completa verde.
- Análise geral e do harness final:0issues sob configuração vigente. Supressões globais herdadas continuam pendentes de auditoria.
- Profile original447tasks PASS2m24; rebuild do harness447tasks PASS1m50; padrão debug ARMv7/ARM64/x86_64,448tasks PASS1m40. APK real não instalado.

## Android real e preservação

stage10-native-study-final/study-decision.json: **LOCAL_STUDY_ANDROID=PASS;104checks**,38seed+33novo processo+33cold boot real. Entrada de texto por eventos Android e controles reais; SDK integration_test/binding, sem mocks de armazenamento. Nenhum pm clear, wipe ou recriação de userdata/banco/chave.

Primeira tentativa em stage10-native-study/ falhou no harness após17checks: tester.pageBack buscava um botão inadequado à interface pt-BR. A criação de duas matérias/dois cartões e uma revisão já tinha ocorrido. Corrigidos os seletores para BackButton real; tentativa incompleta preservada e não contada como aprovação.

Nova rodada usou flag explícita OwnedSyntheticRetry e rawScenario seed-owned-retry. Antes de preparar a rodada, o harness conferiu pacote, perfil sintético exato e conjunto/quantidade/conteúdo dos registros parciais. Gravou JSON completo dessas duas matérias, dois cartões e stats no cache de teste, com flush e SHA256 conferidos ANTES de removê-los pelos métodos do repositório. Runner exportou o checkpoint para stage10-native-study-final/native-results/study-seed-owned-retry-before.json e conferiu o mesmo SHA256 e4b66ce32ca082a12c61bbe49b617997cf67d27ec478c68b9198a2a50cbdecda. Preparação nunca é automática em reopen; conjunto diferente é recusado. Apenas registros sintéticos pertencentes à tentativa foram removidos. Nenhum relatório da tentativa antiga foi copiado como resultado novo: a nova rodada repetiu todos os fluxos reais.

UI criou matérias/cartões, revelou resposta, revisou um cartão, removeu a matéria correta e seus cartões, preservou a contagem da outra matéria, testou Free3 na conexão nativa e resetou progresso mantendo sequência/histórico. Restam uma matéria, dois cartões (um revisado/um vencido), stats queue1/progress0/streak1; fingerprint integral dessas linhas e hash do banco fechado permaneceram iguais em novo processo e reboot.

Tarefa/status, despesa25.5, hábito com duas datas, duas metas/progresso e Check-in5/1/3 preservados e conferidos também por navegação real. Verificador compara IDs/fingerprints desses dados, perfil e chave com a etapa9. SQLite integrity_check=ok, arquivo pessoal criptografado, chave nativa legível, journal READY, fila vazia, FirebaseApps0, plugins remotos não registrados, INTERNET negada, modo avião1 antes/depois e boot_id diferente.

AVD LifeOSRecovery17 API34/x86_64; limitações anteriores mantidas: SwiftShader/Vulkan desativado/Skia somente lab com opt-out depreciado; renderer padrão, hardware/StrongBox/outras APIs não homologados. Agendamento de prova/notificações nativas não foi ativado nem homologado nesta rodada. Warnings Gradle/KGP herdados permanecem; ausência do VM service HTTP por INTERNET negada não bloqueia o binding.

## Critério

GO focal para estudos/flashcards/revisão Free nesse host isolado. Foco foi apenas inventariado, ainda sem integração local. Seguem Saúde/meds/água/ciclo, Home/dashboard/analytics locais, Mercado, perfil/configurações/segurança, notifications ownership, migração UID preparada/verificada e Premium híbrido. Sem alterações em produção, landing, credenciais, Firebase/Google Cloud, Billing ou serviços faturáveis; sem push/deploy/publicação.

LOCAL_STUDY_ANDROID=PASS; APP_WIDE_OFFLINE=NOT_VERIFIED; PREMIUM_HYBRID=NOT_IMPLEMENTED; LOCAL_IDENTITY_GATE=BLOCKED; lançamento NO-GO; ROLLOUT=CLOSED.

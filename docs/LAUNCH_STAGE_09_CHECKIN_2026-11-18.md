# Lançamento Local-First — etapa9: Check-in

Fonte oficial C:/life_os, branch refactor/launch-local-first-20261117; base b8d9572d0dcbd8569b4cbe3f7c979747ee16abb5. Checkpoint byte a byte fora de build em stage9-before/, stage9-before.json e stage9-before-extra.jsonl. Seis configurações protegidas idênticas; backend independente b316df4302e8ae88e5d17af01780d831c0896ab9 permanece limpo, sem mudanças.

## Integração

CheckInRepository.local aceita apenas banco localOnly. Provider escolhe esse ramo antes de construir SyncManager, Auth, Firestore ou custódia de conta. Owner vem da identidade local permanente, sem FirebaseUser. Save mantém a semântica diária de INSERT OR REPLACE e revisão, dentro de transação admitida. Nenhum upload direto, replay ou novo item de SyncQueue. Campo histórico isSynced fica false: não inventa confirmação de upload. Entrypoints de upload/pull ficam inertes no modo local; controller não inicia background remoto no runtime localFirst.

Histórico local mostra os registros reais e permite exclusão confirmada de um dia civil exato, com validação de data/guard e preservação dos demais dias. Save no host local não tenta remover a rota raiz. Sliders e formulário existentes continuam funcionando, com escala1–5 e métricas do repositório validadas no contrato anterior0–10. Caminho remoto anterior e proteções de sessão foram preservados; retorno de navegação legado agora exige rota que possa ser fechada.

main_local navega entre Tarefas, Finanças, Hábitos, Metas e Check-in na mesma sessão/banco. Pacote padrão e main.dart não ativados para Local-First. Target nativo protegido pela guarda simétrica Gradle. Arquivos alterados: checkin_repository.dart, check_in_provider.dart, checkin_controller.dart, checkin_screen.dart, main_local.dart, android/app/build.gradle.kts. Novos: checkin_repository_local_test.dart, local_checkin_native_test.dart, run-checkin.ps1, assert-checkin.ps1 e este relatório. Sem mudança de schema11, migração UID, chaves ou aliases.

## Validação

- stage9-checkin-tests.log:63/63PASS, incluindo8 novas regressões locais SQLite/controller. CRUD/stream diário, provider sem SDKs, sync inerte, replaces concorrentes atômicos, exclusão exata com dia vizinho preservado, métricas inválidas, detach e construtor recusando banco remoto.
- stage9-regressions.log:217/217PASS com regressões dos cinco módulos adaptados. Falhas remotas históricas fora dessa seleção continuam documentadas nas etapas anteriores; testes/guards não removidos.
- Análise geral inicial0. Harness adicionou um import redundante apontado como info; import removido sem supressão, stage9-analyze-final.log0issues. Supressões globais herdadas continuam pendentes de auditoria.
- Profile AOT447tasks PASS2m02; padrão debug ARMv7/ARM64/x86_64,448tasks PASS1m28. APK real não instalado.

## Android real e preservação

stage9-native-checkin/checkin-decision.json: **LOCAL_CHECKIN_ANDROID=PASS;88checks**,32seed+28novo processo+28cold boot. Teste real SDK integration_test/binding, sem mocks de armazenamento, sem pm clear ou recriação de userdata. Sliders acionados por gestos sobre os controles reais, sem atribuir valores ao controller no harness.

UI salvou5/5/5, editou o mesmo dia para1/1/1, abriu histórico, confirmou exclusão do dia e conferiu tabela/lista vazias. Salvou novamente5/1/3, que permaneceu entre processos e reboot, com mesmo ID, fingerprint integral da linha e hash do banco fechado. Todos os dados são sintéticos. Exclusão do teste ocorreu somente sobre o registro sintético recém-criado, pelo mesmo fluxo da aplicação.

Conteúdo/status da tarefa, despesa25.5, hábito com duas datas e duas metas com progresso1 preservados, conferidos no banco e por navegação real. Verificador compara taskId/transactionId/habitId/goalsFingerprint/profileId/keyFingerprint com o gate Metas anterior. SQLite integrity_check=ok, arquivo pessoal criptografado, chave nativa legível, journal READY, fila vazia, FirebaseApps0, plugins remotos não registrados, INTERNET negada, modo avião1 antes/depois e boot_id diferente.

AVD LifeOSRecovery17 API34/x86_64 com as limitações já registradas: SwiftShader, Vulkan desativado e Skia somente lab; opt-out depreciado. Renderer padrão, hardware físico/StrongBox e outras APIs não homologados. Warnings Gradle/KGP herdados permanecem; VM service HTTP indisponível com INTERNET negada não bloqueou o binding/teste.

## Critério

GO focal para Check-in offline neste host isolado. Próximo Estudos, seguido da integração completa de Foco e demais módulos. Notifications ownership, migração UID preparada/verificada, segurança/perfil/configurações e Premium híbrido continuam pendentes. Sem mudanças de produção, landing, credenciais, Firebase/Google Cloud, Billing, serviços faturáveis; sem push/deploy/publicação.

LOCAL_CHECKIN_ANDROID=PASS; APP_WIDE_OFFLINE=NOT_VERIFIED; PREMIUM_HYBRID=NOT_IMPLEMENTED; LOCAL_IDENTITY_GATE=BLOCKED; lançamento NO-GO; ROLLOUT=CLOSED.

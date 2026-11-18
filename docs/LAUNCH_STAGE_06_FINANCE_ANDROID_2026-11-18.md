# Lançamento Local-First — etapa 6: navegação e Finanças Android

Base b10e914b71f138ae314978b1f8cbbf9afb356023, branch refactor/launch-local-first-20261117, fonte oficial C:/life_os. Checkpoint dos arquivos alterados e hashes em stage6-before/ no workspace privado. Backend independente b316df4302e8ae88e5d17af01780d831c0896ab9 permanece limpo e sem alterações.

## Integração

O host de desenvolvimento main_local.dart agora permite alternar entre as telas reais de Tarefas e Finanças. A conexão criptografada e a sessão permanente permanecem na raiz, sem reabrir/criar perfil a cada navegação e sem instanciar Auth/Firestore.

TasksScreen ganhou opção showFocusShortcut, com default true para preservar o fluxo legado. O host local usa false enquanto Foco não estiver adaptado e homologado; não apresenta um atalho para uma rota não implementada. O restante dos módulos continua fora dessa navegação até suas próprias etapas. main.dart e o pacote padrão não foram convertidos para Local-First.

O harness Android aceita somente títulos sintéticos ou números decimais estritamente limitados. O runner envia os eventos de texto do Android e nunca usa pm clear nesta etapa: a tarefa e a chave já qualificadas precisavam permanecer na instalação. O novo target de Finanças também é protegido pela guarda simétrica de pacote/entrypoint do Gradle.

## Evidência real

stage6-native-finance/finance-decision.json: **LOCAL_FINANCE_ANDROID=PASS; 60 checks**.

- Seed22: UI real de receita100,50 e despesa25,50, saldo75, exclusão da receita pela linha correta, limite Free3 na conexão real, navegação e persistência da despesa.
- Novo processo19: despesa, identificador, perfil, chave e banco fechado permanecem idênticos.
- Cold boot19: reboot real do guest, modo avião medido antes/depois, mesmos dados e hashes. A instalação não foi limpa nem recriada.
- O verificador compara todas as rodadas financeiras com o relatório anterior de Tarefas: mesmo perfil, taskId e fingerprint da chave. O conteúdo/status completo da tarefa foi conferido dentro do app após navegar entre módulos.
- Banco pessoal permanece criptografado, integrity_check=ok, journal READY e fila remota vazia. FirebaseApps=0, plugins remotos não registrados e INTERNET negada pelo Android.

O teste usa a aplicação e as telas oficiais no AOT profile, API34/x86_64, no AVD descartável preservado. Não há mocks de armazenamento nativo. A origem anterior é stage4-native-app-android-input, com48checks aprovados; seus arquivos não foram sobrescritos. Dados exclusivamente sintéticos.

## Arquivos e verificações

Alterados: lib/main_local.dart; lib/features/tasks/presentation/tasks_screen.dart; android/app/build.gradle.kts; LocalLabHost.kt; tools/local_app_homologation/run-tasks.ps1. Novos: integration_test/local_finance_native_test.dart; tools/local_app_homologation/run-finance.ps1 e assert-finance.ps1; este relatório. Schema continua11, sem migração de dados ou chaves.

- stage6-regressions.log:65/65PASS, incluindo53 testes de Finanças e12 de Tarefas.
- stage6-analyze.log: nenhum issue reportado pela configuração vigente. Supressões antigas do analyzer continuam pendentes de auditoria; isso não significa que todos os lints do projeto foram habilitados ou resolvidos.
- Formatação aplicada.
- stage6-native-finance-build.log: profile AOT PASS,447tasks,2m02.
- stage6-legacy-build.log: startup padrão debug ARMv7/ARM64/x86_64 PASS,448tasks,1m55. APK do pacote real não instalado.

## Critério

GO focal para Finanças Free e navegação Tarefas/Finanças nesse host Android qualificado. Mesmas limitações gráficas da etapa4: SwiftShader/Vulkan desativado/Skia somente no laboratório, com opt-out depreciado pelo SDK. Renderer padrão, hardware físico/StrongBox, outras APIs Android e todos os módulos ainda não estão homologados.

LOCAL_FINANCE_ANDROID=PASS; APP_WIDE_OFFLINE=NOT_VERIFIED; PREMIUM_HYBRID=NOT_IMPLEMENTED; LOCAL_IDENTITY_GATE=BLOCKED; lançamento NO-GO; ROLLOUT=CLOSED.

Pendentes: hábitos/metas, estudos, saúde/meds/água/ciclo, Foco, check-in, Home/Dashboard/analytics locais, Mercado, perfil/configurações/segurança, notifications ownership, migração UID verificada e Premium híbrido. Não houve alterações de produção, credenciais, landing, Firebase/Google Cloud, push, deploy ou serviços faturáveis. SHA final registrado no workspace privado após commit.

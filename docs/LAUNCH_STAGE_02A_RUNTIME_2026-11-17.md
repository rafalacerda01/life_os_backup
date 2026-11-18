# Lançamento Local-First — etapa 2A: sync e logging

Continuidade da branch refactor/launch-local-first-20261117 em C:/life_os. Base da etapa: ec83689bdd20671b38a5b2275806ff6fefa600bb. Backend, dependências, chaves e schemas não foram alterados.

## Arquivos e comportamento

- sync_manager.dart: factory local, processamento remoto imutavelmente desabilitado para fila de AppDatabase localOnly, inclusive quando o caller usa o construtor genérico. Não realiza manutenção, leitura da fila, envio ou retry nesse modo. Não declara sucesso remoto para itens históricos e não autoriza descarte por esse caminho.
- sync_manager_provider.dart: ramo local é escolhido antes de ler providers Firebase/Firestore, criar transportes ou WaterV2Processor remoto.
- sync_queue_store.dart: expõe somente a política localOnly da conexão ao manager.
- app_logger.dart: remove import e instanciação implícita de Crashlytics. Adapter remoto opcional recebe relatório sanitizado; falhas do logger não substituem a falha original. Módulos locais podem registrar erros sem Firebase inicializado.
- main.dart legado: instala explicitamente o adapter Crashlytics após Firebase.initializeApp. Não troca o modo de startup, login ou rotas.
- Novos testes local_sync_runtime_test.dart e local_app_logger_test.dart: usam SQLite e providers sem inicializar Firebase, com contadores de acesso remoto/maintenance; conferem preservação da fila histórica e sanitização.

Arquivos removidos: nenhum; nenhum teste apagado. O constructor remoto e os recursos ainda consumidos pelo fluxo legado permanecem até a adaptação dos módulos.

## Testes e triagem

- dart format: PASS.
- flutter analyze --no-pub: PASS, zero issues. Dois lints novos de initializing formals foram corrigidos sem suppressions.
- Novos testes + LocalMutationGate: 27 PASS.
- Suíte ampliada de SyncManager/SyncQueue/AppLogger + seis testes novos: 123 PASS /15 FAIL.
- Baseline limpo ec83689, mesmas três suítes antigas e dependências: 117 PASS /15 FAIL. Os 15 nomes de falha são idênticos. Comparação registrada em stage2a-baseline-comparison.json no checkpoint privado.

Os failures antigos envolvem fixtures remotas que esperavam alcançar Firestore/HTTP, mas recebem TRUSTED_LOCAL_SESSION_CLOSED antes do envio, ou aguardam callbacks de envio que não ocorrem. Não são regressões introduzidas nesta etapa. Não foram relaxadas guardas P1, falsificada admissão ou apagados testes para produzir verde. A conciliação/retirada desses contratos faz parte do inventário de legado da missão.

A primeira resolução pub do baseline produziu package_config e retornou 1 pela limitação conhecida de symlink desktop; os testes --no-pub executaram efetivamente. Nenhuma configuração global do Windows foi alterada. Logs preservados.

## Estado e limites

Operacional em testes focais: instanciar o manager local sem Auth/Firestore, manter fila histórica intacta e registrar erros de domínio sem depender de SDK remoto. A homologação Android de armazenamento da etapa 1 permanece registrada; esta etapa ainda não é homologação do aplicativo completo ou de todas as telas.

Critério: GO para as novas fronteiras focais, com dívida remota preexistente explícita. Lançamento NO-GO; LOCAL_IDENTITY_GATE=BLOCKED; APP_WIDE_OFFLINE=NOT_VERIFIED; ROLLOUT=CLOSED.

Ainda faltam journal de criação/recuperação do perfil, admissão entre processos, entrypoint/flavor local, módulos, ownership de notificações, migração UID verificável e Premium híbrido. main.dart segue legado; não houve push, deploy, publicação ou execução do APK oficial. O SHA deste commit está no registro privado da missão, evitando referência circular.

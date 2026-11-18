# Lançamento Local-First — etapa 1: contrato de armazenamento local

Branch oficial: refactor/launch-local-first-20261117 em C:/life_os, a partir de 666819f34f41f4156c5fdb764dead8611624a3d1. Backend independente continua limpo em b316df4302e8ae88e5d17af01780d831c0896ab9; nenhum arquivo backend foi modificado nesta etapa.

## Preservação

243 hashes da entrega de integração anterior foram verificados antes das alterações. Novo checkpoint privado em launch-local-first-20261117/preservation, fora de build: bundles completos verificados dos repositórios app/backend e da branch focal, identidade/status/branches/worktrees. Os checkouts estavam limpos, portanto não havia arquivos pendentes a copiar. Credenciais/configurações protegidas permanecem referenciadas por hashes, sem valores neste relatório. O fork SecureStorage 10.3.1 e sua licença não foram alterados.

## Alterações

- database_sync_policy.dart: política imutável explícita localOnly/remoteEnabled e erro de enqueue desabilitado.
- app_database.dart: localOnly valida identidade local; transações locais preservam atomicidade sem produzir SyncQueue; helper de enqueue recusa a operação. Três triggers SQLite TEMP bloqueiam INSERT/UPDATE/DELETE de filas históricas, inclusive SQL direto, DAOs e batches. Não alteram o schema persistido, que continua 11. Upgrade não homologado é recusado no modo local.
- local_mutation_gate.dart: uma conexão local não pode capturar remote-send permit. Fences de sessão/geração existentes permanecem.
- local_database_identity.dart e local_installation_identity_service.dart: uma única gramática estrita do UUID local; bindings Firebase/geração não são reinterpretados como perfil local.
- local_device_session.dart: factory padrão localOnly; opener que fornece conexão remota é fechado e rejeitado antes de publicar a sessão.
- user_database_factory.dart e database_encryption.dart: caminho local dedicado, sem recuperação implícita, conversão plaintext, checkpoint destrutivo de WAL ou limpeza de artefatos. Reabertura valida cifra, integridade e versão em conexão read-only. Schema não homologado, arquivo vazio/plaintext, órfãos e artefatos de migração bloqueiam, sem criar outra chave/banco. O caminho legado mantém sua API e comportamento anteriores.
- Novos testes database_sync_policy_test.dart e local_profile_database_factory_test.dart; regressões de local_device_session_test.dart atualizadas para conexões locais explícitas. O teste de identidade incorreta agora usa outro UUID local válido, preservando o que ele verifica.
- Instrumentação Android recovery_probe.dart e assert-local-profile.ps1: testa transação local, bloqueio de enqueue SQL, recusa de permit e fila histórica sintética preservada após tentativa de cleanup. README atualizado; nenhum teste foi apagado.

**Arquivos removidos: nenhum.** O inventário ainda encontrou consumidores Auth/Firestore/SyncManager; sua remoção depende da adaptação dos módulos e de comprovar ausência de consumidores necessários. Mercado/lista de compras não foi encontrado como módulo existente na busca inicial e permanece no escopo planejado.

## Testes reais executados

| Verificação | Resultado |
| --- | --- |
| dart format dos fontes alterados | PASS |
| flutter analyze --no-pub em C:/life_os | PASS: zero issues |
| Regressões Flutter focais, 15 arquivos | PASS: 233 testes |
| Android debug completo, main.dart oficial, ARMv7/ARM64/x86_64 | PASS: build offline, 431 tarefas, 1m27 |
| Sonda Android AOT profile, closure real de 33 bibliotecas | PASS: build offline, 133 tarefas |
| Matriz de compatibilidade SecureStorage | PASS: 17 casos, 210 assertions |
| Núcleo/perfil/política local-only | PASS: cinco relatórios, 33 assertions |

Houve uma falha inicial no teste que construía a identidade literal wrong-identity em conexão local; a nova validação impediu sua construção. A fixture foi corrigida para um segundo UUID válido e o teste continua exigindo fechamento/rejeição da identidade errada. Nenhuma guarda de produção foi relaxada.

Android real: novo AVD LifeOSRecovery17, serial emulator-5584, Android14/API34 google_apis x86_64 e userdata exclusiva em launch-local-first-20261117/stage1-native. Só foi instalada/limpa a sonda sintética dev.lifeos.recovery.life_os, sem Firebase/Billing. Nenhum APK oficial foi instalado ou executado. KeyStore, MethodChannel, sqlite3mc/chacha20, factories e schema reais; não se substituiu homologação por mocks.

Modo avião confirmado pelo serviço Connectivity. Boot IDs: 512af0a8-d1b7-4db5-a71b-2538adeb4220 → feedfd18-9c4f-4181-b538-c8a64632b132 → ac6eaa70-4ce7-4001-a238-50619b580436. Reboot real do guest, não apenas provider/engine. Identidade, tarefa, chaves e hashes de domínio sobreviveram; a fila histórica sintetizada permaneceu igual e a tentativa de cleanup foi atômica.

Logs, JSON, snapshots, origem dos fontes e SHAs dos commits ficam no checkpoint privado launch-local-first-20261117. Os validadores versionados calcularam os resultados. Os SHAs finais desta etapa são registrados fora deste documento para evitar referência circular ao seu próprio commit.

## O que está operacional e o que falta

Operacional no escopo homologado: abrir/reabrir perfil local criptografado atual; gravar transação local sem enqueue; bloquear escrita/remoção de fila histórica e envio remoto; recusar material/schema não qualificados sem limpar dados; manter compatibilidade dos bancos e aliases existentes testados.

O aplicativo completo ainda inicia pelo fluxo legado. Nenhuma tela ou módulo completo foi declarado Local-First nesta etapa. Auth/Firestore, telemetria remota e Billing ainda têm consumidores, e o backend P1 mantém a dívida de testes conhecida. Não houve migração de UID real nem adoção de ownership P1.

Riscos pendentes: janela de falha na primeira criação pode deixar banco cifrado schema0 bloqueado; é necessária recuperação por journal explícito e qualificado, sem tratar qualquer schema0 como novo. A criação de identidade ainda precisa admissão por lock entre isolates/processos no startup. Faltam ownership local de notificações, todos os módulos, contrato de entitlement híbrido, testes de aplicação completa, dispositivos físicos/outras APIs e crash em cada estágio relevante. O CBC histórico continua sem autenticação; sua migração exige gate próprio.

**Critério da etapa: GO para o contrato local-only no escopo testado. Lançamento: NO-GO. LOCAL_IDENTITY_GATE=BLOCKED; APP_WIDE_OFFLINE=NOT_VERIFIED; ROLLOUT=CLOSED.**

Próxima etapa: runtime local com journal/admissão, logging sem Firebase implícito, SyncManager desabilitado por política do banco e Tarefas sem Auth. Depois adaptar os demais módulos preservando limites Free/Premium. main.dart não foi trocado para o novo startup nesta etapa. Sem push, deploy, publicação, alteração da landing, credenciais, serviços faturáveis ou dados reais.

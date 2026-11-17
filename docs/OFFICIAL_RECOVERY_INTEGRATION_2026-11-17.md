# Integração oficial da Recovery — 2026-11-17

As correções aprovadas estão integradas fisicamente em **C:/life_os**, com o backend independente em **C:/life_os/backend**. A versão corrigida pode continuar a ser desenvolvida nesses diretórios pelo VS Code. Não houve push, deploy, publicação ou ativação do startup Local-First.

| Repositório | Branch em uso no checkout oficial | Fonte aprovada |
| --- | --- | --- |
| App, C:/life_os | integration/recovery-accelerated-20261117-app | recovery/local-first-native-storage-20261117, bfa2112c0e150d4392e9cb819f44e648315fef5c |
| Backend, C:/life_os/backend | integration/recovery-accelerated-20261117-backend | recovery/p1-preserved-backend-20261117, c3e6197b8ad18e292c73138a8d52b5147080e473 |

## Preservação e compatibilidade

Antes de alterar qualquer arquivo, foram conferidos **538 hashes** da entrega Recovery anterior. Novo checkpoint privado em `official-integration-20261117/preservation`, no workspace da missão anterior e fora de C:/life_os/build: bundles completos verificados dos repositórios app/backend/focal, patches binários staged/unstaged, branches/worktrees/commits e cópias dos 32 arquivos pendentes do app e 14 do backend, com SHA-256. Credenciais/configurações locais protegidas receberam somente fingerprints; não foram copiadas para commits.

O HEAD inicial oficial do app era be0e507f50fe25e5327fda8a8df3c5048b1c59b2; backend a5194bb0e9503281b4bceebb8f04fd528de07eca. As branches review anteriores continuam apontando para esses commits; a focal refactor/offline-first-premium-hybrid-20261116 continua em 6caee6e31316380f2a859df29a6e85660b63c753 e preserva o ancestral 3a0354375e5b0905893ae33aa8329479a7984197. Novas branches de integração foram abertas nos checkouts oficiais com o conteúdo pendente preservado.

Comparação individual dos 91 paths da candidata app: **31 já idênticos, 56 novos, 3 alterações em arquivos iguais ao ancestral e 1 sanitização de fixture demo**. Backend: os 14 arquivos já eram idênticos à Recovery. Nenhum conflito ou alteração P1 mais recente foi sobrescrito. O único arquivo pendente alterado intencionalmente foi tools/p1_android_native_gate/gradle.init.gradle, substituindo um literal de demo com aparência de API key por expressão explicitamente sintética. O original permanece no backup privado; o valor não é reproduzido aqui.

Após o checkpoint local do P1, os seis commits de correção/preparação/documentação foram aplicados individualmente por cherry-pick. O tree Git resultante coincidiu integralmente com bfa2112 antes dos ajustes exclusivos de integração. A diferença final deliberada consiste no pin do novo commit backend e neste relatório. Os 45 outros arquivos P1 mantêm seus hashes originais; os 46 backups e seis configurações protegidas são reconferidos no fechamento.

## Correções disponíveis no diretório oficial

| Área | Arquivos / resultado |
| --- | --- |
| VS Code e Dart | .vscode/settings.json e analysis_options.yaml: excluem cópias antigas em build/**, .dart_tool e descoberta Dart do Java vendorizado. Não acrescentam suppressions de erros reais. |
| SecureStorage Android | third_party/flutter_secure_storage, pubspec.yaml e pubspec.lock: fork 10.3.1 com origem pública, licença/avisos preservados, override local efetivo em C:/life_os. |
| Fronteira nativa | LifeOsPreservingStorage.java, FlutterSecureStoragePlugin.java e crypto/EncryptedSharedPreferences.java: leitura por formato existente, sem reset/migração implícitos ou geração de chaves durante leitura. |
| Núcleo preparado | lib/core/database/local_installation_identity_service.dart, local_installation_identity_provider.dart, local_installation_storage_inspector.dart e local_device_session.dart; três arquivos de regressão em test/core/database. |
| Regressões Android | tools/local_native_storage_recovery: preparador mínimo, sonda Dart, helper Kotlin, runner e validadores de armazenamento/perfil. |
| P1 existente | Código local/concorrência/cleanup, contratos remotos e respectivas fixtures consolidados sem restaurar histórico antigo. Inventário individual em RECOVERY_P1_INVENTORY_2026-11-17.md. |
| Backend independente | Os 14 arquivos preservados foram commitados em seu próprio repositório; nenhuma correção funcional nova foi inventada na integração. O app referencia esse novo SHA pelo gitlink backend. |

O inventário completo de persistências continua em RECOVERY_STORAGE_INVENTORY_2026-11-17.md. Relatórios Recovery anteriores são históricos: suas observações sobre os checkouts oficiais ainda não alterados descrevem a missão anterior. Este relatório registra a integração oficial autorizada e seus testes novos.

## Commits locais

| Repositório / assunto | SHA |
| --- | --- |
| App: checkpoint do P1 oficial | 5a43ebfd0ddfa271a0257d29100a8d39fee75326 |
| App: exclusões do analisador | 8f40fcf7f7614ce5b9aebcfa540fe41c31a9c59b |
| App: correção SecureStorage | ea4ed2ed90cd1664805a93a207f3911597ab05de |
| App: identidade/sessão preparadas | 0c4ef3e82dc757e9eaa4bb876154b5157035bc1d |
| App: regressões Android | 1dcd69a3d7bbd3742663f807ff3c977cf6832662 |
| App: inventário e resultado Recovery | 594b6dc61b6541e89491e3e632bf5101517061d6 |
| App: limites CBC/proveniência | 26645972deb3dc635707be7e3a413efe165e5d40 |
| Backend: checkpoint independente | b316df4302e8ae88e5d17af01780d831c0896ab9 |
| App: pin do backend oficial | 9970cd41cc3991ddb081e2fa074bace07c42ae09 |

O commit documental que contém este relatório e os HEADs finais constam em commits-final.json da entrega privada. O SHA do próprio relatório não é embutido em seu conteúdo. Listagem completa de paths/estados em app-integrated-files.txt e backend-integrated-files.txt; bundles finais verificáveis ficam no mesmo checkpoint externo.

## Validação executada após integrar

| Verificação | Resultado | Evidência privada |
| --- | --- | --- |
| Formatação dos nove fontes Dart preparados/focais | PASS, zero alterações necessárias | dart-format.log |
| flutter analyze --no-pub em C:/life_os | PASS, zero issues | flutter-analyze.log |
| Regressões Flutter, 13 arquivos | PASS, 205/205 | flutter-focal-tests.log |
| Backend focal, cinco arquivos | PASS, 100+18=118, sem skip | backend-focal-tests.log e backend-partitioned-tests.log |
| Gradle debug completo, main.dart oficial | PASS, ARMv7/ARM64/x86_64; ABIs conferidas dentro do APK | android-official-build-final.log e android-debug-artifact.json |
| Build normal sem init script de laboratório | PASS, 431 tarefas, 1m26 | android-standard-online-build.log |
| flutter pub get --offline, nova execução | PASS, exit0, override local resolvido | flutter-pub-official-recheck.log |
| Sonda AOT profile construída dos fontes oficiais | PASS; 32 bibliotecas locais, fork de C:/life_os | native-prepare.log e native-probe-build.log |
| SecureStorage Android real | PASS, 17 casos /210 assertions | native-lab/native-decision.json e native-results |
| Núcleo local preparado Android | PASS, 4 casos /18 assertions | native-lab/local-profile-core-decision.json |
| VS Code, workspace life_os | Branch/histórico integrados visíveis; Problems sem problemas detectados | vscode-verification.json |

O primeiro pub get atualizou dependências/metadados e retornou 1 por symlink de desktop Windows; a repetição sem novas mudanças terminou 0. Não foi ativado Developer Mode nem alterada configuração global. Builds desktop continuam NOT_VERIFIED.

A tentativa inicial de build offline das três ABIs encontrou o JAR Flutter ARMv7 ausente do cache. O artefato público foi obtido por HTTPS validado, com origem/SHA-256 em android-debug-artifact-provenance.json, e usado em Maven privado para um build offline aprovado. Um teste sem init script ainda não encontrou o artefato no cache padrão. O build normal seguinte, permitindo resolução pública padrão do Gradle, passou sem depender desse Maven privado. Nenhuma alteração de trust/TLS, credenciais ou projeto Gradle foi feita para contornar o problema. Logs intermediários de falha permanecem preservados.

O APK oficial foi apenas compilado; não instalado, executado, publicado ou distribuído. O VS Code já mostrou a nova branch e o histórico de correções no workspace oficial, com “No problems have been detected in the workspace”. A janela elevada não respondeu às tentativas de navegação por automação: a aba nativa específica não foi visualmente confirmada. Sua presença, conteúdo e hash no diretório oficial foram comprovados por leitura de arquivo e comparação Git; pode ser aberta pelo caminho listado acima.

## Homologação Android real da implementação integrada

Novo AVD LifeOSRecovery17 em userdata própria de official-integration-20261117/native-lab, serial emulator-5584, Android14/API34 google_apis x86_64. O AVD da Recovery anterior foi preservado; o novo processo usou ANDROID_AVD_HOME privado. Somente a sonda dev.lifeos.recovery.life_os foi instalada/limpa. O pacote oficial com.rafalacerda.lifeos foi comprovadamente ausente antes e depois. Nenhum dado real foi usado.

Sonda AOT profile debuggable apenas para run-as de laboratório; não tem SDK Firebase/Billing. MethodChannel, AndroidKeyStore, ESP/Tink, factories P1/schema11 e sqlite3mc/chacha20 reais. Três bancos sintéticos: legado, UID e binding por geração. Hashes de arquivos, metadados de aliases, valores conhecidos e integrity_check comprovam preservação, sem exportar segredos KeyStore.

Passaram leitura vazia sem criação de material, consumidores antigos/propostos e chamadas concorrentes, GCM/ESP/CBC histórico sem marcadores, readAll com corrupção, material wrapped/master ausente, escritas explícitas, delete por chave e recusa de bulk delete/biometria. Nenhum erro de decifragem causou reset ou fallback para ciphertext.

Dois reboots reais do guest, com modo avião confirmado pelo serviço Connectivity e configuração persistida:

- Matriz: 92c12fa0-d423-4527-84b3-fca911db7789 → 809ae4b9-c904-42ad-b8b6-20a61be051de.
- Perfil preparado: 809ae4b9-c904-42ad-b8b6-20a61be051de → 6dc7bc1d-80de-461a-a034-2dceefd61d64.

O broadcast protegido AIRPLANE_MODE foi recusado pelo Android; a ativação foi feita pela interface suportada `cmd connectivity airplane-mode enable`, sem mudar permissões. O serviço registrou enabled antes/depois. O perfil criou UUID permanente e tarefa por DAO, reabriu ambos e preservou arquivo/aliases após reboot. Não equivale a homologar TasksRepository, telas, entitlement ou aplicativo inteiro sem Firebase. O emulador foi sincronizado e encerrado no fechamento, com userdata/evidências mantidas.

## Falhas e limites que continuam abertos

**Backend ampliado: FAIL preexistente.** Além do subconjunto aprovado, foi executado account-birth-cleanup.test.js: 143 testes, 13 PASS e 130 FAIL. A mesma suíte foi repetida numa worktree limpa de c3e6197 com as mesmas dependências: exatamente os mesmos 130 nomes falharam. A primeira falha retorna ACCOUNT_DELETION_BLOCKED/503 numa fixture que esperava exclusão integral. O tree backend oficial é igual à fonte Recovery; a integração não introduziu essa diferença. Não foram relaxadas as guardas de exclusão/receipts para fazer fixtures antigas passarem. A dívida P1 exige investigação/conciliação própria. backend-expanded-baseline-comparison.json e os dois logs preservam os resultados.

Outros limites: Node executado 24.17.0, engines de produção 22.x ainda NOT_VERIFIED; nenhuma suíte backend total aprovada. Gate nativo limitado a API34 x86_64 e formatos atuais não biométricos; hardware físico/StrongBox, outras APIs, múltiplos processos, namespaces arbitrários e crash em cada estágio da primeira escrita continuam NOT_VERIFIED. CBC legado não tem autenticação e nem toda adulteração pode ser detectada. Migração para formato autenticado ou adoção de dados UID requer gate separado.

Os módulos continuam com Auth/Firestore/SyncManager; AppDatabase ainda pode enfileirar e fornecer remote permits. A guarda de stores P1/registro nativo continua bloqueante. main.dart e rotas não foram trocados; o núcleo preparado permanece desconectado do startup. Premium, limites Free e Google Play não foram alterados, nem liberados por flag local.

**Estado final:** correções integradas no projeto oficial; LOCAL_NATIVE_STORAGE_GATE=PASS no escopo Android sintético acima; LOCAL_PROFILE_CORE=PASS; APP_WIDE_OFFLINE=NOT_VERIFIED; LOCAL_IDENTITY_GATE=BLOCKED; P1=RED; ROLLOUT=CLOSED.

Próximo desenvolvimento: contrato de ownership P1, identidade neutra e política local-only para repositórios/fila/envios; depois entrypoint de desenvolvimento e módulos/telas testados em modo avião. Não retirar guardas, migrar dados UID reais, ativar startup ou publicar antes desses gates. A landing, Firebase/GCP/Vercel, Billing, credenciais e bancos reais não foram alterados.

# Recuperação Life OS — resultado e ponto de continuação

Data: 2026-11-17, America/Sao_Paulo. Candidata isolada `recovery/local-first-native-storage-20261117`, baseada no P1 local atual e preservando seus arquivos pendentes. **A migração do aplicativo inteiro não está concluída.**

| Critério | Resultado e escopo |
| --- | --- |
| Preservação | PASS: dois checkouts oficiais e branch focal, status/HEAD/branch e 46 arquivos conferidos por hash. |
| Análise Flutter candidata | PASS: zero diagnósticos; não significa que o editor aberto no checkout oficial foi alterado. |
| Compilação Android | PASS: aplicativo completo debug compilado, sem instalar/abrir/publicar o APK oficial. |
| LOCAL_NATIVE_STORAGE_GATE | **PASS na candidata**, Android 14/API34 x86_64, formatos sintéticos ESP/RSA/GCM/CBC, 17 casos e 210 assertions. |
| LOCAL_PROFILE_CORE | PASS: 4 casos/18 assertions; UUID, Drift criptografado e tarefa sintética reabertos após reboot em modo avião. |
| LOCAL_IDENTITY_GATE | **BLOCKED**: ownership/migração P1 e integração do startup/módulos pendentes. |
| APP_WIDE_OFFLINE | **NOT_VERIFIED**: nenhum fluxo completo de telas sem Firebase foi aprovado. |
| P1 / ROLLOUT | **RED / CLOSED**: nenhum resultado autoriza ativação em produção. |

O Gate 02 histórico continua FAIL no seu relatório original. Os checkouts oficiais seguem sem o fork desta candidata; não receberam retroativamente um PASS. A aprovação nativa acima é um novo resultado limitado, reproduzido com a implementação corrigida.

## 1. Preservação e origem

| Repositório oficial | Branch preservada | HEAD preservado |
| --- | --- | --- |
| C:/life_os | review/p1-app-functions-rules-20261029 | be0e507f50fe25e5327fda8a8df3c5048b1c59b2 |
| C:/life_os/backend | review/p1-backend-consolidation-20261029 | a5194bb0e9503281b4bceebb8f04fd528de07eca |
| Worktree focal oficial | refactor/offline-first-premium-hybrid-20261116 | 6caee6e31316380f2a859df29a6e85660b63c753 |

Focal aprovado `3a0354375e5b0905893ae33aa8329479a7984197` preservado como ancestral. Focal local dois commits à frente da referência remota observada. Consulta read-only ls-remote confirmou main remota app 7b5c5ad, focal c75a141 e review be0e507; backend main 8d140a5 e review a5194bb. Nenhum fetch/pull/reset substituiu P1 recente.

Backups privados fora de C:/life_os/build, em `../../preservation`: bundles completos verificados, patches binários staged/unstaged e 32 arquivos app +14 backend copiados com SHA-256. Ignorados de build não são apresentados como backup de dados reais. A verificação final exige HEAD, branch, status, arquivos originais/cópias e hashes de bundles iguais ao início. Shared Git recebeu somente novas refs/worktrees/commits isolados; os checkouts principais não foram trocados.

Uma ocorrência com formato de API key em fixture Gradle demo foi retirada apenas da cópia candidata e substituída por valor explicitamente sintético. Valor original não aparece em relatório e permanece no backup privado. Bundles contêm históricos preexistentes: não publicar backups/artefatos privados.

## 2. Problemas do VS Code: antes/depois

O número 80 informado não foi reproduzido neste estado. O painel observado mostrou **50** e a análise do checkout oficial reproduziu **41 ERROR, 0 WARNING, 9 INFO**. Todos apontavam para cópia antiga em build/local-first-focal-official-20261116-r1/snapshot/app. Fontes copiados e imports package: resolviam classes homônimas AppDatabase/LocalDatabaseIdentity em bibliotecas distintas, causando incompatibilidades. Não eram 41 defeitos independentes do lib atual.

| Coorte | Errors | Warnings | Infos | Total |
| --- | ---: | ---: | ---: | ---: |
| Checkout oficial, incluindo snapshot antigo | 41 | 0 | 9 | 50 |
| Worktree fiel ao P1, dependências resolvidas | 0 | 0 | 0 | 0 |
| Reprodução controlada de cópia aninhada, sem exclusão explícita | 61 | 3 | 9 | 73 |
| Mesma reprodução com exclusão build/** | 0 | 0 | 0 | 0 |
| Candidata final, flutter analyze --no-pub | 0 | 0 | 0 | 0 |

Correção: analysis_options.yaml exclui build/**; .vscode/settings.json exclui build/.dart_tool e Java vendorizado da descoberta de projetos Dart, mantendo a análise nativa pelo build Gradle. Política de lint herdada preservada. Nenhum erro real foi convertido em ignore por arquivo. O workspace externo LifeOS-Recovery.code-workspace abre apenas os dois projetos preparados. O editor/checkout oficial não foi reconfigurado; ainda pode mostrar os 50 até usar a worktree corrigida. Logs e diagnostic-counts.json distinguem as coortes 50 e 73.

## 3. P1 e correções

Todos os 46 arquivos pendentes estão individualmente classificados no [inventário P1](RECOVERY_P1_INVENTORY_2026-11-17.md) e em p1-pending-inventory.json privado. REAPROVEITAR preserva mecanismos locais, ADAPTAR mantém fences/bindings antes da separação remota, PRESERVAR retém contratos/homologações anteriores. Nenhuma remoção futura foi afirmada sem prova de obsolescência.

Commits locais de preservação app/backend consolidam os arquivos pendentes sem restaurar a linha focal por cima do P1. As únicas correções comportamentais novas são a fronteira Android de armazenamento e as guardas dos componentes locais preparados. Consulte commits.json e delivery/*changed-files.txt para hashes completos e todos os arquivos; este relatório não contém seu próprio hash para evitar referência circular.

O [inventário de persistências](RECOVERY_STORAGE_INVENTORY_2026-11-17.md) detalha schema 11/17 tabelas, nomes por UID/geração/binding, chaves e aliases, SharedPreferences/DataStore, registro nativo, sidecars/journals/artefatos de criptografia, caches SDK e Premium.

## 4. Causa nativa e correção

flutter_secure_storage 10.3.1 upstream pode inicializar/migrar durante read/readAll, com opções efetivas dependentes do primeiro consumidor; falha em readAll pode alcançar reset global. Trocar somente flags Dart já tinha sido rejeitado no Gate 02. O fork Android desta candidata remove esse despacho automático:

- Formato persistido decide como ler; não há cache de configuração do primeiro consumidor. Um lock serializa engines no mesmo processo.
- ESP abre somente keysets/master existentes. Custom RSA OAEP/PKCS1 e AES GCM/CBC lê wrapped key/alias/config existentes; CBC histórico sem marcadores tem reconhecimento restrito.
- Store vazio lido permanece vazio; corrupção/material ausente/mistura/formato desconhecido retorna erro estável, sem fallback para ciphertext, reset ou recriação de chave.
- Escrita explícita provisiona RSA OAEP/AESGCM somente em store inequivocamente vazio. Falha parcial deixa órfãos bloqueantes para recuperação explícita.
- deleteAll é recusado; delete por chave preserva o contrato de limpeza capturada. Pedidos biométricos/AES-wrapping são recusados antes de tocar o store.

Código em third_party/flutter_secure_storage, versão 10.3.1, origem pública e licença/avisos retidos. pubspec/lock fixam o fork; Dart API e federados não Android mantidos. Mudanças de whitespace no Java upstream não alteram semântica. LIFE_OS_PATCH.md documenta arquivos e limites.

## 5. Android real, integridade e resultados

AVD **LifeOSRecovery17**, serial **emulator-5584**, userdata exclusiva, Android 14 API34 google_apis x86_64, WHPX. Pacote **dev.lifeos.recovery.life_os**, AOT profile com debuggable restrito ao laboratório para run-as. Nenhuma instalação pessoal/oficial ou dado real foi usado. A sonda não tem Firebase/Billing/backend.

Fixtures usam MethodChannel real, AndroidKeyStore, ESP/Tink e as factories P1 reais com sqlite3mc/chacha20/schema 11. Três bancos sintéticos: nome legado, UID simples e binding P1 por geração. Chaves disponíveis comprovadas por decifragem, conteúdo SQL conhecido e integrity_check; snapshots guardam hashes de arquivos e metadados de aliases, sem exportar segredos KeyStore.

| Grupo | Casos / assertions | Resultado |
| --- | --- | --- |
| Leitura vazia sem criar store/alias | 1 / 4 | PASS |
| GCM: seed, ordem/concorrência, readAll corrompido, wrapped ausente, escritas/deleção | 5 / 71 | PASS |
| ESP: seed, ordem/concor­rência, escritas/deleção, master ausente | 4 / 46 | PASS |
| CBC histórico sem marcadores: seed, ordem/concor­rência, escritas/deleção | 3 / 44 | PASS |
| Recusa biométrica | 1 / 2 | PASS |
| Cold boot: seed, leitura antes/depois | 3 / 43 | PASS |
| Núcleo local: guarda secundária + criação/reabertura/reboot | 4 / 18 | PASS separado |

As 210 assertions da matriz não incluem as 18 do núcleo. O erro de corrupção é esperado e aprovado somente porque preservou todas as entradas/aliases e os bancos voltaram a abrir após restaurar exclusivamente a fixture. Material KeyStore genuinamente perdido não é recuperado magicamente: o comportamento aprovado é recusar sem recriar.

Reboot real `adb reboot`, Android/KeyStore/processo reiniciados, modo avião 1. Boot da matriz: db237d15-a1a4-4723-b25b-580a8013b5e6 → 9735099a-9b5c-44f8-8895-782a9028ee5d. Segundo reboot do perfil: 9735099a-9b5c-44f8-8895-782a9028ee5d → 00160664-55e1-4bca-8f2a-aeb69a5a956d. Não foi apenas recriação de provider/engine. Snapshots de domínio/aliases permaneceram iguais, ignorando apenas artefatos do engine.

Houve uma interrupção de fixture CBC por corrida PackageManager após pm clear, com processo encerrado durante a limpeza e timeout. Log retido; runner passou a aguardar 750ms e lançar com am start -S. Somente o caso interrompido foi repetido. Os JSON finais têm cenário solicitado, assertions não vazias e nenhum fatal. assert-native.ps1 e assert-local-profile.ps1 calculam PASS/FAIL/BLOCKED; exit zero do runner sozinho não aprova nada.

Cold boot atual está PASS no laboratório novo; não altera o BLOCKED histórico do ambiente antigo. WAL/SHM/backup sentinelas não são apresentados como migrações SQLite válidas. Não foi repetida toda a matriz histórica rejeitada.

## 6. Compilação e regressões

| Verificação | Resultado | Evidência privada fora do Git |
| --- | --- | --- |
| dart format, fontes novos/preparados | PASS, 9 arquivos/0 alterações no fechamento | format-final-approved.log |
| flutter analyze --no-pub | PASS, zero issues | flutter-analyze-delivery.log |
| Regressões locais P1, 10 arquivos | PASS, 157 testes | tests-local-regressions.log |
| Identidade/sessão/guarda, 3 arquivos | PASS, 48 testes | tests-local-profile-core-final.log |
| Backend, subconjunto focal | PASS, 118/118, nenhum skip | backend-regressions.log |
| App Android completo debug | PASS, 430 tarefas Gradle, 8m06 | app-build-debug-r2.log |
| Sonda Android AOT profile | PASS; formatos e núcleo | probe-build-*-compat.log, probe-build-local-core.log |
| Preparador reproduzível e análise do projeto mínimo | PASS, 32 bibliotecas locais copiadas; zero diagnósticos | toolkit-prepare-validation.log, toolkit-minimal-analyze-final.machine |
| iOS/Windows/macOS/Linux/Web; Node 22; suíte total backend | NOT_VERIFIED | Backend executado em Node 24.17.0; engines de produção pede 22.x. |

Falhas ambientais intermediárias preservadas: wrapper/local.properties não versionados ausentes na cópia; build Android final usou wrapper Gradle 9.1 equivalente da sonda e somente SDK paths locais. flutter pub no app gerou dependências mas retornou 1 por symlinks Windows; build Android e testes --no-pub passaram, sem habilitar Developer Mode. Comandos finais inicialmente presos ao lock/escrita do SDK no sandbox foram encerrados por PID validado e repetidos com acesso aprovado. Formatação direta inicial teve erro de escrita de telemetria após formatar; repetição aprovada terminou zero. Nenhum desses logs intermediários foi usado como PASS.

Builds usaram caches e artefatos públicos Flutter profile da missão anterior, com origem/hashes registrados e TLS validado. Nenhuma mudança global de trust/TLS, instalação de serviço faturável ou conexão de teste com produção. APK completo compilado não foi instalado nem executado. APK profile da sonda é instrumento de laboratório, não distribuição.

## 7. Base Local-First: feito e pendente

Preparados local_installation_identity_service/provider, local_device_session e local_installation_storage_inspector. Identidade UUID permanente, concorrência por isolate, guarda de banco/sidecars, verificação de persistências em Support/shared_prefs/no_backup/databases, bloqueio de links e stores SDK não qualificados. Provider padrão recusa plataformas não Android. Não há importação desses componentes no main.dart nem troca do router.

No Android, uma tarefa foi persistida por DAO direto no Drift criptografado e reaberta com a mesma identidade após modo avião/reboot. Fila vazia comprova apenas esse teste. **AppDatabase ainda oferece enqueue e permissões remotas; não existe política local-only conectada aos módulos.**

Tarefas, Finanças, Hábitos, Metas, Saúde, Água, Estudos/Foco, Check-in e Notificações têm repositórios/provedores/callbacks com Auth/Firestore/SyncManager. Nenhum módulo completo de UI foi homologado sem Firebase. Círculos não foi desligado nesta etapa; Premium/limites Free e Google Play não foram alterados. Não há Premium liberado por flag local.

## 8. Próximos bloqueios e ordem recomendada

1. Revisar o fork e ampliar homologação para APIs/dispositivos físicos relevantes; múltiplos processos, StrongBox e interrupção em cada estágio da primeira escrita permanecem NOT_VERIFIED. Não alegar suporte biométrico nem outros namespaces arbitrários.
2. Definir ownership de notificações P1, journals e stores secundários para instalação nova. A guarda atual bloqueia registros existentes; não removê-la para destravar startup. Migração real UID/geração exige gate separado e continua proibida nesta missão.
3. Introduzir contrato de identidade local para repositórios, com política explícita que mantenha transações locais e impeça enqueue/envio remotos para perfil local; preservar fila antiga intacta. Testar revogação/fences e modo remoto existente.
4. Preparar entrypoint/flavor de desenvolvimento sem bootstrap Auth/Firestore e injetar a sessão local. Adaptar módulos um por vez, preservar limites Free e desabilitar rotas remotas no modo local. Não fabricar FirebaseUser nem entitlement pago.
5. Homologar CRUD, navegação, notificações, fechamento/reboot e ausência de tráfego em modo avião no aplicativo completo. Só depois reconsiderar LOCAL_IDENTITY_GATE; rollout continua fechado até esses testes.
6. Projetar Premium Híbrido com receipt/entitlement verificável, expiração offline e Google Play; testar separadamente antes de retirar Auth da integração de Billing.

Nenhum push, deploy, merge na main, reset, clean, publicação, limpeza de usuário, alteração de Firebase/GCP/Vercel/Billing/credenciais ou de C:/life_os_landing foi realizado. Backend recebeu somente o checkpoint isolado do trabalho já pendente. A continuação deve partir desta candidata, nunca de main remota antiga.

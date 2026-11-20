# Lançamento Local-First — etapa 21 · Barreira nativa

## Escopo e implementação

Base `9d6ee81eac83298fb3abe5be02ea39d574f76981`. As variantes profile `fenceuid`, `fencep1` e `fencelocal` usam três sandboxes de aplicativo distintas no AVD offline, Android API 34 x86_64. Seus manifestos compilados têm duas Activities e os três receivers de notificações. O ensaio verifica ausência de providers, services e permissão de Internet e presença de `FenceComponentFactory`. O Gradle vincula esses identificadores ao probe sintético e desabilita release para as variantes.

O coordenador valida a identidade, o namespace, a versão do registro, a fase de cadastro e o epoch. Uma trava de arquivo entre processos protege a leitura e a publicação do estado em `noBackupFilesDir`. Um journal pendente impede decisão a partir de um registro anterior. O cadastro sintético só fica pronto depois da preparação e da verificação do fixture. No congelamento, o epoch sobe sob a trava. A Activity Flutter é privada, executa em processo separado e mantém a trava desde antes de `FlutterActivity.onCreate`.

`AppComponentFactory` intercepta os três nomes de classe originais, preservando a identificação dos `PendingIntent`. Boot e atualização podem invocar o receiver de restauração antes de Flutter. A entrega pode remover, exibir ou reagendar uma notificação. A ação do plugin pode iniciar um motor assíncrono. A variante exige admissão antes de delegar a restauração e a entrega local, valida o ID e o payload do fixture com o cache em disco e recusa a ação assíncrona. UID e P1 têm seus callbacks e startup bloqueados quando congelados. Guardas de armazenamento valem antes da delegação.

## Baseline, preservação e limites

O manifesto padrão auditado contém `FirebaseInitProvider`, AndroidX Startup/ProfileInstaller, serviços de Measurement e DataTransport, componentes de autenticação/credenciais e entradas de Billing, além dos três receivers de notificações. Esses caminhos continuam no inventário de escritores e no escopo do próximo gate do pacote oficial. O fork de SecureStorage, `lib/main.dart` e o backend continuam nas versões da base.

A primeira compilação expôs que `OsConstants.O_DIRECTORY` está ausente no SDK Java empregado. A primeira rodada UID recusou o cadastro por causa do alias Android entre o diretório privado entregue pelo framework e o caminho canônico. A correção usa o diretório pai canônico e mantém a rejeição de caminhos indiretos na trava e no journal. A primeira tentativa foi arquivada e só recebeu o APK corrigido depois de confirmar ausência de bancos, preferências e registro de cadastro.

O escopo da admissão atual é o laboratório e seus escritores participantes. O startup oficial exige verificar a autoridade do registro derivado da instalação anterior e usar a coordenação nos SDKs e inicializadores do manifesto padrão. As ações que abrem um motor Flutter precisam de uma admissão válida até o fim do trabalho assíncrono. `AppComponentFactory` exige API 28 ou superior. A prova ocorreu na API 34. As APIs 24–27 suportadas pelo APK padrão ainda exigem uma abordagem e qualificação próprias. [Referência Android de AppComponentFactory](https://developer.android.com/reference/android/app/AppComponentFactory)

## Resultados observados

| Cenário | UID | P1 | Local-First |
| --- | --- | --- | --- |
| Abertura anterior ao cadastro | Recusa nativa, sem motor nem preferências | Recusa nativa, sem motor nem preferências | Recusa nativa, sem motor nem preferências |
| Dois processos e encerramento abrupto | A trava bloqueou freeze enquanto o motor vivia e foi liberada com o fim do processo | Mesmo resultado | Mesmo resultado |
| `MY_PACKAGE_REPLACED` com `versionCode` 1 → 2 | Restauração recusada no epoch congelado | Restauração recusada no epoch congelado | Restauração delegada no epoch 1 |
| `BOOT_COMPLETED` em novo kernel | Restauração recusada antes de Dart | Restauração recusada antes de Dart | Restauração delegada antes de Dart |
| Entrega e ações | Entrega e ação recusadas em `FROZEN` | Entrega e ação recusadas em `FROZEN` | Epoch antigo e ação assíncrona recusados. A entrega admitida apareceu no `NotificationManager`. |
| Arquivos após atualização e boot | Dez hashes conferiram | Dez hashes conferiram | Dez hashes conferiram antes da entrega admitida |

O Flutter verificou `integrity_check`, schema, chave existente e a diferença entre as cópias com e sem WAL nas três fixtures. Depois do boot, o Flutter Local-First reabriu as cópias com o mesmo fingerprint de chave. Seu banco, WAL, SHM, journal de recuperação, registry e preferências de criptografia permaneceram iguais mesmo após a entrega admitida. A alteração esperada no cache da agenda local é excluída dessa comparação final. Um journal pendente recusou a abertura antes de Dart após interromper e recriar o processo nativo.

O primeiro limite de 90 segundos expirou com `BOOT_COMPLETED` ainda na fila do Android. O sistema entregou os três broadcasts na mesma inicialização. A retomada conferiu os IDs de kernel existentes e completou o ensaio preservando os APKs e os dados. As evidências estão em `stage21-native-qualified`, com 67 SHA-256 em `stage21-native-proof-hashes.json`.

`flutter analyze --no-pub` retornou zero problemas e os 131 testes Flutter focais passaram. Os seis APKs profile compilaram offline. O APK debug padrão compilou em 3m27s para ARMv7, ARM64 e x86_64. A inspeção confirmou os mesmos 31 componentes de manifesto do APK padrão de referência.

Foram reconferidos 51 arquivos de evidência das etapas 18–20, 15 arquivos Android sintéticos anteriores, seis configurações protegidas e o APK arquivado da etapa 20. A consulta somente leitura de automações confirmou zero workflows e push hooks em ambos os repositórios GitHub e `exit 0` no projeto Vercel vinculado ao backend. A preparação está em commits locais para revisão do gate.

## Arquivos e gates

Implementação e probe no commit local `d21d5755b15cf119970143d26c5a391f96078065`. Reproduzir com `:app:assembleProfile -PlifeOsFenceFixture=uid -Ptarget=integration_test/native_writer_fence_probe.dart -Ptarget-platform=android-x64`, alternando `uid`, `p1` e `local`. Para o APK de atualização, usar também `-PlifeOsFenceUpdate=true`. `Build-Stage21Fence.ps1`, `Run-Stage21Fence.ps1` e `Verify-Stage21Preservation.ps1` estão no workspace privado, junto à matriz complementar `STAGE21_NATIVE_COVERAGE.md`.

- `android/app/build.gradle.kts` e `android/app/src/fenceLab/AndroidManifest.xml`.
- `android/app/src/fenceLab/kotlin/com/rafalacerda/lifeos/fence/NativeWriterFence.kt`, `FenceComponentFactory.kt` e `FenceLabActivity.kt`.
- `integration_test/native_writer_fence_probe.dart` e este relatório.

**`LAB_NATIVE_WRITER_FENCE=PASS`. `NATIVE_WRITER_FENCE=BLOCKED` no pacote oficial.** O próximo bloqueio é demonstrar admissão persistente para os inicializadores e serviços do APK padrão e para o trabalho assíncrono de ações, usando instalação sintética anterior com custódia verificável. `LOCAL_IDENTITY_GATE=BLOCKED · P1 RED · ROLLOUT CLOSED`.

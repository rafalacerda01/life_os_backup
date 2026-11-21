# Life OS · Etapa 22 · Startup Local-First e barreira Android

## Escopo

A branch `refactor/launch-local-first-20261117` recebeu dois commits locais sobre
`5b46eddea5b504b800c60ed981d1d20448b94916`, que contém
`d21d5755b15cf119970143d26c5a391f96078065`. A opção
`-PlifeOsOfficialLocalCandidate=true` seleciona um APK de perfil assinado com
chave de depuração e o identificador `com.rafalacerda.lifeos`. O Gradle exige o
alvo `lib/main_official_local_candidate.dart` e restringe esse modo ao perfil.
O APK padrão mantém o bootstrap autenticado e o manifesto de 31 componentes
confirmado na etapa 21. O backend independente permanece no commit
`b316df4302e8ae88e5d17af01780d831c0896ab9`.

## Manifesto binário e dependências

| Componentes do APK padrão | Dependência no caminho legado | APK candidato |
| --- | --- | --- |
| `FirebaseInitProvider`, descoberta de componentes e serviço de sessões do Firebase | Inicialização dos SDKs, Auth, Firestore, Crashlytics e sessões | Declarações removidas. O engine registra plugins de uma lista explícita. |
| `androidx.startup.InitializationProvider` e `ProfileInstallReceiver` | `ProcessLifecycleInitializer`, `ProfileInstallerInitializer` e instalação/verificação de perfis de desempenho | Declarações removidas. O launcher usa o ciclo de vida explícito de `FragmentActivity`. |
| Receivers e serviços de Measurement e DataTransport | Medição e agendamento/entrega de telemetria | Declarações e permissões de publicidade e referrer removidas. |
| Atividades Firebase Auth, Google Sign-In e credenciais, serviço de revogação e metadados GMS | Login, credenciais e recuperação de sessão | Atividades e serviços removidos. O plugin de biometria local segue disponível ao Flutter. |
| Atividades de Billing, Play Core e Google API | Compras, integrações Play e resolução de APIs GMS | Atividades e permissão Billing removidas. |
| Providers de ImagePicker e Share Plus, receiver de Share Plus e atividade WebView | Seleção de arquivos, compartilhamento de círculos e abertura de links Premium | Entradas removidas. Compartilhamento de círculos e links Premium ficam fora da superfície offline qualificada. |
| Receivers agendado, de ações e de boot do plugin de notificações | Leitura e escrita do cache e das preferências legadas, restauração e ações com Flutter | Substituídos por um receiver privado no processo `:local_candidate_worker`. Ele opera apenas sobre o lembrete de tarefas do candidato. |
| `MainActivity` | Entrypoint Flutter autenticado, com registro dos plugins do aplicativo | O launcher nativo `OfficialStartupActivity` só anexa Flutter após admissão. |

O manifesto mesclado do candidato declara um launcher e um receiver. O APK
tem zero providers e serviços e não solicita `INTERNET`. As bibliotecas
ainda vinculadas ao artefato não são equivalentes a inicializadores ativos.
As sondas usam avião ativo e Wi-Fi desabilitado. O Android recusou inclusive
o socket de loopback tentado pelo serviço de diagnóstico do Flutter em perfil.

## Fronteira de armazenamento

1. O launcher verifica pacote, processo e API antes de verificar arquivos.
   Instalações sem journal nativo só podem criar sua identidade se os
   diretórios protegidos em CE e DE estiverem vazios. A presença de dados
   legados sem admissão válida bloqueia a abertura em código nativo.
2. O processo mantém `session.lock` durante a vida do engine. `writer.lock`
   coordena transições nativas e callbacks em processos distintos. O journal
   em `no_backup/life_os_native_startup_v1` sincroniza os bytes e o diretório
   antes de publicar o estado. O namespace vincula o UUID ao caminho do banco.
3. Dart recebe a identidade esperada antes de resolver o marcador no
   SecureStorage. Ausência ou divergência em uma instalação já admitida
   interrompe a abertura antes de gerar identidade ou solicitar a criação de
   chave. SecureStorage mantém `resetOnError=false` e
   `migrateOnAlgorithmChange=false`. O SQLite local reaproveita a
   verificação de cifra, integridade, schema 12 e fila em modo local.
   A UI só é publicada após a confirmação
   nativa da identidade e do banco.
4. Cada callback adquire sua própria admissão de escrita. Lembretes
   vinculam namespace, epoch, token e horário. O token é consumido de forma
   persistente antes de publicar a notificação. O receiver não instancia
   Flutter nem abre SecureStorage, SQLite ou XML de preferências. A fila
   nativa é limitada, a espera de lock de escrita é de até 400 ms e o
   watchdog de sete segundos encerra somente o processo dedicado.
5. Uma migração futura que precise de exclusividade deve adquirir
   `session.lock` seguido de `writer.lock`. O limite é cooperativo entre
   os componentes admitidos no pacote e não fornece custódia sobre
   escritores de APKs legados, código com o mesmo UID ou acesso privilegiado
   ao Android. A etapa 22 qualifica a recusa no candidato.

## APIs 24–27

O manifesto mantém `minSdk=24`. A recusa antecipada no candidato para
APIs inferiores a 28 ocorre antes da inspeção de dados ou do Flutter.
O launcher e o receiver explícitos independem de `AppComponentFactory`.
No ambiente havia as imagens API 34, 35 e 37.1. A qualificação funcional
nas APIs 24–27 ficou sem execução. `AppComponentFactory` está disponível
a partir da API 28. [Referência Android](https://developer.android.com/reference/android/app/AppComponentFactory)

A alternativa para manter o suporte mínimo é validar o processo e a
identidade no Android 24–27 com um mecanismo que não dependa de
`Application.getProcessName()`, conservando os componentes explícitos.
Isso exige ensaios reais de Keystore, CE/DE, reboot e atualização com
WAL e lembretes nas APIs antigas. Caso essas garantias não possam ser
comprovadas, a proposta para uma futura versão é `minSdk=28`, após medir
a base instalada nas APIs 24–27 e oferecer um caminho de recuperação
ou exportação no cliente legado. Esses dispositivos deixariam de receber
o novo APK. A compatibilidade mínima do produto ainda não foi alterada.

## Análise e comparações

- `flutter analyze --no-pub` sem apontamentos na revisão final. A bateria
  focal final aprovou 345 testes. Ela cobre identidade esperada, journal
  nativo e o seletor de horário. A suíte Flutter completa, executada antes
  do ajuste do seletor, terminou com 2.954 aprovações e 460 falhas.
- Na base da etapa 21, três arquivos representativos produziram 27
  aprovações e as mesmas 157 falhas da amostra no candidato. A comparação
  abrangeu autenticação e limpeza de lembretes, sync local e encerramento de
  envios remotos. Ela não classifica as outras 303 falhas da suíte.
- O build Android debug padrão concluiu nas ABIs ARMv7, ARM64 e x86_64.
  O manifesto binário tem o mesmo conjunto de 31 componentes da etapa 21,
  incluindo `FirebaseInitProvider` e o launcher original. Builds profile
  x86_64 do candidato e do semeador também concluíram.

## Preservação e trilha Git

Foram conferidos 118 hashes de evidências das etapas 18–21, 15 arquivos
sintéticos do AVD preservado, seis configurações protegidas e o APK da etapa
20. O AVD desse acervo foi sincronizado e encerrado após a conferência
para liberar memória. A etapa 22 usa `LifeOSOfficialCandidate22`,
`emulator-5590`, API 34. Os usuários Android 10 e 11 separam UID e P1.
O proprietário do AVD guarda o perfil Local-First sintético com o ID
oficial. O checkpoint local tem hash dos arquivos de origem antes da edição.

| Commit | Escopo |
| --- | --- |
| `e2cf4c20c3d6075b3c42c2c252ff00481808e131` | Validação da identidade esperada, inspeção das pastas protegidas, integração de lembretes e testes de regressão. |
| `4b32fcf1b44982ee3ce882ddec12bbcdb0fe5a38` | Variante Android de perfil, manifesto, admissão pré-Dart, receiver e entrada Flutter. |
| `f6e491cb80a36740bd44855249aaded9ef2161cf` | Alinha a propriedade de build com o incremento de código de versão verificado no APK. |
| `a352ac7f04b98b1a0e17cc1ce2de12d23c1f0895` | Corrige o seletor de horário do lembrete e acrescenta a regressão que reproduz o caso em português. |

A revisão do índice verificou arquivos fonte, tamanho, espaços e padrões
conhecidos de credenciais. APKs, bancos, journals, XMLs, logs, scripts de
fixture e impressões digitais sintéticas ficam no acervo privado da etapa.

Os arquivos integram `android/app/build.gradle.kts`, o manifesto e as
classes `OfficialStartupActivity.kt`, `OfficialStartupFence.kt` e
`OfficialTaskAlarm.kt` da variante `officialLocalCandidate`. As entradas
Dart ficam em `lib/main_local.dart` e
`lib/main_official_local_candidate.dart`. A camada de persistência alterada
consiste no provider e serviço `local_installation_identity` e no
`local_installation_storage_inspector.dart`. A integração de lembrete
fica em `local_task_reminder.dart` e `local_task_reminder_screen.dart`.
As regressões verificam identidade, inspeção de armazenamento e seletor de
horário nos testes correspondentes.

## Verificações no Android API 34

| Ensaio | Evidência observada |
| --- | --- |
| Instalação nova offline | A primeira versão do candidato criou identidade própria e SQLite cifrado. O manifesto e o Package Manager confirmaram ausência de INTERNET. A UI abriu as oito abas e gravou uma tarefa sintética. |
| Atualização 1 → 2 | O Package Manager confirmou a versão 2 com o mesmo certificado de depuração. O journal, a identidade e os hashes do SecureStorage coincidiram. A tarefa reapareceu no APK v2 depois do cold boot. |
| UID e P1 | O semeador usou chaves novas do Keystore, schema 11 e transações confirmadas apenas no WAL que continham a tarefa atualizada e a fila sintética. Antes da troca, uma leitura somente sobre cópias confirmou a integridade, a ausência da linha da fila no banco base isolado e sua presença com o WAL. O candidato recusou antes do Dart e manteve 12 hashes por caso após a atualização e depois do cold boot. Os hashes incluem banco, WAL, SHM, journal de recuperação, preferências de criptografia e registros de notificação. |
| Exclusão entre processos | A sonda Android NDK manteve cada lock POSIX em outro processo. O launcher registrou `WRITER_BUSY` nos dois casos sem iniciar Dart. A abertura voltou a funcionar após a liberação. |
| Entrega e recusa de lembretes | O horário escolhido na UI gerou uma notificação no `NotificationManager`. O registro avançou para o dia seguinte com token novo. O callback sintético com epoch antigo foi recusado sem alterar o registro. |
| Restauração de lembrete ativo | O processo nativo restaurou o registro em `MY_PACKAGE_REPLACED` e no `BOOT_COMPLETED` de outro kernel. A entrega de boot ocorreu após a janela inicial do coletor e foi recuperada no mesmo kernel. |
| Finanças offline | O APK final gravou uma saída sintética de R$ 12,34 pela interface e exibiu a movimentação e a atualização do saldo. |

Os testes antigos de UID/P1 verificam preservação e recusa de adoção. O
candidato não abre dados legados nem confirma ou executa a fila histórica.
A leitura cifrada da origem foi feita antes da troca somente pelo semeador
sintético. A recuperação de chave ou dados de uma instalação antiga em
produção continua sujeita ao gate de custódia e à prova de compatibilidade.

O ensaio real também encontrou uma divergência entre o seletor em português
e a configuração de relógio em 12 horas. O seletor mostrava horas em formato
de 24 horas e a validação recusava 13–23. A tela de lembrete passou a usar
uma configuração de 24 horas explícita. Um teste reproduziu a falha antes
da correção. O APK final preservou a tarefa existente, cancelou o
lembrete sintético anterior e gravou 19:30 com o relógio do Android
configurado para 12 horas. O manifesto binário permaneceu idêntico
ao da versão 2 já auditada.

No quarto usuário Android, o APK v2 criou um perfil Local-First independente.
Após interromper seu processo, o ensaio simulou um journal de publicação
incompleto. A abertura seguinte registrou `INTERRUPTED_JOURNAL` antes do
Dart. O banco, os arquivos do SecureStorage e o estado confirmado
preservaram seus hashes. O journal de teste permanece como evidência.

## Decisão

| Gate | Resultado | Evidência e limite |
| --- | --- | --- |
| `FRESH_INSTALL_LOCAL_FIRST` | **PASS** | Instalações descartáveis API 34 abriram offline com identidades distintas e bancos cifrados. |
| `LEGACY_UID_P1_PRESERVATION` | **PASS** | Os dois perfis sintéticos do pacote oficial recusaram abertura antes do Dart. As 24 verificações de arquivo coincidiram na atualização e após reboot. |
| `NATIVE_WRITER_FENCE` | **PASS** | No candidato API 34, duas travas interprocessos, recusa de epoch antigo, recusa de journal incompleto, entrega e restauração de lembretes. O acionamento do watchdog por uma falha de I/O prolongada não foi provocado. |
| `OFFICIAL_LOCAL_FIRST_STARTUP` | **BLOCKED** | O candidato de perfil está qualificado no escopo sintético acima. A compatibilidade nas APIs 24–27 e a transição segura do APK padrão ainda precisam de homologação. |
| `APP_WIDE_OFFLINE` | **FAIL** | As oito abas abriram, e a gravação de tarefa, movimentação financeira e lembretes foi exercitada. A suíte ampla tem 460 falhas e a cobertura de operações completas em todos os módulos continua em aberto. |
| `LOCAL_IDENTITY_GATE` | **BLOCKED** | Falta homologar a custódia da origem, compatibilidade de chaves, e transição do startup do APK padrão antes de uma adoção real. |

`P1 RED · ROLLOUT CLOSED`. A condição de preparar a publicação ainda tem
gates pendentes. As mudanças desta etapa estão em commits locais.

O próximo gate deve qualificar a variante em Android 24–27 ou decidir
explicitamente o suporte mínimo, reproduzir e resolver as falhas da suíte
que afetam o perfil local, ampliar o ensaio de operações offline e definir
a custódia e a retomada dos registros legados pelo futuro startup padrão.
O lançamento deve continuar condicionado a essas provas. Login Firebase,
Analytics e Billing ficam para a etapa final.

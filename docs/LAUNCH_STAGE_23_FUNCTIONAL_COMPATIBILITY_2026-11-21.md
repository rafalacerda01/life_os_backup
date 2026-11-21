# Etapa 23 · Qualidade funcional e compatibilidade Android

## Revisões e preservação

A etapa partiu de `9b494da70a9602adde97f8f20d9d09e178cc072e` na branch
`refactor/launch-local-first-20261117`. O HEAD da etapa 21,
`5b46eddea5b504b800c60ed981d1d20448b94916`, foi usado como baseline em
uma worktree limpa. Foram conferidos os 127 arquivos do índice da etapa
22 e seis configurações protegidas. O AVD da etapa 22 foi sincronizado e
encerrado. A bateria atual usa outro AVD, com diretório de dados próprio.
O backend independente permaneceu em `b316df4302e8ae88e5d17af01780d831c0896ab9`.

## Inventário Flutter

| Execução | Aprovados | Falhas |
| --- | ---: | ---: |
| Etapa 21, suíte reproduzida nesta etapa | 2.951 | 460 |
| Log integral preservado da etapa 22 | 2.954 | 460 |
| Etapa 23, após correção | 2.956 | 459 |

Os 460 casos do log da etapa 22 coincidem por arquivo, nome e assinatura
normalizada com a linha de base integral da etapa 21. Isso também resolve
a comparação dos 303 casos que ficaram fora da amostra anterior. A
comparação não encontrou regressão nova entre essas revisões. Ela não
atribui a origem de todos os problemas a commits anteriores à etapa 21.
O inventário privado contém os 460 nomes, módulos, linhas dos logs,
mensagens e resultados em cada execução. A análise estática ficou limpa.

| Arquivo da suíte | Falhas iniciais | Escopo dos casos com falha |
| --- | ---: | --- |
| `sync_remote_data_source_test.dart` | 167 | Autorização, Firestore e transporte autenticado |
| `auth_cycle_reminder_cleanup_test.dart` | 141 | Ciclo de sessão, custódia, troca de conta e lembretes do fluxo legado |
| `auth_repository_impl_test.dart` | 49 | Auth, proteção da sessão e cliente remoto |
| `notification_dismissal_test.dart` | 34 | Dismissal e replay com transporte legado, em repositório compartilhado |
| `auth_product_analytics_test.dart` | 23 | Login e Analytics do fluxo autenticado |
| `remote_send_session_test.dart` | 15 | Permissões de envio e ACK remoto |
| `sync_manager_test.dart` | 15 | Transporte, ACK, filas e permissões do Manager compartilhado |
| `trusted_account_transport_test.dart` | 10 | Transporte autenticado e validação de sessão |
| `study_repository_test.dart` | 4 | ACK, fila de revisão e pull autenticado de Estudos |
| `habits_repository_test.dart` | 1 | Exclusão e isolamento em troca de conta autenticada |
| `local_sync_runtime_test.dart` | 1 | Leitura de fila histórica pelo runtime Local-First |

Há 405 falhas em arquivos autenticados/remotos, 54 em arquivos
compartilhados com falha em cenários remotos e uma diretamente no modo
Local-First. Os testes autenticados continuam cobrindo o startup legado
e as guardas de custódia. Eles permanecem na suíte.

| Evidência observada | Quantidade | Interpretação |
| --- | ---: | --- |
| `TRUSTED_LOCAL_SESSION_CLOSED` | 133 | Operação ou fixture recusada pela guarda da sessão confiável |
| `HISTORICAL_FIXTURE_NOT_ADMITTED` | 130 | O harness de custódia interrompeu a preparação da fixture antes da ação sob teste |
| `TEST_GATE_NOT_REACHED` e timeout | 41 | Condição de sincronização esperada pelo teste não foi observada |
| `GENUINE_R1_EMULATORS_REQUIRED` | 4 | Ensaio exige a infraestrutura de emuladores R1 registrada |
| `LOCAL_PROFILE_SCHEMA_MIGRATION_REQUIRED` | 1 | Banco predecessor aberto pela fixture sem journal de admissão |
| Outras divergências | 151 | Asserções e pré-condições incompatíveis com o estado observado. A mensagem individual está no inventário e parte dessas causas exige investigação por cenário. |

## Correção

O teste da fila abriu um predecessor criptografado através de
`UserDatabaseFactory`, com um journal sintético compatível com o
contrato já exigido pelo aplicativo. Com a admissão, o teste verificou a
atualização de schema e a preservação da chave, do payload, do estado
rejeitado e dos valores de tentativa. As asserções de zero leitura para
envio, zero limpeza e zero chamadas ao transporte foram mantidas. As oito
provas focais de fila e schema passaram. O teste deixou de falhar na
execução integral e nenhuma falha nova apareceu.

Commit da correção `0040fd284a6f2e7f97faa3499173b89fd0fbe4ec`.
Arquivo `test/core/services/local_sync_runtime_test.dart`.

## Operações reais no Android API 34

O ensaio usou um AVD novo, offline e com dados sintéticos. O APK profile
do candidato oficial `com.rafalacerda.lifeos`, versão 2, é o binário
homologado na etapa 22. O manifesto inspecionado com `aapt2` não
solicita `INTERNET`. A única alteração de código da etapa 23 está sob
`test/`, portanto os artefatos Android anteriores continuam correspondendo
às fontes do aplicativo. A etapa 23 não repetiu o build Android. O SHA-256
do APK é `33144cdc0b61a6c2e71dfb56962c35dad33de13e742443c1de98f11093c64a`.

| Módulo | Operações verificadas no candidato oficial | Cobertura ainda pendente no APK oficial |
| --- | --- | --- |
| Tarefas | Criação, conclusão ao usar Foco, recusa da quarta tarefa no Free e exclusão de uma tarefa descartável com a outra preservada | Edição dos campos e demais erros do módulo |
| Finanças | Criação de despesa, exclusão, saldo zerado, nova despesa de R$ 12,34 e despesa do Mercado de R$ 48,75, total de R$ 61,09. A quarta transação foi recusada após cadastrar a terceira | Edição, demais validações e isolamento por cenário financeiro |
| Hábitos | Criação, marcação e contagem de hoje. O quarto hábito foi recusado pelo plano Free | Edição, exclusão e demais erros do módulo |
| Metas | Criação, avanço de progresso para 1 de 2 e recusa da quarta meta no Free | Edição, exclusão e demais erros do módulo |
| Check-in | Criação, atualização e consulta do histórico, exclusão e nova gravação | Erros e isolamento de registros por cenário |
| Estudos | Disciplina e flashcard gravados pela interface. A resposta foi aberta e a revisão concluída. A quarta disciplina foi recusada no plano Free | Edição, exclusão e demais erros do módulo |
| Foco | Execução de uma sessão real de um minuto vinculada à tarefa, com transição para pausa de cinco minutos | Cancelamento, retomada e comportamento da tarefa em segundo plano |
| Saúde | Humor, hidratação de 500 ml, medicamento sintético e configuração de ciclo gravados pela interface. O quarto medicamento foi recusado no Free | Edição, exclusão e lembretes por submódulo |
| Mercado | Validação de nome vazio, criação, edição, exclusão, marcação, checkout e integração com Finanças | Erros de recuperação e isolamento por cenário de compra |
| Início, Dashboard e Analytics | O Início refletiu o nome atualizado. A tela de análises calculou o saldo dos lançamentos locais | Indicadores por período, restrições Free e tratamento dos estados de erro |
| Perfil e segurança | Atualização de nome refletida em Perfil e Início | Biometria com sensor e segurança em hardware físico |
| Central de Notificações | Atualização da projeção de dados, com medicamento futuro e hábito concluído. A notificação descartada permaneceu ausente ao atualizar. Lembrete diário gravado no mesmo epoch e namespace no journal nativo | Adiamento, replays e entrega nesta rodada |

As capturas XML, os logs nativos, os identificadores sintéticos e os
resultados de armazenamento permanecem no workspace privado. As etapas
4–17 também contêm ensaios da versão `.localdev` para esses módulos. A
matriz acima registra as operações no candidato oficial desta rodada.
As seis quotas quantitativas dos módulos listados foram verificadas
pela recusa do quarto cadastro. A regra Free de Círculos e a restrição
de Analytics avançado ficaram fora dessa prova.

O log da instalação nova registrou, em ordem, `NATIVE_ADMITTED`,
`STARTING_DART` e `DART_SESSION_READY`. A primeira inspeção encontrou o
perfil `READY` e o cabeçalho cifrado do banco. Em cold boot, o ID do boot
mudou e a identidade, o epoch e os três hashes das preferências de
chave permaneceram iguais. Tarefas, saldo, hábitos, metas, check-in,
hidratação e nome de perfil voltaram a aparecer na interface. Num segundo
usuário do mesmo AVD, o candidato abriu um banco cifrado com identidade e
namespace independentes. O primeiro usuário preservou a identidade e as
impressões digitais originais. A lista do segundo ficou vazia, sem a
tarefa do primeiro. O ensaio comprova a fronteira de armazenamento do
Android e a leitura isolada no módulo de Tarefas.

O journal do lembrete ficou `ACTIVE` às 19h. O seletor encerrou antes do
último toque esperado pelo executor. A confirmação veio da interface e do
journal persistido. A etapa 22 mantém a prova de entrega nativa, recusa
de callback obsoleto e restauração após atualização e reboot no mesmo APK.

O teste de PIN do segundo usuário preparou uma credencial descartável.
A captura de acessibilidade falhou ao entrar em Perfil depois de
confirmado o isolamento, antes de abrir o prompt. A etapa 15 mantém a
prova de PIN de dispositivo no host
`.localdev`. O PIN no APK oficial permanece `NOT_VERIFIED` nesta rodada.

## Compatibilidade do Android

O candidato e o APK padrão mantêm `minSdk=24`. A inspeção do manifesto
binário do candidato confirmou esse valor. O candidato oficial usa
`Application.getProcessName()` a partir da API 28. A Activity, a guarda
de armazenamento e o receiver próprio recusam APIs anteriores a 28. Os
entry points explícitos também evitam depender de `AppComponentFactory`,
disponível a partir de 28. [Application.getProcessName](https://developer.android.com/reference/android/app/Application#getProcessName()) · [AppComponentFactory](https://developer.android.com/reference/android/app/AppComponentFactory)

No Android 8.1, API 27, a instalação da versão 1 e a atualização para a
versão 2 concluíram. Nos dois arranques e num novo cold boot, a Activity
registrou `NATIVE_DENIED PROCESS_UNQUALIFIED`, sem `STARTING_DART` ou
`DART_SESSION_READY`. A área CE continha somente os diretórios de cache
em todas as inspeções. Em DE, a leitura após reboot mostrou o mesmo
inventário. O teste usou a imagem oficial AOSP x86_64 revisada para API 27,
com SHA-1 e tamanho conferidos contra o índice do SDK. Wi-Fi e dados
móveis foram desabilitados. O Android recusou somente o broadcast
de modo avião privilegiado emitido pelo executor. O manifesto do APK
sem `INTERNET` permaneceu uma verificação independente. A inspeção
estática encontrou a mesma recusa no código para APIs 24–26. A execução
nativa ficou restrita à API 27 e à 34.

A guarda reduz o risco de acessar armazenamento em uma configuração
fora da cobertura. A API 27 em si não qualifica uso de AndroidKeyStore,
SQLite cifrado, CE/DE, notificação ou custódia legada enquanto o candidato
recusa qualquer admissão. O Direct Boot permite delimitar CE e DE desde
a API 24. Canais de notificação existem desde a API 26. Esses recursos
precisam de ensaio nativo nas versões em que forem suportados.
[Direct Boot](https://developer.android.com/privacy-and-security/direct-boot) · [NotificationChannel](https://developer.android.com/reference/android/app/NotificationChannel)

Para uma futura decisão de lançamento, a proposta é elevar `minSdk` para
28 se o projeto não puder homologar um mecanismo alternativo de
reconhecimento de processo com as mesmas garantias. Antes de aprovar a
mudança, medir a base Android 7.0–8.1, qualificar o APK de distribuição
com a API 28 no mínimo e oferecer recuperação ou exportação no app legado.
Esses dispositivos deixariam de receber um APK com `minSdk=28`.
[Versionamento de aplicativos Android](https://developer.android.com/studio/publish/versioning)

## Fronteira de produção e custódia

O caminho proposto preserva a recusa nativa por padrão e o launcher
explícito qualificado no candidato. O fluxo de uma instalação nova abre
somente o namespace próprio. Instalações com vestígios UID/P1 entram no
fluxo de custódia, que deve provar projeto, tenant, UID, geração, chave
e alinhamento dos journals antes de admitir uma leitura. A exclusão de
escritores precisa abranger todos os entry points do pacote, processos e
callbacks, com validade limitada à sessão e liberação após o último
trabalho de notificação. O futuro startup padrão precisa herdar essa
propriedade antes de iniciar Dart.

No ensaio de transição, a origem fica intacta, incluindo transações do
WAL e a fila histórica. A captura usa exclusão verificável e inclui o
WAL, prepara um destino criptografado separado e confere conteúdo, chave,
relações e histórico. A publicação do destino deve depender da validação
completa e de um journal recuperável, inclusive após interrupção entre
captura, abertura e confirmação. O pacote de distribuição assinado e
o processo de recuperação do legado ainda precisam de homologação. A
etapa 23 mantém o startup padrão e a configuração de migração da etapa
22. Firebase Authentication, Google Analytics e Google Play Billing
seguem reservados para a etapa final.

## Auditoria para publicar a branch de desenvolvimento

O destino autorizado é `rafalacerda01/life_os_backup`, na branch
`refactor/launch-local-first-20261117`. O intervalo começa no HEAD remoto
da etapa 20 `9d6ee81eac83298fb3abe5be02ea39d574f76981` e inclui os
commits de barreira e startup das etapas 21 e 22. A auditoria examina o
conteúdo completo do HEAD e os novos objetos relativos aos refs remotos.
Os achados de configuração cliente do Firebase e fixtures sintéticas já
estavam no remoto. A verificação procura novas credenciais, bancos,
artefatos de laboratório, binários e arquivos grandes. A listagem
autenticada do GitHub mostrou zero workflows e zero webhooks de push
ativos. A Vercel retornou zero projetos vinculados ao repositório do
aplicativo nos escopos acessíveis. O backend independente e a main ficam
fora da operação. O push de fontes independe do gate de ativação do
startup em produção.

## Gates

| Gate | Resultado | Evidência |
| --- | --- | --- |
| `FLUTTER_FAILURE_INVENTORY` | **PASS** | 460 casos inventariados com comparação integral. Uma falha resolvida e zero casos novos. |
| `FLUTTER_LOCAL_QUEUE_REGRESSION` | **PASS** | Oito testes focais aprovados e a correção confirmada na suíte completa. |
| `FLUTTER_FULL_SUITE` | **FAIL** | 2.956 aprovações e 459 falhas históricas nos cenários autenticados/remotos. |
| `FRESH_INSTALL_LOCAL_FIRST` | **PASS** | No candidato sintético API 34, admissão offline antes do Dart e banco cifrado próprio. |
| `LOCAL_FIRST_REOPEN_AND_ISOLATION` | **PASS** | Na API 34, identidade e preferências de chave recuperadas após cold boot e um segundo namespace isolado. A validade funcional é a das operações da matriz. |
| `LEGACY_UID_P1_PRESERVATION` | **PASS** | Preservação sintética da etapa 22, verificada pelo índice de evidências. A etapa 23 operou em AVDs independentes. |
| `NATIVE_WRITER_FENCE` | **PASS** | No candidato sintético API 34 da etapa 22, exclusão entre processos e recusa de UID/P1. A nova prova API 27 comprova recusa antes do Dart. A cobertura de produção permanece pendente. |
| `ANDROID_27_FAIL_CLOSED` | **PASS** | Instalação, atualização e cold boot com recusa antes do Dart e nenhuma inicialização de banco ou chaves. |
| `ANDROID_24_26_RUNTIME` | **NOT_VERIFIED** | Guarda presente no código. Execução nativa pendente. |
| `ANDROID_24_27_SUPPORT` | **BLOCKED** | O candidato recusa a admissão nessas versões. Keystore, armazenamento, boot e callbacks funcionais seguem sem homologação. |
| `OFFICIAL_CANDIDATE_PIN` | **NOT_VERIFIED** | O ensaio no segundo usuário parou no acesso à tela de Perfil. |
| `APP_WIDE_OFFLINE` | **FAIL** | Operações reais confirmadas na matriz, com lacunas de CRUD, quotas, erros e retomada por módulo. |
| `OFFICIAL_LOCAL_FIRST_STARTUP` | **BLOCKED** | Custódia do legado, compatibilidade mínima e APK de distribuição ainda pendentes. |
| `LOCAL_IDENTITY_GATE` | **BLOCKED** | É necessária homologação do startup padrão e da recuperação do legado antes de qualquer migração real. |

O próximo bloqueio para lançamento é qualificar a custódia do legado no
APK de distribuição com uma matriz aprovada de versões Android e terminar
os ensaios funcionais que faltam. A sequência para as falhas históricas
começa pela sessão confiável e pela admissão de fixtures de custódia,
que respondem por 263 interrupções. Os quatro cenários R1 precisam da
configuração registrada de emuladores, com dados sintéticos. O inventário
mantém os sintomas dos cenários restantes para reprodução sem afrouxar
as guardas. `P1=RED` e `ROLLOUT=CLOSED`.

# D2-C-02-R8/R10 — contrato V2 isolado e leitor compatível

Protótipo isolado, sem SDK, credenciais, rede, endpoint, trigger ou integração.
Todas as respostas de operação contêm somente `status` e
`destructiveAuthority: false`. Erros de configuração também são sanitizados e
mantêm `destructiveAuthority: false`. Nada neste módulo remove Auth ou dados.
R2/R3, cleaners, backend, Flutter, Rules, IAM e Water V2 permanecem intactos.

R10 acrescenta somente o export puro `classifyRetiredIdentitySnapshots` e fatora
a validação estrutural de reserva usada também pelas operações sintéticas V2.
As cinco operações, suas assinaturas e respostas anteriores permanecem iguais.
O teste de exports foi atualizado para reconhecer a função adicional; os 61
cenários V2 foram preservados. Nenhum modelo V3 ou adapter de produção foi criado.

## R10 — entrada do leitor e fronteira de normalização

O leitor recebe dados já carregados, não referências/objetos SDK, callbacks ou
credenciais. Campos obrigatórios da entrada:

```js
{
  reservation: {exists: true, data: record, createTime: {seconds, nanoseconds}},
  guard: {exists: true, data: {
    version: 1, state: "IN_PROGRESS", deletionId,
    startedAt: {seconds, nanoseconds}, retainUntil: null
  }},
  auth: {state: "ABSENT"},
  expectedDeletionId: null,
  expectedOrigin: null,
  now: {seconds, nanoseconds}
}
```

Cada frame é `{exists:false}`, `{readError:true}` ou `{exists:true,data}` com
`createTime` opcional. Omissão de metadata não cria um timestamp. Falha de leitura
nunca pode virar `exists:false`. `auth.state` aceita PRESENT, ABSENT, AMBIGUOUS
ou UNAVAILABLE; campos adicionais, incluindo metadata de criação, não provam
geração e tornam a observação ambígua. `now` pode ser null quando desconhecido.
O esperado deletionId é UUID v4 ou null; origem esperada é uma das três ou null.
São referências de comparação do procedimento chamador, nunca autorização.

O futuro adapter confiável deverá verificar projeto, banco e caminhos do UID antes
de fornecer esses frames; o leitor puro não faz IO nem comprova o escopo de origem
dos dados. A fábrica sintética continua restrita a demo-* e não foi aberta à produção.
Guard e reserva devem vir de uma leitura consistente; o resultado não detecta
staleness posterior nem substitui a releitura/fencing na transação de uma ação.

Timestamps normalizados são objetos de dados exatos `{seconds,nanoseconds}`:
segundos inteiros no intervalo Firestore e nanossegundos inteiros de 0 a 999999999.
Comparação usa os dois componentes, sem total em nanossegundos sujeito a overflow,
toMillis, toDate, Date.now ou métodos SDK. Metadata ausente, valor numérico legado
ou objeto SDK não normalizado permanece contexto insuficiente. O leitor rejeita
accessors sem invocá-los e não executa data(), toMillis() ou toJSON().

O adapter futuro poderá extrair seconds/nanoseconds de um Timestamp real conhecido,
preservando sua precisão. Não poderá reconstruir createTime a partir de Auth,
startedAt, relógio local, data pública truncada ou arredondamento. Nenhum adapter
Firestore foi implementado e nenhuma metadata real foi lida nesta rodada.

## R10 — dimensões e estados sanitizados

Toda classificação retorna campos imutáveis, sem dados ou identificadores originais:

| Campo | Significado |
|---|---|
| reservation | ABSENT, V1_STRUCTURALLY_VALID, V2_PRE_AUTH, V2_AUTH_EVENT, V2_LEGACY_REVIEW, MALFORMED, UNKNOWN_VERSION ou UNAVAILABLE. |
| guard | ABSENT, IN_PROGRESS, COMPLETE, COMPLETE_RETENTION_EXPIRED, COMPLETE_RETENTION_UNKNOWN, MALFORMED ou UNAVAILABLE. |
| guardContext | Consistência temporal, insuficiência, inconsistência ou não aplicável; não é prova de geração. |
| operation | MATCH, MATCH_UNBOUND, CONFLICT, GUARD_MISSING, GUARD_ONLY, UNBOUND ou UNDETERMINED. |
| v1Context | NOT_APPLICABLE, INSUFFICIENT, CONSISTENT ou INCONSISTENT. |
| auth | Estado observado/ambíguo/indisponível; PRESENT não identifica geração. |
| provenance | Sempre UNPROVEN; origem declarada não é atestação. |
| terminalProof | Sempre NOT_PERFORMED, inclusive com Auth ausente, COMPLETE ou retenção vencida. |
| requiredEvidence | Pendências de procedência, identidade, prova terminal e contexto/vínculo conforme necessário. |
| destructiveAuthority / admissionAuthority | Sempre false. |

`status` sintetiza a condição preponderante, sem apagar as outras dimensões.
Falha de leitura, registro inválido/versão desconhecida, guard inválido, identidade
ambígua e conflitos têm precedência sobre observações de continuidade. Nenhum
status significa operação autorizada. Uma exceção de introspecção é sanitizada
como READ_UNAVAILABLE; objetos de erro e suas mensagens não são retornados.

V1 estruturalmente válida não exige metadata para ser reconhecida. Seu contexto
somente é consistente quando há guard temporalmente consistente, createTime
normalizado e as relações temporais preservadas: authCreatedAtMs <= startedAt e
createTime >= startedAt. Isso compara o número armazenado em V1, sem confirmar
precisão histórica nem comparar uma suposta geração Auth atual. Sem metadata,
retorna contexto insuficiente, nunca completa/migra o registro. Conflito de
deletionId permanece separado e bloqueante mesmo se a cronologia for consistente.
As operações V2 antigas continuam exigindo createTimeMs para reconhecer V1 conforme
seu contrato sintético anterior; a separação do novo leitor não relaxa essa regra.

COMPLETE somente é logicamente vencido quando `now > retainUntil`: igualdade ainda
não é vencimento. Sem relógio/normalização suficiente, a retenção fica UNKNOWN.
Guard com cronologia inválida fica inconclusivo por inconsistência. O leitor não
simula o TTL, apaga documentos, reabre COMPLETE ou cria guard quando ele está ausente.
Um guard IN_PROGRESS pode ter seus timestamps consistentes sem relógio fornecido;
isso não comprova sua idade atual. Versão futura de guard é recusada como inválida.

| Situação | Status representativo, sem autoridade |
|---|---|
| Reserva ausente | LEGACY_OR_NEW_UNPROVEN. |
| V1 com/sem contexto | V1_REVIEW_REQUIRED / V1_CONTEXT_INSUFFICIENT. |
| Cronologia V1 incompatível | V1_CONTEXT_INCONSISTENT. |
| PRE_AUTH / AUTH_EVENT | PRE_AUTH_PROCEDURE_REVALIDATION_REQUIRED / MANAGED_AUTH_EVENT_REVALIDATION_REQUIRED. |
| LEGACY_REVIEW | LEGACY_REVIEW_REQUIRED. |
| Registro malformado / versão futura | RECORD_INVALID / VERSION_UNSUPPORTED. |
| deletionId / origem esperada divergentes | DELETION_ID_CONFLICT / ORIGIN_CONFLICT. |
| Guard ausente com reserva | GUARD_MISSING_REVIEW_REQUIRED. |
| COMPLETE, inclusive vencido | TERMINAL_PROOF_REQUIRED; estado de retenção permanece no campo guard. |
| Auth presente / ambíguo | AUTH_PRESENT_RECOVERY_BLOCKED / IDENTITY_AMBIGUOUS. |
| Leitura indisponível | READ_UNAVAILABLE; nunca ausência presumida. |

A API não recebe root e não verifica descendentes: raiz ausente não pode virar
prova terminal. Um registro não se converte em prova de origem, admissão ou limpeza.
O leitor é determinístico, sem cache, relógio implícito, porta de escrita ou efeitos
persistentes. Não substitui autorização, normalização confiável ou fencing real.

## R10 — conformidade entre repositórios e custos

Os vetores `readerVectors` no teste existente definem entradas/saídas sanitizadas
para ambos os runtimes: versões, três origens, conflitos, leitura indisponível,
V1 sem metadata, retenção no limite e precisão de um nanossegundo. Os testes
adicionais verificam ausência de mutação/autoridade e a API anterior preservada.

Futura replicação para o backend independente deverá distribuir uma cópia revisada
do leitor puro, com versão/hash e os mesmos vetores de conformidade, comparando
todos os campos e pendências. Não importar ../functions em Vercel, criar outro
estado/algoritmo de identidade, abrir a fábrica sintética ou alterar o backend aqui.
Não foi criado package, monorepo, dependência ou distribuição automática. Leitores
relevantes devem compreender V1/V2 antes de qualquer writer V2 ser ativado.

Classificar frames carregados custa zero leituras/escritas Firestore adicionais.
Qualquer futura aquisição dos frames terá custo próprio, fora desta função. Não
há consultas globais, polling, Scheduler, serviço ou cache persistente novo.
Procedência real, IAM, corrida Auth/Firestore, retenção durável e prova terminal
continuam pendentes; o leitor não concede autoridade ao protótipo de reserva.

## Registro mínimo e diferença para V1

Localização lógica preservada: projeto/banco explícitos, chave direta por UID em
`retired_auth_identities`. Somente namespaces `demo-*` são aceitos pelo módulo.

```js
{version: 2, state: "RESERVED", deletionId, origin: "PRE_AUTH"}
```

Não há metadata de criação Auth no registro V2. Não há comparação de datas Auth,
identificador global de geração, novo campo no guard, cópia de perfil ou timestamp
fabricado. O schema sintético do guard V1 é validado sem alterações ou writes.
O UID permanece um identificador potencialmente pessoal no caminho.

V1 permanece imutável: seu shape e metadata sintética são reconhecidos apenas para
retornar `V1_REVIEW_REQUIRED`; nunca são convertidos, atualizados ou usados como
prova de geração pela V2. Reservas V1/V2 bloqueiam admissão controlada. Ausência
retorna `LEGACY_OR_NEW_UNPROVEN`, nunca autorização para criar ou excluir conta.
O modelo R2 e seu harness R3 não foram modificados nem tiveram validações relaxadas.

## Procedência e fronteiras de confiança

`createSyntheticRetirementContractV2` captura quatro colaboradores de teste:
`authorize`, `attestOrigin`, `observeAuth`, `runTransaction`. Não são uma API de
callbacks de clientes. Seus autores pertencem à fronteira confiável do teste.
Um callback arbitrário pode mentir ou fazer IO; o módulo não consegue impedir isso.
Não existe adaptador de produção nem ativação por ambiente ou parâmetro.

Métodos de origem distintos fixam a origem internamente. O request não pode enviar
`origin`. A autoridade da operação e a procedência são verificações separadas;
ambas exigem `true` estrito e escopo congelado com ação, origem, projeto, banco,
UID e deletionId. Os testes usam capacidades opacas distintas, vinculadas por
referência e escopo, não um objeto `{origin, verified:true}` aceito como evidência.

| Método | Fronteira que um adaptador futuro precisará comprovar | Observação Auth exigida | Resultado de armazenamento |
|---|---|---|---|
| `reservePreAuth` | Procedimento servidor autenticado, operação atual e controlador que aguarda o commit antes de remover Auth | PRESENT antes/depois | `PRE_AUTH_RECORD_ACKNOWLEDGED` |
| `recordAuthEvent` | Invocação de evento gerenciado onDelete autêntico, vinculada ao UID/projeto e à operação atual | ABSENT antes/depois | `AUTH_EVENT_RECORD_ACKNOWLEDGED` |
| `recordLegacyReview` | Revisão administrativa explícita e escopada; ausência de evento não é prova pré-Auth | ABSENT antes/depois | `LEGACY_REVIEW_RECORDED_INCONCLUSIVE` |

O protótipo prova essas separações somente com colaboradores sintéticos. Não
autentica EventContext recebido como JSON, não implementa emissor de capacidades
reais e não demonstra a autenticidade de um evento Firebase de produção. Um futuro
adaptador precisa vincular o evento real à operação; o registro não contém eventId
nem preserva o evento bruto. Sem essa evidência externa, a inspeção continua
exigindo revalidação, nunca usa o campo origin como atestado autossuficiente.

## Sem falsa prova de geração ou de ordem

Auth é observado apenas como PRESENT/ABSENT. Observação ambígua, incompatível ou
com campos adicionais é recusada. PRESENT não identifica uma geração.
`authCreatedAtMs` é lido somente para reconhecer registros V1; não é comparado
com a identidade atual nem participa de uma decisão V2 de geração.

ACK confirma apenas o registro. Na sequência sintética normal, o controlador
aguarda o ACK para remover Auth. Auth e Firestore continuam sem transação comum:
uma alteração Auth durante o commit pode deixar uma reserva persistida e retornar
`AUTH_CHANGED_REQUIRES_REVIEW`. `inspect` posteriormente exige revalidação do
procedimento. O módulo não renomeia esse registro para torná-lo prova pré-Auth.
Uma substituição PRESENT -> PRESENT pode ser indistinguível e é caracterizada
explicitamente nos testes. Duas consultas não resolvem TOCTOU nem UID reutilizado.

Consequentemente, `PRE_AUTH` identifica o procedimento atestado sinteticamente,
não prova, sozinho, que o commit precedeu toda remoção externa de Auth. Ao integrar,
essa ordem exige o procedimento confiável e a política/IAM de não reutilização.
Mesmo uma ordem observada não concederia autoridade destrutiva por este contrato.

## Transações, idempotência e resultados desconhecidos

Cada registro lê guard e reserva na mesma transação; todos os reads precedem o
único write possível, `tx.create` da reserva ausente. Guard deve estar IN_PROGRESS
e deletionId deve coincidir. Replay da mesma origem/operação não escreve.
Uma origem não pode substituir outra: não promover AUTH_EVENT ou LEGACY_REVIEW a
PRE_AUTH; não converter PRE_AUTH em AUTH_EVENT; não adotar deletionId anterior.
Um evento correspondente a uma reserva PRE_AUTH usa a futura rota de revalidação,
sem precisar regravar a origem. Não há limpeza ou renovação de reservas antigas.

O fake MVCC reexecuta o callback se guard ou reserva mudar. COMPLETE, operação
diferente ou schema inválido são revalidados. O módulo não cria, atualiza ou reabre
guards. Um guard ausente exige a fronteira existente apropriada: para onDelete,
uma futura integração poderá usar a admissão confiável já existente no cleaner;
a V2 isolada não inventa essa admissão nem bloqueia o cleaner atual.

Falhas de porta/commit são `UNKNOWN_REQUIRES_REREAD`, sem retry automático. Após
resposta perdida, inspeção e replay explícitos preservam registro/createTime e
não duplicam writes. Se Auth já estiver ausente, o método PRE_AUTH não cria uma
reserva retroativa. O registro existente só informa que é necessária revalidação.

## Compatibilidade nova/legada

| Caso | Comportamento isolado e integração futura |
|---|---|
| A. Conta nova ativa | Reserva PRE_AUTH sob procedimento confiável; ACK de storage, sem autoridade destrutiva. |
| B. Conta antiga ativa pede exclusão nova | Mesmo procedimento A; idade da conta não invalida nem exige metadata de criação precisa. |
| C. onDelete legítimo sem reserva | Pode registrar AUTH_EVENT após atestação própria e guard ativo; não exigir PRE_AUTH retroativo. Limpeza atual não foi alterada. |
| D. Exclusão em lote sem evento individual | Ausência não fabrica evento; revisão própria LEGACY_REVIEW, sempre inconclusiva para recuperação. |
| E. IN_PROGRESS legado | Sem reserva, revisão necessária; evento gerenciado autêntico e recuperação administrativa seguem fronteiras diferentes. |
| F. COMPLETE com possíveis resíduos | `TERMINAL_PROOF_REQUIRED`; nenhum reopen ou declaração automática de limpeza. |
| G. Auth reaparecido/incompatível | Presença bloqueia recuperação; mudança observada recusa; geração indistinguível continua sendo limitação explícita. |
| H. Reserva V1 | Preservar e revisar; não converter usando a data pública como prova. |
| I. Raiz ausente com descendentes | Contrato não consulta nem remove árvore; presença de reserva/COMPLETE não prova ausência de descendentes. Prova terminal externa obrigatória. |
| J. Confirmação do commit perdida | UNKNOWN; releitura/replay da mesma operação, sem overwrite, promoção ou segunda reserva. |

`inspect` requer autoridade própria, lê guard/reserva transacionalmente e observa
Auth antes/depois. Seus estados distinguem V1, guard COMPLETE, presença Auth,
PRE_AUTH, AUTH_EVENT e revisão legada; todos exigem validações adicionais.
`checkAdmission` não examina todo o histórico: reserva bloqueia; ausência não admite.

## Integração futura e rollback — não implementados

1. Fechar política/IAM/custódia de chaves e definir adaptadores confiáveis por
   origem. Não aceitar UID arbitrário, diagnóstico R2-A ou JSON de evento como
   autoridade. Timestamp público Auth não vira prova de geração.
2. Implantar leitores versionados antes de qualquer writer V2. R2 isolado não é
   leitor compatível de V2. Registros V1 continuam na sua rota, sem migração global.
3. Backend: colocar eventual reserva PRE_AUTH antes de auth.deleteUser e resolver
   UNKNOWN por revalidação. Preservar fences, Billing, Círculos e prova terminal.
4. Functions: manter rota do evento gerenciado para contas legadas sem PRE_AUTH.
   Só um adaptador revisado poderá atestar evento e vinculá-lo ao guard. Não exigir
   que toda conta antiga possua uma reserva nova para manter limpeza legítima.
5. Recuperação administrativa: autorização explícita e evidência própria;
   LEGACY_REVIEW nunca é promoção automática a evento gerenciado ou pré-Auth.
   Identidade ambígua impede integração destrutiva. COMPLETE exige prova terminal.
6. Validar com Emulator descartável o adaptador de storage: createTime real,
   timestamps do guard, retries/locks, conta ausente e descendentes órfãos. Fakes
   não comprovam esses aspectos do SDK nem IAM real.

Rollback futuro: parar writers V2, manter leitura V1/V2, preservar registros e
guards e suspender operações ambíguas. Não voltar cegamente a um reader V1 após
criar registros V2; não apagar ou converter reservas para restaurar disponibilidade.
Nenhuma migração completa Flutter ou accountGen global é exigida pelo contrato.

## Custos previstos

| Operação, sem retry | Reads de documentos | Writes | Observações Auth | Atestação de origem |
|---|---:|---:|---:|---:|
| Registro inicial de qualquer origem | 2 | 1 create | 2 | 1 |
| Replay mesma operação/origem | 2 | 0 | 2 | 1 |
| Inspeção | 2 | 0 | 2 | 0 |
| Consulta de admissão | 1 | 0 | 0 | 0 |

Cada retry repete reads do callback; create tentado não significa commit duplicado.
Falhas podem interromper antes desses totais. O custo da atestação futura é
PENDENTE: não é uma chamada de serviço implementada. Reusar o guard já lido na
mesma transação pode reduzir o incremento a 1 read + 1 create por primeira reserva.
Um documento pequeno por UID, sem registro paralelo por origem, consultas globais,
polling, Scheduler, dependência nova ou serviço permanentemente ativo. As duas
observações não são consultas globais nem solução para a corrida entre serviços.
Retenção e acesso da reserva exigem revisão própria; nenhum TTL é criado aqui.

## Validação

Os testes novos usam somente fakes MVCC, hooks e promises, sem timers/sleeps,
SDK, credenciais ou rede. Cobrem origem/escopo, V1/V2, concorrência, guard alterado,
Auth reaparecido, resultados desconhecidos, sanitização e ausência de integração.
Resultados finais de execução são registrados no relatório desta rodada.
Node disponível inicialmente: v24.17.0; Node 22 não foi encontrado nos caminhos
usuais consultados. Compatibilidade executada com Node 22 permanece PENDENTE.

Validação em 2026-10-17:

| Comando / escopo | Resultado |
|---|---|
| V2 + R2 focais | 99/99 passaram: 61 novos V2 e 38 R2; zero falhas/skips. |
| `node --test` Functions | 539 testes: 538 passaram, zero falhas, 1 skip (contêiner R3 opt-in). |
| Launcher R3 existente com `--all` | Bloqueado antes dos testes: Firestore Emulator encerrou com erro de permissão de socket local e Java exit 1. |

O launcher e seus entrypoints não foram editados. Diagnóstico temporário em memória
identificou `EMULATOR_EARLY_EXIT` e `java.net.SocketException`/erro de permissão;
os processos descartáveis foram encerrados pelo launcher. Nenhuma elevação ou
alternativa de rede/credenciais foi usada. Os 24 cenários internos R3 não foram
reexecutados nesta rodada e continuam PENDENTES neste ambiente. O resultado anterior
de 502 testes com Emulator não é reapresentado como validação atual.
Nenhuma integração Firebase real foi acessada; testes V2 são totalmente sintéticos.

## Validação R10 em 2026-10-17

- Focais finais V2/R10 + R2: 155/155 passaram, zero falhas/skips. O arquivo V2
  conserva os 61 cenários anteriores e acrescenta 56 do leitor; R2 mantém seus 38.
- Functions: 595 descobertos, 594 aprovados, zero falhas, 1 skip (contêiner R3 opt-in).
- R3 não foi reexecutado nesta rodada; a restrição prévia de socket continua uma
  pendência e não foi contornada. Os arquivos R2/R3 não foram modificados.
- Node executado: v24.17.0. Node 22 permanece pendente; nenhuma instalação realizada.
- Nenhuma integração, conexão de produção, alteração de guard/schema real ou
  ativação de writer foi realizada. A classificação de frames é integralmente local.

## R10-FIX1 — frames e retenção explícita

Os sete frames solicitados na revisão já respeitavam a precedência de
`snapshotFrame()` no código local inspecionado: ausência legítima é `ABSENT`,
`{readError: true}` isolado é `READ_UNAVAILABLE`, e combinações contraditórias
ou campos extras resultam em `reservation: MALFORMED` / `RECORD_INVALID`.
Não houve relaxamento do frame nem alteração dessa precedência. Regressões
explícitas também cobrem frames V1 malformados e V1/V2 válidos, com ou sem
`createTime`. Reconhecimento estrutural continua sem provar procedência.

Foi reproduzida a inconsistência de `COMPLETE` com `retainUntil: null`: antes,
o leitor retornava `COMPLETE_RETENTION_UNKNOWN` / `TERMINAL_PROOF_REQUIRED`.
Embora não concedesse autoridade, confundia retenção explicitamente inválida
com precisão desconhecida. Agora esse guard é `MALFORMED` / `GUARD_INVALID`,
sem contexto temporal consistente nem vínculo de operação reconhecido pelo guard.

A normalização local distingue `null` explícito de metadados de tempo SDK não
suportados, representados internamente como `undefined`. Instâncias SDK continuam
inconclusivas (`COMPLETE_RETENTION_UNKNOWN`), sem chamar métodos, fabricar valores
ou arredondar timestamps. Nenhum formato persistido ou adapter foi alterado.
As cinco operações sintéticas, o modelo R2 e o harness R3 permanecem preservados.
Todas as respostas do leitor continuam imutáveis, sanitizadas e com
`destructiveAuthority: false`, `admissionAuthority: false`, `provenance: UNPROVEN`
e `terminalProof: NOT_PERFORMED`.

Validação FIX1 em 2026-10-17, Node v24.17.0:

- Antes da correção: 15 regressões novas, 13 aprovadas e 2 falhas esperadas
  (retenção nula com reserva V1 e V2). Os 12 casos de frame já passavam.
- Após a correção: 15/15 regressões FIX1 aprovadas.
- Focais V2/R10 + R2: 170/170 aprovados, zero falhas/skips.
- Functions: 610 descobertos, 609 aprovados, zero falhas, 1 skip R3 opt-in.
- Sintaxe dos dois arquivos JavaScript e whitespace dos três arquivos verificados.
- Node 22 não disponível no PATH consultado; execução nessa versão permanece
  PENDENTE. Nenhuma instalação realizada.
- Launcher R3 não reexecutado: bloqueio anterior de socket permanece pendente,
  sem elevação ou contorno. Nenhum acesso à produção foi realizado.

## R11 — adapter Firestore isolado, somente leitura

Arquivos: `retired_identity_firestore_reader.js`, testes dedicados em
`test/retired-identity-firestore-reader.test.js` e esta documentação. O classificador
R10/FIX1, R2, harness R3, dispatchers, cleaners e backend não foram alterados.
Nenhum writer, endpoint, migração ou recuperação foi integrado.

### Interfaces e limites de confiança

`classifyLoadedRetiredIdentitySnapshots(input)` é a fronteira A, síncrona, sem IO.
Recebe exatamente `scope`, `reservation`, `guard`, `auth`, `expectedDeletionId`,
`expectedOrigin` e `now`. `scope` contém exatamente `projectId`, `databaseId`, `uid`.
Cada leitura é `{snapshot: documentSnapshot}` ou `{readError: true}`. Não recebe
callbacks de aquisição, escrita ou autorização. Snapshots devem ser das classes
instaladas DocumentSnapshot/QueryDocumentSnapshot, sem converter customizado nem
overrides dos acessos públicos utilizados. JSON com `exists: false` não é snapshot.

O escopo aceita somente projetos explícitos `demo-*`, banco `(default)` e UID
canônico com até 128 caracteres/bytes UTF-8, sem controles, separadores, espaços
nas extremidades ou nomes reservados. Referências são verificadas por UID,
coleção, projeto, banco e mesmo cliente Firestore. Instâncias SDK e identidade de
referência não atestam procedência Auth; código privilegiado no mesmo processo
não é isolado por essas verificações. Não é uma interface para requests públicos.

`classifyRetiredIdentityFromEmulator(input)` é a fronteira B, assíncrona e somente
para testes. Recebe exatamente `scope`, `emulatorHost` e os quatro campos de
contexto acima, sem snapshots, referências ou callbacks fornecidos pelo chamador.
Constrói seu próprio cliente SDK e lê os dois documentos em `runTransaction`
com `{readOnly: true}`, por um único `tx.getAll`. Confere cardinalidade, identidade
das referências e igualdade exata dos `readTime` antes da classificação.
Captura escopo e contexto antes do await para impedir troca tardia pelo chamador.

Ambas retornam `{classification, normalization, acquisition}` congelado. O campo
`classification` é a resposta original do classificador puro, sem promoção ou
alteração de autoridade. `normalization` contém somente enums sanitizados;
`acquisition` distingue `LOADED_ONLY`, `READ_ONLY_TRANSACTION`, `NOT_PERFORMED`
e `UNAVAILABLE`. Frames e dados dos documentos nunca são retornados publicamente.
Não são publicados UID, projeto, host, deletionId, payload ou texto de exceções.

### Frames internos e precisão

- Ausência confirmada: `{exists: false}`, somente para snapshot SDK ausente com
  readTime suportado, data indefinida e sem createTime/updateTime contraditórios.
- Presença: `{exists: true, data}` com `createTime` opcional; schema desconhecido
  ou malformado é encaminhado sem transformar campos extras em schema válido.
- Erro explícito ou exceção SDK: `{readError: true}`; nunca vira ausência.
- Snapshot/escopo inválido: frame inválido, sem copiar payload desconhecido.

Timestamps instalados são extraídos por `seconds` e `nanoseconds`, sem `toMillis`,
`toDate`, arredondamento, relógio implícito ou data Auth. A saída de normalização
distingue `SDK_TIMESTAMP`, `NULL`, `MISSING`, `UNSUPPORTED` e `INVALID`. Valores
não normalizáveis permanecem inconclusivos no classificador, sem fabricar tempo.
`now` também deve ser fornecido explicitamente; não é preenchido automaticamente.
`snapshot.createTime` é a criação do documento Firestore, nunca geração Auth.

### Compatibilidade demonstrada por testes locais

| Entrada | Classificação preservada / limitação |
|---|---|
| Reserva ausente | ABSENT; nenhuma admissão autorizada. |
| V1 válida | V1_REVIEW_REQUIRED; sem createTime, V1_CONTEXT_INSUFFICIENT. |
| V2 PRE_AUTH / AUTH_EVENT / LEGACY_REVIEW | Revalidação específica da origem; procedência UNPROVEN. |
| Versão futura / schema inválido | VERSION_UNSUPPORTED / RECORD_INVALID. |
| Guard IN_PROGRESS / deletionId divergente | Contexto temporal separado / DELETION_ID_CONFLICT. |
| COMPLETE retido ou expirado | TERMINAL_PROOF_REQUIRED; sem reabertura. |
| COMPLETE com retainUntil null | GUARD_INVALID, preservando FIX1. |
| Guard ausente com reserva | GUARD_MISSING_REVIEW_REQUIRED. |
| Leitura negada, deadline, desconexão ou transação parcial | READ_UNAVAILABLE; sem ausência presumida. |
| Metadados fora do formato suportado | Inconclusivos; precisão não é inventada. |

### Isolamento e consistência

B exige host explícito `127.0.0.1:porta` (1..65535), igual a
`FIRESTORE_EMULATOR_HOST`. Configurações de projeto presentes devem coincidir com
o projeto demo explícito. Recusa configuração de credenciais, proxies e tracing
externos listada no módulo. O cliente usa autenticação sintética fixa do emulador,
sem descoberta ADC, certificado, chave privada ou login. Não possui caminho de
fallback para Google Cloud. Revalida o ambiente antes/durante/depois da aquisição
e encerra o cliente ao terminar. Nenhum emulador é iniciado pelo módulo.

COMPROVADA localmente: SDK instalado `@google-cloud/firestore` 8.7.1 suporta
transação read-only, sem write batch/commit e sem retry do callback nessa modalidade.
Seus comentários documentam snapshot consistente possivelmente até 60 segundos
no passado. Teste com pipeline SDK e RPC simulado verifica `newTransaction.readOnly`,
dois nomes de documento corretos, timestamps SDK e zero commits. A comparação
entre operações observa mudanças do guard sem recriar ou alterar nada.

PENDENTE no Emulator: garantia real do servidor, timestamps de commits reais,
concorrência real, endpoint/autenticação de transporte e timeout configurado.
Auth está fora da transação Firestore. Igualdade de readTime, reserva ou COMPLETE
não comprovam continuidade de geração Auth, não reutilização de UID nem integridade
terminal. Permanecem `destructiveAuthority: false`, `admissionAuthority: false`,
`provenance: UNPROVEN` e `terminalProof: NOT_PERFORMED` em todas as classificações.

### Validação e custos R11 em 2026-10-17

- 85/85 testes novos: objetos SDK com dados sintéticos, mocks de aquisição e um
  teste do pipeline SDK com RPC simulado. Zero sockets e zero descoberta ADC.
- Accessors adicionados a Timestamp são recusados sem executar callbacks.
- Focais R11 + V2/R10/FIX1 + R2: 255/255 aprovados, zero falhas/skips.
- Functions: 695 descobertos, 694 aprovados, zero falhas e 1 skip R3 opt-in.
- Nenhum teste real de Firestore Emulator foi executado. A restrição anterior de
  socket no launcher R3 continua uma pendência, sem nova tentativa, elevação,
  instalação ou contorno. Não declarar R11 validada contra o Emulator.
- Node executado v24.17.0; execução Node 22 continua pendente se indisponível.
- A normalização A custa zero operações adicionais. B solicita dois documentos
  por operação explícita, sem consultas globais, polling, writes ou retry próprio.
  Há timeout RPC configurado de 5 segundos; não é prova de deadline total e sua
  efetividade no transporte permanece pendente. Nova chamada manual solicita duas
  leituras novamente. Não há armazenamento permanente ou serviço novo.
- Utilização/custo adicional de Firebase e Google Cloud de produção: zero.

Próxima revisão: executar testes reais somente quando a execução regular de
emuladores for permitida; revisar transporte/IAM/identidade antes de qualquer
integração futura. R11 não autoriza recuperação destrutiva nem writer V2.

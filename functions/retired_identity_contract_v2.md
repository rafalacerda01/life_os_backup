# D2-C-02-R8 — contrato sintético de identidade retirada V2

Protótipo isolado, sem SDK, credenciais, rede, endpoint, trigger ou integração.
Todas as respostas de operação contêm somente `status` e
`destructiveAuthority: false`. Erros de configuração também são sanitizados e
mantêm `destructiveAuthority: false`. Nada neste módulo remove Auth ou dados.
R2/R3, cleaners, backend, Flutter, Rules, IAM e Water V2 permanecem intactos.

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

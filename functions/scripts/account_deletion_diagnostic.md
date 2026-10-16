# Diagnóstico D2-C-01-R2-A — somente Emulator

Comando manual, sem endpoint, scheduler ou integração com `index.js`.
Não executa recuperação nem comprova exclusão integral.

## Execução

Inicie separadamente emuladores locais descartáveis de Firestore e Auth para
`demo-life-os`. Não reutilize dados/serviços reais. No PowerShell, configure
explicitamente os hosts dos emuladores já iniciados:

```powershell
$env:FIRESTORE_EMULATOR_HOST = '127.0.0.1:8089'
$env:FIREBASE_AUTH_EMULATOR_HOST = '127.0.0.1:9099'
node C:\life_os\functions\scripts\diagnose_account_deletions.js --project demo-life-os
```

As portas devem ser distintas. Apenas `127.0.0.1`, sem protocolo, é aceito;
projetos sem prefixo `demo-` são recusados. Os dois hosts são obrigatórios.
Variáveis de credenciais explícitas e debug SDK são recusadas sem mostrar seus
valores. O cliente usa somente a credencial sintética `owner`, host Firestore
explícito sem TLS e Auth Emulator; não utiliza ADC ou login da CLI. Não há modo
de produção, flag de ativação nem argumento de UID. O operador deve manter o
ambiente do processo e os serviços loopback confiáveis.

Firestore recebe um `GoogleAuth` explicitamente ligado a `OAuth2Client` com
token sintético. `google-auth-library` já está instalada e fixada no lockfile como
dependência transitiva do Admin SDK; nenhum pacote ou manifesto foi alterado.
Essa ligação evita descoberta de credenciais/metadados mesmo com host explícito.
Uma atualização do SDK precisa repetir o ensaio do comando em Emulator.

Opções permitidas:

| Opção | Padrão | Intervalo |
| --- | --- | --- |
| `--page-size` | 50 | 1–100 |
| `--max-documents` | 200 | 1–1000 |
| `--older-than-ms` | 3600000 | 60000–2592000000 |
| `--max-pages` | 20 | 1–100 |
| `--max-duration-ms` | 30000 | 1000–60000 |
| `--manual-pages` | false | true / false |

Para continuar manualmente dentro da mesma execução:

```powershell
node C:\life_os\functions\scripts\diagnose_account_deletions.js --project demo-life-os --page-size 10 --max-pages 5 --max-documents 50 --max-duration-ms 30000 --manual-pages true
```

Depois de cada página cheia, Enter permite a próxima; qualquer texto ou EOF
interrompe. Os prompts genéricos ficam em stderr; stdout contém somente o JSON.
O cursor fica apenas em memória e nunca é impresso ou persistido. Não há
continuação entre processos: um novo comando começa um inventário novo.
Escolheu-se essa restrição para não criar arquivos/chaves de cursor contendo
UIDs reversíveis nem um protocolo complexo de armazenamento/criptografia.
O modo padrão continua pelas páginas automaticamente, dentro dos mesmos limites.

Saída: um JSON com contagens, cobertura, truncamento e operações. Não contém
UIDs, hashes de UID, emails, caminhos de documentos, deletionIds, payloads ou
erros originais. Exit 0 indica observações sem inconclusivos e inventário
esgotado; **não** significa conta excluída. Exit 2 indica cobertura parcial ou
candidatos inconclusivos/alterados. Exit 1 indica recusa/falha do comando.
O relatório usa schemaVersion 2. Os contadores R1 são observações da primeira
etapa; `residues` refina somente candidatos antigos observados com Auth ausente.
Não somar esses dois grupos como se fossem populações independentes.

## Consultas e interpretação

Uma única coleção, `account_deletion_guards`, é paginada por document ID, sem
offset ou collection groups. Ler todos os guards dentro do limite permite
detectar registros com estado malformado que um filtro `state == IN_PROGRESS`
ocultaria. Nenhum índice novo é necessário. O schema é validado pelo helper
existente `validateGuard`, sem chamar qualquer função de mutação/limpeza.

Guards recentes, inválidos ou de outro estado não consultam Auth. São
observações do snapshot da página, sem promessa de estabilidade posterior.
Somente candidatos antigos válidos consultam Auth; em seguida o guard é relido.
Mudança de updateTime (inclusive ida e volta ao mesmo conteúdo), remoção ou
divergência de campos torna o candidato inconclusivo. Não há
transação, locks, polling ou retry implementado pelo diagnóstico.

Somente após Auth ausente e essa revalidação há um batch de quatro leituras de
existência, com `fieldMask: []`, sem materializar campos privados:

- `users/{uid}`;
- `billing_google_accounts/{SHA256(uid em UTF-8)}`;
- `users/{uid}/runtime/account_deletion`;
- `account_birth_decisions/{uid}`.

Esses caminhos vêm de index.js e birth_ledger_cleanup.js já existentes; nenhum
limpador é chamado. Não são consultados outros usuários, índices de tokens ou
collection groups. O resultado usa apenas `exists`, sem chamar `data()`.
Auth é consultado novamente e o guard é relido ao final. Se Auth reaparecer ou
G mudar, `candidateChanged` descarta a evidência. Falhas resultam em
`inconclusive`. Guard estável e Auth ainda ausente permitem somente
`detected` ou `noneObservedInLimitedScope`. Os contadores por tipo de documento
só recebem evidência após a revalidação final; não contêm valores dos markers.

`auth/user-not-found` significa somente Auth ausente naquela consulta. O estado
`oldAuthAbsentPotentiallyIncomplete` pede triagem; não é prova de resíduos nem
de exclusão integral. Falha Auth de outra natureza é inconclusiva. Falha na
consulta de página encerra a coleta com `QUERY_FAILED`; falha na releitura
torna apenas aquele candidato inconclusivo. Erros são contados e sanitizados.

Auth e Firestore não possuem snapshot conjunto. Auth pode mudar depois da
consulta; nem updateTime estável transforma o diagnóstico em autorização.
Nenhuma saída autoriza apagar dados, declarar COMPLETE ou recuperar uma conta.

## Tempo e interrupções

O orçamento usa relógio monotônico a partir do início do diagnóstico, incluindo
as pausas manuais. Cada leitura e pausa disputa o tempo restante e um sinal de
interrupção. SIGINT, SIGTERM, EOF ou recusa manual encerram com cobertura
inconclusiva. `TIME_LIMIT`, `INTERRUPTED`, `PAGE_LIMIT` e `LIMIT_REACHED` preservam
as contagens já obtidas e impedem novas consultas. Falha de página produz
`QUERY_FAILED`; não se repete a primeira página para tentar compensar.

Não há garantia de cancelamento físico de uma chamada SDK em andamento. O
resultado tardio é tratado sem modificar o relatório ou lançar nova leitura.
O CLI limita a espera de descarte dos clientes a 500 ms e encerra o processo
depois de enviar o JSON; isso fecha os recursos locais pendentes. O prazo de
diagnóstico não inclui carga síncrona inicial dos módulos. Não se promete um
deadline rígido de sistema operacional durante bloqueio do event loop.

## Limites e custos

Para M documentos máximos, página P e limite de páginas L, defina
`N = min(M, P*L)` e `Q = min(L, ceil(M/P))`:

- No máximo Q consultas de página e N documentos retornados no inventário.
- No máximo 2N releituras de guard (antes/depois da verificação de resíduos).
- No máximo N batches de existência com quatro documentos cada: 4N leituras.
- No máximo 2N consultas Auth, sendo a segunda só para candidatos antes ausentes.
- Estimativa conservadora de leituras Firestore: `7N + Q`, incluindo
  margem para o mínimo de uma leitura por query vazia.
- Padrão: até 4 queries, 200 resultados, 400 releituras, 800 documentos de
  existência e 400 consultas Auth; estimativa de até 1404 leituras Firestore.
- Teto conservador de qualquer configuração aceita: até 100 queries,
  1000 resultados, 2000 releituras, 4000 documentos de existência e 2000
  consultas Auth; até 7100 leituras Firestore. Com página 1, L=100 limita N a
  100; não se pode examinar 1000 documentos nesse tamanho de página.

São limites das chamadas lógicas da aplicação. Retries de transporte internos
do SDK não são um orçamento financeiro rígido. Não há execução real em nuvem
neste modo, nem estimativa monetária: o custo de uso de Firestore/Auth emulado
é zero. Não há infraestrutura contínua, recursos permanentes ou novos índices.

Ao atingir M sem uma página curta, a saída informa truncamento mesmo se M for
exatamente o total existente. Não se faz uma query extra para descobrir isso.
O relatório é parcial: ausência de candidatos nessa amostra não prova ausência
global. Ausência de root não prova ausência de subcoleções. Não são examinados
conteúdos privados, subcoleções arbitrárias, tokens Billing, Circles, root/ledger
sem guard ou resíduos sob guards de outro estado. Mesmo `EXHAUSTED` significa
apenas que a paginação observada terminou; `NOT_GLOBAL_SNAPSHOT` explicita que
inserções atrás do cursor e outras mutações podem escapar dessa execução.
Repetir o comando não cria um cursor durável e pode reencontrar a mesma amostra.

## Validação e próxima rodada

```powershell
cd C:\life_os\functions
node --test test/account-deletion-diagnostic.test.js
node --test
```

Os testes usam relógio fixo e fakes de leitura, sem sleeps ou Firebase real.
Fixtures só alteram memória sintética; capacidades de escrita são proibidas.
Node 22 continua obrigatório antes de publicação se indisponível localmente.

Proposta R2-B, não implementada: revisão independente das lacunas de cobertura,
limites/abort e critérios para eventual verificação adicional direcionada,
sempre limitada e sem limpeza. Validar Node 22 antes de qualquer publicação.
Cursor entre processos e modo de produção não fazem parte desta solução.
Qualquer autorização futura exige decisão própria; recuperação destrutiva
continua separada e nunca decorre deste relatório.

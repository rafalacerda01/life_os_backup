# Diagnóstico D2-C-01-R1 — somente Emulator

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

Saída: um JSON com contagens, cobertura, truncamento e operações. Não contém
UIDs, hashes de UID, emails, caminhos de documentos, deletionIds, payloads ou
erros originais. Exit 0 indica observações sem inconclusivos e inventário
esgotado; **não** significa conta excluída. Exit 2 indica cobertura parcial ou
candidatos inconclusivos. Exit 1 indica recusa/falha do comando.

## Consultas e interpretação

Uma única coleção, `account_deletion_guards`, é paginada por document ID, sem
offset ou collection groups. Ler todos os guards dentro do limite permite
detectar registros com estado malformado que um filtro `state == IN_PROGRESS`
ocultaria. Nenhum índice novo é necessário. O schema é validado pelo helper
existente `validateGuard`, sem chamar qualquer função de mutação/limpeza.

Guards recentes, inválidos ou de outro estado não consultam Auth. São
observações do snapshot da página, sem promessa de estabilidade posterior.
Somente candidatos antigos válidos consultam Auth uma vez; em seguida o guard
é relido. Mudança de updateTime (inclusive ida e volta ao mesmo conteúdo),
remoção ou divergência de campos torna o candidato inconclusivo. Não há
transação, locks, polling ou retry implementado pelo diagnóstico.

`auth/user-not-found` significa somente Auth ausente naquela consulta. O estado
`oldAuthAbsentPotentiallyIncomplete` pede triagem; não é prova de resíduos nem
de exclusão integral. Falha Auth de outra natureza é inconclusiva. Falha na
consulta de página encerra a coleta com `QUERY_FAILED`; falha na releitura
torna apenas aquele candidato inconclusivo. Erros são contados e sanitizados.

Auth e Firestore não possuem snapshot conjunto. Auth pode mudar depois da
consulta; nem updateTime estável transforma o diagnóstico em autorização.
Nenhuma saída autoriza apagar dados, declarar COMPLETE ou recuperar uma conta.

## Limites e custos

Para M documentos máximos e página P:

- No máximo `ceil(M/P)` consultas de página.
- No máximo M documentos retornados pelo inventário.
- No máximo M releituras de guard e M consultas Auth.
- Estimativa conservadora de leituras Firestore: `2M + ceil(M/P)`, incluindo
  margem para o mínimo de uma leitura por query vazia.
- Padrão: até 4 queries, 200 resultados, 200 releituras, 200 consultas Auth;
  estimativa de até 404 unidades de leitura de documentos.
- Maior configuração aceita: M=1000, P=1; até 1000 queries, 1000 releituras e
  1000 consultas Auth; estimativa de até 3000 unidades de leitura Firestore.

São limites das chamadas lógicas da aplicação. Retries de transporte internos
do SDK não são um orçamento financeiro rígido. Não há execução real em nuvem
neste modo, nem estimativa monetária: o custo de uso de Firestore/Auth emulado
é zero. Não há infraestrutura contínua, recursos permanentes ou novos índices.

Ao atingir M sem uma página curta, a saída informa truncamento mesmo se M for
exatamente o total existente. Não se faz uma query extra para descobrir isso.
O relatório é parcial: ausência de candidatos nessa amostra não prova ausência
global. Não são examinados dados privados, Billing, Circles, root/ledger sem
guard, nem resíduos sob guards de outro estado. Repetir o comando não cria um
cursor durável e pode reencontrar a mesma primeira amostra.

## Validação e próxima rodada

```powershell
cd C:\life_os\functions
node --test test/account-deletion-diagnostic.test.js
node --test
```

Os testes usam relógio fixo e fakes de leitura, sem sleeps ou Firebase real.
Fixtures só alteram memória sintética; capacidades de escrita são proibidas.
Node 22 continua obrigatório antes de publicação se indisponível localmente.

Proposta R2, sem implementação: revisar os limites e eventual continuação
manual de inventário; adicionar diagnóstico direcionado e limitado de resíduos
para candidatos comprovados, sem reutilizar as rotinas destrutivas. Qualquer
modo de produção exige aprovação específica, IAM somente leitura, orçamento
de transporte/tempo, validação de identidade e revisão das saídas. Recuperação
destrutiva continua uma decisão separada e não é consequência deste relatório.

# D2-C-02-R2 — contrato sintético de identidade retirada

Status: protótipo local isolado, sem integração nem autorização destrutiva.

## Política proposta

Uma identidade Firebase Auth excluída pelo Life OS não poderá ser intencionalmente
recriada ou reutilizada com o mesmo UID pelos fluxos controlados pela aplicação.
O contrato abrange cadastro, administração, importação/restauração, custom tokens,
exclusão e recuperação pós-Auth. Não impõe uma restrição a administradores externos
que ignorem esses contratos. Ausência de chamadas no código ou de registros não
comprova ausência histórica de reutilização.

## Escopo e registro mínimo

Localização lógica: projeto/banco explícitos, coleção `retired_auth_identities`,
chave direta pelo UID. Projeto, banco e UID vêm do caminho; não são duplicados.
Documento proposto (ainda somente em memória nos testes):

```js
{version: 1, state: "RESERVED", deletionId, authCreatedAtMs}
```

`deletionId` deve coincidir com o guard atual. `authCreatedAtMs` é uma observação
sintética precisa, não uma garantia criptográfica de geração. O modelo rejeita
observações ausentes de precisão ou explicitamente ambíguas. Um futuro adaptador
não poderá converter metadata ausente/imprecisa em prova suficiente de identidade.
Não há email, nome, payloads de usuário ou campos de saúde/finanças no registro.
O UID continua sendo um identificador potencialmente pessoal.

Há somente `RESERVED`: não duplicar `COMPLETE` nem usar o registro como prova de
exclusão. O guard existente conserva seu schema e sua responsabilidade terminal.
O contrato de storage exige transação com reads antes dos writes e criação sem
overwrite. A releitura usa metadata confiável `createTimeMs` do storage; no futuro,
isso deve ser `DocumentSnapshot.createTime`, nunca timestamp fabricado pelo cliente.
A sequência exigida será commit confirmado/revalidado da reserva antes da remoção
Auth. Este protótipo não remove Auth nem demonstra essa ordem em infraestrutura real.

## API e fronteiras de confiança

`createSyntheticRetirementModel` exige projeto `demo-*`, banco explícito e três
colaboradores sintéticos: `authorize`, `observeAuth`, `runTransaction`. Não importa
SDK nem lê ambiente, credenciais ou rede. Não existe modo de produção, flag enabled,
CLI, endpoint, Scheduler, Function nova ou adaptador Firestore neste módulo.
Os colaboradores são código de teste confiável, não dados fornecidos por clientes.
O módulo não consegue provar que um callback arbitrário é honesto ou não tem rede.

- `reserve`: autoriza a ação e o escopo; observa Auth presente; lê guard ativo e
  reserva na mesma transação; cria somente se ausente. Replay idêntico não escreve.
  Guard COMPLETE, operação diferente, registro malformado ou identidade divergente
  falham fechados. Nunca escreve no guard e nunca reabre COMPLETE.
- `inspect`: duas observações Auth ao redor da leitura transacional. Mudança ou
  ambiguidade bloqueia; Auth presente impede recuperação. Auth ausente e reserva
  consistente produzem apenas observação, nunca permissão de recuperação.
- `checkAdmission`: qualquer reserva bloqueia nova admissão; ausência retorna
  `LEGACY_OR_NEW_UNPROVEN`, não autorização para criação, adoção ou exclusão.

Toda saída tem apenas `status` sanitizado e `destructiveAuthority: false`. Não há
logs, IDs, caminhos, credenciais, payloads, erros originais ou stack externa na saída.
Falha de porta, timeout ou resposta perdida retorna `UNKNOWN_REQUIRES_REREAD`,
mesmo quando a falha ocorreu antes do commit. `inspect` pode distinguir ausência,
reserva ainda com Auth presente e reserva com Auth ausente; nenhuma observação
substitui prova terminal. Não há retry automático após resultado desconhecido.

## Concorrência e limites

Backend, Function e futuro recuperador devem compartilhar escopo e deletionId.
MVCC reexecuta a transação se o guard ou a reserva mudar: um executor antigo não
pode usar o snapshot capturado para escrever após COMPLETE. Duas instâncias da
mesma operação convergem; outra operação não pode adotar a reserva existente.
Nenhuma nova lease ou campo no guard é necessário neste protótipo.

Auth e Firestore não têm uma transação comum. Duas consultas Auth não eliminam
TOCTOU, nem distinguem recriação com a mesma metadata, nem provam não reutilização
histórica. As garantias continuam condicionadas à política e à auditoria IAM.
Este módulo não concede capacidade destrutiva sequer em um caso aparentemente
consistente. Proteção contra administradores que contornem o contrato, integração
com writers de dados e execução real continuam fora do escopo e bloqueadas.

## Chave direta, hash e HMAC

| Opção | Consequência |
|---|---|
| UID direto | Menos complexidade e nenhuma chave criptográfica nova; identificador visível no caminho, acesso servidor restrito obrigatório. Opção do modelo. |
| SHA-256 de UID | Mesmo número de documentos/operações; determinístico e correlacionável. Não comprova anonimato nem melhora autoridade. |
| HMAC com versão | Reduz correlação por quem não possui a chave; exige gestão/rotação e acesso à chave. Não impede bypass administrativo nem cria prova de geração. Adiado. |

## Contas legadas e retenção

Não criar reservas retroativas a partir apenas de Auth ausente, diagnóstico R2-A,
guard COMPLETE ou resíduos. Exigir proveniência e revisão humana; na ambiguidade,
quarentena. A reserva não atesta eventos anteriores à sua criação.

Nesta rodada há somente memória de testes e arquivos locais: nenhuma retenção de
dados reais, TTL ou registro persistente é implementada. Para integração, propor
retenção separada do guard, limitada à finalidade de impedir reutilização/replays,
com revisão ao menos anual e no encerramento do projeto. Doze meses não constituem
prazo automaticamente seguro para apagar a reserva. Eliminação depende de demonstrar
que não reabre risco nem permite reutilização. Finalidade, base legal, transparência,
prazo, acesso e destino final dependem de aprovação jurídica/administrativa antes
de produção; não se presume legalidade de retenção indefinida ou de pseudonimização.

## Operações estimadas

| Ação sem retry transacional | Leituras de documentos | Escritas | Observações Auth |
|---|---:|---:|---:|
| Primeira reserva | 2 (guard + reserva) | 1 create | 1 |
| Replay com Auth ainda presente | 2 | 0 | 1 |
| Releitura de resultado desconhecido | 2 | 0 | 2 |
| Consulta de nova admissão | 1 | 0 | 0 |

Esses são custos totais do seam. Se a futura exclusão já ler o guard na mesma
transação, o incremento mínimo é 1 leitura + 1 criação; replay acrescenta 1 leitura.
Cada retry repete os reads; tentativas recusadas podem terminar antes. Armazenamento
O(identidades retiradas), um documento pequeno mais índices. Sem varredura, polling,
serviço contínuo, API habilitada ou dependência nova. Nenhuma garantia de custo zero
ou estimativa monetária sem conhecer a implantação futura.

## Integração futura — requer próxima revisão

1. Aprovar política de não reutilização, escopos IAM e retenção; identificar todos
   os criadores/importadores/signers e a autoridade administrativa de recuperação.
2. Validar o seam com Firestore/Auth Emulator: createTime real, tx.create, retries,
   concorrência e respostas perdidas. Normalizar timestamps do guard sem alterá-lo.
3. Backend: reservar antes de auth.deleteUser, resolver UNKNOWN por releitura e
   manter os fences e a prova terminal existentes. Não chamar deleteAccount como
   recuperador administrativo; separar pós-Auth sem nova remoção de Auth.
4. Functions: consumidor onDelete não pode fabricar uma reserva pré-Auth ausente.
   Caso reservado: validar operação; caso legado/evento externo: diagnóstico e
   quarentena, com política explícita para o comportamento legado antes de integrar.
5. Recuperador: autorização administrativa explícita, identidade não ambígua,
   política de não reutilização demonstrada e prova terminal completa. Nenhum
   endpoint público ou autorização derivada automaticamente de R2-A.
6. Writers/admissões controlados devem consultar a reserva. Isso poderá exigir
   revisão específica dos gates/Rules; nenhuma dessas mudanças foi feita aqui.

O protótipo não exige mudanças incompatíveis nos schemas ou cleaners atuais.
A integração de exclusões externas/legadas exige decisão humana; não se presume
que o onDelete consiga provar uma reserva anterior à exclusão.

## Validação local

Testes focais: `node --test test/retired-identity-model.test.js` em functions.
Regressões: `node --test` em functions. Fakes MVCC determinísticos verificam
guard alterado durante commit, retries, duas operações concorrentes, Auth recriado,
resposta perdida, PII, escopo e isolamento. Não substituem prova no Emulator.
O teste de metadata idêntica caracteriza explicitamente a limitação de geração:
não detectar uma recriação indistinguível não pode resultar em permissão destrutiva.

Resultado local em 2026-10-16: 38 testes focais e 477 testes Functions totais
(439 existentes + 38 novos), todos passaram, zero falhas ou skips. Node utilizado:
v24.17.0. Não foi localizado Node 22 no PATH nem nos diretórios usuais verificados
de nvm/fnm/Volta e runtimes locais; o runtime bundled também é v24 (v24.19.0).
Validação em Node 22 permanece pendente; nenhum runtime ou dependência foi instalado.
Nenhum teste novo usa Firebase Emulator, serviços reais, timers ou sleeps.

Referências públicas:
- https://firebase.google.com/docs/firestore/manage-data/transactions
- https://firebase.google.com/docs/auth/admin/manage-users
- https://www.planalto.gov.br/ccivil_03/_ato2015-2018/2018/lei/l13709.htm

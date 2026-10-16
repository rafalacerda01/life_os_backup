# D2-C-02-R3 — validação local com Firebase Emulator

Resultado: protocolo transacional testado com SDKs reais, sem integração. A corrida
Auth/Firestore continua reproduzível; nenhuma saída concede autoridade destrutiva.

## Baseline e escopo

- Root: security-audit-before-circles-fix, 072c499f286218e6a4097df8c50aee4707f69f8a.
- Backend independente: main, 593b826cedffe8039f6f78e74a61f548a2c58d02, limpo.
- Gitlink HEAD/index: d2af978f3aa99eae2d21e50a89d411894c449b37.
- Nenhum arquivo existente, modelo R2, cleaner ou schema foi modificado.

Arquivos novos: `test/retired-identity-emulator.test.js` (adapter fechado no teste,
sem exports), `tools/retired_identity_emulator_run.cjs` (launcher descartável) e
este relatório. Nenhum endpoint, Function, CLI de produção ou dependência nova.

## Reprodução

Em functions, com os binários já instalados:

```text
node tools/retired_identity_emulator_run.cjs
node tools/retired_identity_emulator_run.cjs --all
node --test test/retired-identity-model.test.js
```

O launcher recusa outros argumentos, inclusive seleção de projeto. Caminhos locais
alternativos para binários existentes podem ser informados por R3_JAVA_EXE,
R3_FIRESTORE_JAR e R3_FIREBASE_TOOLS_DIR; não há instalação ou download automático.
Sem opt-in, o teste Emulator fica explicitamente skipped. A execução completa aqui
usou opt-in e NÃO teve skips. Uma suíte sem emuladores não substitui esse resultado.

## Isolamento comprovado no harness

- Projeto fixo demo-life-os-d2c02r3; teste de namespace adicional usa somente
  demo-life-os-d2c02r3-other. Bancos: (default) e r3-other-db.
- Ambos os emuladores iniciados do zero em portas distintas, atribuídas localmente,
  exclusivamente 127.0.0.1; nenhuma conexão com emuladores previamente existentes.
- Ambiente filho por allowlist, sem GOOGLE_APPLICATION_CREDENTIALS, Firebase tokens,
  configuração Firebase, proxies ou hub de Functions. Configuração CLI isolada em
  diretório temporário; o dispatcher/login Firebase CLI não é executado.
- Credenciais explícitas e sintéticas: token Emulator `owner`; GoogleAuth com
  OAuth2Client explícito; getApplicationDefault bloqueado e monitorado.
- O worker recusa sockets que não tenham exatamente os dois hosts/portas aprovados.
  Mudança de ambiente/escopo é verificada antes das portas do adapter.
- Zero tentativas ADC e zero sockets externos inesperados na execução final.
  Uma tentativa sintética deliberada de socket não permitido é recusada antes de conectar.
- Fixtures de UID r3-* exclusivamente sintéticas. Auth create/delete só no Emulator.
  Não há importação de endpoint/cleanup, nem Functions Emulator em execução.
- Máximo de 50 fixtures, 900 verificações instrumentadas de operação, três tentativas
  por transação; teste limitado a 120 s e launcher a 180 s. O contador instrumentado
  não representa todos os RPCs/cobranças: fixtures diretas e RPCs internos do SDK são
  adicionais, mas os cenários são finitos. Não há polling ou varredura global.
- Emuladores encerrados no finally, sem exportação/persistência de contas; nenhum
  reset, importação ou limpeza de emulador compartilhado.

## Resultados em 2026-10-16

| Validação | Resultado |
|---|---|
| R2 focal | 38/38 passaram |
| R3 focal | 24 cenários + 1 teste contêiner = 25/25 passaram |
| Functions completa com emuladores | 502/502 passaram; zero falhas/skips |
| Launcher com argumento de projeto real | Recusa antes de iniciar SDK/emulador |

Suíte completa final: 24 fixtures; 457 verificações instrumentadas; zero ADC e zero
sockets externos inesperados. Duração dos testes: aproximadamente 9,16 s, excluindo
inicialização dos emuladores. Os 477 testes preexistentes permanecem aprovados.

Ambiente usado: Node v24.17.0, Java 25.0.2, firebase-admin 14.2.0,
@google-cloud/firestore 8.7.1, google-auth-library 10.9.1, firebase-tools 15.24.0,
Firestore Emulator 1.22.0. Node 22 não foi localizado no PATH nem nos diretórios
usuais verificados; runtime bundled também é v24. Não instalado nada.
Compatibilidade executada com Node 22 permanece PENDENTE.

## Matriz de comportamento

| Cenários obrigatórios | Evidência |
|---|---|
| Criação real, create-only, createTime e ordem pré-remoção controlada | Documento criado por transação; Auth presente após commit; createTime SDK real; remoção sintética somente depois |
| tx.create contra registro existente | Erro ALREADY_EXISTS (6), conteúdo e createTime intactos |
| Replay e duas transações da mesma operação | Zero create no replay; concorrência com 3 tentativas de callback, 2 tentativas create e só 1 create confirmado |
| Operações incompatíveis | Concorrente perde no guard; guard trocado não permite adotar reserva de outro deletionId |
| Guard modificado durante admissão/transação | COMPLETE antes do read recusa; corrida após lock serializa sem gravação tardia inválida |
| COMPLETE e executor antigo | Guard e updateTime não mudam; inspeção exige prova terminal |
| Timestamp ausente, inválido e submilissegundo | Recusa sem arredondar guard; tipo incompatível no registro também recusado |
| Falha pré-commit | Transação abortada, reserva ausente, releitura inconclusiva e novo retry explícito funciona |
| Commit com resposta perdida | UNKNOWN, reserva realmente existente; releitura e replay preservam updateTime sem duplicação |
| UID recriado entre observações | IDENTITY_CHANGED, sem autoridade |
| Auth substituído antes do commit da reserva | ACK da reserva antiga ainda possível: limite reproduzido, não resolvido |
| Legados e namespaces | Ausência não autoriza; mesmo UID isolado entre projeto/banco reais no Emulator |
| Operador, PII, produção e fluxos existentes | Operador recusado sem I/O; saída contém somente status e destructiveAuthority:false; configurações inseguras recusadas; entrypoints intactos |

## Diferenças reais em relação aos fakes

1. **Tentativas não são commits.** Firestore pode executar tx.create em callback
   abortado e repetir a transação. A medição correta verifica commit efetivo e
   metadados persistidos. A validação de idempotência não foi relaxada: só um
   documento foi criado e replay manteve createTime/updateTime.
2. **Locks e serialização.** O writer concorrente do guard pode esperar a transação
   que já o leu. Na execução final, a reserva precedeu COMPLETE; o teste compara os
   Timestamps originais para garantir essa ordem. O fake MVCC não modela a espera.
3. **Precisão do Firestore.** A fixture inicial de 1 ns foi truncada ao persistir;
   o teste usa agora 1 us real persistível para testar guard submilissegundo. O SDK
   toMillis trunca fração abaixo de ms; o createTime observado tinha 605000 ns abaixo
   do ms. Guard submilissegundo é recusado sem arredondamento; guard normal atual
   usa Timestamp.now, com precisão de ms. Comparações de ordenação usam Timestamp
   original, não o valor truncado. Esse adapter não aceita generalização silenciosa.
4. **Precisão Auth.** UserRecord.metadata.creationTime do Admin SDK 14.2.0 usa string
   UTC com precisão de segundos. No teste final, o storage tinha resto 434 ms,
   ausente da metadata pública. Parsear essa string não cria precisão.

Para testar o restante do contrato sem inventar evidência, o adapter fechado no
teste suplementa getUser com accounts:lookup HTTP no próprio Auth Emulator,
Bearer owner, redirect recusado e timeout de 5 s. UID e projeção UTC devem coincidir;
o createdAt vem da resposta real do servidor. Essa leitura não é uma proposta de
adapter de produção nem prova de geração irrefazível. O caminho somente com SDK
público sem evidência precisa é caracterizado como IDENTITY_AMBIGUOUS e não escreve.

As primeiras falhas do harness eram normalização do argumento array de Socket.connect,
contagem de tentativas create como commits e fixture de 1 ns não persistida como tal.
Foram corrigidas somente no harness. Nenhuma validação do modelo foi enfraquecida.

## Limite de identidade reproduzido

Reprodução mínima: criar Auth sintético e guard; observar identidade antiga;
durante o callback Firestore, excluir/recriar esse UID no Auth Emulator; concluir
a transação de reserva. Resultado: RESERVATION_ACKNOWLEDGED contendo a observação
antiga, enquanto Auth já representa outra criação. A inspeção posterior retornou
IDENTITY_CHANGED. Todas as saídas mantiveram destructiveAuthority:false.

Causa: Auth não pertence ao read-set/lock da transação Firestore. A reserva não
consegue condicionar atomicamente auth.deleteUser à geração observada. Uma consulta
extra posterior tampouco elimina a janela antes de uma remoção futura. Os testes
não comprovam IAM real, impossibilidade absoluta de UID reuse ou custom tokens externos.

## Custos e recomendação R4

Sem acesso à nuvem nem custo Google causado por estes testes. Nenhum serviço/API
habilitado ou recurso permanente. Futuro seam: primeira reserva 2 reads + 1 create;
replay 2 reads e zero writes; inspeção 2 reads, zero writes e 2 observações Auth;
admissão 1 read. Reutilizar leitura do guard na mesma transação reduz incremento
para 1 read + 1 create. Retries repetem reads; callback repetido não significa
escrita duplicada. A consulta adicional de metadata deste harness não deve ser
contabilizada como adapter de produção já aprovado.

R4 recomendado: manter integração destrutiva bloqueada; decidir contrato de origem
e precisão da evidência Auth, bem como representação/normalização dos Timestamps;
validar política operacional de não reutilização e capacidades IAM; definir legados,
retenção e autoridade administrativa. Qualquer adapter futuro exige revisão própria.
Não migrar schema, abrir exceção de validação, renovar identidade antiga nem usar
reserva como autorização para limpeza. AccountGen amplo só deve ser discutido se
o produto precisar suportar reutilização; este experimento não a torna segura.

Referências oficiais sobre escopo e limitações da emulação:
- https://firebase.google.com/docs/emulator-suite/connect_auth
- https://firebase.google.com/docs/emulator-suite/connect_firestore

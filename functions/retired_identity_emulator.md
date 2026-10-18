# D2-C-02-R3 — validação local com Firebase Emulator

**R16-FIX1: execução manual BLOQUEADA.** A sanitização do Auth em processo
continua parcial: console.error e logger próprio não passam pelo filtro io.
As instruções de execução abaixo são históricas, não uma autorização atual.
É necessária decisão humana antes de ampliar o isolamento do Auth.

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

## R16 — encerramento e diagnóstico do launcher

O launcher existente foi endurecido sem iniciar emuladores nesta rodada. Importar
o módulo é inerte; a porta de dependências exportada serve aos testes unitários.
Não há nova opção CLI, projeto, adapter Firebase ou integração destrutiva.

- Toda aquisição ocorre sob try/finally. Auth e o servidor de seleção de porta
  são registrados antes de listen; subprocessos antes de await. Cancelamento
  impede próximas etapas, inclusive após resolução tardia de createApp.
- Um único cleanup compartilhado fecha recursos parcialmente inicializados.
  Cada recurso tem uma única tentativa de fechamento e espera limitada a 3 s;
  as esperas ocorrem em paralelo. Deadlines de fechamento já iniciados são
  preservados. Listeners próprios e timers são removidos ao finalizar.
- Somente servidores e ChildProcess desta execução recebem close/kill/unref.
  Não há taskkill, seleção por nome/PID ou encerramento de processos externos.
  Se close/kill falhar ou o encerramento não chegar no prazo, há CLEANUP_FAILED
  e RESOURCES_NOT_CONFIRMED_STOPPED; nunca se declara encerramento confirmado.
- O limite operacional continua 180 s desde o preflight; prontidão Java tem
  30 s. Após cancelamento pode haver até 3 s adicionais de cleanup assíncrono.
  Esses limites não preemptam código síncrono bloqueado nem garantem escalonamento OS.
- SIGINT, SIGTERM e SIGHUP são tratados; no Windows também SIGBREAK (Ctrl+Break).
  Repetições não iniciam outro cleanup. A primeira causa de cancelamento prevalece.
  Não há garantia para SIGKILL, TerminateProcess externo, falha do runtime/OS ou
  fechamento forçado do terminal. No Windows kill atua no processo direto;
  descendentes dos workers não são uma árvore supervisionada pelo launcher.
  Recursos que não fecham são liberados por unref após o prazo, com falha explícita;
  isso permite sair, mas não comprova que o processo remanescente terminou.
- O diretório temporário isolado de configuração continua sem exportação de dados;
  não é apagado automaticamente. A remoção de dados não faz parte desta correção.

| Código | Significado |
|---|---|
| 0 | Runner terminou com sucesso, cleanup sem falhas e evidência R3/TAP válida |
| 1 | Preflight/inicialização/runner sem código utilizável, ou cleanup falhou após sucesso |
| outro código do runner | Falha do runner preservada, sem cancelamento prioritário |
| 124 | Timeout operacional; saída tardia do runner não sobrescreve |
| 130 / 143 / 129 / 131 | SIGINT / SIGTERM / SIGHUP / SIGBREAK tratados, respectivamente |

124 e os códigos de sinal identificam a causa somente quando emitidos pelo próprio
launcher; um runner pode devolver numericamente o mesmo código. Diagnósticos
distinguem a etapa. Não converter nenhuma interrupção em sucesso.

Diagnósticos JSON contêm apenas stage/category: PREFLIGHT_FAILED,
AUTH_START_FAILED, PORT_ALLOCATION_FAILED, FIRESTORE_START_FAILED,
FIRESTORE_NOT_READY, TEST_RUNNER_FAILED, TEST_TIMEOUT, EXECUTION_INTERRUPTED e
CLEANUP_FAILED. Códigos externos aceitos: EADDRINUSE, EACCES, EPERM e ENOENT;
outros erros viram UNAVAILABLE. Há categorias fechadas EARLY_EXIT, EXIT_NONZERO,
DEADLINE, TERMINATION_FAILED e os sinais suportados. Mensagens e stacks desses
diagnósticos não saem; os canais diretos do Auth não estão cobertos (ver FIX1).

Output arbitrário de Java/testes não é encaminhado. stdout fornece somente escopo
sintético, contadores TAP numéricos TEST_SUMMARY e contadores R3_ISOLATION validados.
Falhas detalhadas de assertions e payloads são deliberadamente omitidos. --all
mantém descoberta da suíte Functions; não executa backend nem valida R11/R13 com
servidor real. O bloqueio de sockets do worker R3 permanece intacto.

O comando manual proposto na R16 fica suspenso pela R16-FIX1. Não executar o
launcher enquanto os canais diretos do Auth não tiverem uma decisão de segurança.

Exigir projeto demo-life-os-d2c02r3, dois endpoints 127.0.0.1 distintos, resumo
sem falhas e R3_ISOLATION com adcAttempts=0 e unexpectedOutboundSockets=0.
ExitCode zero sem esses indicadores não demonstra execução do R3. Falha de socket
ou CLEANUP_FAILED exige interromper e registrar apenas stage/category/exit code,
sem elevação, mudança de firewall ou encerramento amplo de processos.
O Node disponível é v24.17.0; Node 22 e encerramento real Windows permanecem
PENDENTES. Não instalar componentes nem iniciar esta execução automaticamente.

Validação R16 com Node v24.17.0: 44 testes unitários do launcher; focais
R2/V2/R10/FIX1/R11/R12 + launcher 373/373; suíte Functions 813 descobertos,
812 aprovados, zero falhas e um skip explícito R3. Sintaxe dos dois arquivos JS
aprovada. Emuladores, Java e launcher real não foram executados nesta validação.
Os testes usam EventEmitter, processos/servidores falsos e relógio manual, sem
sockets, sleeps, timers reais ou SDK Firebase. As garantias acima são comprovadas
com esses colaboradores; Ctrl+C/Ctrl+Break e fechamento de subprocessos no Windows
real ainda exigem a validação manual posterior.

## R16-FIX1 — framing de stdout e limite de sanitização do Auth

P2-01 reproduzido antes da correção: dois testes falharam. Um chunk de cerca de
20 KB perdeu cinco dos seis indicadores, mantendo só skipped. A mesma saída em
chunks pequenos preservava os indicadores: o corte antecedia a separação de linhas.

O parser agora processa todas as linhas completas sem truncar o chunk. O fragmento
incompleto retido tem até 12000 unidades UTF-16; StringDecoder preserva UTF-8
fragmentado. Uma linha que excede esse limite entra em estado de descarte até LF,
inclusive através de chunks, impedindo promover sua cauda a outro marcador.
O chunk corrente ainda ocupa a memória do evento recebido, mas não é acumulado
entre eventos; não há array de todas as linhas nem concatenação de saída ilimitada.
Filtros TAP/R3_ISOLATION e contadores emitidos são preservados; campos arbitrários
do JSON não são encaminhados. Linhas sem LF não constituem evidência completa.

Havia também aceitação de exit zero sem indicadores. A verificação final agora
ocorre depois de fechar/drenar stdout, sem mudar a prioridade de timeout/sinais:
exige tests/pass positivos, fail/cancelled zero e marcador R3 do projeto fixo com
fixtures/operações positivas, ADC e sockets inesperados zero. Evidência ausente
ou inválida transforma sucesso aparente em código 1 com TEST_RUNNER_FAILED e
R3_EVIDENCE_MISSING/R3_EVIDENCE_INVALID. Skips de outros testes não são promovidos
a execução do R3. Os indicadores não são assinatura, prova IAM ou autorização
destrutiva; um processo de testes adulterado continua fora do modelo de confiança.
As 44 regressões R16 foram preservadas. Sua fixture de runner bem-sucedido passou
a emitir o rodapé sintético esperado; os cenários sem evidência desativam esse
rodapé explicitamente para testar a recusa, sem modificar expectativas antigas.

P2-02 permanece PARCIAL, não corrigido integralmente. Inspeção estática do Firebase
Tools 15.24.0 instalado identificou:

- auth/utils.js:61-65: logError chama console.error(err) quando Auth não está no
  EmulatorRegistry, depois encaminha stack/message ao EmulatorLogger WARN.
  createApp direto não registra Auth pelo ciclo normal do EmulatorRegistry.
- auth/server.js:146: WARN pode incluir token recebido; :196 inclui detalhes de
  validação; :267-268 encaminha erro 500 a logError. Não foram feitos esses requests.
- logger.js: logger Winston inicia com transporte console silencioso; configuração
  e outros transportes podem mudar isso. Silenciar esse logger não cobre console.error.

Cobertos: diagnósticos gerados via io, stdout/stderr dos subprocessos Java/runner
conforme os filtros. Não cobertos: console/process.stdout/process.stderr/logger
diretos da dependência Auth e eventuais transportes próprios, inclusive arquivos.
O teste com Auth simulado emite marcador privado por console.error e por logger
simulado que escreve em process.stderr. Spies temporários capturam esses dois
escapes sem publicar o marcador, restauram os métodos em finally e comprovam
que io não os recebeu. Essa captura existe somente no teste; não protege produção.

Não foi aplicada interceptação global em runtime: afetaria canais compartilhados,
callbacks concorrentes e logs tardios depois da restauração, sem provar isolamento.
Erros operacionais tratados pelo launcher continuam diagnosticados por categoria;
os logs diretos do Auth não foram silenciosamente desabilitados.

Decisão humana solicitada antes de ampliar o escopo: aprovar ou rejeitar um desenho
de Auth em processo supervisionado com canais filtrados e controle separado. Não
foi implementado novo worker/launcher, patch do Firebase Tools ou alteração global.
Até essa decisão, execução manual continua BLOQUEADA, mesmo com exit zero nos
testes unitários. Node 22 e emuladores reais permanecem PENDENTES.

Validação FIX1 em Node v24.17.0: RED inicial 0/2 (perda de indicadores reproduzida);
depois da correção, launcher 62/62 (44 originais e 18 novos), focais 391/391,
Functions 831 descobertos, 830 aprovados, zero falhas e um skip R3 sem opt-in.
Sintaxe aprovada. Nenhum launcher real, Auth/Firestore Emulator ou Java executado;
o teste de console/logger utiliza apenas dependência Auth simulada e spies
restaurados, não lê credenciais nem registra o marcador privado na saída.

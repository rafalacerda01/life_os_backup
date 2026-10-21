# Water Android — homologação debug isolada

Estado atual: a R3 corrigiu a leitura exata da criação Auth; a R4 validou os
fluxos isolados, incluindo logout e troca A→B→A. Na R5, uma regressão offline
comprovou e corrigiu um stream de notificações que ainda podia reter o banco
durante logout. O Android não foi reexecutado após esse ajuste R5.
Não é uma versão de publicação nem autorização de ativação. A autorização
efetiva da consulta Auth em produção continua pendente de comprovação; P1 aberto.

## Fronteira de isolamento

- Nenhum arquivo de produção é importador deste diretório. O init script Gradle
  é aplicado explicitamente; cria somente a variante debug `waterHomologation`.
- Pacote `com.rafalacerda.lifeos.waterhomologation`, projeto `demo-life-os`.
  Sem processamento de `google-services.json`. Recursos Firebase sintéticos.
- `FirebaseInitProvider` removido e lista nativa explícita de registradores e
  plugins. Analytics, Crashlytics, App Check, Installations e Sessions não são
  registrados. Não há Google Sign-In ou Billing nativo neste engine.
- A Application inicializa explicitamente o projeto demo e fixa Auth 9099 e
  Firestore 8089 antes da execução Dart. Dart verifica essa configuração e a
  disponibilidade de todos os serviços antes de construir providers.
- Transporte debug fixo `10.0.2.2:8789`. O adaptador não altera o validador HTTPS
  de produção e rejeita qualquer requisição diferente do contrato exato.
- O marcador App Check é somente sintético; não representa atestação real.
- Instalação/execução exigem AVD com discos sintéticos separados e os bloqueios
  IPv4/IPv6 de `guard-android.ps1` aplicados ANTES da primeira abertura. A barreira
  global bloqueia inclusive saídas de serviços Android fora do UID do app.
- O cliente se fecha se faltar configuração nativa ou serviços locais. Uma falha
  posterior de serviço usa os contratos retryable/outbox dos componentes reais.

## Preparação local reproduzível

Requisitos já existentes: Node `C:\tools\node.exe` 22, Flutter 3.44.4/engine
`a10d8ac38de835021c8d2f920dbf50a920ccc030`, Gradle 9.1.0, Android API 34
Google APIs x86_64 do AVD Pixel_7. Não atualizar versões para esta homologação.

1. Criar um diretório externo de evidências e `demo-run.json` com `projectId`
   exatamente `demo-life-os`, `runId` novo, `cohortId` sintético, `cutoverMillis`
   positivo anterior à criação das contas e `birthDelayMillis` entre 0 e 60000.
   A rodada usou 30000 para observar a tela pendente antes do evento.
2. Reutilizar as dependências Functions instaladas por uma junction local
   `functions/node_modules` para `C:\life_os\functions\node_modules`.
   Não instalar dependências. A junction, `.env.local` e cópia local de Rules
   são ignoradas pelo Git. O launcher copia as Rules aprovadas byte a byte.
3. Compilar a partir de `C:\life_os\android`, com JAVA_HOME do Android Studio:

   ```powershell
   .\gradlew.bat --offline --no-daemon --console=plain `
     -I ..\tools\water_android_homologation\gradle.init.gradle `
     '-Ptarget=tools/water_android_homologation/main.dart' `
     '-Ptarget-platform=android-x64' '-Ptrack-widget-creation=true' `
     '-Ptree-shake-icons=false' assembleWaterHomologationDebug
   ```

4. Antes de instalar, verificar manifest e recursos do APK com as ferramentas
   oficiais Android: pacote acima, debuggable=true, project_id=demo-life-os,
   Application própria, ausência de FirebaseInitProvider e apenas cinco
   registradores permitidos. Registrar SHA-256. Não instalar o APK convencional.
5. Executar `start-local.ps1 -Mode emulators -EvidenceRoot <diretório>` e
   `start-local.ps1 -Mode transport -EvidenceRoot <diretório>` em processos locais.
   Conferir definições Functions carregadas e TODOS os listeners em loopback.
   O SDK/CLI instalado suporta descoberta por arquivo; o launcher usa essa
   opção para não abrir um servidor temporário em todas as interfaces.
6. Subir Pixel_7 com `-datadir`, `-data`, `-initdata`, `-cache` e `-sdcard`
   apontando exclusivamente para discos novos, com `-no-snapshot -read-only`.
   Não apagar/reutilizar dados originais. Porta ADB desta rodada: emulator-5580.
7. Somente nesse AVD: `adb root`, `guard-android.ps1 -Mode global`, instalar o APK
   isolado, `guard-android.ps1 -Mode app`, conferir regras e só então abrir a
   HomologationActivity. Não executar Google Sign-In real.
8. Usar apenas emails `@example.test`. O servidor deriva UID do token do Auth
   Emulator, nunca do corpo. O trigger recebe o evento real do Auth Emulator e
   chama o registrador existente, sem fabricar/transcrever evidência de criação.

## Histórico R2 — bloqueio reproduzido e corrigido na R3

Na conta B, o evento SDK trouxe `2026-10-21T18:36:33.946Z`, enquanto `getUser()`
Admin retornou `Wed, 21 Oct 2026 18:36:33 GMT`. O core existente exige igualdade
exata e recusou `WATER_BIRTH_GENERATION_CONFLICT`. O registro não foi forjado,
arredondado ou inserido manualmente. Bootstrap permaneceu 503/
`WATER_PROVISIONING_PENDING`; a sessão permaneceu no mesmo UID.

Esse bloqueio foi corrigido na R3 pelo leitor servidor existente
`functions/water_auth_generation.js`, usando `createdAt` em milissegundos da
API oficial e a credencial Admin já vinculada. A comparação exata foi mantida.
Não interpretar timestamps como garantia de atomicidade entre Auth e Firestore.

O adapter local OPEN e seus booleanos de política são dependências sintéticas
de teste; NÃO comprovam IAM/fences de produção. Flags de produção continuam false,
as duas políticas CLOSED, cutovers nulos e P1 aberto.

## Resultados históricos R2 (não representam o estado após R3/R4)

- Análise Dart: PASS. Nove testes de transporte negativo: PASS. Sintaxe Node: PASS.
- Build convencional arm64 e build isolado: PASS; somente o segundo foi instalado.
- Inicialização nativa/Dart, cadastro Auth sintético, UI pendente/sessão preservada
  e encerramento explícito de sessão: PASS. Dois UIDs sintéticos diferentes.
- Registro de nascimento: FAIL na integração real acima.
- READY, consumo, meta, offline/reconexão, reinício de Water admitida e integridade
  de sua fila: BLOCKED; não foram executados e não devem ser apresentados como PASS.

Testes anteriores R1 não foram repetidos. Nenhum commit, push, deploy, alteração
IAM ou alteração de serviços/credenciais de produção faz parte deste procedimento.

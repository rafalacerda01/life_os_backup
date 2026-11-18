# Lançamento Local-First — etapa 4: host Android e Tarefas

Integração direta em C:/life_os, branch refactor/launch-local-first-20261117. Base: 79bfc759f27e9759a6b95a9332ad9e02c7feb82f. Backend independente permanece b316df4302e8ae88e5d17af01780d831c0896ab9, sem alterações. Checkpoint seletivo stage4-before/ e hashes no workspace privado launch-local-first-20261117. O SHA final da etapa fica registrado nesse workspace após o commit.

## Host isolado e preservação do startup

main_local.dart exige handshake Android antes de acessar identidade, chave ou banco: pacote EXATO com.rafalacerda.lifeos.localdev, nenhum FirebaseApp inicializado e nenhum plugin Firebase/GoogleSignIn/Billing registrado. Abre LocalDeviceSession real, mantém a identidade permanente, disponibiliza a conexão localOnly e o runtime local para TasksScreen. Erro preserva arquivos/chaves e oferece retry. Nenhum FirebaseUser é inventado.

Gradle só habilita o pacote .localdev mediante lifeOsLocalLab=true. O host de laboratório não tem variante release; não executa GoogleServices ou uploads Crashlytics. Os targets locais são recusados no pacote oficial, e o target legado é recusado no laboratório. O startup padrão main.dart permanece legado. Não houve instalação, execução ou publicação do APK com.rafalacerda.lifeos.

MainActivity mantém super.configureFlutterEngine para o pacote normal. No pacote de laboratório, registra explicitamente apenas FSS, SharedPreferences, lifecycle, JNI/JNIFlutter e o SDK integration_test quando presente. A auditoria usa Class.forName com initialize=false, para observar registro sem inicializar classes remotas. FirebaseInitProvider é removido só nos manifests do laboratório. O boot receiver de notificações fica desativado nesse host até o gate de ownership local.

O profile AOT de homologação nega INTERNET pelo próprio Android e permite run-as apenas para extrair relatórios sintéticos. Debug permite INTERNET para ferramentas/hot reload; isso não equivale à qualificação offline do profile. A configuração do VS Code aponta para main_local.dart e define a propriedade Gradle somente nessa execução. A configuração legada continua disponível.

## Teste funcional real

integration_test/local_tasks_native_test.dart executou na aplicação Android real, com banco criptografado e armazenamento seguro nativo. O runner confere pacote, AVD, cenário, contagens e resultados do binding; recusa saída incompleta, falha de pm clear ou texto fora do padrão sintético. Antes de instalar, aapt2 confirmou o pacote .localdev e a ausência de INTERNET.

Resultado final em stage4-native-app-android-input/tasks-decision.json: **LOCAL_TASKS_ANDROID=PASS, 48 checks**.

- Seed:18 checks, criação, toggle e exclusão pela UI, quota Free3 no repositório real, ausência de fila remota, integridade SQLite, chave acessível e journal READY.
- Novo processo:15 checks, mesmos perfil, tarefa, status, chave e hash do banco fechado.
- Cold boot real, modo avião antes/depois:15 checks, dados e chave continuam acessíveis e os mesmos fingerprints permanecem idênticos. Boot IDs diferentes foram medidos diretamente no guest.

Os dados são exclusivamente sintéticos. Não há mocks de FSS/KeyStore/SQLite nem troca do teste Android por testes Dart. Entradas de texto são eventos reais enviados pelo Android via ADB, solicitados pelo harness restrito ao pacote de laboratório. Não são atribuições diretas ao controller. O teste usa a tela e o repositório oficiais, não uma implementação alternativa de Tarefas.

## Falhas preservadas e limitações do ambiente

Tentativas anteriores ficaram BLOCKED por crashes reais do QEMU 36.6.11/WHPX (Windows APPCRASH 0xc0000005). Os eventos e logs foram preservados. O mesmo userdata foi mantido; não houve wipe de AVD ou exclusão de arquivos de banco/chave. A tentativa de CPU sem WHPX não concluiu boot e foi encerrada somente no processo comprovadamente pertencente ao laboratório.

O host ficou estável com SwiftShader, Vulkan desativado e Skia nos manifests exclusivos do laboratório. Esses fallbacks são documentados pelo [Android](https://developer.android.com/studio/run/emulator-troubleshooting) e pelo [Flutter](https://docs.flutter.dev/perf/impeller). A opção Skia emite aviso de descontinuação futura. O renderer padrão do aplicativo real não foi alterado e não recebe aprovação por esses resultados.

Um teste real anterior falhou na primeira criação, mesmo ampliando a espera pelo stream. A entrada via TestTextInput não entregou o estado esperado no cenário com IME nativo; a rodada final usa eventos Android e mantém todas as verificações. Falhas anteriores não foram apagadas nem convertidas em PASS. A seleção de exclusão agora identifica a linha pelo título, em vez de assumir que o primeiro ícone visível pertence ao item esperado. Diagnósticos de falha registram estado do formulário e linhas sintéticas sem exportar a chave.

O SDK integration_test precisou de dependências públicas ainda não cacheadas. A resolução inicial encontrou PKIX no Java, embora HTTPS oficial fosse validado pelo Windows. Uma cópia privada de certificados públicos já confiáveis no Windows foi usada apenas naquele processo de build; nenhum certificado global, chave privada, hostname check ou TLS foi alterado/desabilitado. Builds seguintes funcionaram offline com o cache obtido. A configuração segue o mecanismo de truststore por processo do [JSSE](https://docs.oracle.com/en/java/javase/24/security/java-secure-socket-extension-jsse-reference-guide.html). O pub get resolveu o grafo, mas retornou1 pela limitação desktop de symlinks já conhecida; nenhuma configuração global do Windows foi alterada.

## Arquivos e validação complementar

Novos: lib/main_local.dart; LocalLabHost.kt; manifests localLab/localLabProfile; .vscode/launch.json; integration_test/local_tasks_native_test.dart; tools/local_app_homologation/run-tasks.ps1 e assert-tasks.ps1; este relatório. Alterados: MainActivity.kt, android/app/build.gradle.kts, pubspec.yaml e pubspec.lock. Seis dependências de teste do SDK foram adicionadas; o fork FSS permanece intacto. Nenhum código remoto ativo foi removido.

Análise Dart sem issues. Regressões de Tarefas:35PASS. Builds profile AOT passaram. O build padrão legado nas três ABIs passou na validação da etapa e voltou a ser executado após as mudanças de Finanças; o resultado final consta no log stage5-legacy-build.log. As duas guardas de target são verificadas com recusas reais do Gradle, antes da compilação do entrypoint incompatível. O artefato HTML gerado/rastreado de problemas de build deve ser preservado fora de build e retirado do diff de código após a validação final.

## Critério

GO focal para o host isolado e CRUD Free de Tarefas no Android14/API34 x86_64, com Skia no laboratório. O gate de armazenamento da etapa3 continua registrado:283checks PASS. Não há homologação de hardware físico/StrongBox, outras APIs, renderer padrão ou todos os módulos.

APP_WIDE_OFFLINE=NOT_VERIFIED; PREMIUM_HYBRID=NOT_IMPLEMENTED; LOCAL_IDENTITY_GATE=BLOCKED; lançamento NO-GO; ROLLOUT=CLOSED.

O entrypoint de desenvolvimento ainda apresenta somente Tarefas. A navegação/CTA de Foco, notificações, demais módulos, Mercado, segurança opcional, migração UID e Premium híbrido continuam pendentes. Nenhum novo startup foi ativado no pacote oficial. Sem push, deploy, landing, alterações de credenciais ou serviços faturáveis.

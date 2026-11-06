# Android native prerequisite gate — development only

Estado: **BLOCKED para integração funcional**. O probe exercita FlutterFire Android
real, sem REST ports substitutos. Não monta LifeOSApp nem publica AuthAuthenticated.
Ele não é uma nova arquitetura de sessão nem um caminho de produção.

- Pacote exclusivo com.rafalacerda.lifeos.p1nativegate; projeto demo-life-os,
  app Firebase sintético e database (default).
- Init Gradle explícito, somente assembleP1NativeGateDebug e target exato.
  Variantes release/profile desabilitadas; Dart exige kDebugMode/Android e a
  Application exige pacote debug exato. Não há flag que abra produção.
- FirebaseInitProvider e MainActivity produtivos removidos. Sem processamento de
  google-services.json; sem registro de Analytics, Crashlytics, Billing, Google,
  lembretes ou notification engine. App Check usa o provider debug oficial.
- Auth 45099, Firestore 45089 e backend 45789, todos host 127.0.0.1. ADB reverse
  conecta o loopback do aparelho aos três listeners host. Native e Dart fixam os
  SDKs nos Emulators antes de qualquer IO de usuário.
- Executar somente em AVD descartável com discos separados. Aplicar guard-avd.ps1
  global e app antes de abrir o app. Nenhuma regra do firewall host é alterada.
- O backend mantém o App Check exigido e usa o produtor R1 existente. Nenhum
  token sintético de App Check é aceito; não registrar tokens em Cloud nesta missão.
- Probes initial/restart/offline/second não exportam tokens de Auth/App Check,
  chaves ou app data. O marcador de secure storage é diagnóstico, não credencial
  nem prova de custódia de banco. Nenhum banco geracional de conta é aberto.

Build local, dentro de android, sem atualização de dependências:

```powershell
.\gradlew.bat --offline --no-daemon --max-workers=2 `
  '-Dorg.gradle.jvmargs=-Xmx1536m -XX:MaxMetaspaceSize=768m -XX:ReservedCodeCacheSize=256m' `
  --console=plain -I ../tools/p1_android_native_gate/gradle.init.gradle `
  '-Ptarget=tools/p1_android_native_gate/main.dart' `
  '-Ptarget-platform=android-x64' '-Ptrack-widget-creation=true' `
  '-Ptree-shake-icons=false' assembleP1NativeGateDebug
```

O diretório externo p1-android-native-gate contém snapshot, build log, verificador
de APK, launcher dos serviços com perfil vazio/guard de rede, argumentos dos
discos do AVD, coordenador nativo e resultados. run-local.ps1 exige esse pacote
externo e recusa instalação se verify-apk.cjs falhar; não limpa um app existente.
Ele foi acrescentado para impedir a instalação antes da verificação completa.
Sua sequência integral não foi repetida em outro AVD: a primeira execução
manual antecedeu parte da inspeção de recursos, foi interrompida e o mesmo APK
instalado foi depois verificado por hash. Restart/offline/segunda conta ocorreram
após a inspeção completa. Esse desvio está preservado no relatório.

O App Check debug foi ativado pelo SDK, mas getToken retornou unknown e nenhum
token foi obtido sob o isolamento local. O runtime recusou admissão, bootstrap
sem App Check retornou 401 e as duas origens R1 permaneceram RESERVED, sem perfil
ou recibos. Não usar esses resultados como homologação de Home/Tasks, Drift,
SyncQueue, ACK, módulos, cold start offline admitido, notificações ou Android real.
Debug token registrado/atestado, política IAM e entrega gerenciada não foram
comprovados. Não contornar o bloqueio nem publicar o APK.

## Diagnóstico App Check posterior

A fase appcheck ativa o provider debug oficial e captura a falha Java completa
com causas, suppressed e stack frames. Mensagens são redigidas no Android antes
da exportação; nenhum token, segredo debug ou app data é retornado. Essa fase
não cria usuário, não publica sessão e não abre banco ou módulo.

No AVD com rede somente loopback, o SDK 19.2.0 percorreu DebugAppCheckProvider
e NetworkClient e falhou em UnknownHostException para
firebaseappcheck.googleapis.com, causado por GaiException/EAI_NODATA. O plugin
Flutter 0.3.2+10 converte falhas para unknown; esse código não identifica causa.
Não houve erro observado de classe, método ou registrador nesse percurso.

A emissão oficial usa exchangeDebugToken HTTPS e exige cadastro autorizado do
debug secret no projeto/app gerenciado correspondente. Isso não foi executado.
Nenhum token foi emitido ou verificado, e o gate funcional permanece BLOCKED.
Não alterar os guards para produzir token fictício ou admitir dados.

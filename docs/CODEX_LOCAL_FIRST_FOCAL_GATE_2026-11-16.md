# CODEX — Gate focal 01: identidade e sessão local do Life OS

**Data:** 2026-11-16  
**Escopo:** somente repositório Flutter, branch `refactor/offline-first-premium-hybrid-20261116`.  
**Base original preservada:** `security-audit-before-circles-fix`.  
**Estado:** aguardando execução de testes e revisão; não é aprovação da migração.

## Objetivo
Validar e, se necessário, corrigir apenas os novos componentes preparatórios de identidade e sessão locais, sem ativá-los em `main.dart` ou trocar fluxos de autenticação em produção.

Arquivos criados/alterados:
- `lib/core/database/local_installation_identity_service.dart`
- `lib/core/database/local_installation_identity_provider.dart`
- `lib/core/database/local_device_session.dart`
- `test/core/database/local_installation_identity_service_test.dart`
- `test/core/database/local_device_session_test.dart`

### Contexto técnico confirmado
- O app da branch auditada depende atualmente de Firebase Auth, App Check, Firestore, Crashlytics e SyncQueue, inclusive em `main.dart`, no roteador e nos repositórios dos módulos.
- O Drift v11 tem bancos criptografados por identidade e gerenciamento de chave em `UserDbKeyManager`.
- O serviço local novo usa UUID v4 e não transfere dados nem migra as chaves existentes.
- A presença de qualquer banco SQLite antigo ou indícios conhecidos em SecureStorage/SharedPreferences deve bloquear a criação silenciosa de perfil novo.
- O onboarding guarda `life_os_onboarding_completed_v1` em SharedPreferences. O antigo `DbKeyManager` guarda `db_encryption_key`, e o banco por UID utiliza aliases `db_encryption_key_v2_*`.
- Vercel Billing ainda depende Firebase Admin, Auth, App Check e Firestore; outra branch de design existe em `life_os_backend:refactor/premium-without-firebase-20261116`.

## Trabalho autorizado

1. Confirmar o HEAD e a branch sem substituir ou misturar `main`.
2. Executar `dart format --output=none --set-exit-if-changed` nos cinco arquivos e registrar alterações necessárias. Formatação pode ser aplicada apenas nos cinco arquivos listados.
3. Executar `flutter analyze` focal e testes focais:
   `flutter test test/core/database/local_installation_identity_service_test.dart test/core/database/local_device_session_test.dart`
4. Em caso de erro, corrigir estritamente os arquivos novos e adicionar testes focais quando necessário; preservar os contratos existentes.
5. Avaliar corrida de `resolve()`, consistência de marcador local vs SQLite, colaterais da leitura de SecureStorage e SharedPreferences, aliases de chaves e proteção contra migração silenciosa.
6. Conferir compatibilidade real dos métodos `FlutterSecureStorage.readAll`, `SharedPreferencesAsync.getBool`, UUID v4 e construtores de `LocalDatabaseIdentity` com as versões do pubspec.
7. Fazer revisão adversarial de `LocalDeviceSession.open()`: concorrência, falha na abertura, dispose, tentativa tardia de publicação, troca de identidade e fechamento de banco.
8. Manter bloqueio por padrão de instalações existentes; não criar migrador de UID nem apagar arquivos nesta etapa.
9. Confirmar que `main.dart`, router, Billing e endpoints remotos seguem intocados e nenhum serviço novo foi ativado.
10. Apresentar relatório com tabelas PASS / FAIL / BLOCKED / NOT_VERIFIED, paths, comandos executados e commit SHA(s). Se houver falha não resolvida, deixar gate fechado.

## Limites e proibições
- Não fazer merge para `main`, push/deploy da Vercel, release Android, Cloud Run, Cloud Build, Firebase, Google Cloud ou IAM.
- Não remover dados, pastas de bancos, sidecars WAL/SHM, chaves, arquivos antigos, cache ou projeto remoto.
- Não executar exclusão de conta real; usar arquivos temporários de teste.
- Não alterar `pubspec.yaml`, `pubspec.lock`, schema Drift, Firebase Auth ou roteador nesta rodada.
- Não ativar a nova sessão local no app ainda.
- Não instalar serviços pagos, contratar recursos, rodar CI remota sem confirmação de custo, nem presumir US$ 0 em infraestrutura não verificada.
- Não falsificar PASS; execução efetiva dos testes é condição obrigatória.
- Não transformar o P1 remoto em RESOLVED sem prova de separação completa da arquitetura.

## Resultados a devolver
1. Identificação exata do commit/branch e estado da working tree.
2. Versões Flutter/Dart observadas.
3. Resultado de formatação, análise e testes focais, com contagens.
4. Correções aplicadas, diffs e novos commits (somente na branch isolada).
5. Riscos não resolvidos e recomendação de gate: `LOCAL_IDENTITY_GATE=PASS|FAIL|BLOCKED`.
6. Proposta para a etapa seguinte: inventário de storage fora do Drift e prova de migração local sem perda de dados. **Não executar a etapa seguinte automaticamente.**

**Estado geral até lá:** LOCAL_BOOTSTRAP_SCAFFOLD_UNVERIFIED · NO_RUNTIME_CUTOVER · P1 RED (arquitetura antiga) · ROLLOUT CLOSED.

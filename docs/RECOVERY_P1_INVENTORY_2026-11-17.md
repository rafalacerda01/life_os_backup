# Inventário P1 pendente — recuperação 2026-11-17

Snapshot integral com hashes em ../preservation/, fora de C:/life_os/build. Nenhum arquivo original foi sobrescrito.

| Repo | Arquivo | Classificação | Motivo |
| --- | --- | --- | --- |
| app-main | `functions/account_cleanup_manifest.js` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| app-main | `functions/circle_cleanup.js` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| app-main | `functions/local_homologation_environment.cjs` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| app-main | `functions/p1_native_environment.json` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| app-main | `functions/trusted_account.js` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| app-main | `lib/core/database/local_account_session.dart` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| app-main | `lib/core/network/generational_http_provider.dart` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| app-main | `lib/core/network/generational_http_transport.dart` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| app-main | `lib/core/services/emulator_account_runtime.dart` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| app-main | `lib/core/services/local_homologation_environment.dart` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| app-main | `lib/core/services/sync_manager.dart` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| app-main | `lib/core/services/sync_queue_store.dart` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| app-main | `lib/core/services/trusted_account_access.dart` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| app-main | `lib/core/storage/generational_cleanup.dart` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| app-main | `lib/features/auth/data/local/account_deletion_cleanup_barrier.dart` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| app-main | `lib/features/auth/data/local/generational_deletion_finalizer.dart` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| app-main | `lib/features/auth/data/local/generational_deletion_flow.dart` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| app-main | `lib/features/auth/data/remote/account_deletion_recovery.dart` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| app-main | `lib/features/auth/data/remote/account_remote_data_source.dart` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| app-main | `lib/features/auth/data/repositories/auth_entry_failure.dart` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| app-main | `lib/features/auth/data/repositories/auth_repository_impl.dart` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| app-main | `lib/features/auth/presentation/providers/auth_provider.dart` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| app-main | `lib/features/onboarding/presentation/splash_screen.dart` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| app-main | `test/core/services/local_homologation_environment_test.dart` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| app-main | `test/core/services/local_runtime_appcheck_refusal_test.dart` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| app-main | `test/features/onboarding/splash_screen_test.dart` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| app-main | `tools/p1_android_native_gate/android/java/com/rafalacerda/lifeos/nativegate/NativeGateActivity.java` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| app-main | `tools/p1_android_native_gate/android/java/com/rafalacerda/lifeos/nativegate/NativeGateApplication.java` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| app-main | `tools/p1_android_native_gate/gradle.init.gradle` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| app-main | `tools/p1_android_native_gate/main.dart` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| app-main | `tools/p1_android_native_gate/README.md` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| app-main | `tools/trusted_account/auth-worker.cjs` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| backend | `api/_http_generation_custody.cjs` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| backend | `api/account/_birth_ledger_cleanup.js` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| backend | `api/account/_circle_cleanup.cjs` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| backend | `api/account/_cleanup_manifest.cjs` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| backend | `api/account/_deletion_control.cjs` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| backend | `api/account/_shared.js` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| backend | `api/account/_terminal_receipt.js` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| backend | `api/account/_trusted_account.cjs` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| backend | `api/account/delete.js` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| backend | `config/local_homologation_environment.cjs` | **ADAPTAR** | Contrato atual contém dependências Auth/Firestore/receipts; preservar fences antes de separar acesso remoto. |
| backend | `config/p1_native_environment.json` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| backend | `test/p1-native-appcheck-boundary.test.cjs` | **REAPROVEITAR** | Mecanismo local, recuperação, journal, sessão, fila ou regressão útil à preservação Local-First. |
| backend | `tools/p1_native_local/official_app_check.cjs` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |
| backend | `tools/p1_native_local/server.cjs` | **PRESERVAR** | Diagnóstico/infraestrutura remota existente; manter histórico e adaptar em gate próprio. |

Nenhum componente foi classificado REMOVER FUTURAMENTE sem prova suficiente de obsolescência. Círculos e contratos Firebase permanecem preservados até o gate funcional posterior.

Revisão de segredos: uma ocorrência com formato de API key em fixture Gradle de demo foi encontrada. O original permanece somente no snapshot privado; na worktree a fixture usa um valor sintético construído deterministicamente, sem credencial real. Nenhum valor sensível é reproduzido neste relatório.

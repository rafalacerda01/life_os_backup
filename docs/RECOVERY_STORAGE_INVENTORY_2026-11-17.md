# Persistências e fronteiras — candidata de recuperação

Inventário dos fontes P1 atuais em 2026-11-17. Não é um censo de aparelhos reais. A linha P1 mais recente foi preservada; nenhum banco real foi aberto, importado, apagado ou renomeado. O inventário anterior do Gate 02 permanece imutável. Esta versão registra também a correção Android da candidata.

## Bancos e propriedade

| Armazenamento | Endereço / versão | Preservação e dependências |
| --- | --- | --- |
| Drift legado | Documents/app_flutter, `life_os.sqlite`; chave `db_encryption_key` | Abertura legada ainda existe em AppDatabase. Não se torna banco de identidade local por inferência. |
| Drift por UID | `life_os_u_<sha256>.sqlite`; chave `db_encryption_key_v2_u_<sha256>` | Digest do UID normalizado. Chave preexistente obrigatória quando há banco/artefato; sidecar órfão bloqueia abertura. |
| Drift P1 por geração | Digest do JSON `[uid,generation]` na forma antiga/draft; forma vinculada usa `[2,projectId,databaseId,tenantId,uid,generation]` | LocalDatabaseIdentity.bound valida binding e geração UUIDv4. Mudar fórmula ou perder metadados perde o endereço da chave/banco. Nenhum draft foi promovido. |
| Drift da instalação preparada | Mesma factory, entrada `local-v1-<UUIDv4>`; marcador seguro separado | Só provisiona após guardas; não adota UID Firebase. Classes ainda desconectadas do startup principal. |
| Criptografia | Drift 2.34.3, sqlite3 3.5.1, hook sqlite3mc, chacha20/legacy=0 | PRAGMA key, validação do cipher e quick_check; temp_store MEMORY; WAL e synchronous NORMAL. SQLite do SO não é substituto. |
| Sidecars e migração | `-wal`, `-shm`, `-journal`, `.plaintext-backup`, `.encryption-candidate`, inclusive seus sidecars | WAL pode conter commits ausentes no arquivo principal. Bootstrap de criptografia contém recuperação/migração própria; não foi executado em dados reais. Guardas recusam nomes e ownership não qualificados. |
| Registro nativo P1 | Support/files, `life_os_native_ownership_v1.sqlite`, tabelas native_notification_owners/seals | SQLite auxiliar sem PRAGMA key e sem versão user_version explícita; synchronous FULL, busy_timeout 5000, transação IMMEDIATE. Está fora de Documents. A nova guarda recusa seu arquivo e sidecars, preservando bytes. |
| Quarentena/destruição | legacy_database_quarantine e user_database_storage_destroyer | Caminhos separados; não autorizam remoção durante bootstrap. Nenhuma destruição real foi executada. |

Schema Drift **11**, 17 tabelas: HealthEntries, Medications, Transactions, TaskTable, Habits, StudyStats, Subjects, Flashcards, Goals, FocusLogs, CheckInTable, NotificationsTable, NotificationDismissals, SyncQueueTable, WaterV2DailyStates, WaterV2Intents e WaterV2Preferences.

Evolução: v2 FocusLogs; v3 subjectId; v4 lastReviewed; v5 CheckIn; v6 Notifications; v7 SyncQueue; v8 owner/status/error/attempts da fila; v9 occurrenceKey/dismissals; v10 Water V2 estados/intents; v11 Water V2 preferências. A cadeia completa de upgrades v1→11 no Android permanece NOT_VERIFIED; a sonda criou bancos atuais com o schema real.

## SecureStorage

| Chave / família lógica | Conteúdo e cuidados |
| --- | --- |
| `db_encryption_key` | Chave aleatória legada de 32 bytes em base64url; DbKeyManager tem cache em memória. |
| `db_encryption_key_v2_u_<digest>` | UserDbKeyManager, chaves por identidade/binding/geração; caches/tails/revisões por alias lógico. |
| `life_os_local_installation_id_v1` | UUID permanente preparado, formato estrito local-v1. Só escrito após auditoria; relido para confirmação. |
| `auth_access_token` | Token legado; P1 tem valores scoped. Não apagar na ausência transitória de Auth. |
| `life_os_cycle_reminder_v1_<uid>` / `life_os_cycle_action_token_v1_<uid>` | Preferências JSON v1 e token aleatório de ações; variantes P1 nos domínios cycle_preferences/cycle_tokens. |
| `life_os_auth_cleanup_pending_v1` | Journal de limpeza Auth; binding e revisões P1 devem sobreviver. |
| `life_os_account_deletion_cleanup_v1` | Barreira persistente de exclusão/recuperação; não equivale a permissão para limpar. |
| `life_os_generation_cleanup_v1:<namespace>` | Plano e passos REQUESTED/REMOTE_CONFIRMED/COMPLETE, formatos v1/v2, prova remota necessária. |
| `life_os_deletion_recovery_v1:<namespace>` | Recuperação vinculada ao ambiente, operação/revisão/chave de recuperação. |
| `life_os_scoped_v2:<domain>:<namespace>:journal` e `...:value:<base64url>` | Journal OPEN/SEALED/COMPLETE, binding e manifestos; domínios seguros session_tokens, cycle_preferences e cycle_tokens. Prefixos lógicos compartilham store nativo; não são isolamento físico do plugin. |

flutter_secure_storage **10.3.1**, agora fixado em fork local auditável por dependency_overrides. Backend Android: shared_prefs/FlutterSecureStorage.xml, FlutterSecureKeyStorage.xml, FlutterSecureStorageConfiguration e configuração namespaced `FlutterSecureStorageConfiguration:FlutterSecureStorage.xml`; versões antigas podem ter outros marcadores/backup do plugin. Aliases AndroidKeyStore RSA antigo, RSA OAEP e `_androidx_security_master_key_`; wrapped AES; keysets Tink key/value no XML ESP. Estes nomes não são material secreto exportado.

Consumidores antigos continuam passando defaults resetOnError/migrateOnAlgorithmChange true; o provider preparado passa false. O problema não foi resolvido apenas por flags Dart. O dispatcher Android da candidata identifica o formato persistido por chamada, usa material existente e não despacha leitura para initialize/reset/migration do upstream. ESP abre keysets existentes; RSA/CBC/GCM usa os mesmos parâmetros históricos. read/readAll/contains em store vazio não geram arquivos/aliases. Falha/corrupção não retorna ciphertext nem limpa entradas. Primeira escrita explícita só provisiona em store inequivocamente vazio. deleteAll é recusado; delete por chave continua disponível aos fluxos autorizados de domínio. Formatos biométricos/AES-wrapping não homologados são recusados.

O fork Android muda globalmente a implementação do pacote nessa branch, embora o startup Local-First permaneça desligado. Helpers upstream continuam apenas para semear fixtures. iOS/Windows/Linux/macOS/Web e APIs biométricas não estão homologados por este resultado.

## Preferências, arquivos auxiliares e SO

| Persistência | Versão / comportamento |
| --- | --- |
| Onboarding `life_os_onboarding_completed_v1` | SharedPreferencesAsync, Android DataStore em files/datastore/*.preferences_pb. Tanto false quanto true preexistentes impedem inferir instalação nova. |
| Preferências legado | FlutterSharedPreferences.xml, prefixo flutter.; analytics_enabled, biometrics_enabled, all_notifications, study_reminders, habit_reminders, medication_reminders e ai_consent_accepted_<uid>. |
| Preferências P1 scoped | notification_preferences e ai_consent, valores/journals com binding, reload e confirmação de escrita. |
| Constantes antigas | HAS_COMPLETED_ONBOARDING, USER_SECURE_TOKEN, APP_THEME_MODE: sem writer atual identificado; ocorrências antigas ainda podem ser dados legados. |
| Notificações | scheduled_notifications.xml/JSON, callback handles em flutter_local_notifications_plugin, AlarmManager/NotificationManager, canais/tags/IDs; receivers de boot e atualização. Payload life_os_owned_v2 deve respeitar binding P1. Nenhuma agenda real alterada. |
| Auth / SDKs Google | Firebase Auth, Installations/App Check, Analytics/Crashlytics e Google Sign-In mantêm arquivos/tokens/caches próprios. Não foram extraídos de aparelhos reais. Guardas recusam stores SDK não qualificados. |
| Firestore | Configuração atual persistenceEnabled false em Android/iOS; não comprova ausência de cache persistente de versões anteriores. |
| Imagens/perfil | File/FileImage e caches de rede/Flutter; nenhum writer próprio de repositório de avatar encontrado. Caminho exibido não prova ownership. |
| Engine/temporários | app_flutter/flutter_assets e res_timestamp, cache/code_cache/assets extraídos; diferenciados na sonda. Não houve limpeza em instalação real. |
| Backup Android | allowBackup false e regras data extraction presentes; não recuperam uma chave KeyStore ausente nem provam que restauração antiga não ocorreu. Preservar também .bak/temporários de preferências. |

Busca não identificou Hive, Isar, sqflite, HydratedBloc, Realm ou ObjectBox como outro armazenamento de domínio. O SQLite auxiliar de notificações foi identificado separadamente. Fontes de bibliotecas e estados internos não documentados de SDKs continuam limite do inventário, não prova de ausência física.

## Firebase, SyncQueue e Premium

database_provider lê FirebaseAuth.uid; LocalAccountSession, SessionDatabaseCoordinator e LocalMutationGate protegem sessão/geração. TrustedAccountAccess valida projeto/banco/usuário/claim lifeos_generation contra receipt Firestore. Identidade local não substitui essas provas para operações remotas.

SyncQueue mora no banco criptografado e contém ownerUid, coleção/docId, operação/payload, status, tentativas e erro. Não descartar nem reinterpretar itens antigos. ACK confirmado é necessário; hidratação remota respeita mutações pendentes. SyncManager, processadores, repositórios e callbacks de telas ainda dependem de Auth/Firestore e permits.

Logout/exclusão usa barreiras e journals de geração, recovery e finalizer. Timeout, signOut ou ausência de Auth não autorizam excluir arquivos, aliases, registro nativo ou filas. O núcleo preparado não inicia SyncManager; contudo AppDatabase ainda permite enqueue e remote permits. Falta política local-only antes de conectar módulos.

Premium usa Google Play `life_os_premium`, UID ofuscado via SHA-256, purchaseToken enviado ao backend com Auth/App Check; entitlement em users/<uid> no Firestore, estado/expiração em memória e timer. Não foi identificado cache Dart durável de receipt/entitlement. Play/SDK tem estado próprio. Billing não foi ativado/testado e nenhum flag local concede Premium. Contrato offline verificável e política de expiração continuam pendentes.

Círculos colaborativos, IA/backend e outros recursos remotos continuam preservados. Não foram desativados silenciosamente, nem se declarou funcionamento offline das telas. Consulte o relatório de resultados para o próximo gate.

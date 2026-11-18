# Lançamento Local-First — etapa 3: admissão e recuperação

Base: 12fba7cffc52d0740d60d3df21ae1f10299d4285. Integração no checkout oficial C:/life_os, branch refactor/launch-local-first-20261117. Backend independente permanece b316df4302e8ae88e5d17af01780d831c0896ab9, sem modificações. Cópias e hashes pré-alteração em stage3-before/ e manifests no checkpoint privado launch-local-first-20261117. Seis configurações protegidas continuam idênticas por SHA256.

## Problema e comportamento resultante

Uma interrupção após a criação do arquivo criptografado, mas antes do schema Drift, deixava schema zero recusado no próximo startup. A serialização anterior da identidade também era limitada ao isolate; o bootstrap completo não compartilhava uma admissão entre conexões.

LocalProfileAdmission agora mantém BEGIN EXCLUSIVE em conexão SQLite separada durante resolução da identidade, criação da chave, inicialização do schema e publicação da sessão. O retry é assíncrono e limitado; o lease expira ao terminar e não fica válido em callbacks escapados. LocalDeviceSession compartilha a abertura pendente, inclusive sua falha, entre callers concorrentes. Não há alteração de locks, journal mode ou chaves de bancos existentes por esse coordenador.

O arquivo EXATO Documents/life_os_local_admission_v1.sqlite permanece com zero bytes, sem tabelas, dados ou chaves. Tipos não regulares, conteúdo ou sidecars nesse caminho são recusados. O inspector só reconhece esse arquivo enquanto o lease validado estiver ativo. Journal MEMORY é usado exclusivamente nessa conexão vazia, nunca commitada: evita criar um rollback journal no disco só para manter o lock. Os bancos pessoais mantêm sua configuração criptografada/WAL anterior. O contrato de transação exclusiva e os limites de MEMORY estão descritos na [documentação SQLite de transações](https://www.sqlite.org/lang_transaction.html) e [PRAGMA journal_mode](https://www.sqlite.org/pragma.html#pragma_journal_mode); a aprovação abaixo depende dos testes reais, não apenas dessa documentação.

LocalProfileBootstrapJournal adiciona um valor criptografado ao SecureStorage: life_os_local_profile_bootstrap_v1. O JSON estrito contém versão, perfil, namespace, nome do banco, alias da chave, schema esperado, nonce e fase CREATING/READY. Não contém a chave nem concede Premium. Não há nova preferência booleana de acesso.

Somente CREATING validado em admissão ativa emite um permit privado limitado ao caminho/schema. Reabertura de schema zero requer chave já acessível, criptografia e integridade válidas, sqlite_master vazio, uma página, nenhuma página livre e application_id zero. Qualquer tabela ou vestígio de páginas livres bloqueia. A factory conclui o schema antes de READY; falha ao persistir READY fecha o candidate. Perfis staged atuais só recebem READY após validação bem-sucedida. Chave sem banco, READY sem banco, journal inválido, plaintext, versões antigas e artefatos de migração continuam bloqueados. Nenhum UID antigo é adotado.

## Arquivos

Novos: lib/core/database/local_profile_admission.dart, local_profile_bootstrap_journal.dart; test/core/database/local_profile_admission_test.dart, local_profile_bootstrap_journal_test.dart; tools/local_native_storage_recovery/assert-bootstrap.ps1; este relatório.

Alterados: database_encryption.dart, local_device_session.dart, local_installation_identity_service.dart, local_installation_storage_inspector.dart, user_database_factory.dart, core/db/user_db_key_manager.dart e tools/local_native_storage_recovery/recovery_probe.dart. Nenhum arquivo removido. Schema pessoal permanece 11. O fork SecureStorage não foi alterado. main.dart permanece legado.

## Validação

- stage3-regressions-qualified.log: 108/108 PASS. Inclui 25 testes novos de journal/admissão e regressões de identidade/sessão, criptografia, chave, política localOnly e factory. Confere concorrência real de SQLite em isolates, quota de admissão, retry, recusa sem leitura de chaves em artefatos e manutenção dos contratos anteriores. Falhas intermediárias foram corrigidas no código, sem apagar ou relaxar testes antigos.
- stage3-analyze-final.log: zero issues; formatação aplicada.
- stage3-app-build.log: assembleDebug offline, ARMv7/ARM64/x86_64 PASS, 431 tasks, 1m32. APK oficial não instalado.
- Probe Android AOT profile: build PASS, 36 bibliotecas locais do aplicativo, fork nativo preservado, sem Firebase/Billing/credenciais reais. AVD novo com userdata separado em stage3-native/android-avd, LifeOSRecovery17/emulator-5584, Android14/API34 x86_64/WHPX.
- bootstrap-decision.json: 40 checks PASS em nove relatórios. Quatro isolates completam 16 incrementos sem perda; encerramento real do processo que segura o lock permite nova aquisição; interrupção controlada deixa CREATING/schema zero criptografado; processos novos recuperam schema/conteúdo e mantêm UUID/chave; reboot real em modo avião mantém dados/chaves/aliases; schema zero com conteúdo é recusado com bytes e journal intactos.
- Regressão SecureStorage: native-decision.json, 17 casos/210 checks PASS, incluindo formatos ESP/GCM/CBC, ordens antiga/proposta, flags reset/migrate, read/readAll, erros nativos, ausência de material e cold boot. Uma primeira rodada ficou BLOCKED por ausência do arquivo airplane-before.txt. Essa decisão e os arquivos correspondentes foram preservados em attempt1-missing-airplane-before; o cold boot foi efetivamente repetido com novas medições reais antes/depois. Nenhum registro ausente foi inventado.
- Regressão core: local-profile-core-decision.json, 33 checks PASS, incluindo fila histórica imutável, bulk cleanup atômico recusado, perfil permanente, ausência de envio e outro reboot offline. Total nativo desta etapa: 283 checks.

Os relatórios JSON, hashes de arquivos e metadata de aliases, fingerprints sintéticos de chave e boot IDs reais ficam no laboratório privado. Sem substituição por mocks Dart e sem executar os testes no pacote oficial com dados reais.

## Limites e decisão

GO focal para os cenários de bootstrap qualificados. LOCAL_PROFILE_BOOTSTRAP=PASS e LOCAL_NATIVE_STORAGE_GATE=PASS exclusivamente no escopo descrito. Lançamento NO-GO; APP_WIDE_OFFLINE=NOT_VERIFIED; LOCAL_IDENTITY_GATE=BLOCKED; ROLLOUT=CLOSED.

Não há homologação de writers simultâneos em múltiplos processos Android, hardware físico/StrongBox, outras APIs Android ou aplicativo completo. Encerramento durante operações físicas de criptografia que deixe arquivo parcial/vazio ou perda de chave continua bloqueado para recuperação verificada; não há reparo destrutivo automático nem prova de tolerância a toda perda de energia. Importação UID, notifications ownership P1, demais módulos, Mercado, biometria/PIN, backup recuperável e Premium híbrido continuam pendentes. As falhas remotas P1 classificadas em baseline continuam registradas. Nenhuma produção, landing, credencial, projeto Firebase ou Google Cloud foi alterado; sem push/deploy/publicação.

Próxima etapa: criar host Android de desenvolvimento isolado com registro exclusivo de plugins locais e adaptar os módulos reais antes de qualquer troca do startup padrão. O SHA desta etapa será registrado após o commit no checkpoint privado.

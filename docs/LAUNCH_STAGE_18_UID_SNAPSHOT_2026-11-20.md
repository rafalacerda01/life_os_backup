# Lançamento Local-First — etapa 18 · Preservação de UID e P1

O ensaio usa um pacote Android descartável, `dev.lifeos.recovery.life_os`, sem permissão de Internet, em um AVD API 34 x86_64 em modo avião. O pacote e seus arquivos ficam separados do pacote `.localdev` usado para homologar os módulos. O APK profile usa o fork oficial de SecureStorage e a factory oficial de bancos. Os bancos e os aliases são sintéticos.

O ensaio cria dois bancos cifrados de schema 11. Um usa o endereço por UID e outro usa o binding P1 completo. Cada origem recebe uma tarefa no arquivo principal e uma entrada histórica da fila em uma transação gravada somente no WAL. O executor compara o arquivo principal isolado com uma cópia que inclui o WAL. SQLite abre somente cópias privadas de consulta, com `query_only` para as consultas. O SHM original é arquivado com seu hash. A cópia de consulta reconstrói seu próprio índice.

O APK do laboratório compilou offline em 1m37s e a análise do probe retornou zero issues. A baseline de chave, criptografia, journal e política da fila aprovou 52 testes Dart. A primeira execução nativa produziu 28 verificações válidas, incluindo os dois WAL e SHM reais. O executor PowerShell demorou a reconhecê-las porque o objeto de hashes usa a chave vazia para o arquivo principal. O relatório original foi arquivado e o executor passou a interpretar o JSON como hashtable. A retomada preserva o APK e os bancos já criados.

## Resultado Android

`SYNTHETIC_UID_P1_SNAPSHOT_ANDROID=PASS` com 58 verificações. A prova final teve 28 verificações antes do encerramento abrupto do processo de teste e 30 depois de um reboot com outro ID de kernel. Em ambos os bancos, a tarefa permaneceu legível e `PRAGMA integrity_check` retornou `ok`. A entrada de fila apareceu somente na cópia com WAL e preservou proprietário, coleção, operação, identificador, payload e data. Os hashes de cada banco, WAL, SHM e fingerprint das duas chaves coincidiram. O SHA-256 do banco separado da Central e os seis hashes de configuração protegida também coincidiram.

Foram recusados alias ausente, chave do outro banco, binding draft, namespace divergente, WAL órfão, sidecar de candidato de criptografia, origem modificada durante a captura e schema 10. O WAL órfão e o sidecar permaneceram byte a byte. A alteração durante a captura foi induzida em cópia sintética. A comparação de hashes detecta essa divergência. Uma migração futura ainda precisa de exclusão de escritores comprovada.

O workspace privado preserva as duas rodadas em `stage18-native-uid-snapshot` e `stage18-native-uid-cold`. A decisão está em `stage18-native-uid-cold/decision.json`, com 16 arquivos de evidência em `stage18-native-proof-hashes.json`. O backend segue em `b316df4302e8ae88e5d17af01780d831c0896ab9`.

O modo integrado `prepare.ps1 -UidSnapshot` gerou em outra pasta um probe com o mesmo SHA-256 do código homologado e um manifesto profile equivalente. O build de reprodução passou offline em 2m11s e `flutter analyze --no-pub` passou no checkout oficial. Os commits focais originais continuam referenciados nas branches locais de preservação.

## Arquivos integrados

- `tools/local_native_storage_recovery/uid_snapshot_probe.dart`.
- `tools/local_native_storage_recovery/prepare.ps1` e `tools/local_native_storage_recovery/README.md`.
- Este relatório.

GO focal para snapshot e leitura de origens sintéticas. A adoção no perfil Local-First depende de verificação de custódia, snapshot consistente sob exclusão de escritores e comparação com destino isolado. Excluir dados locais, restaurar backup e validar Premium real também exigem gates próprios. `LOCAL_IDENTITY_GATE=BLOCKED · P1 RED · ROLLOUT CLOSED` e lançamento `NO-GO`.

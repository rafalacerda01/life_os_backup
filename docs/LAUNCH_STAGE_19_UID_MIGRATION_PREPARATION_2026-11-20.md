# Lançamento Local-First — etapa 19 · Custódia UID/P1

**`SYNTHETIC_UID_P1_MIGRATION_PREPARATION=PASS`.** O ensaio usou exclusivamente dados sintéticos no pacote `dev.lifeos.recovery.life_os.custody`, sem permissão de Internet, em Android API 34 x86_64 e modo avião.

## Custódia e captura

- Um emissor sintético com chave no Android vinculou cada autorização a projeto, banco, tenant, UID, geração, namespace, nome de arquivo e fingerprint da chave. O probe validou a assinatura e todos os campos antes de capturar. O UID legado recebeu uma atribuição explícita do emissor. A origem P1 usou o binding completo.
- Os escritores do ensaio e a captura usaram a mesma trava exclusiva de um SQLite de coordenação separado. Dois processos Android observaram a recusa nos dois sentidos. O escritor recusou a captura concorrente. A captura recusou a tentativa de escrita. As recusas preservaram os hashes da origem.
- A captura arquivou banco, WAL e SHM sob a trava. SQLite consultou cópias descartáveis. A fila e a data de revisão de um flashcard estavam em transações confirmadas presentes apenas no WAL. A prova comparou leituras com e sem WAL e confirmou a integridade das cópias e dos hashes originais.

## Destinos e interrupção

Cada origem teve um destino independente com schema local 12, namespace novo e chave própria. Os hashes de conteúdo das 17 tabelas legadas corresponderam. A comparação incluiu tarefa, disciplina, flashcard, referência entre disciplina e flashcard, histórico de foco, sequência de IDs e fila original. As duas tabelas de Mercado do destino começaram vazias. A fila histórica foi preservada em uma tabela de arquivo dentro do destino cifrado. A fila ativa ficou vazia. Triggers persistentes recusaram a reinserção para envio, a confirmação artificial e a exclusão.

O executor interrompeu os processos depois de gravar os destinos provisórios e antes do recibo de prontidão. Após reboot do kernel, o ensaio gerou um novo par de destinos e verificou o recibo e o SHA-256 de cada arquivo. A tentativa interrompida conservou os hashes de 13 arquivos e permaneceu sem recibo. Os hashes dos destinos aprovados foram `6be6c8a1d90a6753bd0ecef32fcdbe489486f1a160cb46438bf2ddd58068118c` para UID e `56bdfd4e4a59c1db52772034e788e6cda083f41c9f01cca19fa16d8824089f39` para P1.

## Verificação e preservação

Foram 88 verificações nativas aprovadas. A prova recusou identidade divergente em cada campo, assinatura forjada, captura sem trava, arquivo com WAL inconsistente, schema 10 e abertura do destino com a chave da origem. O checkout oficial aprovou os 56 testes Flutter focais, incluindo quatro regressões novas e rollback total por coluna incompatível e referência quebrada. A análise do probe e do checkout oficial passou. O APK profile do primeiro ensaio compilou offline em 1m45s.

As 16 evidências aprovadas da etapa 18 foram conferidas antes e depois. Os hashes de banco, WAL e SHM das duas origens da etapa 18 e do banco da Central também coincidiram no AVD. Seis configurações protegidas coincidiram com a referência. `stage19-native-proof/decision.json` guarda a decisão e `stage19-native-proof-hashes.json` cataloga os 18 arquivos de prova.

O toolkit oficial reproduziu os seis arquivos de fonte e configuração do APK homologado. O build profile dessa reprodução passou offline em 1m40s.

O commit integra o modo opcional `prepare.ps1 -UidMigrationPreparation`, os dois fontes Dart, Activity e manifesto de laboratório, regressões Flutter e os relatórios. O startup oficial permanece legado e o backend segue em `b316df4302e8ae88e5d17af01780d831c0896ab9`. O gate autoriza a preparação sintética. Uma migração real exige custódia verificável e cobertura de todos os escritores reais.

**`LOCAL_IDENTITY_GATE=BLOCKED · P1 RED · ROLLOUT CLOSED`**

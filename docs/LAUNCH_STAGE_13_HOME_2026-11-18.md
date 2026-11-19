# Lançamento Local-First — etapa 13 · Início, Dashboard e Análises

O aplicativo oficial em `C:/life_os` está na branch `refactor/launch-local-first-20261117`. A base da etapa é o commit de Saúde `e991de4d50d80dae0b0a02ef9601a7cfb64129fe`. A evidência e os hashes de preservação estão no workspace privado da missão. O backend independente permanece em `b316df4302e8ae88e5d17af01780d831c0896ab9`.

No host `.localdev`, Início apresenta a saudação de perfil local, o Dashboard consome os repositórios locais existentes e os atalhos abrem telas reais. Análises apresenta tarefas concluídas, os registros de hábitos dos últimos sete dias civis, o saldo registrado e o progresso de água em relação à meta local. Erros de leitura mostram a opção de recarregar. A etapa usa o schema 11 e mantém o startup oficial no caminho legado.

O controle manual de Hábitos passou a selecionar a coleta de analytics pelo modo de runtime. Isso corrigiu cinco falhas da suíte de produto, introduzidas na etapa de Hábitos, em que a consulta ao provider de banco inicializava dependências não previstas mesmo com o repositório já injetado. A simulação de Finanças no teste novo foi corrigida para informar o campo obrigatório `isDeleted`. A suíte final passou em 156 testes. O analisador retornou zero issues na configuração vigente.

- **`LOCAL_HOME_ANDROID=PASS`** com 25 verificações no processo inicial, 25 na reabertura e 25 após reboot. O AVD API 34 x86_64 permaneceu em modo avião e o APK `.localdev` não tinha permissão de internet. As verificações nativas confirmaram ausência de Firebase e de Billing registrados.
- O conteúdo exibido correspondeu aos dados sintéticos persistidos. O atalho abriu Tarefas e as três rodadas preservaram o perfil, a chave, os dados dos módulos anteriores, os resultados de integridade e o SHA-256 do banco fechado da etapa Saúde. A fila remota permaneceu vazia.
- O build profile isolado passou em 1m53s. O build padrão debug ARMv7, ARM64 e x86_64 passou em 1m43s. Os logs registram avisos Gradle/Kotlin e de compatibilidade das ferramentas Android.

Foram atualizados os pontos de entrada e providers de Início, Dashboard, Saúde, Hábitos e Análises. A tela de análises básicas, os testes de métricas e o protocolo Android com executor e verificador foram adicionados. A evidência Android está em `stage13-native-home/home-decision.json`. O checkpoint das fontes anteriores está em `stage13-before`.

A prova é focal. Mercado, perfil e proteção opcional, notificações, migração de dados vinculados a UID e Premium híbrido seguem pendentes. Lançamento `NO-GO`, `LOCAL_IDENTITY_GATE=BLOCKED` e `ROLLOUT=CLOSED`.

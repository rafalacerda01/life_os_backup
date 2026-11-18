# Lançamento Local-First — etapa 5: repositório de Finanças

Alterações integradas diretamente em C:/life_os, branch refactor/launch-local-first-20261117, com checkpoint seletivo e hashes em stage5-before/. Backend independente sem alterações. Sem modificação de schema, arquivos reais, chaves, credenciais ou endpoints.

## Comportamento

FinanceRepository.local exige uma conexão localOnly e obtém o owner da identidade permanente do banco. Não cria Auth, Firestore, SyncManager remoto ou FirebaseUser. O provider escolhe esse ramo antes de ler os providers remotos ou de custódia P1.

Criação e exclusão mantêm o gate de sessão, validação de títulos/categorias/tipo/valores e streams Drift. Mutações locais não enfileiram envios e não agendam sync. Pull Firestore retorna sem acessar rede ou alterar dados quando a conexão é localOnly. Construtor e comportamento remoto permanecem disponíveis para os consumidores legados existentes.

O limite Free de três transações ativas é verificado dentro da transação SQLite. Criações concorrentes não ultrapassam esse limite e excluir uma transação libera um slot. O modo local de desenvolvimento continua Free até existir uma autoridade híbrida verificável; nenhum booleano local concede Premium.

FinanceScreen deixa de disparar hidratação remota no modo local e mantém o formulário quando uma corrida atinge a quota, apresentando o erro de domínio. A navegação de desenvolvimento ainda não foi ampliada para Finanças: isso exige a próxima homologação de UI Android.

## Arquivos

Alterados: lib/features/finance/data/repositories/finance_repository.dart; lib/features/finance/presentation/providers/finance_provider.dart; lib/features/finance/presentation/finance_screen.dart. Novo: test/features/finance/data/repositories/finance_repository_local_test.dart e este relatório. Nenhum arquivo removido.

## Testes

- Oito testes locais PASS: receitas/despesas/saldo/stream/delete sem Firebase, providers remotos que falham caso sejam consultados, pull inerte, quota atômica, oito creates concorrentes com somente três commits, dados inválidos, recusa de mutations após detach e construtor local recusando conexão remota.
- Os testes de detach também confirmam que a leitura é recusada enquanto a sessão está destacada. Os dados só são comparados após nova admissão válida; o gate não foi relaxado para permitir a leitura antiga.
- 45 testes legados de repositório/providers/tela PASS na rodada completa. A falha de fixture de detach foi corrigida; os logs intermediários permanecem preservados.
- Análise Dart sem issues; formatação aplicada. Build Android padrão três ABIs em stage5-legacy-build.log, conferido antes do commit.

Esses são testes Dart com SQLite real para o contrato de repositório e regressões de UI legada. Não são homologação nativa Android de Finanças. A evidência nativa48checks da etapa4 cobre Tarefas, sem aprovar Finanças por associação.

## Critério e pendências

GO focal para a fronteira local do repositório de Finanças. FINANCE_ANDROID=NOT_VERIFIED; aplicativo completo e lançamento NO-GO; ROLLOUT=CLOSED.

Ainda faltam UI local/navegação e cold boot Android específicos de Finanças, integração de Mercado/histórico, entitlement Premium verificável e demais módulos. O modelo monetário existente continua usando double; não foi executada conversão de dados ou schema nesta etapa. Source e testes mantêm compatibilidade com os consumidores remotos ativos; a retirada deles depende do inventário e migração qualificados. Sem push, deploy ou alteração de produção.

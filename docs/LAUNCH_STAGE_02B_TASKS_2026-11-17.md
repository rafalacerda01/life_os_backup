# Lançamento Local-First — etapa 2B: Tarefas

Base: db59f2ca5b6b624fcac1cfac366a283bd48d3f81, branch refactor/launch-local-first-20261117, integração direta em C:/life_os. Backend independente permanece b316df4302e8ae88e5d17af01780d831c0896ab9, sem alterações.

## Escopo integrado

- TasksRepository.local exige conexão localOnly e utiliza a identidade permanente do banco, sem FirebaseUser, Auth ou Firestore. Providers escolhem esse caminho antes de consultar serviços remotos. Pull remoto torna-se inerte; mutações continuam sob o gate da conexão e não enfileiram sync.
- Validação de título/prioridade e quota Free dentro da mesma transação SQLite. O limite inclui tarefas concluídas; criações concorrentes não ultrapassam três. Não há concessão local de Premium: este caminho de desenvolvimento permanece Free até existir autoridade de entitlement verificável.
- TasksScreen não agenda sync no modo local e mantém formulário diante de quota excedida ou falha de gravação. Toggle manual local não instancia analytics remoto.
- app_runtime_mode.dart explicita o modo de desenvolvimento. O valor padrão continua legacyRemote. plan_limits_provider retorna Free antes de consultar o Premium legado somente nesse modo local. A política de banco continua independente desse provider.
- Novos testes tasks_repository_local_test.dart e tasks_screen_local_test.dart. Arquivos alterados: tasks_provider.dart, tasks_screen.dart, quota_service.dart, plan_limits_provider.dart; novo runtime provider e este relatório. Nenhum arquivo removido.

## Evidências

Logs preservados no workspace privado launch-local-first-20261117:

- stage2b-regressions-final.log: 50/50 PASS (oito novos de repositório local, um de tela local, 23 do repositório legado, três de tela legada, 15 de analytics).
- A tela usa Drift/SQLite real e binding de relógio real com onlyPumps; o binding automatizado bloqueava a fixture no I/O. Esse ajuste é restrito ao teste. Não representa homologação Android da aplicação completa.
- stage2b-analyze-final.log: zero issues.
- stage2b-format-final.log: formatação aplicada.
- stage2b-app-build.log: assembleDebug offline nas ABIs ARMv7/ARM64/x86_64 PASS (431 tasks, 58s). APK oficial não foi instalado nem executado.

CRUD e stream de Tarefas operacionais nos testes, guardas de mutação preservadas, fila vazia e providers Firebase/sync deliberadamente indisponíveis. A matriz nativa da etapa 1 continua registrada; nenhuma criptografia foi alterada nesta etapa.

## Limites e decisão

GO focal para CRUD Free de Tarefas e UI local sob injeção de banco. Lançamento NO-GO; APP_WIDE_OFFLINE=NOT_VERIFIED; LOCAL_IDENTITY_GATE=BLOCKED; ROLLOUT=CLOSED.

Ainda pendentes: entrypoint Android isolado, bootstrap com journal/admissão, demais módulos, notificações, migração UID, segurança opcional, Mercado e Premium híbrido. As 15 falhas remotas P1 Dart e 130 falhas backend, comprovadas em baseline nas etapas anteriores, não foram apagadas ou resolvidas por esta etapa. Não houve push, deploy, publicação, alteração da landing ou de serviços de produção. O SHA desta etapa será registrado no workspace privado após o commit.

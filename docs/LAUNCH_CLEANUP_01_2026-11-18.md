# Lançamento Local-First — limpeza comprovada 1

## Mock Premium

Removido somente lib/features/premium/data/repositories/mock_premium_repository.dart. Busca Git incluindo código não rastreado ativo encontrou apenas sua própria declaração, sem import, export, instanciação ou referências em consumidores. premium_provider.dart utiliza GooglePlayPremiumRepository, que não foi removido. Busca no backend independente também não encontrou dependência desse mock.

A implementação morta consultava users.isPremium e simulava tier anual sem expiração. Sua remoção não implementa Premium híbrido nem altera o Billing ativo legado. O arquivo original e seu SHA256 foram preservados fora de build em cleanup-01-before/, junto das evidências de busca. Histórico Git permanece intacto.

## Artefato gerado

android/build/reports/problems/problems-report.html era rastreado e reescrito por execuções Gradle, sem consumidores de código. Foi retirado apenas do índice Git; o arquivo físico foi mantido e uma cópia/hash preservados fora de build. Acrescentado /android/build/ ao .gitignore e android/build/** às exclusões de análise. Esses caminhos contêm saídas geradas; lib/ e test/ não foram excluídos e nenhuma nova supressão de erro foi adicionada.

As supressões antigas globais de unused_import/dead_code e outros lints já existentes em analysis_options.yaml não foram ampliadas ou resolvidas por esta limpeza. Ainda precisam de auditoria na etapa geral de qualidade.

## Validação e limites

Análise com a configuração vigente conferida após a retirada; buscas repetidas comprovam ausência de consumidores restantes do mock. Não foram removidos testes, endpoints, código ativo de Auth/Billing/Firestore ou estruturas necessárias à migração. Nenhum banco, chave, credencial, dado real, projeto Firebase/Google Cloud ou arquivo da landing foi apagado. Sem push/deploy/publicação. Lançamento continua NO-GO e rollout fechado.

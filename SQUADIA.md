# SQUADIA.md — squadia-ai/workflows (memória do repositório)

Reusable workflows públicos do squadia: o contrato de execução entre o `ops` de cada tenant e a imagem privada do `core`. Nada de lógica de negócio, prompt ou dado de cliente aqui (ver README).

## Convenções

- **Todo run de GitHub Actions da squad leva o ID da história no nome** (regra do PO, 29/10): `run-name` com a chave (`SQD-NNN`) e, quando houver, o PR — como "Promoção de canal: develop → release (platform) — SQD-812 (#701)". Workflow reutilizável recebe a chave por input e a repassa ao `run-name` do chamador; quando o gatilho não tem a chave (ex.: `deployment_status`), ela vai no nome do primeiro job e no summary.
- **Repositório público**: nenhum segredo no arquivo (só por `secrets:` do chamador) e nunca `${{ }}` de dado externo dentro de `run:` (passe por `env:`).

# workflows

Reusable workflows do squadia — o "encanamento" público de execução dos agentes IA (refinador, dev, revisor, orquestrador) sobre issues Jira e repos GitHub de cada tenant.

Este repositório é **público** e não contém nenhuma lógica de negócio, prompt, IP do produto ou dado de cliente. Ele só define o *contrato* de execução: como um repo "ops" de um tenant deve chamar a imagem privada do core (`ghcr.io/squadia-ai/core`) via GitHub Actions, e como os secrets/config daquele tenant chegam até o container. Toda a inteligência (prompts, orquestração, integrações) vive no core, numa imagem Docker privada — não aqui.

## Como funciona (visão geral)

Cada tenant tem um repo "ops" (privado, do cliente) com:
- `squadia.config.yml` e `CLAUDE.md` na raiz;
- GitHub Secrets/Variables com credenciais do tenant (ver seção abaixo);
- stubs de workflow curtos em `.github/workflows/`, que apenas fazem `uses:` para um dos workflows deste repo, com `secrets: inherit`.

O trabalho pesado (rodar o papel, decidir concurrency, exportar credenciais para o processo) acontece dentro do workflow reusable, dentro de um container rodando a imagem privada do core.

## Workflows disponíveis

| Arquivo | Papel | Principais inputs | Concurrency group |
|---|---|---|---|
| `refine.yml` | Refinador | `issue_key` (required), `image` (default `ghcr.io/squadia-ai/core:dev`), `instance`, `timeout_minutes` (default 75) | `squadia-refine-<issue_key>` |
| `dev.yml` | Dev | `issue_key` (required), `image`, `instance`, `timeout_minutes` (default 75) | `squadia-dev-<issue_key>` |
| `review.yml` | Revisor | `issue_key` (required), `image`, `instance`, `timeout_minutes` (default 75) | `squadia-review-<issue_key>` |
| `qa-scenarios.yml` | QA (gerador de cenários) | `issue_key` (required), `image`, `instance`, `timeout_minutes` (default 75) | `squadia-qa-scenarios-<issue_key>` |
| `qa-execute.yml` | QA (executor — build/testes/merge) | `issue_key` (required), `image`, `instance`, `timeout_minutes` (default 75) | `squadia-qa-execute-<issue_key>` |
| `orchestrate-worker.yml` | Orquestrador | `free_workflows` (CSV de `refine,dev,review,qa_scenarios,qa`, default `""`), `image`, `instance`, `timeout_minutes` (default 20) | `squadia-orchestrator` (fixo, sem issue) |
| `orchestrate-dispatcher.yml` | Pré-check do orquestrador | `worker_workflow` (default `orchestrate.yml`), `agent_workflows` (CSV de pares `papel:arquivo`, default `refine:refine-agent.yml,dev:dev-agent.yml,review:review-agent.yml`) | `squadia-dispatcher` (fixo) |

Os seis primeiros rodam dentro de um `container:` com a imagem do core (contrato de entrypoints abaixo). O `orchestrate-dispatcher.yml` é diferente de propósito: roda **sem container, sem Docker e sem LLM**, direto no runner `ubuntu-latest` — é só um pré-check barato (via `actions/github-script`) para decidir se vale a pena acordar o worker do orquestrador, olhando quais workflows já estão `in_progress`/`queued` no repo. O worker sempre revalida ocupação, rate-limit e pausa por conta própria antes de agir (defesa em profundidade) — o dispatcher é otimização de custo, não fonte de verdade.

Os seis primeiros também declaram `permissions: id-token: write` no job (além de `contents: read`), necessário pro step opcional de credenciais AWS via OIDC — ver "Credenciais AWS do data plane (OIDC)" abaixo. O `orchestrate-dispatcher.yml` não precisa disso (não toca dataplane).

### Contrato com a imagem do core

- Imagem default: `ghcr.io/squadia-ai/core:dev` (privada no GHCR; pull autenticado com o secret `GHCR_PULL_TOKEN`).
- Dentro do container: `WORKDIR /app`, Node 22, `git` e `bash` disponíveis, core já compilado em `/app/dist`.
- Base Debian/glibc (**não** Alpine/musl): em container jobs, as actions JavaScript (`actions/checkout`, `github-script`) executam com o Node do runner montado dentro do container, que exige glibc.
- Comando por papel:
  - `node /app/dist/entrypoints/refine.js <ISSUE-KEY> [--instance NOME]`
  - `node /app/dist/entrypoints/dev.js <ISSUE-KEY> [--instance NOME]`
  - `node /app/dist/entrypoints/review.js <ISSUE-KEY> [--instance NOME]`
  - `node /app/dist/entrypoints/qa-scenarios.js <ISSUE-KEY> [--instance NOME]`
  - `node /app/dist/entrypoints/qa-execute.js <ISSUE-KEY> [--instance NOME]`
  - `node /app/dist/entrypoints/orchestrate.js [--free refine,dev,review,qa_scenarios,qa] [--instance NOME]`

### Contrato de ambiente dos entrypoints

O checkout do repo **caller** (o ops do tenant) é quem fornece `squadia.config.yml` e `CLAUDE.md` na raiz. Os workflows deste repo exportam as seguintes env vars antes de chamar o entrypoint:

| Env var | Origem |
|---|---|
| `SQUADIA_CONFIG_PATH` | fixo: `squadia.config.yml` (path no checkout do caller) |
| `TENANT_CLAUDE_MD_PATH` | fixo: `CLAUDE.md` (opcional, path no checkout do caller) |
| `WORKSPACE_DIR` | fixo: `/tmp/squadia-workspace` (dir de trabalho dos clones que o entrypoint faz) |
| `JIRA_BASE_URL` | `vars.JIRA_BASE_URL` do repo caller (Actions **Variable**, não secret) |
| `ISSUE_KEY` / `INSTANCE` / `FREE` | dos inputs do workflow_call |
| credenciais não sensíveis (`GH_APP_ID_<SUF>`, `GH_INSTALLATION_ID_<SUF>`, `JIRA_EMAIL_<SUF>`, etc.) | Actions **Variables** do repo caller, reexportadas para o ambiente do processo (ver abaixo) |
| credenciais sensíveis (`JIRA_API_TOKEN_<SUF>`, `GH_APP_PRIVATE_KEY_<SUF>`, `CLAUDE_CODE_OAUTH_TOKEN_<SUF>`, etc.) | Secrets do repo caller, herdados via `secrets: inherit` e reexportados para o ambiente do processo (ver abaixo) |

Os sufixos de instância (`<SUF>`) variam por tenant, então o workflow não tenta enumerá-los: em vez disso, cada workflow tem dois passos, nesta ordem:

1. **"Exporta variables do tenant"**: lê `toJSON(vars)`, itera todas as entradas do repo caller e escreve cada uma em `GITHUB_ENV` usando o formato heredoc do GitHub Actions. Variables não têm lista de exclusão (não existe equivalente a `github_token`/`GHCR_PULL_TOKEN` no contexto `vars`).
2. **"Exporta secrets do tenant"**: lê `toJSON(secrets)`, itera todas as entradas recebidas via `secrets: inherit` e escreve cada uma em `GITHUB_ENV` do mesmo jeito (heredoc obrigatório porque `GH_APP_PRIVATE_KEY_<SUF>` é um PEM multiline). Duas chaves são sempre excluídas dessa exportação: `github_token` (o token automático do Actions) e `GHCR_PULL_TOKEN` (usado só para o pull da imagem, não deve vazar pro processo do entrypoint).

A ordem importa: variables primeiro, secrets depois. Se um tenant tiver, por engano ou por transição, uma Variable e um Secret com o mesmo nome, o secret vence — porque escreve por último em `GITHUB_ENV`, cuja regra é "a última atribuição pra uma chave numa mesma execução ganha". Credenciais não sensíveis do tenant (ex.: `GH_APP_ID_<SUF>`, `GH_INSTALLATION_ID_<SUF>`, `JIRA_EMAIL_<SUF>`) podem viver em Actions Variables — chegam ao ambiente do processo do mesmo jeito que os secrets. Credenciais sensíveis (tokens, chaves privadas) devem ficar em Actions Secrets. Em ambos os casos, o processo do entrypoint não diferencia a origem: só enxerga a env var já exportada.

### Credenciais AWS do data plane (OIDC)

A infra AWS do produto (tabelas DynamoDB do `StateStore`, roles) mora na org do fornecedor e é provisionada fora deste repo (ADR-015). O que os seis workflows de papel (`refine`, `dev`, `review`, `qa-scenarios`, `qa-execute`, `orchestrate-worker`) fazem é *consumir* essa infra: cada um ganha, logo antes do step "Executa o papel/orquestrador", um step opcional de [`aws-actions/configure-aws-credentials@v4`](https://github.com/aws-actions/configure-aws-credentials) que troca a identidade OIDC do job por credenciais temporárias via `role-to-assume: ${{ vars.AWS_DATAPLANE_ROLE_ARN }}`.

- **Opcional por tenant**: o step só roda quando o caller define a Variable `AWS_DATAPLANE_ROLE_ARN` (`if: vars.AWS_DATAPLANE_ROLE_ARN != ''`). Tenant sem essa Variable não sofre nenhuma mudança de comportamento.
- **Sem access key estática**: a role IAM (`squadia-dataplane-<tenant>-<env>`) é assumida via OIDC do GitHub Actions, com trust restrito ao repo `ops` daquele tenant. Nenhum secret de AWS de longa duração circula por este repo.
- **Propagação pro entrypoint**: `configure-aws-credentials` exporta `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` (temporárias) via `GITHUB_ENV` — o mesmo mecanismo de `GITHUB_ENV` que os steps "Exporta variables/secrets do tenant" já usam —, então chegam ao ambiente do processo do entrypoint automaticamente, sem step extra de re-export.
- **`permissions: id-token: write` é obrigatório** no job destes seis workflows (e no job do stub caller que os invoca — ver seção de permissions do stub abaixo), porque o token OIDC do job vem dessa permissão. **Erro típico quando o caller esquece**: o step `configure-aws-credentials` falha com `Error: Unable to get ACTIONS_ID_TOKEN_REQUEST_URL env variable` — a permissão não foi concedida, então o runner nunca populou a env var que a action usa pra pedir o token OIDC.
- **A credencial não chega ao Claude CLI**: o entrypoint roda no core, cujo wrapper controla explicitamente que env vars repassa pro subprocesso do `claude` CLI (allowlist do `untrusted.ts`, fora deste repo). `AWS_*` nunca fez parte dessa allowlist — só o código TypeScript do wrapper acessa o DynamoDB, nunca o LLM — e esta mudança não adiciona `AWS_*` lá.

### Regra de segurança

Nenhum workflow deste repo interpola `${{ inputs.* }}`, `${{ vars.* }}` ou `${{ secrets.* }}` diretamente dentro de um bloco `run:`. Todo dado externo entra via `env:` e é lido do ambiente (`$VAR`) dentro do script — isso evita injeção de shell via valores controlados por config/secret. Expressões `${{ }}` só aparecem em campos estruturados do YAML (`image`, `concurrency.group`, `timeout-minutes`, `container.credentials`, `env:`).

## Contrato do stub no repo ops

Um workflow de papel no ops do tenant é só um gatilho (ex.: em resposta a um evento/label do Jira, ou dispatch manual) chamando o reusable workflow correspondente:

```yaml
# .github/workflows/dev-agent.yml (no repo ops do tenant)
name: Dev agent

on:
  workflow_dispatch:
    inputs:
      issue_key:
        required: true
        type: string

jobs:
  dev:
    # id-token: write é obrigatório aqui pro step de OIDC do reusable
    # conseguir emitir o token (ver "Credenciais AWS do data plane" acima);
    # contents: read precisa ser repetido porque declarar `permissions:`
    # troca o default (amplo) por "só o que estiver listado".
    permissions:
      contents: read
      id-token: write
    uses: squadia-ai/workflows/.github/workflows/dev.yml@dev
    with:
      issue_key: ${{ inputs.issue_key }}
      instance: "" # ou o sufixo, se o tenant tiver múltiplas instâncias
    secrets: inherit
```

O orquestrador usa **dois stubs**: o cron roda só o dispatcher (pré-check barato), e o worker fica num arquivo próprio que o dispatcher acorda via `workflow_dispatch` quando há papel livre (economizando execuções do worker/imagem):

```yaml
# .github/workflows/orchestrate-cron.yml (no repo ops do tenant)
name: Orchestrate cron

on:
  schedule:
    - cron: "*/5 * * * *"

jobs:
  dispatch-check:
    uses: squadia-ai/workflows/.github/workflows/orchestrate-dispatcher.yml@dev
    with:
      worker_workflow: orchestrate.yml
      agent_workflows: refine:refine-agent.yml,dev:dev-agent.yml,review:review-agent.yml
    secrets: inherit
```

```yaml
# .github/workflows/orchestrate.yml (no repo ops do tenant)
name: Orchestrate

on:
  workflow_dispatch:
    inputs:
      free:
        description: "CSV dos papeis livres (refine,dev,review,qa_scenarios,qa); vazio = revalidar todos"
        type: string
        default: ""

jobs:
  orchestrate:
    # Mesmo motivo do stub do dev acima: OIDC do reusable exige id-token:
    # write no job que o chama.
    permissions:
      contents: read
      id-token: write
    uses: squadia-ai/workflows/.github/workflows/orchestrate-worker.yml@dev
    with:
      free_workflows: ${{ inputs.free }}
    secrets: inherit
```

O nome do stub do worker (`orchestrate.yml` acima) é o valor que o tenant passa em `worker_workflow` no dispatcher — é ele quem o dispatcher vai "acordar" quando achar que vale a pena. O dispatch manual do worker (aba Actions → Run workflow) também funciona e bypassa o dispatcher — o worker revalida tudo sozinho.

## Secrets e vars esperados no repo ops

Credenciais do tenant, com sufixo `<SUF>` por conjunto (ex.: `DEV`, `LT`, `QA` — uma identidade IA por papel, ADR-005). O sufixo é declarado no campo `credentials` de cada instância do `squadia.config.yml` — **não** é o input `instance` dos stubs, que carrega o *nome* da instância do papel (útil só quando um papel tem mais de uma instância). A escolha entre Variable e Secret é por sensibilidade: credenciais não sensíveis vão em Actions **Variables**; credenciais sensíveis (tokens, chaves privadas) vão em Actions **Secrets**. Ambas chegam ao ambiente do processo do mesmo jeito (ver "Contrato de ambiente dos entrypoints" acima).

Actions **Variables** (não sensíveis), no repo caller:

- `JIRA_BASE_URL` — URL base da instância Jira do tenant.
- `JIRA_EMAIL_<SUF>`
- `GH_APP_ID_<SUF>`
- `GH_INSTALLATION_ID_<SUF>`
- `AWS_DATAPLANE_ROLE_ARN` — ARN da role IAM do tenant pro data plane (ADR-015), provisionada fora deste repo; ausente = tenant sem AWS, nenhum step OIDC roda.
- `AWS_REGION` — região AWS da tabela de estado do tenant; só relevante junto com `AWS_DATAPLANE_ROLE_ARN`.

Actions **Secrets** (sensíveis), no repo caller:

- `JIRA_API_TOKEN_<SUF>`
- `GH_APP_PRIVATE_KEY_<SUF>` (PEM multiline)
- `CLAUDE_CODE_OAUTH_TOKEN_<SUF>`

Além dessas, um secret sem sufixo, usado só para autenticar o pull da imagem privada do core:

- `GHCR_PULL_TOKEN`

Todos esses secrets/variables chegam aos workflows reusable via `secrets: inherit` no stub do ops — nada precisa ser declarado nome a nome neste repo. (Variables de um repo GitHub Actions ficam disponíveis a todo workflow do repo automaticamente, sem equivalente a `secrets: inherit`; a menção aqui é só para deixar explícito que este repo as consome via `toJSON(vars)`.)

## Versionamento

Os stubs do ops referenciam este repo por tag: `@dev` (HEAD da branch `develop` — squad trabalha aqui, pode quebrar; reapontada automaticamente a cada push via `move-channel-tag.yml`) ou `@prod` (HEAD da branch `main` — só existe quando o PO decide promover, mesclando `develop` → `main`; também reapontada automaticamente). Tenant 0 (`squadia-ai/ops`, dogfooding) consome `@dev` por design. Tenants de cliente consomem `@prod`. Tags imutáveis por versão semântica (`@v1`, `@v2`, ...) ficam para quando o contrato estabilizar ainda mais.

#!/usr/bin/env bash
# Confere (SQD-1535) que o acesso ao Docker do host existe SOMENTE na variante
# flutter-go, em cada workflow de papel. Sem rede, sem segredo, sem dependência
# além de bash/grep/awk.
#
# Regras, por workflow de papel (dev, refine, review, qa-scenarios, qa-execute):
#   1. exatamente UMA linha menciona o socket do daemon, e ela é a linha canônica de
#      `container.options` abaixo — condicionada a `== 'flutter-go'`, com '' no
#      caminho de padrao/flutter;
#   2. essa linha está dentro do bloco `container:` (entre `container:` e `steps:`);
#   3. nada de privileged, DOCKER_HOST nem docker-in-docker;
#   4. o container.image continua derivando a tag só de flutter e flutter-go.
# E nos demais workflows do diretório: nenhuma menção ao socket nem a privileged.
#
# Uso: scripts/verificar-docker-por-variante.sh [diretório de workflows]
set -uo pipefail

DIR="${1:-.github/workflows}"
PAPEIS=(dev refine review qa-scenarios qa-execute)
SOCKET='/var/run/'"docker"'.sock'
CANONICA="options: \${{ inputs.environment_variant == 'flutter-go' && '--volume ${SOCKET}:${SOCKET}' || '' }}"

falhas=0
falha() { echo "ERRO: $1" >&2; falhas=$((falhas + 1)); }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }

for papel in "${PAPEIS[@]}"; do
  arq="${DIR}/${papel}.yml"
  if [[ ! -f "$arq" ]]; then falha "${arq}: workflow de papel não encontrado"; continue; fi

  mapfile -t linhas < <(grep -n -i 'docker\.sock' "$arq" | grep -v '^[0-9]*:[[:space:]]*#')
  if [[ ${#linhas[@]} -ne 1 ]]; then
    falha "${arq}: esperava 1 linha com acesso ao socket do Docker, achei ${#linhas[@]}"
  else
    num="${linhas[0]%%:*}"; texto="$(trim "${linhas[0]#*:}")"
    if [[ "$texto" != "$CANONICA" ]]; then
      falha "${arq}:${num}: o acesso ao Docker não está condicionado somente a flutter-go (padrao/flutter devem receber ''): ${texto}"
    fi
    ini="$(grep -n '^    container:' "$arq" | head -1 | cut -d: -f1)"
    fim="$(grep -n '^    steps:' "$arq" | head -1 | cut -d: -f1)"
    if [[ -z "$ini" || -z "$fim" || "$num" -le "$ini" || "$num" -ge "$fim" ]]; then
      falha "${arq}:${num}: o acesso ao Docker precisa estar dentro do bloco container: do job"
    fi
  fi

  if grep -n -i -E 'privileged|DOCKER_HOST|docker:dind|docker-in-docker' "$arq" | grep -v '^[0-9]*:[[:space:]]*#' | grep -q .; then
    falha "${arq}: privileged/DOCKER_HOST/docker-in-docker não são permitidos (só o socket, só na flutter-go)"
  fi

  if ! grep -q "^      image: .*(inputs.environment_variant == 'flutter' || inputs.environment_variant == 'flutter-go') && format('{0}-{1}', inputs.image, inputs.environment_variant) || inputs.image" "$arq"; then
    falha "${arq}: container.image fora do padrão esperado (sufixo só para flutter e flutter-go)"
  fi
done

for arq in "$DIR"/*.yml; do
  base="$(basename "$arq" .yml)"
  [[ " ${PAPEIS[*]} " == *" ${base} "* ]] && continue
  if grep -n -i -E 'docker\.sock|privileged' "$arq" | grep -v '^[0-9]*:[[:space:]]*#' | grep -q .; then
    falha "${arq}: workflow que não é de papel não pode conceder acesso ao Docker"
  fi
done

if [[ $falhas -gt 0 ]]; then echo "Verificação do isolamento do Docker: ${falhas} falha(s)." >&2; exit 1; fi
echo "OK: o acesso ao Docker do host existe somente na variante flutter-go (${#PAPEIS[@]} workflows de papel)."

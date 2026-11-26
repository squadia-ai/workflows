#!/usr/bin/env bash
# Testa o verificador (SQD-1535): o estado real passa, e cada violação plantada em
# uma cópia dos workflows é recusada.
set -uo pipefail
cd "$(dirname "$0")/.."
VERIF=scripts/verificar-docker-por-variante.sh
SOCKET='/var/run/'"docker"'.sock'
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
esperar() { # nome, código esperado (0 ou 1), diretório
  "$VERIF" "$3" >/dev/null 2>&1; local rc=$?
  if [[ $rc -ne $2 ]]; then echo "FALHOU: $1 (saída $rc, esperada $2)" >&2; fail=1; else echo "ok: $1"; fi
}
novo() { rm -rf "$tmp/w"; mkdir -p "$tmp/w"; cp .github/workflows/*.yml "$tmp/w/"; }

esperar "estado real passa" 0 .github/workflows

novo; sed -i "s/inputs.environment_variant == 'flutter-go' \&\& '--volume/inputs.environment_variant == 'flutter' \&\& '--volume/" "$tmp/w/dev.yml"
esperar "socket condicionado à flutter é recusado" 1 "$tmp/w"

novo; sed -i "s#\\(options: .*\\)|| '' }}\$#\\1|| '--volume ${SOCKET}:${SOCKET}' }}#" "$tmp/w/review.yml"
esperar "socket também no caminho padrao é recusado" 1 "$tmp/w"

novo; sed -i "/^      options: /d" "$tmp/w/refine.yml"
esperar "workflow de papel sem a linha canônica é recusado" 1 "$tmp/w"

novo; printf '    # x\n      volumes:\n        - %s:%s\n' "$SOCKET" "$SOCKET" >> "$tmp/w/qa-execute.yml"
esperar "segundo acesso ao socket é recusado" 1 "$tmp/w"

novo; sed -i "s|^    steps:|      # (comentário)\n    steps:\n      # privileged\n|" "$tmp/w/qa-scenarios.yml"; sed -i "s|^    container:|    container:\n      privileged: true|" "$tmp/w/qa-scenarios.yml"
esperar "privileged é recusado" 1 "$tmp/w"

novo; printf '      - run: ls %s\n' "$SOCKET" >> "$tmp/w/publish-callback.yml"
esperar "workflow que não é de papel com o socket é recusado" 1 "$tmp/w"

novo; sed -i "s/inputs.environment_variant == 'flutter' || //" "$tmp/w/dev.yml"
esperar "image fora do padrão é recusada" 1 "$tmp/w"

exit $fail

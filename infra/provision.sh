#!/usr/bin/env bash
source "$(dirname "$(readlink -f "$0")")/lib/comum.sh"
iniciar "$@"

ETAPAS=(01-infra 02-auditoria 03-app 04-monitoramento)

for e in "${ETAPAS[@]}"; do
  bash "$INFRA_DIR/scripts/$e.sh" || falha "Etapa $e falhou; veja $LOG_EXECUCAO"
done

bash "$INFRA_DIR/status.sh"

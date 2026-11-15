#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$INFRA_DIR/config.env"

SCRIPT_NOME="$(basename "$0" .sh)"
LOG_EXECUCAO="$LOG_DIR/${LOG_NOME:-provisionamento}.log"
LOG_AUDITORIA="$LOG_DIR/auditoria.log"

if [[ -t 1 ]]; then
  COR_INFO=$'\e[36m' COR_OK=$'\e[32m' COR_AVISO=$'\e[33m' COR_ERRO=$'\e[31m' COR_ETAPA=$'\e[1;35m' COR_FIM=$'\e[0m'
else
  COR_INFO='' COR_OK='' COR_AVISO='' COR_ERRO='' COR_ETAPA='' COR_FIM=''
fi

agora() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log() {
  local nivel="$1"; shift
  local cor_var="COR_$nivel"
  local linha
  linha="$(agora) [$nivel] [$SCRIPT_NOME] $*"
  echo "$linha" >> "$LOG_EXECUCAO"
  echo "${!cor_var:-}${linha}${COR_FIM}"
  logger -t "oportuniza-$SCRIPT_NOME" -- "[$nivel] $*" 2>/dev/null || true
}

registrar_saida() { sed 's/^/    /' | tee -a "$LOG_EXECUCAO"; }

info()  { log INFO "$@"; }
ok()    { log OK "$@"; }
aviso() { log AVISO "$@"; }
etapa() { log ETAPA "==== $* ===="; }
falha() { log ERRO "$@"; exit 1; }

executar() {
  local descricao="$1"; shift
  info "$descricao"
  echo "$(agora) [CMD] [$SCRIPT_NOME] $*" >> "$LOG_EXECUCAO"
  if "$@" >> "$LOG_EXECUCAO" 2>&1; then
    ok "$descricao"
  else
    local codigo=$?
    log ERRO "$descricao (código $codigo, detalhes em $LOG_EXECUCAO)"
    return "$codigo"
  fi
}

auditar() {
  printf '%s evento=%s script=%s usuario=%s sudo_usuario=%s tty=%s host=%s %s\n' \
    "$(agora)" "$1" "$SCRIPT_NOME" "$(id -un)" "${SUDO_USER:--}" "$(tty -s && tty || echo nenhum)" \
    "$(hostname)" "${2:-}" >> "$LOG_AUDITORIA"
}

finalizar() {
  local codigo=$1
  local duracao=$(( $(date +%s) - INICIO_EPOCH ))
  auditar FIM "codigo=$codigo duracao=${duracao}s"
  if (( codigo == 0 )); then
    ok "Concluído em ${duracao}s"
  else
    log ERRO "Terminou com código $codigo após ${duracao}s"
  fi
}

iniciar() {
  if (( EUID != 0 )); then
    echo "Execute como root: sudo $0 $*" >&2
    exit 1
  fi
  install -d -m 750 -o root -g adm "$LOG_DIR"
  install -d -m 755 "$CONF_DIR"
  touch "$LOG_EXECUCAO" "$LOG_AUDITORIA"
  chmod 640 "$LOG_EXECUCAO" "$LOG_AUDITORIA"
  chgrp adm "$LOG_EXECUCAO" "$LOG_AUDITORIA"
  INICIO_EPOCH=$(date +%s)
  auditar INICIO "args=\"$*\" sha256=$(sha256sum "$0" | cut -c1-16)"
  trap 'finalizar $?' EXIT
  trap 'log ERRO "Falha na linha $LINENO: $BASH_COMMAND"' ERR
  etapa "$SCRIPT_NOME"
}

aguardar() {
  local descricao="$1" tentativas="$2" intervalo="$3"; shift 3
  info "Aguardando: $descricao"
  for ((i = 1; i <= tentativas; i++)); do
    if "$@" > /dev/null 2>&1; then
      ok "$descricao (tentativa $i)"
      return 0
    fi
    sleep "$intervalo"
  done
  log ERRO "$descricao: tempo esgotado após $((tentativas * intervalo))s"
  return 1
}

instalar_template() {
  local origem="$1" destino="$2" modo="${3:-644}"
  local temp
  temp="$(mktemp)"
  sed -e "s|@APP_DIR@|$APP_DIR|g" \
      -e "s|@CONF_DIR@|$CONF_DIR|g" \
      -e "s|@LOG_DIR@|$LOG_DIR|g" \
      -e "s|@BIN_DIR@|$BIN_DIR|g" \
      -e "s|@INFRA_DIR@|$INFRA_DIR|g" \
      "$origem" > "$temp"
  install -m "$modo" "$temp" "$destino"
  rm -f "$temp"
  info "Instalado $destino"
}

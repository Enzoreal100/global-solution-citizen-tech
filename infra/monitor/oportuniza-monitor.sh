#!/usr/bin/env bash
set -uo pipefail
umask 027

: "${LIMITE_CPU:=80}" "${LIMITE_MEMORIA:=80}" "${LIMITE_DISCO:=80}"
: "${INTERVALO_MONITOR:=15}" "${FALHAS_ANTES_DE_RECUPERAR:=2}"
: "${APP_URL_SAUDE:=http://127.0.0.1:5080/health}"
: "${LOG_DIR:=/var/log/oportuniza}" "${BIN_DIR:=/usr/local/bin}"
: "${DISCO_MONITORADO:=/}"

LOG_MONITOR="$LOG_DIR/monitor.log"
LOG_ALERTAS="$LOG_DIR/alertas.log"
install -d -m 750 "$LOG_DIR"
touch "$LOG_MONITOR" "$LOG_ALERTAS"
chmod 640 "$LOG_MONITOR" "$LOG_ALERTAS"
chgrp adm "$LOG_MONITOR" "$LOG_ALERTAS"

declare -A EM_ALERTA=()
FALHAS_API=0
API_FORA=0

registrar() {
  local nivel="$1"; shift
  local linha prioridade
  linha="$(date '+%Y-%m-%dT%H:%M:%S%z') [$nivel] $*"
  echo "$linha" >> "$LOG_MONITOR"
  case "$nivel" in
    INFO) prioridade=6 ;;
    NORMALIZADO|RECUPERADO) prioridade=5 ;;
    ALERTA) prioridade=4 ;;
    *) prioridade=2 ;;
  esac
  (( prioridade <= 5 )) && echo "$linha" >> "$LOG_ALERTAS"
  echo "<$prioridade>[$nivel] $*"
}

ler_cpu() {
  local _ user nice system idle iowait irq softirq steal
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  echo "$((user + nice + system + idle + iowait + irq + softirq + steal)) $((idle + iowait))"
}

read -r CPU_TOTAL_ANT CPU_OCIOSO_ANT < <(ler_cpu)
sleep 1

medir_cpu() {
  local total ocioso
  read -r total ocioso < <(ler_cpu)
  local dt=$((total - CPU_TOTAL_ANT)) di=$((ocioso - CPU_OCIOSO_ANT))
  CPU_TOTAL_ANT=$total CPU_OCIOSO_ANT=$ocioso
  CPU=0
  (( dt > 0 )) && CPU=$(( 100 * (dt - di) / dt ))
}

uso_memoria() {
  awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%d", (t - a) * 100 / t}' /proc/meminfo
}

uso_disco() {
  df -P "$DISCO_MONITORADO" | awk 'NR == 2 {gsub("%", "", $5); print $5}'
}

avaliar() {
  local recurso="$1" valor="$2" limite="$3" detalhe="$4"
  if (( valor >= limite )); then
    registrar ALERTA "$recurso em ${valor}% (limite ${limite}%) $detalhe"
    EM_ALERTA[$recurso]=1
  elif [[ -n "${EM_ALERTA[$recurso]:-}" ]]; then
    registrar NORMALIZADO "$recurso voltou para ${valor}% (limite ${limite}%)"
    unset "EM_ALERTA[$recurso]"
  fi
}

recuperar_api() {
  if ! systemctl is-active --quiet docker; then
    registrar CRITICO "Docker parado; iniciando docker.service"
    systemctl start docker
  fi
  registrar CRITICO "API fora do ar em $FALHAS_API verificações seguidas; recuperando contêineres"
  if "$BIN_DIR/oportuniza-compose" up -d > /dev/null 2>&1; then
    registrar INFO "oportuniza-compose up -d executado"
  else
    registrar CRITICO "Falha ao executar oportuniza-compose up -d; reiniciando oportuniza.service"
    systemctl restart oportuniza.service
  fi
  FALHAS_API=0
}

verificar_api() {
  local codigo
  codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$APP_URL_SAUDE")"
  if [[ "$codigo" == "200" ]]; then
    if (( API_FORA )); then
      registrar RECUPERADO "API respondendo novamente em $APP_URL_SAUDE"
    fi
    FALHAS_API=0 API_FORA=0
    STATUS_API=ok
    return
  fi
  FALHAS_API=$((FALHAS_API + 1)) API_FORA=1
  STATUS_API="falha($codigo)"
  registrar ALERTA "API sem resposta saudável (HTTP $codigo), falha $FALHAS_API/$FALHAS_ANTES_DE_RECUPERAR"
  (( FALHAS_API >= FALHAS_ANTES_DE_RECUPERAR )) && recuperar_api
}

encerrar() {
  registrar INFO "Monitor encerrado (sinal recebido)"
  exit 0
}
trap encerrar SIGTERM SIGINT

registrar INFO "Monitor iniciado (PID $$): CPU ${LIMITE_CPU}%, memória ${LIMITE_MEMORIA}%, disco ${LIMITE_DISCO}%, intervalo ${INTERVALO_MONITOR}s"

while true; do
  medir_cpu
  MEM="$(uso_memoria)"
  DISCO="$(uso_disco)"
  CARGA="$(cut -d' ' -f1-3 /proc/loadavg)"

  avaliar CPU "$CPU" "$LIMITE_CPU" "(carga: $CARGA)"
  avaliar MEMORIA "$MEM" "$LIMITE_MEMORIA" "($(free -m | awk '/^Mem:/ {print $3 "MB de " $2 "MB"}'))"
  avaliar DISCO "$DISCO" "$LIMITE_DISCO" "($DISCO_MONITORADO, $(df -Ph "$DISCO_MONITORADO" | awk 'NR == 2 {print $4}') livres)"
  verificar_api

  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [INFO] cpu=${CPU}% memoria=${MEM}% disco=${DISCO}% carga=\"$CARGA\" api=$STATUS_API" >> "$LOG_MONITOR"

  sleep "$INTERVALO_MONITOR" &
  wait $!
done

#!/usr/bin/env bash
source "$(dirname "$(readlink -f "$0")")/../lib/comum.sh"
iniciar "$@"

etapa "Monitor como serviço"
cat > "$CONF_DIR/monitor.env" <<EOF
LIMITE_CPU=$LIMITE_CPU
LIMITE_MEMORIA=$LIMITE_MEMORIA
LIMITE_DISCO=$LIMITE_DISCO
INTERVALO_MONITOR=$INTERVALO_MONITOR
FALHAS_ANTES_DE_RECUPERAR=$FALHAS_ANTES_DE_RECUPERAR
APP_URL_SAUDE=$APP_URL_SAUDE
LOG_DIR=$LOG_DIR
BIN_DIR=$BIN_DIR
DISCO_MONITORADO=/
EOF
info "Limites: CPU ${LIMITE_CPU}%, memória ${LIMITE_MEMORIA}%, disco ${LIMITE_DISCO}%, intervalo ${INTERVALO_MONITOR}s"

install -m 755 "$INFRA_DIR/monitor/oportuniza-monitor.sh" "$BIN_DIR/oportuniza-monitor"
info "Instalado $BIN_DIR/oportuniza-monitor"
instalar_template "$INFRA_DIR/systemd/oportuniza-monitor.service" /etc/systemd/system/oportuniza-monitor.service
executar "Validando a unit" systemd-analyze verify /etc/systemd/system/oportuniza-monitor.service
executar "Recarregando systemd" systemctl daemon-reload
executar "Habilitando oportuniza-monitor.service no boot" systemctl enable oportuniza-monitor.service
executar "Iniciando o monitor" systemctl restart oportuniza-monitor.service
aguardar "Monitor ativo" 10 1 systemctl is-active --quiet oportuniza-monitor.service
aguardar "Primeira leitura gravada em $LOG_DIR/monitor.log" 20 1 grep -q 'cpu=' "$LOG_DIR/monitor.log"
info "Última leitura: $(grep 'cpu=' "$LOG_DIR/monitor.log" | tail -1)"
info "Política de reinício: $(systemctl show -p Restart --value oportuniza-monitor) a cada $(systemctl show -p RestartUSec --value oportuniza-monitor)"

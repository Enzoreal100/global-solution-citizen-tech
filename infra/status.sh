#!/usr/bin/env bash
LOG_NOME=status
source "$(dirname "$(readlink -f "$0")")/lib/comum.sh"
iniciar "$@"
set +eE
trap - ERR

LOG_AUDITD="$LOG_DIR/auditd-resumo.log"
source "$CONF_DIR/rede.env" 2>/dev/null || true

secao() { printf '\n%s== %s ==%s\n' "$COR_ETAPA" "$1" "$COR_FIM"; }

resumo_auditd() {
  echo "Gerado em $(agora) por status.sh"
  echo
  aureport --input-logs -k --summary -ts today 2>/dev/null
  for chave in oportuniza-servicos oportuniza-segredos oportuniza-rede oportuniza-firewall; do
    echo
    echo "== Últimos eventos: $chave =="
    ausearch --input-logs -k "$chave" -ts today --raw 2>/dev/null | aureport -f -i 2>/dev/null | tail -n +6 | tail -n 6
  done
}

relatorio() {
  secao "Host e rede ($(agora))"
  echo "Hostname:   $(hostname) ($(hostname -f 2>/dev/null))"
  echo "IP privado: ${IP_PRIVADO:-?}/${PREFIXO:-?} em ${INTERFACE:-?} | gateway ${GATEWAY:-?}"
  echo "IP público: ${IP_PUBLICO:-?}"
  echo "DNS:        $(resolvectl dns 2>/dev/null | awk -F': ' 'NF > 1 && $2 != "" {print $2}' | paste -sd ' ')"
  echo "Interno:    $(getent hosts "api.$DOMINIO_LOCAL" | awk '{print $2 " -> " $1}')"
  ufw status | sed -n '1p;/ALLOW\|LIMIT/p' | grep -v '(v6)'

  secao "Serviços"
  for s in docker oportuniza oportuniza-monitor auditd; do
    printf '%-20s %-10s boot=%-9s reinícios=%s\n' "$s" "$(systemctl is-active "$s")" \
      "$(systemctl is-enabled "$s" 2>/dev/null)" "$(systemctl show -p NRestarts --value "$s")"
  done

  secao "Contêineres"
  "$BIN_DIR/oportuniza-compose" ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || echo "indisponível"

  secao "Aplicação"
  echo "Saúde:   $(curl -s --max-time 3 "$APP_URL_SAUDE" || echo 'sem resposta')"
  echo "Swagger: http://${IP_PUBLICO:-<ip>}:$APP_PORTA/swagger"

  secao "Recursos (última leitura do monitor)"
  grep 'cpu=' "$LOG_DIR/monitor.log" 2>/dev/null | tail -1 || echo "sem leituras"

  secao "Últimos alertas ($LOG_DIR/alertas.log)"
  tail -n 8 "$LOG_DIR/alertas.log" 2>/dev/null || echo "nenhum"

  secao "Auditoria de scripts ($LOG_AUDITORIA)"
  tail -n 6 "$LOG_AUDITORIA"

  secao "Auditoria do kernel (resumo completo em $LOG_AUDITD)"
  resumo_auditd > "$LOG_AUDITD"
  chmod 640 "$LOG_AUDITD"
  chgrp adm "$LOG_AUDITD"
  sed -n '/^[0-9]\+  oportuniza/p' "$LOG_AUDITD"
}

SAIDA="$(relatorio)"
printf '%s\n' "$SAIDA"
printf '%s\n' "$SAIDA" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_EXECUCAO"

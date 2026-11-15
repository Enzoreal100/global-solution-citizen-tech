#!/usr/bin/env bash
LOG_NOME=teste-falha
source "$(dirname "$(readlink -f "$0")")/lib/comum.sh"
iniciar "$@"

COMPOSE="$BIN_DIR/oportuniza-compose"
ALERTAS="$LOG_DIR/alertas.log"
ARQUIVO_DISCO=/var/tmp/oportuniza-teste-disco.img
RESULTADOS=()

uso() {
  echo "Uso: sudo $0 {monitor|api|banco|cpu|memoria|disco|todos}" >&2
  exit 2
}

marcar_alertas() { touch "$ALERTAS"; MARCA=$(wc -l < "$ALERTAS"); }

mostrar_alertas() {
  info "Alertas registrados durante o teste:"
  tail -n +"$((MARCA + 1))" "$ALERTAS" | registrar_saida
}

esperar_alerta() {
  local padrao="$1" limite="$2"
  for ((s = 0; s < limite; s++)); do
    grep -q -- "$padrao" < <(tail -n +"$((MARCA + 1))" "$ALERTAS") && return 0
    sleep 1
  done
  return 1
}

resultado() {
  local teste="$1" passou="$2"
  if [[ "$passou" == 1 ]]; then
    ok "TESTE $teste: PASSOU"
    RESULTADOS+=("$teste=PASSOU")
  else
    log ERRO "TESTE $teste: FALHOU"
    RESULTADOS+=("$teste=FALHOU")
  fi
}

saude_ok() { curl -fsS --max-time 3 "$APP_URL_SAUDE" > /dev/null; }

teste_monitor() {
  etapa "Falha: processo do monitor morto com SIGKILL"
  local pid_antes reinicios_antes pid_depois
  pid_antes=$(systemctl show -p MainPID --value oportuniza-monitor)
  reinicios_antes=$(systemctl show -p NRestarts --value oportuniza-monitor)
  info "PID atual $pid_antes, reinícios até agora $reinicios_antes"
  executar "kill -9 $pid_antes" kill -9 "$pid_antes"
  sleep 1
  info "Estado logo após o kill: $(systemctl is-active oportuniza-monitor || true)"
  if aguardar "systemd reiniciar o monitor" 20 1 bash -c \
      "[[ \$(systemctl is-active oportuniza-monitor) == active && \$(systemctl show -p MainPID --value oportuniza-monitor) != $pid_antes ]]"; then
    pid_depois=$(systemctl show -p MainPID --value oportuniza-monitor)
    info "Novo PID $pid_depois, reinícios agora $(systemctl show -p NRestarts --value oportuniza-monitor)"
    journalctl -u oportuniza-monitor --since "-30s" --no-pager -o short-iso | tail -n 5 | registrar_saida
    resultado monitor 1
  else
    resultado monitor 0
  fi
}

teste_conteiner() {
  local servico="$1" nome="$2"
  etapa "Falha: contêiner $servico parado ($nome)"
  saude_ok || aviso "API já estava fora do ar antes do teste"
  marcar_alertas
  executar "docker stop do contêiner $servico" docker stop "$($COMPOSE ps -q "$servico")"
  sleep 2
  info "Saúde logo após a parada: $(curl -s --max-time 3 "$APP_URL_SAUDE" || echo 'sem resposta')"
  local espera=$(( (FALHAS_ANTES_DE_RECUPERAR + 2) * INTERVALO_MONITOR + 90 ))
  local passou=0
  if aguardar "monitor detectar e recuperar o $servico (até ${espera}s)" "$((espera / 3))" 3 saude_ok; then
    esperar_alerta RECUPERADO 30 && passou=1
  fi
  mostrar_alertas
  "$COMPOSE" ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}' | registrar_saida
  resultado "$nome" "$passou"
}

teste_cpu() {
  etapa "Sobrecarga: CPU em 100% por 45s"
  marcar_alertas
  executar "stress-ng --cpu $(nproc) --timeout 45s" stress-ng --cpu "$(nproc)" --timeout 45s
  local passou=0
  esperar_alerta "\[ALERTA\] CPU" 5 && esperar_alerta "\[NORMALIZADO\] CPU" $((INTERVALO_MONITOR * 2 + 5)) && passou=1
  mostrar_alertas
  resultado cpu "$passou"
}

teste_memoria() {
  etapa "Sobrecarga: memória acima de ${LIMITE_MEMORIA}% por 45s"
  marcar_alertas
  local total_mb usado_mb alvo_mb
  total_mb=$(free -m | awk '/^Mem:/ {print $2}')
  usado_mb=$(free -m | awk '/^Mem:/ {print $3}')
  alvo_mb=$(( total_mb * (LIMITE_MEMORIA + 8) / 100 - usado_mb ))
  (( alvo_mb > 0 )) || alvo_mb=256
  info "Total ${total_mb}MB, em uso ${usado_mb}MB; alocando mais ${alvo_mb}MB"
  executar "stress-ng --vm 1 --vm-bytes ${alvo_mb}M --vm-keep --timeout 45s" \
    stress-ng --vm 1 --vm-bytes "${alvo_mb}M" --vm-keep --timeout 45s
  local passou=0
  esperar_alerta "\[ALERTA\] MEMORIA" 5 && esperar_alerta "\[NORMALIZADO\] MEMORIA" $((INTERVALO_MONITOR * 2 + 5)) && passou=1
  mostrar_alertas
  resultado memoria "$passou"
}

teste_disco() {
  etapa "Sobrecarga: disco acima de ${LIMITE_DISCO}%"
  marcar_alertas
  local total_kb usado_kb alvo_kb
  read -r total_kb usado_kb < <(df -Pk / | awk 'NR == 2 {print $2, $3}')
  alvo_kb=$(( total_kb * (LIMITE_DISCO + 5) / 100 - usado_kb ))
  (( alvo_kb > 0 )) || alvo_kb=1048576
  rm -f "$ARQUIVO_DISCO"
  executar "Criando arquivo de $((alvo_kb / 1024 / 1024))GB em $ARQUIVO_DISCO" fallocate -l "${alvo_kb}K" "$ARQUIVO_DISCO"
  info "Uso do disco agora: $(df -P / | awk 'NR == 2 {print $5}')"
  local passou=0
  if esperar_alerta "\[ALERTA\] DISCO" $((INTERVALO_MONITOR * 2 + 5)); then
    executar "Removendo o arquivo de teste" rm -f "$ARQUIVO_DISCO"
    esperar_alerta "\[NORMALIZADO\] DISCO" $((INTERVALO_MONITOR * 2 + 5)) && passou=1
  fi
  rm -f "$ARQUIVO_DISCO"
  mostrar_alertas
  resultado disco "$passou"
}

[[ $# -eq 1 ]] || uso
systemctl is-active --quiet oportuniza-monitor || falha "oportuniza-monitor não está ativo; rode o provision.sh antes"

case "$1" in
  monitor) teste_monitor ;;
  api) teste_conteiner api api ;;
  banco) teste_conteiner mysql banco ;;
  cpu) teste_cpu ;;
  memoria) teste_memoria ;;
  disco) teste_disco ;;
  todos) teste_monitor; teste_conteiner api api; teste_conteiner mysql banco; teste_cpu; teste_memoria; teste_disco ;;
  *) uso ;;
esac

etapa "Resultado"
for r in "${RESULTADOS[@]}"; do info "$r"; done
auditar RESULTADO "${RESULTADOS[*]}"
[[ "${RESULTADOS[*]}" != *FALHOU* ]]

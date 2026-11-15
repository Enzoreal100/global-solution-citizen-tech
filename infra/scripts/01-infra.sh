#!/usr/bin/env bash
source "$(dirname "$(readlink -f "$0")")/../lib/comum.sh"
iniciar "$@"

PACOTES=(curl jq git rsync ufw auditd sysstat stress-ng logrotate bind9-dnsutils iproute2 iputils-ping openssl ca-certificates)

etapa "Pacotes base"
executar "Atualizando índice do apt" apt-get update -q
executar "Instalando ${PACOTES[*]}" apt-get install -y -q "${PACOTES[@]}"

etapa "Relógio"
executar "Fuso horário $FUSO_HORARIO" timedatectl set-timezone "$FUSO_HORARIO"
executar "Sincronização NTP" timedatectl set-ntp true

etapa "Hostname"
executar "Definindo hostname $HOSTNAME_SERVIDOR" hostnamectl set-hostname "$HOSTNAME_SERVIDOR"
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
  printf 'preserve_hostname: true\nmanage_etc_hosts: false\n' > /etc/cloud/cloud.cfg.d/99-oportuniza.cfg
  info "cloud-init configurado para preservar o hostname após reboot"
fi

etapa "Rede e IP"
INTERFACE="$(ip -4 route show default | awk '{print $5; exit}')"
GATEWAY="$(ip -4 route show default | awk '{print $3; exit}')"
IP_PRIVADO="$(ip -4 -o addr show dev "$INTERFACE" | awk '{split($4, a, "/"); print a[1]; exit}')"
PREFIXO="$(ip -4 -o addr show dev "$INTERFACE" | awk '{split($4, a, "/"); print a[2]; exit}')"
MAC="$(cat "/sys/class/net/$INTERFACE/address")"
IP_PUBLICO="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$IP_PUBLICO" ]] || IP_PUBLICO="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo desconhecido)"

[[ -n "$INTERFACE" && -n "$IP_PRIVADO" && -n "$GATEWAY" ]] || falha "Não foi possível detectar interface, IP ou gateway"

cat > "$CONF_DIR/rede.env" <<EOF
INTERFACE=$INTERFACE
MAC=$MAC
IP_PRIVADO=$IP_PRIVADO
PREFIXO=$PREFIXO
GATEWAY=$GATEWAY
IP_PUBLICO=$IP_PUBLICO
HOSTNAME=$HOSTNAME_SERVIDOR
FQDN=$HOSTNAME_SERVIDOR.$DOMINIO_LOCAL
DNS_PUBLICO=${DNS_PUBLICO:-}
EOF
info "Interface $INTERFACE ($MAC): $IP_PRIVADO/$PREFIXO, gateway $GATEWAY, IP público $IP_PUBLICO"
info "Inventário de rede salvo em $CONF_DIR/rede.env"

sed -i '/# BEGIN oportuniza/,/# END oportuniza/d' /etc/hosts
cat >> /etc/hosts <<EOF
# BEGIN oportuniza
127.0.1.1 $HOSTNAME_SERVIDOR.$DOMINIO_LOCAL $HOSTNAME_SERVIDOR
$IP_PRIVADO api.$DOMINIO_LOCAL db.$DOMINIO_LOCAL monitor.$DOMINIO_LOCAL
# END oportuniza
EOF
ok "/etc/hosts: $HOSTNAME_SERVIDOR, api, db e monitor.$DOMINIO_LOCAL -> $IP_PRIVADO"

cat > /etc/sysctl.d/90-oportuniza.conf <<EOF
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.all.log_martians=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.tcp_syncookies=1
vm.swappiness=10
EOF
executar "Aplicando parâmetros de rede do kernel (sysctl)" sysctl --system

etapa "DNS"
install -d /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/oportuniza.conf <<EOF
[Resolve]
DNS=$DNS_PRIMARIOS
FallbackDNS=$DNS_FALLBACK
Domains=$DOMINIO_LOCAL
Cache=yes
EOF
executar "Reiniciando systemd-resolved" systemctl restart systemd-resolved
aguardar "Resolução de nomes externos (github.com)" 10 2 resolvectl query github.com
aguardar "Resolução de nomes internos (api.$DOMINIO_LOCAL)" 5 1 getent hosts "api.$DOMINIO_LOCAL"
aguardar "Rota padrão via $GATEWAY ($INTERFACE)" 5 1 bash -c "ip route get 1.1.1.1 | grep -q 'via $GATEWAY dev $INTERFACE'"
aguardar "Servidor DNS 1.1.1.1 acessível (TCP/53)" 5 1 timeout 3 bash -c '</dev/tcp/1.1.1.1/53'
if [[ -n "${DNS_PUBLICO:-}" ]]; then
  aguardar "Nome público $DNS_PUBLICO resolvendo" 10 3 getent hosts "$DNS_PUBLICO"
  IP_DO_NOME="$(getent hosts "$DNS_PUBLICO" | awk '{print $1; exit}')"
  if [[ "$IP_DO_NOME" == "$IP_PUBLICO" ]]; then
    ok "DNS público: $DNS_PUBLICO -> $IP_DO_NOME (confere com o IP público)"
  else
    aviso "DNS público: $DNS_PUBLICO -> ${IP_DO_NOME:-nada}, mas o IP público é $IP_PUBLICO"
  fi
fi
aguardar "Saída para a internet (HTTPS)" 5 2 curl -sS --max-time 5 -o /dev/null https://mcr.microsoft.com

etapa "Firewall (ufw)"
executar "Política padrão: bloquear entrada" ufw default deny incoming
executar "Política padrão: liberar saída" ufw default allow outgoing
executar "SSH (22/tcp) com limite contra força bruta" ufw limit 22/tcp comment 'SSH'
executar "API ($APP_PORTA/tcp)" ufw allow "$APP_PORTA/tcp" comment 'Oportuniza API'
executar "Ativando firewall" ufw --force enable

etapa "Swap"
if swapon --show=NAME --noheadings | grep -qx /swapfile; then
  info "Swap /swapfile já ativa"
else
  executar "Criando /swapfile de $SWAP_TAMANHO" fallocate -l "$SWAP_TAMANHO" /swapfile
  chmod 600 /swapfile
  executar "Formatando swap" mkswap /swapfile
  executar "Ativando swap" swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

etapa "Resumo da infraestrutura"
info "Hostname: $(hostname) | FQDN: $(hostname -f 2>/dev/null || echo '-')"
info "IP privado: $IP_PRIVADO/$PREFIXO | IP público: $IP_PUBLICO | Gateway: $GATEWAY"
info "Nome público: ${DNS_PUBLICO:-não configurado}"
info "DNS: $(resolvectl dns 2>/dev/null | tr -s ' ' | paste -sd ';')"
info "Firewall: $(ufw status | head -1)"
info "Swap: $(swapon --show=SIZE --noheadings | head -1) | Fuso: $(timedatectl show -p Timezone --value)"

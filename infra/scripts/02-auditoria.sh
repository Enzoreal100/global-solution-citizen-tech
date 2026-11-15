#!/usr/bin/env bash
source "$(dirname "$(readlink -f "$0")")/../lib/comum.sh"
iniciar "$@"

REGRAS=/etc/audit/rules.d/oportuniza.rules

etapa "Regras do auditd"
install -d -m 755 "$APP_DIR"
cat > "$REGRAS" <<EOF
-w $CONF_DIR/ -p wa -k oportuniza-config
-w $CONF_DIR/app.env -p r -k oportuniza-segredos
-w $APP_DIR/docker-compose.yml -p wa -k oportuniza-app
-w $APP_DIR/docker-compose.vm.yml -p wa -k oportuniza-app
-w $INFRA_DIR/ -p wa -k oportuniza-scripts
-w $BIN_DIR/oportuniza-monitor -p wax -k oportuniza-monitor
-w $BIN_DIR/oportuniza-compose -p wa -k oportuniza-app
-w /etc/systemd/system/oportuniza.service -p wa -k oportuniza-servicos
-w /etc/systemd/system/oportuniza-monitor.service -p wa -k oportuniza-servicos
-w /etc/hosts -p wa -k oportuniza-rede
-w /etc/hostname -p wa -k oportuniza-rede
-w /etc/netplan/ -p wa -k oportuniza-rede
-w /etc/sysctl.d/ -p wa -k oportuniza-rede
-w /etc/systemd/resolved.conf.d/ -p wa -k oportuniza-dns
-w /etc/ufw/ -p wa -k oportuniza-firewall
-w /etc/ssh/sshd_config -p wa -k oportuniza-ssh
-w /etc/ssh/sshd_config.d/ -p wa -k oportuniza-ssh
-w /etc/sudoers -p wa -k oportuniza-privilegios
-w /etc/sudoers.d/ -p wa -k oportuniza-privilegios
-w /etc/passwd -p wa -k oportuniza-identidade
-w /etc/group -p wa -k oportuniza-identidade
-w /usr/bin/docker -p x -k oportuniza-docker
-a always,exit -F arch=b64 -S unlink,unlinkat,rename,renameat,truncate,ftruncate -F dir=$LOG_DIR -k oportuniza-logs
EOF
chmod 640 "$REGRAS"
info "Regras gravadas em $REGRAS"

executar "Habilitando auditd" systemctl enable --now auditd
executar "Carregando regras (augenrules)" augenrules --load
QTD="$(auditctl -l | grep -c 'oportuniza-' || true)"
(( QTD > 0 )) || falha "Nenhuma regra oportuniza-* carregada no kernel"
ok "$QTD regras de auditoria ativas no kernel"

etapa "Rotação de logs"
cat > /etc/logrotate.d/oportuniza <<EOF
$LOG_DIR/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
executar "Validando configuração do logrotate" logrotate -d /etc/logrotate.d/oportuniza

etapa "Persistência do journal"
install -d /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=persistent\nSystemMaxUse=300M\n' > /etc/systemd/journald.conf.d/oportuniza.conf
executar "Reiniciando journald" systemctl restart systemd-journald

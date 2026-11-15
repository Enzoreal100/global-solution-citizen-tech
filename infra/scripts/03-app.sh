#!/usr/bin/env bash
source "$(dirname "$(readlink -f "$0")")/../lib/comum.sh"
iniciar "$@"

REPO_RAIZ="$(cd "$INFRA_DIR/.." && pwd)"
ENV_APP="$CONF_DIR/app.env"
COMPOSE="$BIN_DIR/oportuniza-compose"

etapa "Docker Engine e Compose"
if ! command -v docker > /dev/null || ! docker compose version > /dev/null 2>&1; then
  executar "Instalando docker.io e docker-compose-v2" apt-get install -y -q docker.io docker-compose-v2
fi
executar "Habilitando docker.service no boot" systemctl enable --now docker
aguardar "Docker respondendo" 10 2 docker info
info "$(docker --version) | $(docker compose version)"
if [[ -n "${SUDO_USER:-}" ]] && ! id -nG "$SUDO_USER" | grep -qw docker; then
  executar "Adicionando $SUDO_USER ao grupo docker" usermod -aG docker "$SUDO_USER"
fi

etapa "Código da aplicação"
[[ -f "$REPO_RAIZ/docker-compose.yml" && -f "$REPO_RAIZ/Dockerfile" ]] || falha "docker-compose.yml ou Dockerfile não encontrado em $REPO_RAIZ"
install -d -m 755 "$APP_DIR"
executar "Sincronizando $REPO_RAIZ -> $APP_DIR" rsync -a --delete \
  --exclude .git --exclude .env --exclude infra --exclude front --exclude tests \
  --exclude evidencias --exclude graphify-out --exclude docs --exclude '*.pdf' \
  --exclude 'bin/' --exclude 'obj/' --exclude docker-compose.vm.yml \
  "$REPO_RAIZ/" "$APP_DIR/"
install -m 644 "$INFRA_DIR/app/docker-compose.vm.yml" "$APP_DIR/docker-compose.vm.yml"
ok "Override da VM instalado (MySQL só em 127.0.0.1, restart e rotação de logs dos contêineres)"
if git -C "$REPO_RAIZ" rev-parse HEAD > /dev/null 2>&1; then
  git -C "$REPO_RAIZ" rev-parse HEAD > "$APP_DIR/VERSAO"
  info "Versão implantada: $(cut -c1-12 "$APP_DIR/VERSAO")"
fi

etapa "Variáveis de ambiente e segredos"
if [[ -s "$ENV_APP" ]]; then
  info "$ENV_APP já existe; segredos mantidos"
else
  (
    umask 077
    {
      echo "MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)"
      echo "JWT_SECRET=$(openssl rand -hex 32)"
    } > "$ENV_APP"
  )
  ok "Segredos gerados com openssl rand em $ENV_APP"
fi
chown root:root "$ENV_APP"
chmod 600 "$ENV_APP"
grep -q '^JWT_SECRET=.\{32,\}$' "$ENV_APP" || falha "JWT_SECRET ausente ou com menos de 32 caracteres"
info "Permissões de $ENV_APP: $(stat -c '%A %U:%G' "$ENV_APP")"

etapa "Orquestração (Docker Compose + systemd)"
instalar_template "$INFRA_DIR/app/oportuniza-compose" "$COMPOSE" 755
executar "Validando a composição" "$COMPOSE" config --quiet
executar "Baixando imagem do MySQL" "$COMPOSE" pull mysql
executar "Construindo imagem da API (.NET 10)" "$COMPOSE" build api
instalar_template "$INFRA_DIR/systemd/oportuniza.service" /etc/systemd/system/oportuniza.service
executar "Recarregando systemd" systemctl daemon-reload
executar "Habilitando oportuniza.service no boot" systemctl enable oportuniza.service
executar "Subindo a aplicação" systemctl restart oportuniza.service

etapa "Verificação da aplicação"
aguardar "MySQL saudável" 40 3 bash -c "[[ \$(docker inspect -f '{{.State.Health.Status}}' \$($COMPOSE ps -q mysql)) == healthy ]]"
aguardar "API respondendo em $APP_URL_SAUDE" 60 3 curl -fsS --max-time 3 "$APP_URL_SAUDE"
info "Saúde: $(curl -fsS --max-time 3 "$APP_URL_SAUDE")"

TOKEN="$(curl -fsS --max-time 10 -H 'Content-Type: application/json' \
  -d '{"email":"ana@exemplo.local","senha":"Senha@123"}' "$APP_URL_BASE/auth/login" | jq -r '.token // empty')"
[[ -n "$TOKEN" ]] || falha "Login de demonstração falhou"
ok "Login de demonstração (ana@exemplo.local) gerou JWT"

QTD="$(curl -fsS --max-time 10 "$APP_URL_BASE/oportunidades" | jq '.totalItens // (.itens | length)')"
ok "GET /oportunidades devolveu $QTD oportunidades do seed"

source "$CONF_DIR/rede.env" 2>/dev/null || true
ok "Swagger: http://${DNS_PUBLICO:-${IP_PUBLICO:-<ip-publico>}}:$APP_PORTA/swagger"

# Oportuniza · Infraestrutura Linux

Provisionamento automatizado, em Bash, de um servidor Ubuntu 24.04 que hospeda a API Oportuniza (ASP.NET Core .NET 10 + MySQL 8), com monitoramento como serviço, auditoria e teste de falha.

## Ambiente

| Item | Valor |
|---|---|
| Nuvem | Azure for Students, região `chilecentral` |
| VM | `Standard_B2als_v2` (2 vCPU, 4 GB RAM, 30 GB de disco) |
| Sistema | Ubuntu 24.04 LTS |
| Aplicação | API Oportuniza + MySQL 8.4 em Docker Compose, controlados pelo systemd |

Criação da VM (única etapa fora da VM):

```bash
az group create -n gs-linux -l chilecentral
az vm create -g gs-linux -n oportuniza-vm --image Ubuntu2404 --size Standard_B2als_v2 \
  --admin-username azureuser --ssh-key-values ~/.ssh/id_ed25519.pub --public-ip-sku Standard --os-disk-size-gb 30
az vm open-port -g gs-linux -n oportuniza-vm --port 5080 --priority 1010
az network public-ip update -g gs-linux -n oportuniza-vmPublicIP --dns-name oportuniza-gs
```

O último comando cria o nome público `oportuniza-gs.chilecentral.cloudapp.azure.com`, gratuito, apontando para o IP da VM.

## Como executar

Dentro da VM:

```bash
git clone https://github.com/hellen-silvaa/global-solution-citizen-tech.git
cd global-solution-citizen-tech
sudo ./infra/provision.sh
```

O `provision.sh` roda as quatro etapas em ordem e termina com um relatório de status. Na primeira execução leva cerca de 2 minutos. Ele é idempotente: rodar de novo mantém os segredos e reaplica a configuração (cerca de 30 s).

Depois: Swagger em `http://oportuniza-gs.chilecentral.cloudapp.azure.com:5080/swagger`, login com `ana@exemplo.local` / `Senha@123`.

| Comando | O que faz |
|---|---|
| `sudo ./infra/provision.sh` | Provisiona tudo |
| `sudo ./infra/status.sh` | Rede, serviços, contêineres, saúde, últimos alertas e auditoria |
| `sudo ./infra/teste-falha.sh <teste>` | `monitor`, `api`, `banco`, `cpu`, `memoria`, `disco` ou `todos` |

## Estrutura

```
infra/
├── provision.sh                 orquestrador
├── status.sh                    relatório do ambiente
├── teste-falha.sh               testes de falha e sobrecarga
├── config.env                   todas as variáveis (hostname, DNS, limites, portas, caminhos)
├── lib/comum.sh                 log, auditoria, tratamento de erro, espera com timeout
├── scripts/
│   ├── 01-infra.sh              pacotes, fuso/NTP, hostname, IP, /etc/hosts, sysctl, DNS, firewall, swap
│   ├── 02-auditoria.sh          regras do auditd, logrotate, journal persistente
│   ├── 03-app.sh                Docker, código, segredos, build, systemd, smoke test
│   └── 04-monitoramento.sh      instala e ativa o monitor como serviço
├── monitor/oportuniza-monitor.sh
├── systemd/                     oportuniza.service e oportuniza-monitor.service
├── app/                         override do compose para a VM e wrapper oportuniza-compose
└── evidencias/logs/             cópia de /var/log/oportuniza tirada da VM
```

## Critérios da avaliação

### Provisionamento de infra: rede, DNS, IP (`01-infra.sh`)

- **Hostname** `oportuniza-srv` via `hostnamectl`, com o cloud-init configurado para não sobrescrevê-lo no reboot.
- **IP:** detecta interface, IP privado, prefixo, gateway, MAC e IP público e grava o inventário em `/etc/oportuniza/rede.env`. O IP da VM é entregue pelo DHCP da Azure; fixá-lo dentro da VM derrubaria o acesso, por isso o script registra e valida o endereço em vez de alterá-lo.
- **Resolução local:** `/etc/hosts` com `oportuniza-srv`, `api`, `db` e `monitor.oportuniza.internal`.
- **DNS:** `systemd-resolved` com 1.1.1.1 e 8.8.8.8, fallback 9.9.9.9 e domínio de busca `oportuniza.internal`. Valida resolução externa, interna, rota padrão, porta 53 e saída HTTPS.
- **DNS público:** confere que `DNS_PUBLICO` (o nome `cloudapp.azure.com` da VM) resolve para o IP público detectado.
- **Kernel:** `sysctl` sem ICMP redirects nem source routing, com SYN cookies e log de pacotes marcianos.
- **Firewall:** `ufw` bloqueia a entrada por padrão, libera 5080 e aplica `limit` no SSH (contra força bruta).
- Fuso `America/Sao_Paulo`, NTP e 2 GB de swap.

### Provisionamento da aplicação (`03-app.sh`)

- Instala Docker Engine e Compose v2 e habilita no boot.
- Copia o código para `/opt/oportuniza/app` e registra a versão (commit) em `VERSAO`.
- Gera `MYSQL_ROOT_PASSWORD` e `JWT_SECRET` com `openssl rand` em `/etc/oportuniza/app.env` (permissão 600, fora do Git) e recusa um segredo JWT com menos de 32 caracteres.
- `docker-compose.vm.yml` publica o MySQL só em `127.0.0.1`. O Docker escreve regras de iptables que passam por cima do `ufw`, então sem esse ajuste a porta 3307 ficaria aberta na internet. Também ativa `restart: unless-stopped` e rotação dos logs dos contêineres.
- `oportuniza.service` (systemd) sobe a composição no boot.
- Smoke test: espera o MySQL ficar `healthy`, o `/health` responder, faz login de demonstração e consulta `/oportunidades`.

### Monitoramento de CPU, disco e memória (`oportuniza-monitor.sh`)

A cada 15 s o monitor lê CPU (`/proc/stat`), memória (`MemAvailable`), disco (`df /`) e a saúde da API (`/health`, que também testa o banco).

| Nível | Quando |
|---|---|
| `ALERTA` | recurso em 80% ou mais, ou API sem HTTP 200 |
| `NORMALIZADO` | recurso voltou para baixo do limite |
| `CRITICO` | API falhou 2 verificações seguidas; o monitor executa `oportuniza-compose up -d` (e, se isso falhar, reinicia `oportuniza.service`) |
| `RECUPERADO` | API voltou a responder |

Os limites ficam em `config.env`.

### Monitoramento como serviço tolerante a falhas (`oportuniza-monitor.service`)

- `Restart=always`, `RestartSec=5` e `StartLimitIntervalSec=0`: o systemd reinicia o monitor sempre, sem limite de tentativas.
- `OOMScoreAdjust=-900`: o monitor é o último candidato do OOM killer, então continua vivo durante falta de memória.
- `MemoryMax=128M` e `CPUQuota=25%`: o próprio monitor não consegue esgotar a máquina.
- Habilitado no boot, com ordem `After=docker.service oportuniza.service`.

### Logs de auditoria e execução

| Arquivo | Conteúdo |
|---|---|
| `/var/log/oportuniza/provisionamento.log` | Cada passo do `provision.sh` e das etapas, com o comando executado e a saída completa |
| `/var/log/oportuniza/teste-falha.log` | Cada teste de falha: o que foi provocado, os alertas gerados e o resultado |
| `/var/log/oportuniza/status.log` | Cada relatório gerado pelo `status.sh` |
| `/var/log/oportuniza/auditd-resumo.log` | Resumo do auditd por chave e últimos eventos (atualizado a cada `status.sh`) |
| `/var/log/oportuniza/auditoria.log` | `INICIO`/`FIM` de cada script: usuário real (`SUDO_USER`), TTY, host, argumentos, hash do script, código de saída e duração |
| `/var/log/oportuniza/monitor.log` | Uma leitura por ciclo: `cpu= memoria= disco= carga= api=` |
| `/var/log/oportuniza/alertas.log` | Só alertas, normalizações, críticos e recuperações |
| `journalctl -t oportuniza-<script>` / `-u oportuniza-monitor` | As mesmas mensagens no journal (persistente), com prioridade syslog |
| `auditd`, chaves `oportuniza-*` | Kernel registra quem altera configuração, rede, DNS, firewall, units, SSH, sudoers, usuários e logs, quem lê `app.env` e quem executa `docker` |

Consultas úteis:

```bash
sudo aureport --input-logs -k --summary -ts today
sudo ausearch --input-logs -k oportuniza-segredos -i
sudo journalctl -u oportuniza-monitor -p warning
```

Os logs rodam diariamente e são mantidos por 14 dias (`/etc/logrotate.d/oportuniza`).

### Teste de falha (`teste-falha.sh`)

| Teste | Falha provocada | Recuperação esperada |
|---|---|---|
| `monitor` | `kill -9` no monitor | systemd reinicia em 5 s com novo PID |
| `api` | `docker stop` na API | monitor alerta, executa a recuperação e registra `RECUPERADO` |
| `banco` | `docker stop` no MySQL (o `/health` passa a devolver 503) | idem |
| `cpu` | `stress-ng --cpu` por 45 s | `ALERTA CPU` e depois `NORMALIZADO` |
| `memoria` | `stress-ng --vm` até cerca de 88% da RAM | `ALERTA MEMORIA` e depois `NORMALIZADO` |
| `disco` | `fallocate` até cerca de 85% do disco | `ALERTA DISCO`, remove o arquivo, `NORMALIZADO` |

Cada teste marca `PASSOU` ou `FALHOU` e o resultado vai para o `auditoria.log`. Na execução registrada em [`evidencias/logs/teste-falha.log`](evidencias/logs/teste-falha.log), os seis passaram. Depois de um `sudo reboot`, todos os serviços e contêineres voltaram sozinhos ([`evidencias/logs/status.log`](evidencias/logs/status.log)).

## Evidências

A pasta [`evidencias/logs/`](evidencias/logs/) é uma cópia de `/var/log/oportuniza/` tirada da VM depois do provisionamento, dos testes de falha e de um reboot:

| Arquivo | Conteúdo |
|---|---|
| [`provisionamento.log`](evidencias/logs/provisionamento.log) | Execução completa do `provision.sh` |
| [`teste-falha.log`](evidencias/logs/teste-falha.log) | Os seis testes de falha e o resultado de cada um |
| [`status.log`](evidencias/logs/status.log) | Relatórios do ambiente, inclusive depois do reboot |
| [`alertas.log`](evidencias/logs/alertas.log) | Alertas, normalizações e recuperações do monitor |
| [`monitor.log`](evidencias/logs/monitor.log) | Todas as leituras do monitor |
| [`auditoria.log`](evidencias/logs/auditoria.log) | Início e fim de cada execução de script |
| [`auditd-resumo.log`](evidencias/logs/auditd-resumo.log) | Eventos do auditd por chave |

Para atualizar a cópia a partir da máquina local:

```bash
ssh azureuser@<ip> 'sudo tar -C /var/log/oportuniza -cf - .' | tar -C infra/evidencias/logs -xf -
```

## Roteiro do vídeo (até 7 min)

| Tempo | Bloco | Comandos |
|---|---|---|
| 0:00 a 0:20 | Abertura | — |
| 0:20 a 0:50 | VM vazia | `hostname`, `docker --version`, `git clone`, `cat infra/config.env` |
| 0:50 a 2:50 | Provisionamento | `sudo ./infra/provision.sh` |
| 2:50 a 3:30 | Aplicação no ar | Swagger em `http://oportuniza-gs.chilecentral.cloudapp.azure.com:5080/swagger`, login e recomendações |
| 3:30 a 4:10 | Monitor como serviço | `systemctl cat oportuniza-monitor`, `tail /var/log/oportuniza/monitor.log` |
| 4:10 a 6:00 | Teste de falha | `tail -f alertas.log` em outro terminal; `teste-falha.sh monitor`, `api` e `cpu` |
| 6:00 a 6:30 | Auditoria | `tail auditoria.log`, `aureport -k --summary` |
| 6:30 a 6:40 | Fechamento | `ls -R infra/evidencias` |

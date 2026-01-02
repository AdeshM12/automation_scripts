#!/bin/bash
set -e

### Versions ###
NODE_EXPORTER_VERSION="1.8.1"
PROMETHEUS_VERSION="2.54.0"
ALERTMANAGER_VERSION="0.27.0"

### Users ###
id prometheus &>/dev/null || useradd --no-create-home --shell /usr/sbin/nologin prometheus
id alertmanager &>/dev/null || useradd --no-create-home --shell /usr/sbin/nologin alertmanager

echo "==> Updating system"
apt update -y
apt install -y curl tar apt-transport-https software-properties-common

############################
# Node Exporter
############################
echo "==> Installing Node Exporter"
if ! command -v node_exporter &>/dev/null; then
  cd /tmp
  curl -LO https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
  tar -xzf node_exporter-*.tar.gz
  mv node_exporter-*/node_exporter /usr/local/bin/
  chmod +x /usr/local/bin/node_exporter
fi

cat >/etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=nobody
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

############################
# Prometheus
############################
echo "==> Installing Prometheus"
mkdir -p /etc/prometheus /var/lib/prometheus
chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

if ! command -v prometheus &>/dev/null; then
  cd /tmp
  curl -LO https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
  tar -xzf prometheus-*.tar.gz
  mv prometheus-*/prometheus /usr/local/bin/
  mv prometheus-*/promtool /usr/local/bin/
  mv prometheus-*/{consoles,console_libraries} /etc/prometheus/
  chmod +x /usr/local/bin/prometheus /usr/local/bin/promtool
fi

cat >/etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]

rule_files:
  - /etc/prometheus/alerts.yml

scrape_configs:
  - job_name: "node"
    static_configs:
      - targets: ["localhost:9100"]
EOF

cat >/etc/prometheus/alerts.yml <<EOF
groups:
- name: node-alerts
  rules:
  - alert: HighCPUUsage
    expr: avg(rate(node_cpu_seconds_total{mode!="idle"}[2m])) > 0.8
    for: 2m
    labels:
      severity: warning
    annotations:
      description: CPU usage > 80%

  - alert: DiskAlmostFull
    expr: node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} < 0.15
    for: 2m
    labels:
      severity: critical
    annotations:
      description: Root disk almost full
EOF

chown -R prometheus:prometheus /etc/prometheus

cat >/etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus
After=network.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus

[Install]
WantedBy=multi-user.target
EOF

############################
# Alertmanager
############################
echo "==> Installing Alertmanager"
mkdir -p /etc/alertmanager /var/lib/alertmanager
chown alertmanager:alertmanager /var/lib/alertmanager

if ! command -v alertmanager &>/dev/null; then
  cd /tmp
  curl -LO https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz
  tar -xzf alertmanager-*.tar.gz
  mv alertmanager-*/alertmanager /usr/local/bin/
  mv alertmanager-*/amtool /usr/local/bin/
  chmod +x /usr/local/bin/alertmanager /usr/local/bin/amtool
fi

cat >/etc/alertmanager/alertmanager.yml <<EOF
route:
  receiver: default

receivers:
  - name: default
EOF

cat >/etc/systemd/system/alertmanager.service <<EOF
[Unit]
Description=Alertmanager
After=network.target

[Service]
User=alertmanager
ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/alertmanager \
  --web.listen-address=0.0.0.0:9093

[Install]
WantedBy=multi-user.target
EOF

############################
# Grafana
############################
echo "==> Installing Grafana"
if ! dpkg -l | grep -q grafana; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://packages.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://packages.grafana.com/oss/deb stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt update
  apt install -y grafana
fi

############################
# UFW (Ubuntu firewall) – safe automation
############################
if command -v ufw &>/dev/null; then
  echo "==> Configuring UFW"
  ufw allow 9090/tcp
  ufw allow 9093/tcp
  ufw allow 9100/tcp
  ufw allow 3000/tcp
fi

############################
# Enable services
############################
echo "==> Enabling services"
systemctl daemon-reload
systemctl enable --now node_exporter
systemctl enable --now prometheus
systemctl enable --now alertmanager
systemctl enable --now grafana-server

echo "======================================="
echo " Monitoring stack installed successfully"
echo "---------------------------------------"
echo " Prometheus   : http://<VM-IP>:9090"
echo " Grafana      : http://<VM-IP>:3000"
echo " Alertmanager : http://<VM-IP>:9093"
echo " NodeExporter : http://<VM-IP>:9100/metrics"
echo "======================================="

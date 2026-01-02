#!/bin/bash
set -e

### Versions ###
NODE_EXPORTER_VERSION="1.8.1"
PROMETHEUS_VERSION="2.54.0"
ALERTMANAGER_VERSION="0.27.0"

### Helpers ###
PKG=""
if command -v dnf >/dev/null 2>&1; then
  PKG="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG="yum"
else
  echo "No supported package manager (dnf/yum) found." >&2
  exit 1
fi

# ensure basic tools
sudo $PKG install -y curl tar gzip gnupg || sudo $PKG install -y curl tar gzip gnupg2

### Users ###
id prometheus &>/dev/null || sudo useradd -r -s /sbin/nologin prometheus
id alertmanager &>/dev/null || sudo useradd -r -s /sbin/nologin alertmanager

echo "==> Updating system"
sudo $PKG makecache
sudo $PKG -y upgrade

############################
# Node Exporter
############################
echo "==> Installing Node Exporter"
if ! command -v node_exporter &>/dev/null; then
  cd /tmp
  curl -LO "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
  tar -xzf node_exporter-*.tar.gz
  sudo mv node_exporter-*/node_exporter /usr/local/bin/
  sudo chown root:root /usr/local/bin/node_exporter
fi

sudo tee /etc/systemd/system/node_exporter.service >/dev/null <<'EOF'
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
sudo mkdir -p /etc/prometheus /var/lib/prometheus
sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

if ! command -v prometheus &>/dev/null; then
  cd /tmp
  curl -LO "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
  tar -xzf prometheus-*.tar.gz
  sudo mv prometheus-*/prometheus /usr/local/bin/
  sudo mv prometheus-*/promtool /usr/local/bin/
  sudo mv prometheus-*/{consoles,console_libraries} /etc/prometheus/
fi

sudo tee /etc/prometheus/prometheus.yml >/dev/null <<'EOF'
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

sudo tee /etc/prometheus/alerts.yml >/dev/null <<'EOF'
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

sudo chown -R prometheus:prometheus /etc/prometheus

sudo tee /etc/systemd/system/prometheus.service >/dev/null <<'EOF'
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
sudo mkdir -p /etc/alertmanager
sudo chown -R alertmanager:alertmanager /etc/alertmanager

if ! command -v alertmanager &>/dev/null; then
  cd /tmp
  curl -LO "https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz"
  tar -xzf alertmanager-*.tar.gz
  sudo mv alertmanager-*/alertmanager /usr/local/bin/
  sudo mv alertmanager-*/amtool /usr/local/bin/
  sudo chown root:root /usr/local/bin/alertmanager /usr/local/bin/amtool
fi

sudo tee /etc/alertmanager/alertmanager.yml >/dev/null <<'EOF'
route:
  receiver: default

receivers:
  - name: default
EOF

sudo tee /etc/systemd/system/alertmanager.service >/dev/null <<'EOF'
[Unit]
Description=Alertmanager
After=network.target

[Service]
User=alertmanager
ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml

[Install]
WantedBy=multi-user.target
EOF

############################
# Grafana
############################
echo "==> Installing Grafana"
if ! rpm -q grafana >/dev/null 2>&1; then
  sudo tee /etc/yum.repos.d/grafana.repo >/dev/null <<'EOF'
[grafana]
name=grafana
baseurl=https://packages.grafana.com/oss/rpm
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://packages.grafana.com/gpg.key
EOF
  sudo $PKG makecache
  sudo $PKG install -y grafana
fi

############################
# Enable services
############################
echo "==> Enabling services"
sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter
sudo systemctl enable --now prometheus
sudo systemctl enable --now alertmanager
sudo systemctl enable --now grafana-server

echo "======================================="
echo " Monitoring stack installed successfully"
echo "---------------------------------------"
echo " Prometheus   : http://<>:9090"
echo " Grafana      : http://<>:3000"
echo " Alertmanager : http://<>:9093"
echo " NodeExporter : http://<>:9100/metrics"
echo "======================================="

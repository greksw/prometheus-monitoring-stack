#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

readonly PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-3.13.3}"
readonly PROMETHEUS_SHA256="${PROMETHEUS_SHA256:-b349c732d8a853e657d0e7ae1bbad4d11b586615fb65fdc59d896b9f869c001e}"
readonly NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.12.1}"
readonly NODE_EXPORTER_SHA256="${NODE_EXPORTER_SHA256:-b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63}"
readonly INSTALL_GRAFANA="${INSTALL_GRAFANA:-1}"

readonly PROMETHEUS_USER="prometheus"
readonly NODE_EXPORTER_USER="node_exporter"
readonly PROMETHEUS_CONFIG_DIR="/etc/prometheus"
readonly PROMETHEUS_DATA_DIR="/var/lib/prometheus"
readonly GRAFANA_ADMIN_PASSWORD_FILE="/etc/grafana/admin-password"

TMP_DIR=""

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fatal() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf -- "${TMP_DIR}"
    fi
}

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    printf 'ERROR: installer failed at line %s (exit code %s)\n' "${line_no}" "${exit_code}" >&2
    exit "${exit_code}"
}

trap cleanup EXIT
trap 'on_error ${LINENO}' ERR

require_root() {
    [[ ${EUID} -eq 0 ]] || fatal 'Run this installer as root.'
}

check_platform() {
    [[ -r /etc/os-release ]] || fatal '/etc/os-release is missing.'
    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        ubuntu|debian) ;;
        *) fatal "Unsupported operating system: ${ID:-unknown}. Supported: Debian and Ubuntu." ;;
    esac

    case "$(uname -m)" in
        x86_64) ;;
        *) fatal 'This release currently supports x86_64/amd64 only.' ;;
    esac
}

install_prerequisites() {
    log 'Installing prerequisite packages.'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        openssl \
        tar
}

ensure_system_user() {
    local user_name=$1
    local home_dir=$2

    if ! id "${user_name}" >/dev/null 2>&1; then
        useradd \
            --system \
            --home-dir "${home_dir}" \
            --no-create-home \
            --shell /usr/sbin/nologin \
            "${user_name}"
    fi
}

download_and_verify() {
    local url=$1
    local destination=$2
    local expected_sha256=$3

    curl --fail --location --show-error --silent \
        --retry 3 --retry-delay 2 \
        --output "${destination}" \
        "${url}"

    printf '%s  %s\n' "${expected_sha256}" "${destination}" | sha256sum --check --status \
        || fatal "Checksum verification failed for ${destination}."
}

install_prometheus() {
    local archive="${TMP_DIR}/prometheus.tar.gz"
    local extracted_dir="${TMP_DIR}/prometheus-${PROMETHEUS_VERSION}.linux-amd64"
    local url="https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"

    log "Installing Prometheus ${PROMETHEUS_VERSION}."
    ensure_system_user "${PROMETHEUS_USER}" "${PROMETHEUS_DATA_DIR}"

    download_and_verify "${url}" "${archive}" "${PROMETHEUS_SHA256}"
    tar -xzf "${archive}" -C "${TMP_DIR}"

    install -m 0755 "${extracted_dir}/prometheus" /usr/local/bin/prometheus
    install -m 0755 "${extracted_dir}/promtool" /usr/local/bin/promtool

    install -d -m 0750 -o root -g "${PROMETHEUS_USER}" "${PROMETHEUS_CONFIG_DIR}"
    install -d -m 0750 -o "${PROMETHEUS_USER}" -g "${PROMETHEUS_USER}" "${PROMETHEUS_DATA_DIR}"

    cat > "${PROMETHEUS_CONFIG_DIR}/prometheus.yml" <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: node
    static_configs:
      - targets:
          - 127.0.0.1:9100
EOF

    chown root:"${PROMETHEUS_USER}" "${PROMETHEUS_CONFIG_DIR}/prometheus.yml"
    chmod 0640 "${PROMETHEUS_CONFIG_DIR}/prometheus.yml"

    cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus Monitoring Server
Documentation=https://prometheus.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${PROMETHEUS_USER}
Group=${PROMETHEUS_USER}
ExecStart=/usr/local/bin/prometheus \\
  --config.file=${PROMETHEUS_CONFIG_DIR}/prometheus.yml \\
  --storage.tsdb.path=${PROMETHEUS_DATA_DIR} \\
  --web.listen-address=127.0.0.1:9090
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

    /usr/local/bin/promtool check config "${PROMETHEUS_CONFIG_DIR}/prometheus.yml"
}

install_node_exporter() {
    local archive="${TMP_DIR}/node_exporter.tar.gz"
    local extracted_dir="${TMP_DIR}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"
    local url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

    log "Installing node_exporter ${NODE_EXPORTER_VERSION}."
    ensure_system_user "${NODE_EXPORTER_USER}" "/nonexistent"

    download_and_verify "${url}" "${archive}" "${NODE_EXPORTER_SHA256}"
    tar -xzf "${archive}" -C "${TMP_DIR}"
    install -m 0755 "${extracted_dir}/node_exporter" /usr/local/bin/node_exporter

    cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${NODE_EXPORTER_USER}
Group=${NODE_EXPORTER_USER}
ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=read-only
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
}

install_grafana() {
    [[ "${INSTALL_GRAFANA}" == "1" ]] || {
        log 'Grafana installation disabled (INSTALL_GRAFANA=0).'
        return
    }

    log 'Installing Grafana OSS from the official APT repository.'
    install -d -m 0755 /etc/apt/keyrings
    curl --fail --location --show-error --silent \
        https://apt.grafana.com/gpg-full.key \
        -o /etc/apt/keyrings/grafana.asc
    chmod 0644 /etc/apt/keyrings/grafana.asc

    cat > /etc/apt/sources.list.d/grafana.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main
EOF

    apt-get update
    apt-get install -y --no-install-recommends grafana

    if [[ ! -s "${GRAFANA_ADMIN_PASSWORD_FILE}" ]]; then
        openssl rand -base64 32 > "${GRAFANA_ADMIN_PASSWORD_FILE}"
    fi
    chown root:grafana "${GRAFANA_ADMIN_PASSWORD_FILE}"
    chmod 0640 "${GRAFANA_ADMIN_PASSWORD_FILE}"

    install -d -m 0755 /etc/systemd/system/grafana-server.service.d
    cat > /etc/systemd/system/grafana-server.service.d/10-security.conf <<EOF
[Service]
Environment="GF_SERVER_HTTP_ADDR=127.0.0.1"
Environment="GF_USERS_ALLOW_SIGN_UP=false"
Environment="GF_SECURITY_ADMIN_USER=admin"
Environment="GF_SECURITY_ADMIN_PASSWORD=\$__file{${GRAFANA_ADMIN_PASSWORD_FILE}}"
EOF

    install -d -m 0755 /etc/grafana/provisioning/datasources
    cat > /etc/grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
EOF
}

start_services() {
    log 'Starting monitoring services.'
    systemctl daemon-reload
    systemctl enable --now node_exporter
    systemctl enable --now prometheus

    if [[ "${INSTALL_GRAFANA}" == "1" ]]; then
        systemctl enable --now grafana-server
    fi
}

verify_services() {
    log 'Verifying service state and local endpoints.'

    systemctl is-active --quiet node_exporter || fatal 'node_exporter is not active.'
    systemctl is-active --quiet prometheus || fatal 'Prometheus is not active.'

    curl --fail --silent --show-error http://127.0.0.1:9100/metrics >/dev/null
    curl --fail --silent --show-error http://127.0.0.1:9090/-/ready >/dev/null

    if [[ "${INSTALL_GRAFANA}" == "1" ]]; then
        systemctl is-active --quiet grafana-server || fatal 'Grafana is not active.'
        curl --fail --silent --show-error http://127.0.0.1:3000/api/health >/dev/null
    fi
}

print_summary() {
    cat <<EOF

Monitoring stack installation completed successfully.

Local endpoints:
  Prometheus:    http://127.0.0.1:9090
  node_exporter: http://127.0.0.1:9100
EOF

    if [[ "${INSTALL_GRAFANA}" == "1" ]]; then
        cat <<EOF
  Grafana:       http://127.0.0.1:3000

Grafana credentials:
  User: admin
  Password file: ${GRAFANA_ADMIN_PASSWORD_FILE}

The services listen on loopback by default. Use an SSH tunnel or a separately
managed reverse proxy/TLS endpoint instead of exposing metrics ports directly.
EOF
    fi
}

main() {
    require_root
    check_platform
    TMP_DIR=$(mktemp -d)

    install_prerequisites
    install_prometheus
    install_node_exporter
    install_grafana
    start_services
    verify_services
    print_summary
}

main "$@"

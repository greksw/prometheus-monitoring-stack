# Prometheus Monitoring Stack Installer

A Bash-based bootstrap installer for a small, single-node monitoring stack on Debian and Ubuntu.

The project installs and configures:

- Prometheus
- Prometheus Node Exporter
- Grafana OSS (optional)
- systemd service units
- a provisioned Grafana Prometheus datasource

The default design intentionally keeps Prometheus, Node Exporter, and Grafana bound to loopback. Remote access should be provided through an SSH tunnel or a separately managed reverse proxy/TLS endpoint rather than by exposing monitoring ports directly.

## Why this project exists

This repository started as a practical automation script for quickly deploying a monitoring node. The current version has been reworked around repeatability, least exposure, checksum verification, service validation, and explicit operational assumptions.

It is intended as a compact infrastructure automation example rather than a replacement for configuration-management systems such as Ansible.

## Architecture

```text
                   optional external access
                           |
                  SSH tunnel / reverse proxy
                           |
                           v
                  +-------------------+
                  | Grafana :3000     |
                  | 127.0.0.1 only    |
                  +---------+---------+
                            |
                            | datasource
                            v
                  +-------------------+
                  | Prometheus :9090  |
                  | 127.0.0.1 only    |
                  +---------+---------+
                            |
                            | scrape
                            v
                  +-------------------+
                  | node_exporter     |
                  | :9100 loopback    |
                  +-------------------+
```

## Security model

The installer uses the following defaults:

- services run under dedicated non-login system users;
- Prometheus and Node Exporter listen on `127.0.0.1`;
- Grafana is also bound to `127.0.0.1`;
- Grafana self-registration is disabled;
- the generated Grafana admin password is stored in a root-owned file instead of being written to installer logs;
- downloaded Prometheus and Node Exporter archives are verified by SHA-256;
- systemd units use basic sandboxing options such as `NoNewPrivileges`, `PrivateTmp`, and `ProtectSystem`;
- the script does not reset or rewrite the host firewall.

TLS termination is deliberately left outside this installer. In production, expose Grafana through a properly managed reverse proxy or load balancer with a trusted certificate.

## Supported platform

Current release scope:

- Debian / Ubuntu
- x86_64 / amd64
- systemd
- root access during installation

The installer currently pins:

- Prometheus `3.13.3`
- Node Exporter `1.12.1`

Grafana is installed from Grafana's official APT repository and therefore follows the repository's current stable package.

## Installation

Clone the repository and run the installer as root:

```bash
git clone https://github.com/greksw/auto_prometheus.git
cd auto_prometheus
sudo ./auto_prometheus.sh
```

To skip Grafana and install only Prometheus plus Node Exporter:

```bash
sudo INSTALL_GRAFANA=0 ./auto_prometheus.sh
```

Versions can be overridden explicitly, but their checksums must be overridden at the same time:

```bash
sudo \
  PROMETHEUS_VERSION="3.13.3" \
  PROMETHEUS_SHA256="<sha256>" \
  NODE_EXPORTER_VERSION="1.12.1" \
  NODE_EXPORTER_SHA256="<sha256>" \
  ./auto_prometheus.sh
```

## Validation

The installer performs several checks before returning success:

- validates the Prometheus configuration with `promtool`;
- checks that all installed systemd services are active;
- probes the Node Exporter metrics endpoint;
- probes Prometheus readiness;
- probes the Grafana health endpoint when Grafana is enabled.

Useful manual checks:

```bash
systemctl status prometheus node_exporter grafana-server
curl -fsS http://127.0.0.1:9090/-/ready
curl -fsS http://127.0.0.1:9100/metrics | head
curl -fsS http://127.0.0.1:3000/api/health
```

## Accessing Grafana remotely

The simplest secure option for an administrative workstation is an SSH tunnel:

```bash
ssh -L 3000:127.0.0.1:3000 user@monitoring-host
```

Then open `http://127.0.0.1:3000` locally.

The installer prints the path to the generated admin password file. Read it locally on the monitoring server with appropriate privileges.

## Files created by the installer

```text
/usr/local/bin/prometheus
/usr/local/bin/promtool
/usr/local/bin/node_exporter
/etc/prometheus/prometheus.yml
/var/lib/prometheus/
/etc/systemd/system/prometheus.service
/etc/systemd/system/node_exporter.service
/etc/systemd/system/grafana-server.service.d/10-security.conf
/etc/grafana/provisioning/datasources/prometheus.yml
/etc/grafana/admin-password
```

## Operational notes

The script is designed to be safe to rerun for the same pinned versions and configuration, but it is not a full state-management system. Existing local Prometheus or Grafana customizations may be overwritten where this installer owns the corresponding files.

For larger environments, use this repository as a reference implementation and move host-specific configuration into Ansible, Puppet, Salt, Terraform-driven provisioning, or another configuration-management workflow.

## Limitations

- single-node deployment only;
- amd64 only;
- no Alertmanager deployment yet;
- no automatic reverse proxy or TLS termination;
- no automatic firewall management;
- no package-based lifecycle management for Prometheus or Node Exporter;
- no automated integration test against a disposable VM yet.

## Repository quality checks

GitHub Actions runs:

- `bash -n` syntax validation;
- ShellCheck static analysis.

## Roadmap

Planned improvements:

- add Alertmanager as an optional component;
- add an example reverse-proxy configuration;
- add Molecule or disposable-VM integration testing;
- support arm64;
- separate installer logic from rendered configuration templates.

## License

No license has been selected yet. Until a license is added, the repository remains under standard copyright terms.
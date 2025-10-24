# 🚀 Complete Kubernetes Monitoring Stack Setup

A production-ready, one-command setup for a complete monitoring stack on Kubernetes. Includes Prometheus, Grafana, Loki, Tempo, Node Exporter, PostgreSQL Database, Demo Application, and NFS Server with Slack alert notifications and NFS storage monitoring.

## 📋 Overview

This script automates the full installation and configuration of a cloud-native monitoring solution for Kubernetes environments. It handles everything from deploying Prometheus and Grafana dashboards to setting up Slack alerts, logs, and traces via Loki and Tempo.

## ✅ Components Installed

| Component | Purpose |
|-----------|---------|
| Prometheus | Metrics collection and alerting |
| AlertManager | Slack alert routing |
| Grafana | Metrics visualization dashboards |
| Loki | Centralized log aggregation |
| Promtail | Log shipping from nodes and pods |
| Tempo | Distributed tracing backend |
| Node Exporter | Host metrics collection |
| PostgreSQL | Example monitored database |
| NFS Server | Shared storage with monitoring |
| Demo App (NGINX) | Example web workload for monitoring |

## ⚙️ Prerequisites

Ensure you have the following tools and environment ready before running the script:

### 🧩 Required Tools

| Tool | Version | Description |
|------|---------|-------------|
| kubectl | v1.24+ | Kubernetes CLI tool |
| helm | v3.10+ | Helm package manager |
| bash | Any modern version | To execute the installer |

### ☁️ Kubernetes Cluster

- A Kubernetes cluster (v1.24 or higher)
- Cluster admin permissions
- Sufficient storage available (around 60Gi total recommended)

### 🔐 Slack Webhook (optional)

To receive alert notifications in Slack:

1. Create an Incoming Webhook in your Slack workspace ([Guide](https://api.slack.com/messaging/webhooks))
2. Export your webhook before running:

export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
export SLACK_CHANNEL="#alert_notification"

### 🧭 Installation Steps
git clone https://github.com/<your-repo>/monitoring-stack.git
cd monitoring-stack
chmod +x quick-setup.sh
./quick-setup.sh

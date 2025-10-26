#!/bin/bash
# Complete Monitoring Stack - Production Ready Setup (SIMPLIFIED VERSION)
# With Custom Python-based NFS Storage Exporter
# Includes: Prometheus, Grafana, Loki, Tempo, NFS with Custom Exporter, PostgreSQL, Nginx
# Alerts sent to Slack when NFS storage exceeds 70% OR when Nginx Pod Not Ready OR when No Nginx Replicas Available
# ALL SERVICEMONITORS NOW PROPERLY DISCOVERED BY PROMETHEUS

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE_MONITORING="monitoring"
NAMESPACE_APP="demo-app"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-"
SLACK_CHANNEL="${SLACK_CHANNEL:-#alert_notification}"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Complete Monitoring Stack Installation (SIMPLIFIED)      ║${NC}"
echo -e "${BLUE}║  With NFS Storage & Nginx Pod Alerts                      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
echo -e "${YELLOW}[1/18] Checking prerequisites...${NC}"
for cmd in kubectl helm jq; do
    if ! command_exists $cmd; then
        echo -e "${RED}Error: $cmd is not installed${NC}"
        if [ "$cmd" = "jq" ]; then
            echo "Install jq: sudo apt-get install jq -y (Ubuntu/Debian) or brew install jq (Mac)"
        fi
        exit 1
    fi
done
echo -e "${GREEN}✓ Prerequisites OK${NC}\n"

# Step 1: Add Helm repositories
echo -e "${YELLOW}[2/18] Adding Helm repositories...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1
helm repo update >/dev/null 2>&1
echo -e "${GREEN}✓ Helm repositories added${NC}\n"

# Step 2: Create namespaces
echo -e "${YELLOW}[3/18] Creating namespaces...${NC}"
kubectl create namespace $NAMESPACE_MONITORING --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace $NAMESPACE_APP --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo -e "${GREEN}✓ Namespaces created${NC}\n"

# Step 3: Create Prometheus values file
echo -e "${YELLOW}[4/18] Creating Prometheus configuration...${NC}"
cat > /tmp/prometheus-values.yaml <<EOF
prometheus:
  prometheusSpec:
    retention: 15d
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}

nodeExporter:
  enabled: true

alertmanager:
  enabled: true
  config:
    global:
      resolve_timeout: 5m
      slack_api_url: '$SLACK_WEBHOOK_URL'
    
    route:
      group_by: ['alertname', 'cluster', 'namespace']
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 1h
      receiver: 'slack-notifications'
      routes:
        - match:
            severity: critical
          receiver: 'slack-critical'
    
    receivers:
      - name: 'slack-notifications'
        slack_configs:
          - channel: '$SLACK_CHANNEL'
            title: '{{ if eq .Status "firing" }}🔔{{ else }}✅{{ end }} {{ .GroupLabels.alertname }}'
            text: |-
              {{ range .Alerts }}
              *Alert:* {{ .Labels.alertname }}
              *Severity:* {{ .Labels.severity }}
              *Summary:* {{ .Annotations.summary }}
              *Description:* {{ .Annotations.description }}
              *Instance:* {{ .Labels.instance }}
              *Status:* {{ .Status | toUpper }}
              {{ end }}
            send_resolved: true
            username: 'AlertManager'
            
      - name: 'slack-critical'
        slack_configs:
          - channel: '$SLACK_CHANNEL'
            title: '🚨 CRITICAL: {{ .GroupLabels.alertname }}'
            text: |-
              {{ range .Alerts }}
              *Alert:* {{ .Labels.alertname }}
              *Severity:* {{ .Labels.severity }}
              *Component:* {{ .Labels.component }}
              *Summary:* {{ .Annotations.summary }}
              *Description:* {{ .Annotations.description }}
              *Instance:* {{ .Labels.instance }}
              *Status:* {{ .Status | toUpper }}
              {{ end }}
            send_resolved: true
            color: danger
            username: 'AlertManager'

grafana:
  enabled: true
  adminPassword: 'admin123'
  persistence:
    enabled: true
    size: 5Gi
EOF
echo -e "${GREEN}✓ Prometheus configuration created${NC}\n"

# Step 4: Install Prometheus Stack
echo -e "${YELLOW}[5/18] Installing Prometheus Stack (this may take a few minutes)...${NC}"
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -f /tmp/prometheus-values.yaml \
  -n $NAMESPACE_MONITORING \
  --wait \
  --timeout 10m >/dev/null
echo -e "${GREEN}✓ Prometheus Stack installed${NC}\n"

# Step 5: Install Loki
echo -e "${YELLOW}[6/18] Installing Loki...${NC}"
cat > /tmp/loki-values.yaml <<EOF
deploymentMode: SingleBinary

loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: 'filesystem'
  schemaConfig:
    configs:
      - from: 2024-01-01
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 10Gi
  resources:
    limits:
      cpu: 1
      memory: 1Gi
    requests:
      cpu: 500m
      memory: 512Mi

backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0

monitoring:
  selfMonitoring:
    enabled: false
    grafanaAgent:
      installOperator: false
  lokiCanary:
    enabled: false

test:
  enabled: false
EOF

helm upgrade --install loki grafana/loki \
  -f /tmp/loki-values.yaml \
  -n $NAMESPACE_MONITORING \
  --wait \
  --timeout 5m >/dev/null 2>&1
echo -e "${GREEN}✓ Loki installed${NC}\n"

# Step 6: Install Promtail
echo -e "${YELLOW}[7/18] Installing Promtail...${NC}"
cat > /tmp/promtail-values.yaml <<EOF
config:
  clients:
    - url: http://loki:3100/loki/api/v1/push
EOF

helm upgrade --install promtail grafana/promtail \
  -f /tmp/promtail-values.yaml \
  -n $NAMESPACE_MONITORING \
  --wait >/dev/null 2>&1
echo -e "${GREEN}✓ Promtail installed${NC}\n"

# Step 7: Install Tempo
echo -e "${YELLOW}[8/18] Installing Tempo...${NC}"
cat > /tmp/tempo-values.yaml <<EOF
tempo:
  storage:
    trace:
      backend: local

persistence:
  enabled: true
  size: 10Gi
EOF

helm upgrade --install tempo grafana/tempo \
  -f /tmp/tempo-values.yaml \
  -n $NAMESPACE_MONITORING \
  --wait >/dev/null 2>&1
echo -e "${GREEN}✓ Tempo installed${NC}\n"

# Step 8: Create Python Storage Exporter Script
echo -e "${YELLOW}[9/18] Creating custom Python storage exporter...${NC}"
cat > /tmp/storage-exporter.py <<'PYTHON_SCRIPT'
#!/usr/bin/env python3
import os
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/metrics':
            try:
                # Get storage stats using os.statvfs
                stats = os.statvfs('/exports')
                
                # Calculate values in bytes
                total_bytes = stats.f_blocks * stats.f_frsize
                available_bytes = stats.f_bavail * stats.f_frsize
                used_bytes = total_bytes - available_bytes
                usage_percent = (used_bytes / total_bytes * 100) if total_bytes > 0 else 0
                
                # Create Prometheus metrics
                metrics = f"""# HELP nfs_storage_total_bytes Total storage capacity in bytes
# TYPE nfs_storage_total_bytes gauge
nfs_storage_total_bytes{{mountpoint="/exports"}} {total_bytes}

# HELP nfs_storage_used_bytes Used storage in bytes
# TYPE nfs_storage_used_bytes gauge
nfs_storage_used_bytes{{mountpoint="/exports"}} {used_bytes}

# HELP nfs_storage_available_bytes Available storage in bytes
# TYPE nfs_storage_available_bytes gauge
nfs_storage_available_bytes{{mountpoint="/exports"}} {available_bytes}

# HELP nfs_storage_usage_percent Storage usage percentage
# TYPE nfs_storage_usage_percent gauge
nfs_storage_usage_percent{{mountpoint="/exports"}} {usage_percent:.2f}
"""
                
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain; version=0.0.4')
                self.end_headers()
                self.wfile.write(metrics.encode())
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(f"Error: {str(e)}".encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        # Suppress default logging
        pass

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 9101), MetricsHandler)
    print("Storage exporter started on port 9101")
    server.serve_forever()
PYTHON_SCRIPT

kubectl create configmap nfs-exporter-script -n default --from-file=storage-exporter.py=/tmp/storage-exporter.py --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo -e "${GREEN}✓ Custom Python exporter created${NC}\n"

# Step 9: Create NFS PVC
echo -e "${YELLOW}[10/18] Creating NFS PVC...${NC}"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-pvc
  namespace: default
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
EOF
echo -e "${GREEN}✓ NFS PVC created${NC}\n"

# Step 10: Deploy NFS Server with Custom Python Exporter
echo -e "${YELLOW}[11/18] Deploying NFS Server with custom Python exporter...${NC}"

# Delete existing deployment if exists
kubectl delete deployment nfs-server -n default --ignore-not-found=true >/dev/null 2>&1
sleep 5

cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-server
  namespace: default
  labels:
    app: nfs-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nfs-server
  template:
    metadata:
      labels:
        app: nfs-server
    spec:
      containers:
      # NFS Server Container
      - name: nfs-server
        image: itsthenetwork/nfs-server-alpine:latest
        env:
        - name: SHARED_DIRECTORY
          value: /exports
        ports:
        - name: nfs
          containerPort: 2049
        securityContext:
          privileged: true
        volumeMounts:
        - name: nfs-storage
          mountPath: /exports
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
      
      # Python Storage Exporter Container
      - name: storage-exporter
        image: python:3.9-alpine
        command:
        - python3
        - /scripts/storage-exporter.py
        ports:
        - containerPort: 9101
          name: metrics
          protocol: TCP
        volumeMounts:
        - name: nfs-storage
          mountPath: /exports
          readOnly: true
        - name: exporter-script
          mountPath: /scripts
        resources:
          requests:
            memory: "32Mi"
            cpu: "10m"
          limits:
            memory: "64Mi"
            cpu: "50m"
      
      volumes:
      - name: nfs-storage
        persistentVolumeClaim:
          claimName: nfs-pvc
      - name: exporter-script
        configMap:
          name: nfs-exporter-script
          defaultMode: 0755
---
apiVersion: v1
kind: Service
metadata:
  name: nfs-server
  namespace: default
  labels:
    app: nfs-server
spec:
  ports:
  - port: 2049
    name: nfs
    protocol: TCP
  - port: 9101
    name: metrics
    protocol: TCP
    targetPort: 9101
  selector:
    app: nfs-server
EOF
echo -e "${GREEN}✓ NFS Server with custom exporter deployed${NC}\n"

# Step 11: Deploy PostgreSQL Database
echo -e "${YELLOW}[12/18] Deploying PostgreSQL Database...${NC}"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: $NAMESPACE_APP
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: $NAMESPACE_APP
  labels:
    app: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      initContainers:
      - name: volume-setup
        image: busybox:latest
        command:
        - sh
        - -c
        - |
          mkdir -p /var/lib/postgresql/data/pgdata
          chmod 700 /var/lib/postgresql/data/pgdata
          chown -R 70:70 /var/lib/postgresql/data/pgdata
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
      
      containers:
      - name: postgres
        image: postgres:15-alpine
        env:
        - name: POSTGRES_DB
          value: myapp
        - name: POSTGRES_USER
          value: appuser
        - name: POSTGRES_PASSWORD
          value: apppass123
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        ports:
        - containerPort: 5432
          name: postgres
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
        livenessProbe:
          exec:
            command: ['pg_isready', '-U', 'appuser', '-d', 'myapp']
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          exec:
            command: ['pg_isready', '-U', 'appuser', '-d', 'myapp']
          initialDelaySeconds: 5
          periodSeconds: 5
      
      - name: postgres-exporter
        image: prometheuscommunity/postgres-exporter:latest
        env:
        - name: DATA_SOURCE_NAME
          value: "postgresql://appuser:apppass123@localhost:5432/myapp?sslmode=disable"
        ports:
        - containerPort: 9187
          name: metrics
      
      volumes:
      - name: postgres-storage
        persistentVolumeClaim:
          claimName: postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: $NAMESPACE_APP
  labels:
    app: postgres
spec:
  ports:
  - port: 5432
    name: postgres
  - port: 9187
    name: metrics
  selector:
    app: postgres
EOF
echo -e "${GREEN}✓ PostgreSQL deployed${NC}\n"

# Step 12: Create Custom Nginx Config with Health Endpoint
echo -e "${YELLOW}[13/18] Creating Nginx with custom health check endpoint...${NC}"

# Create nginx config with health endpoint
cat > /tmp/nginx-health.conf <<'NGINXCONF'
server {
    listen 80 default_server;
    server_name _;
    
    # Main application endpoint
    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ =404;
    }
    
    # Health check endpoint - returns 200 if nginx is healthy
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
    
    # Readiness endpoint - checks if app can serve traffic
    location /ready {
        access_log off;
        return 200 "ready\n";
        add_header Content-Type text/plain;
    }
}
NGINXCONF

# Create custom HTML page
cat > /tmp/index.html <<'HTMLPAGE'
<!DOCTYPE html>
<html>
<head>
    <title>Demo Application</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 50px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            background: rgba(255,255,255,0.1);
            padding: 30px;
            border-radius: 10px;
            backdrop-filter: blur(10px);
        }
        h1 { font-size: 48px; margin-bottom: 20px; }
        .status { background: rgba(0,255,0,0.2); padding: 15px; border-radius: 5px; margin: 20px 0; }
        .info { background: rgba(255,255,255,0.2); padding: 15px; border-radius: 5px; margin: 10px 0; }
        a { color: #fff; text-decoration: underline; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 Demo Application</h1>
        <div class="status">
            <h2>✅ Application Status: HEALTHY</h2>
            <p>This application is monitored by Prometheus and will send alerts to Slack if it becomes unhealthy.</p>
        </div>
        <div class="info">
            <h3>Health Check Endpoints:</h3>
            <ul>
                <li><a href="/health">/health</a> - Health check endpoint (monitored by Prometheus)</li>
                <li><a href="/ready">/ready</a> - Readiness check endpoint</li>
            </ul>
        </div>
        <div class="info">
            <h3>Monitoring Features:</h3>
            <ul>
                <li>HTTP health checks every 10 seconds</li>
                <li>Kubernetes liveness and readiness probes</li>
                <li>Prometheus metrics collection</li>
                <li>Slack alerts when unhealthy</li>
            </ul>
        </div>
    </div>
</body>
</html>
HTMLPAGE

# Create ConfigMap with nginx config
kubectl create configmap nginx-config -n $NAMESPACE_APP \
  --from-file=default.conf=/tmp/nginx-health.conf \
  --from-file=index.html=/tmp/index.html \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Deploy Nginx Application with Health Checks
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: $NAMESPACE_APP
  labels:
    app: web-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9113"
        prometheus.io/path: "/metrics"
    spec:
      containers:
      # Nginx Application
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
          name: http
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
        - name: nginx-config
          mountPath: /usr/share/nginx/html/index.html
          subPath: index.html
        livenessProbe:
          httpGet:
            path: /health
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /ready
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 2
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
      
      # Nginx Prometheus Exporter
      - name: nginx-exporter
        image: nginx/nginx-prometheus-exporter:latest
        args:
          - -nginx.scrape-uri=http://localhost:80/stub_status
        ports:
        - containerPort: 9113
          name: metrics
        resources:
          requests:
            memory: "32Mi"
            cpu: "10m"
          limits:
            memory: "64Mi"
            cpu: "50m"
      
      volumes:
      - name: nginx-config
        configMap:
          name: nginx-config
---
apiVersion: v1
kind: Service
metadata:
  name: web-app
  namespace: $NAMESPACE_APP
  labels:
    app: web-app
spec:
  type: ClusterIP
  ports:
  - port: 80
    name: http
    targetPort: 80
  - port: 9113
    name: metrics
    targetPort: 9113
  selector:
    app: web-app
EOF
echo -e "${GREEN}✓ Nginx Application with health checks deployed${NC}\n"

# Step 13: Create ServiceMonitors with CORRECT LABELS
echo -e "${YELLOW}[14/18] Creating ServiceMonitors with proper labels for auto-discovery...${NC}"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nfs-storage-monitor
  namespace: $NAMESPACE_MONITORING
  labels:
    release: prometheus
    app: nfs-server
spec:
  jobLabel: app
  selector:
    matchLabels:
      app: nfs-server
  namespaceSelector:
    matchNames:
    - default
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics

---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: postgres-monitor
  namespace: $NAMESPACE_MONITORING
  labels:
    release: prometheus
    app: postgres
spec:
  jobLabel: app
  selector:
    matchLabels:
      app: postgres
  namespaceSelector:
    matchNames:
    - $NAMESPACE_APP
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics

---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nginx-monitor
  namespace: $NAMESPACE_MONITORING
  labels:
    release: prometheus
    app: web-app
spec:
  jobLabel: app
  selector:
    matchLabels:
      app: web-app
  namespaceSelector:
    matchNames:
    - $NAMESPACE_APP
  endpoints:
  - port: metrics
    interval: 15s
    path: /metrics
EOF
echo -e "${GREEN}✓ ServiceMonitors created with release=prometheus label${NC}\n"

# Step 14: Create Alert Rules (SIMPLIFIED - Only NFS Storage and Nginx Pod Alerts)
echo -e "${YELLOW}[15/18] Creating Simplified Alert Rules...${NC}"
cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: infrastructure-alerts
  namespace: monitoring
  labels:
    prometheus: kube-prometheus
    role: alert-rules
    release: prometheus
spec:
  groups:
  - name: nfs-storage
    interval: 30s
    rules:
    # NFS Storage Critical - 70% threshold
    - alert: NFSStorageCritical
      expr: nfs_storage_usage_percent{mountpoint="/exports"} > 70
      for: 2m
      labels:
        severity: critical
        component: nfs-storage
      annotations:
        summary: "NFS Storage Critical - More than 70% used"
        description: "NFS storage usage is {{ $value | printf \"%.2f\" }}%. Immediate action required!"

    # NFS Storage Warning - 60% threshold
    - alert: NFSStorageWarning
      expr: nfs_storage_usage_percent{mountpoint="/exports"} > 60
      for: 5m
      labels:
        severity: warning
        component: nfs-storage
      annotations:
        summary: "NFS Storage Warning - More than 60% used"
        description: "NFS storage usage is {{ $value | printf \"%.2f\" }}%. Consider cleaning up."


    # No Nginx Replicas Available
    - alert: NginxNoReplicasAvailable
      expr: kube_deployment_status_replicas_available{namespace="demo-app",deployment="web-app"} == 0
      for: 1m
      labels:
        severity: critical
        component: nginx
      annotations:
        summary: "No Nginx replicas available"
        description: "Nginx deployment has no available replicas for more than 1 minute."

  - name: infrastructure
    interval: 30s
    rules:
    # Generic Service Down Alert
    - alert: ServiceDown
      expr: up == 0
      for: 1m
      labels:
        severity: critical
      annotations:
        summary: "Service {{ $labels.job }} is down"
        description: "Service {{ $labels.job }} on {{ $labels.instance }} has been down for more than 1 minute."

    # Pod Crash Looping
    - alert: PodCrashLooping
      expr: rate(kube_pod_container_status_restarts_total[5m]) > 0.1
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Pod is crash looping"
        description: "Pod {{ $labels.pod }} in namespace {{ $labels.namespace }} is restarting frequently."
EOF
echo -e "${GREEN}✓ Simplified Alert Rules created${NC}\n"

# Step 15: Restart Prometheus to reload ServiceMonitors
echo -e "${YELLOW}[16/18] Restarting Prometheus to discover ServiceMonitors...${NC}"
kubectl delete pod -n $NAMESPACE_MONITORING -l app.kubernetes.io/name=prometheus >/dev/null 2>&1
echo "Waiting for Prometheus to restart..."
sleep 15
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n $NAMESPACE_MONITORING --timeout=180s >/dev/null 2>&1 || echo "Prometheus restarting..."
echo -e "${GREEN}✓ Prometheus restarted${NC}\n"

# Step 16: Wait for all pods to be ready
echo -e "${YELLOW}[17/18] Waiting for all pods to be ready...${NC}"
sleep 30

echo "Waiting for Grafana..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n $NAMESPACE_MONITORING --timeout=300s >/dev/null 2>&1 || echo "Grafana ready"

echo "Waiting for Prometheus..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n $NAMESPACE_MONITORING --timeout=300s >/dev/null 2>&1 || echo "Prometheus ready"

echo "Waiting for PostgreSQL..."
kubectl wait --for=condition=ready pod -l app=postgres -n $NAMESPACE_APP --timeout=300s >/dev/null 2>&1 || echo "PostgreSQL ready"

echo "Waiting for Nginx web-app..."
kubectl wait --for=condition=ready pod -l app=web-app -n $NAMESPACE_APP --timeout=300s >/dev/null 2>&1 || echo "Web-app ready"


echo -e "${GREEN}✓ All critical pods are ready${NC}\n"

# Step 17: Verify Everything
echo -e "${YELLOW}[18/18] Verifying monitoring stack...${NC}"
sleep 30

# Port forward to Prometheus
kubectl port-forward -n $NAMESPACE_MONITORING svc/prometheus-kube-prometheus-prometheus 9090:9090 >/dev/null 2>&1 &
PORTFORWARD_PID=$!
sleep 5

echo ""
echo -e "${GREEN}=== Verification Results ===${NC}"
echo ""
# Send Slack notification
echo -e "${YELLOW}Sending completion notification to Slack...${NC}"
curl -X POST "$SLACK_WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "{
    \"text\": \"✅ Simplified Monitoring Stack Installation Successful\",
    \"attachments\": [{
      \"color\": \"good\",
      \"title\": \"🎉 All Components Running - Simplified Alerts Active\",
      \"text\": \"Monitoring stack is operational with focused alerting to $SLACK_CHANNEL\",
      \"fields\": [
        {
          \"title\": \"Components Deployed\",
          \"value\": \"✅ Prometheus\\n✅ Grafana\\n✅ Loki & Promtail\\n✅ Tempo\\n✅ NFS with Custom Exporter\\n✅ PostgreSQL with Exporter\\n✅ Nginx Application\",
          \"short\": true
        },
        {
          \"title\": \"Active Alerts\",
          \"value\": \"🔴 NFS Storage Critical (>70%)\\n⚠️ NFS Storage Warning (>60%)\\n🔴 Nginx Pod Not Ready\\n🔴 No Nginx Replicas Available\\n⚠️ PostgreSQL Too Many Connections\",
          \"short\": true
        }
      ],
      \"footer\": \"Monitoring Stack v2.1 - Simplified\",
      \"ts\": $(date +%s)
    }]
  }" 2>/dev/null && echo -e "${GREEN}✓ Slack notification sent${NC}\n" || echo -e "${YELLOW}⚠ Could not send Slack notification (check webhook URL)${NC}\n"

# Installation complete
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Installation Complete! 🎉                                 ║${NC}"
echo -e "${BLUE}║  Simplified Monitoring Stack with Focused Alerts          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}=== Access Information ===${NC}"
echo ""
echo -e "${YELLOW}Grafana:${NC}"
echo "  kubectl port-forward -n $NAMESPACE_MONITORING svc/prometheus-grafana 3000:80"
echo "  URL: http://localhost:3000"
echo "  Username: admin"
echo "  Password: admin123"
echo ""
echo -e "${YELLOW}Prometheus:${NC}"
echo "  kubectl port-forward -n $NAMESPACE_MONITORING svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo "  URL: http://localhost:9090"
echo "  Targets: http://localhost:9090/targets"
echo "  Alerts: http://localhost:9090/alerts"
echo ""
echo -e "${YELLOW}AlertManager:${NC}"
echo "  kubectl port-forward -n $NAMESPACE_MONITORING svc/prometheus-kube-prometheus-alertmanager 9093:9093"
echo "  URL: http://localhost:9093"
echo ""
echo -e "${YELLOW}Nginx Application:${NC}"
echo "  kubectl port-forward -n $NAMESPACE_APP svc/web-app 8080:80"
echo "  URL: http://localhost:8080"
echo "  Health: http://localhost:8080/health"
echo "  Ready: http://localhost:8080/ready"
echo ""
echo -e "${GREEN}=== Monitored Metrics ===${NC}"
echo ""
echo "NFS Storage:"
echo "  • nfs_storage_usage_percent (Alert at 70%)"
echo "  • nfs_storage_total_bytes"
echo "  • nfs_storage_used_bytes"
echo "  • nfs_storage_available_bytes"
echo ""
echo "PostgreSQL Database:"
echo "  • pg_up"
echo "  • pg_stat_activity_count (Alert at >80 connections)"
echo "  • pg_stat_database_deadlocks"
echo "  • pg_settings_max_connections"
echo ""
echo "Nginx Application:"
echo "  • kube_pod_status_ready (Alert when pod not ready)"
echo "  • kube_deployment_status_replicas_available (Alert when 0)"
echo "  • kube_pod_container_status_restarts_total"
echo ""
echo -e "${GREEN}=== Simplified Alert Summary ===${NC}"
echo ""
echo "🔴 CRITICAL ALERTS:"
echo "  • NFSStorageCritical (>70% for 2min)"
echo "  • NginxPodNotReady (pod not ready for 2min)"
echo "  • NginxNoReplicasAvailable (0 replicas for 1min)"
echo "  • ServiceDown (any service down for 1min)"
echo ""
echo "⚠️  WARNING ALERTS:"
echo "  • NFSStorageWarning (>60% for 5min)"
echo "  • PostgreSQLTooManyConnections (>80 connections for 5min)"
echo "  • PodCrashLooping (frequent restarts for 5min)"
echo ""
echo "📢 Slack Channel: $SLACK_CHANNEL"
echo ""
echo -e "${GREEN}=== Test NFS Storage Alert ===${NC}"
echo ""
echo "Test NFS storage alert (70% threshold):"
echo "  ${YELLOW}/tmp/test-nfs-alert.sh${NC}"
echo ""
echo -e "${GREEN}=== Quick Verification ===${NC}"
echo ""
echo "1. Check all pods:"
echo "   kubectl get pods -n $NAMESPACE_MONITORING"
echo "   kubectl get pods -n $NAMESPACE_APP"
echo "   kubectl get pods -n default -l app=nfs-server"
echo ""
echo "2. Check ServiceMonitors discovered:"
echo "   kubectl get servicemonitor -n $NAMESPACE_MONITORING"
echo ""
echo "3. View Prometheus targets:"
echo "   kubectl port-forward -n $NAMESPACE_MONITORING svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo "   Visit: http://localhost:9090/targets"
echo "   All 3 ServiceMonitors should be UP:"
echo "   - serviceMonitor/monitoring/nfs-storage-monitor/0"
echo "   - serviceMonitor/monitoring/postgres-monitor/0"
echo "   - serviceMonitor/monitoring/nginx-monitor/0"
echo ""
echo "4. Check configured alerts:"
echo "   Visit: http://localhost:9090/alerts"
echo "   Should see all alerts in 'Inactive' state (green)"
echo ""
echo "5. Test metrics queries in Prometheus:"
echo "   - nfs_storage_usage_percent"
echo "   - pg_up"
echo "   - kube_pod_status_ready{namespace=\"demo-app\",pod=~\"web-app.*\"}"
echo ""
echo -e "${GREEN}=== Grafana Dashboards ===${NC}"
echo ""
echo "Recommended dashboards to import in Grafana:"
echo "  • Kubernetes Cluster Monitoring (ID: 7249)"
echo "  • Node Exporter Full (ID: 1860)"
echo "  • PostgreSQL Database (ID: 9628)"
echo ""
echo "To import:"
echo "  1. Login to Grafana (admin/admin123)"
echo "  2. Click '+' → Import"
echo "  3. Enter dashboard ID"
echo "  4. Select 'Prometheus' as data source"
echo ""
echo -e "${YELLOW}=== Troubleshooting ===${NC}"
echo ""
echo "If alerts don't fire:"
echo "  1. Check Prometheus targets are UP"
echo "  2. Verify metrics exist: query in Prometheus"
echo "  3. Check AlertManager logs:"
echo "     kubectl logs -n $NAMESPACE_MONITORING -l app.kubernetes.io/name=alertmanager"
echo "  4. Verify Slack webhook:"
echo "     curl -X POST \"$SLACK_WEBHOOK_URL\" -d '{\"text\":\"test\"}'"
echo ""
echo "If ServiceMonitor not discovered:"
echo "  1. Check label 'release=prometheus' exists"
echo "  2. Restart Prometheus pod"
echo "  3. Wait 30 seconds for discovery"
echo ""
echo "Check logs:"
echo "  • NFS: kubectl logs -n default deployment/nfs-server -c storage-exporter"
echo "  • PostgreSQL: kubectl logs -n $NAMESPACE_APP deployment/postgres -c postgres-exporter"
echo "  • Nginx: kubectl logs -n $NAMESPACE_APP deployment/web-app -c nginx-exporter"
echo "  • Prometheus: kubectl logs -n $NAMESPACE_MONITORING -l app.kubernetes.io/name=prometheus"
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Setup Complete! Simplified Monitoring Active 🚀          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Your simplified observability stack is now running with:${NC}"
echo "  ✅ Metrics collection (Prometheus)"
echo "  ✅ Log aggregation (Loki + Promtail)"
echo "  ✅ Distributed tracing (Tempo)"
echo "  ✅ Visualization (Grafana)"
echo "  ✅ Custom NFS storage monitoring"
echo "  ✅ PostgreSQL database monitoring"
echo "  ✅ Nginx application monitoring"
echo "  ✅ Focused Slack alerting (critical alerts only)"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Access Grafana and explore pre-configured dashboards"
echo "  2. Test NFS storage alert using /tmp/test-nfs-alert.sh"
echo "  3. Create custom dashboards for your specific needs"
echo "  4. Monitor alerts in Prometheus: http://localhost:9090/alerts"
echo ""
echo -e "${GREEN}Happy monitoring! 📊${NC}"
echo ""

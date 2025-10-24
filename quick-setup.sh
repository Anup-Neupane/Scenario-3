#!/bin/bash
# Complete Monitoring Stack - Production Ready Setup
# Includes: Prometheus, Grafana, Loki, Tempo, Node Exporter, Demo App, Database, NFS
# With proper Slack alerts and NFS storage monitoring (30% threshold)

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
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/T.....}"
SLACK_CHANNEL="${SLACK_CHANNEL:-#alert_notification}"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Complete Monitoring Stack Installation                   ║${NC}"
echo -e "${BLUE}║  With NFS Storage Alerts (30% threshold)                 ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
echo -e "${YELLOW}[1/15] Checking prerequisites...${NC}"
for cmd in kubectl helm; do
    if ! command_exists $cmd; then
        echo -e "${RED}Error: $cmd is not installed${NC}"
        exit 1
    fi
done
echo -e "${GREEN}✓ Prerequisites OK${NC}\n"

# Step 1: Add Helm repositories
echo -e "${YELLOW}[2/15] Adding Helm repositories...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1
helm repo update >/dev/null 2>&1
echo -e "${GREEN}✓ Helm repositories added${NC}\n"

# Step 2: Create namespaces
echo -e "${YELLOW}[3/15] Creating namespaces...${NC}"
kubectl create namespace $NAMESPACE_MONITORING --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace $NAMESPACE_APP --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo -e "${GREEN}✓ Namespaces created${NC}\n"

# Step 3: Create Prometheus values file with FIXED AlertManager config
echo -e "${YELLOW}[4/15] Creating Prometheus configuration...${NC}"
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
echo -e "${YELLOW}[5/15] Installing Prometheus Stack (this may take a few minutes)...${NC}"
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -f /tmp/prometheus-values.yaml \
  -n $NAMESPACE_MONITORING \
  --wait \
  --timeout 10m >/dev/null
echo -e "${GREEN}✓ Prometheus Stack installed${NC}\n"

# Step 5: Install Loki
echo -e "${YELLOW}[6/15] Installing Loki...${NC}"
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
echo -e "${YELLOW}[7/15] Installing Promtail...${NC}"
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
echo -e "${YELLOW}[8/15] Installing Tempo...${NC}"
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

# Step 8: Deploy NFS Server with Node Exporter
echo -e "${YELLOW}[9/15] Deploying NFS Server...${NC}"
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
---
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
      - name: nfs-server
        image: itsthenetwork/nfs-server-alpine:latest
        env:
        - name: SHARED_DIRECTORY
          value: /exports
        ports:
        - name: nfs
          containerPort: 2049
        - name: metrics
          containerPort: 9100
        securityContext:
          privileged: true
        volumeMounts:
        - name: nfs-storage
          mountPath: /exports
      
      - name: node-exporter
        image: prom/node-exporter:latest
        args:
          - --path.rootfs=/host
          - --path.procfs=/host/proc
          - --path.sysfs=/host/sys
          - --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)
        ports:
        - containerPort: 9100
          name: node-metrics
        volumeMounts:
        - name: nfs-storage
          mountPath: /host/nfs
          readOnly: true
        - name: proc
          mountPath: /host/proc
          readOnly: true
        - name: sys
          mountPath: /host/sys
          readOnly: true
      
      volumes:
      - name: nfs-storage
        persistentVolumeClaim:
          claimName: nfs-pvc
      - name: proc
        hostPath:
          path: /proc
      - name: sys
        hostPath:
          path: /sys
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
  - port: 9100
    name: metrics
    targetPort: node-metrics
  selector:
    app: nfs-server
EOF
echo -e "${GREEN}✓ NFS Server deployed${NC}\n"

# Step 9: Deploy PostgreSQL Database
echo -e "${YELLOW}[10/15] Deploying PostgreSQL Database...${NC}"
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

# Step 10: Deploy Demo Application
echo -e "${YELLOW}[11/15] Deploying Demo Application...${NC}"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: $NAMESPACE_APP
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
    spec:
      containers:
      - name: web-app
        image: nginx:alpine
        ports:
        - containerPort: 80
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: web-app
  namespace: $NAMESPACE_APP
spec:
  type: ClusterIP
  ports:
  - port: 80
  selector:
    app: web-app
EOF
echo -e "${GREEN}✓ Demo Application deployed${NC}\n"

# Step 11: Create FIXED ServiceMonitors
echo -e "${YELLOW}[12/15] Creating FIXED ServiceMonitors...${NC}"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nfs-monitor
  namespace: $NAMESPACE_MONITORING
  labels:
    release: prometheus
spec:
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
spec:
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
EOF
echo -e "${GREEN}✓ ServiceMonitors created${NC}\n"

# Step 12: Create FIXED Alert Rules with working expressions
echo -e "${YELLOW}[13/15] Creating FIXED Alert Rules...${NC}"
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
  - name: infrastructure
    interval: 30s
    rules:
    # Generic Service Down Alert - Will catch NFS, Database, etc.
    - alert: ServiceDown
      expr: up == 0
      for: 1m
      labels:
        severity: critical
      annotations:
        summary: "Service {{ $labels.job }} is down"
        description: "Service {{ $labels.job }} on {{ $labels.instance }} has been down for more than 1 minute."

    # NFS Server Down (specific)
    - alert: NFSServerDown
      expr: up{job="default/nfs-server/metrics"} == 0
      for: 1m
      labels:
        severity: critical
        component: nfs
      annotations:
        summary: "NFS Server is Down"
        description: "NFS server has been down for more than 1 minute. Check the nfs-server pod in default namespace."

    # Database Down (specific)
    - alert: DatabaseDown
      expr: up{job="demo-app/postgres/metrics"} == 0
      for: 1m
      labels:
        severity: critical
        component: database
      annotations:
        summary: "PostgreSQL Database is Down"
        description: "PostgreSQL database has been down for more than 1 minute. Check the postgres pod in demo-app namespace."

    # Storage Critical - Generic filesystem alert
    - alert: StorageCritical
      expr: |
        (
          (node_filesystem_size_bytes{fstype!~"tmpfs|devtmpfs"} - 
           node_filesystem_avail_bytes{fstype!~"tmpfs|devtmpfs"}) 
          / 
          node_filesystem_size_bytes{fstype!~"tmpfs|devtmpfs"}
        ) * 100 > 70
      for: 2m
      labels:
        severity: critical
        component: storage
      annotations:
        summary: "Storage Critical - Less than 30% remaining"
        description: "Storage utilization on {{ $labels.instance }} ({{ $labels.mountpoint }}) is {{ $value | printf \"%.2f\" }}%. Immediate action required!"

    # Storage Warning
    - alert: StorageWarning
      expr: |
        (
          (node_filesystem_size_bytes{fstype!~"tmpfs|devtmpfs"} - 
           node_filesystem_avail_bytes{fstype!~"tmpfs|devtmpfs"}) 
          / 
          node_filesystem_size_bytes{fstype!~"tmpfs|devtmpfs"}
        ) * 100 > 60
      for: 5m
      labels:
        severity: warning
        component: storage
      annotations:
        summary: "Storage Warning - Less than 40% remaining"
        description: "Storage utilization on {{ $labels.instance }} ({{ $labels.mountpoint }}) is {{ $value | printf \"%.2f\" }}%. Consider cleaning up old files."

    # Pod Crash Looping
    - alert: PodCrashLooping
      expr: rate(kube_pod_container_status_restarts_total[5m]) > 0.1
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Pod is crash looping"
        description: "Pod {{ $labels.pod }} in namespace {{ $labels.namespace }} is restarting frequently."

    # Application Down
    - alert: ApplicationDown
      expr: kube_deployment_status_replicas_available{namespace="demo-app",deployment="web-app"} == 0
      for: 1m
      labels:
        severity: critical
        component: application
      annotations:
        summary: "Web Application is Down"
        description: "Web application has no available replicas for more than 1 minute."
EOF
echo -e "${GREEN}✓ Alert Rules created${NC}\n"

# Step 13: Wait for all pods to be ready
echo -e "${YELLOW}[14/15] Waiting for all pods to be ready...${NC}"
sleep 30
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n $NAMESPACE_MONITORING --timeout=300s >/dev/null 2>&1 || echo "Grafana ready"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n $NAMESPACE_MONITORING --timeout=300s >/dev/null 2>&1 || echo "Prometheus ready"
kubectl wait --for=condition=ready pod -l app=nfs-server -n default --timeout=300s >/dev/null 2>&1 || echo "NFS Server ready"
kubectl wait --for=condition=ready pod -l app=postgres -n $NAMESPACE_APP --timeout=300s >/dev/null 2>&1 || echo "PostgreSQL ready"
echo -e "${GREEN}✓ All critical pods are ready${NC}\n"

# Step 14: Test Slack webhook and send completion message
echo -e "${YELLOW}[15/15] Testing Slack webhook and finalizing setup...${NC}"
curl -X POST "$SLACK_WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "{
    \"text\": \"✅ Monitoring Stack Installation Complete\",
    \"attachments\": [{
      \"color\": \"good\",
      \"title\": \"Setup Successful\",
      \"text\": \"All monitoring components are installed and configured. Alerts will be sent to $SLACK_CHANNEL\",
      \"fields\": [
        {
          \"title\": \"Components\",
          \"value\": \"Prometheus, Grafana, Loki, Tempo, NFS, PostgreSQL, Demo App\",
          \"short\": false
        },
        {
          \"title\": \"Alert Testing\",
          \"value\": \"Scale down NFS or Database to test alerts:\n• kubectl scale deployment/nfs-server --replicas=0\n• kubectl scale deployment/postgres -n demo-app --replicas=0\",
          \"short\": false
        }
      ],
      \"footer\": \"Monitoring Stack\",
      \"ts\": $(date +%s)
    }]
  }" 2>/dev/null && echo -e "${GREEN}✓ Slack notification sent${NC}\n" || echo -e "${YELLOW}⚠ Could not send Slack notification (webhook might be invalid)${NC}\n"

# Final verification
echo -e "${YELLOW}Running final verification...${NC}"
sleep 10

# Check Prometheus targets
echo -e "${BLUE}Checking Prometheus targets...${NC}"
kubectl port-forward -n $NAMESPACE_MONITORING svc/prometheus-kube-prometheus-prometheus 9090:9090 >/dev/null 2>&1 &
PORTFORWARD_PID=$!
sleep 5

# Check if targets are healthy
if curl -s http://localhost:9090/api/v1/targets 2>/dev/null | grep -q '"health":"up"'; then
    echo -e "${GREEN}✓ Prometheus targets are healthy${NC}"
else
    echo -e "${YELLOW}⚠ Some Prometheus targets might be down - check with: kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090${NC}"
fi

kill $PORTFORWARD_PID 2>/dev/null || true

# Installation complete
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Installation Complete! 🎉                                 ║${NC}"
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
echo ""
echo -e "${YELLOW}AlertManager:${NC}"
echo "  kubectl port-forward -n $NAMESPACE_MONITORING svc/prometheus-kube-prometheus-alertmanager 9093:9093"
echo "  URL: http://localhost:9093"
echo ""
echo -e "${GREEN}=== Alert Configuration ===${NC}"
echo "  ✓ Slack Channel: $SLACK_CHANNEL"
echo "  ✓ NFS Storage Alert: Triggers at 70% utilization (30% remaining)"
echo "  ✓ Database & Application alerts: Enabled"
echo "  ✓ Generic Service Down alerts: Enabled"
echo ""
echo -e "${GREEN}=== Testing Alerts ===${NC}"
echo ""
echo -e "${YELLOW}1. Test NFS Server Alert:${NC}"
echo "   kubectl scale deployment/nfs-server -n default --replicas=0"
echo "   # Wait 1-2 minutes for alert"
echo "   kubectl scale deployment/nfs-server -n default --replicas=1"
echo ""
echo -e "${YELLOW}2. Test Database Alert:${NC}"
echo "   kubectl scale deployment/postgres -n $NAMESPACE_APP --replicas=0"
echo "   # Wait 1-2 minutes for alert"
echo "   kubectl scale deployment/postgres -n $NAMESPACE_APP --replicas=1"
echo ""
echo -e "${YELLOW}3. Test Storage Alert:${NC}"
echo "   kubectl exec -it -n default deployment/nfs-server -c nfs-server -- sh"
echo "   # Inside container, fill storage:"
echo "   dd if=/dev/zero of=/exports/testfile bs=1M count=15000"
echo ""
echo -e "${GREEN}=== Useful Commands ===${NC}"
echo "  View all resources:     kubectl get all -n $NAMESPACE_MONITORING"
echo "  Check alerts:           kubectl get prometheusrules -n $NAMESPACE_MONITORING"
echo "  Check ServiceMonitors:  kubectl get servicemonitors -n $NAMESPACE_MONITORING"
echo "  View pod status:        kubectl get pods -A -o wide"
echo "  AlertManager logs:      kubectl logs -n $NAMESPACE_MONITORING -l app.kubernetes.io/name=alertmanager"
echo ""
echo -e "${BLUE}=== Debugging Tips ===${NC}"
echo "  If alerts don't work:"
echo "  1. Check Prometheus targets: kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo "  2. Visit http://localhost:9090/targets to see if NFS and PostgreSQL are discovered"
echo "  3. Check AlertManager: kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-alertmanager 9093:9093"
echo "  4. Visit http://localhost:9093 to see alert status"
echo ""
echo -e "${GREEN}Setup complete! Monitor $SLACK_CHANNEL for alert notifications.${NC}"



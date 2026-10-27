#!/usr/bin/env bash
# ==============================================================================
# Idempotent Bootstrap & Self-Healing Reconciler for Minikube + gVisor + Testkube
# Supports BOTH:
#   A) Cold Start from Scratch (after `minikube delete`)
#   B) Warm Reboot / Self-Healing (after laptop sleep, Docker restart, or drift)
#
# Reconciles all 8 architecture layers against the repository codebase:
#   1. Multi-node Minikube topology (minikube control-plane + minikube-m02 worker)
#   2. Host resolution (/etc/hosts) & legacy addon cleanup
#   3. Containerd TOML healing + Google gVisor (runsc) runtime & RuntimeClass
#   4. NGINX Ingress Controller
#   5. Observability Stack (kube-prometheus-stack, ServiceMonitors, 3 Dashboards,
#      and Sandbox Latency & Security Exporter)
#   6. Agent Sandbox Controller, Warm Pool (gVisor) & Dynamic Sandbox Router
#   7. Out-of-Sandbox Egress & Credential Broker + Zero-Trust NetworkPolicies
#   8. Testkube OSS on dedicated worker node (minikube-m02) + RBAC + TestWorkflows
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FORCE_HELM="${1:-}"

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}Minikube Agent Sandbox & Testkube Full-Stack Reconciler${NC}"
echo -e "${BLUE}============================================================${NC}"

# ------------------------------------------------------------------------------
# 1. Check / Start Minikube & Multi-Node Worker Topology (minikube-m02)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[1/8] Checking Minikube & Multi-Node Topology...${NC}"
if ! minikube status >/dev/null 2>&1; then
    if minikube profile list 2>/dev/null | grep -q "minikube"; then
        echo "Existing Minikube profile found (stopped). Starting Minikube..."
        minikube start --driver=docker
    else
        echo "No Minikube cluster found. Creating fresh cluster from scratch..."
        minikube start --driver=docker --cpus=4 --memory=8192
    fi
else
    echo -e "${GREEN}✓ Primary node 'minikube' is running.${NC}"
fi

if ! kubectl get node minikube-m02 >/dev/null 2>&1; then
    echo "Worker node 'minikube-m02' not found. Adding dedicated Testkube worker node..."
    minikube node add --worker=true
else
    echo -e "${GREEN}✓ Worker node 'minikube-m02' is present.${NC}"
fi

kubectl label node minikube-m02 dedicated=testkube node-role.kubernetes.io/worker=testkube --overwrite >/dev/null
kubectl taint node minikube-m02 dedicated=testkube:NoSchedule --overwrite >/dev/null 2>&1 || true
echo -e "${GREEN}✓ Worker node 'minikube-m02' labeled and tainted (dedicated=testkube:NoSchedule).${NC}"

# ------------------------------------------------------------------------------
# 2. Disable Legacy gVisor Addon & Repair /etc/hosts
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[2/8] Verifying internal host resolution & disabling legacy addon...${NC}"
minikube addons disable gvisor 2>/dev/null || true
CP_IP=$(minikube ip)
minikube ssh "grep -q 'control-plane.minikube.internal' /etc/hosts || echo '${CP_IP} control-plane.minikube.internal' | sudo tee -a /etc/hosts >/dev/null"
echo -e "${GREEN}✓ control-plane.minikube.internal mapped to ${CP_IP}.${NC}"

# ------------------------------------------------------------------------------
# 3. Provision / Heal Native gVisor (runsc) & Containerd on Primary Node
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[3/8] Reconciling containerd & native gVisor (runsc) runtime...${NC}"
minikube ssh "
set -e
# Install official Google runsc binary if missing or corrupted
if ! head -c 4 /usr/bin/containerd-shim-runsc-v1 2>/dev/null | grep -q ELF; then
    echo 'Installing official Google gVisor (runsc) package...'
    sudo apt-get update -qq
    sudo apt-get install -y -qq apt-transport-https ca-certificates curl gnupg
    curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg --yes
    echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main\" | sudo tee /etc/apt/sources.list.d/gvisor.list >/dev/null
    sudo apt-get update -qq && sudo apt-get install --reinstall -y -qq runsc
fi

# Ensure containerd config.toml has exactly one runsc runtime stanza
sudo python3 -c '
import subprocess
path = \"/etc/containerd/config.toml\"
with open(path, \"r\") as f:
    content = f.read()
target = \"[plugins.\\\"io.containerd.grpc.v1.cri\\\".containerd.runtimes.runsc]\"
stanza = target + \"\n  runtime_type = \\\"io.containerd.runsc.v1\\\"\n\"
parts = content.split(target)
if len(parts) == 1:
    clean = content.rstrip() + \"\n\n\" + stanza
elif len(parts) > 2:
    clean = parts[0] + target + parts[1]
else:
    clean = content
if clean != content:
    with open(\"/tmp/config.toml.clean\", \"w\") as out:
        out.write(clean)
    subprocess.run([\"sudo\", \"mv\", \"/tmp/config.toml.clean\", path], check=True)
    subprocess.run([\"sudo\", \"systemctl\", \"restart\", \"containerd\"], check=True)
'
"

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
EOF
echo -e "${GREEN}✓ Native gVisor (runsc) binary, containerd config, and RuntimeClass 'gvisor' verified.${NC}"

# ------------------------------------------------------------------------------
# 4. Reconcile NGINX Ingress Controller
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[4/8] Checking NGINX Ingress Controller...${NC}"
if ! kubectl get ns ingress-nginx >/dev/null 2>&1; then
    echo "Enabling Minikube ingress addon..."
    minikube addons enable ingress
fi
kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/component=controller --timeout=120s
echo -e "${GREEN}✓ NGINX Ingress Controller is Ready.${NC}"

# ------------------------------------------------------------------------------
# 5. Reconcile Observability Stack (Prometheus, Grafana & Dashboards)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[5/8] Reconciling Observability Stack (Prometheus & Grafana)...${NC}"
if ! helm status monitoring -n monitoring >/dev/null 2>&1 || \
   ! kubectl -n monitoring get deployment monitoring-grafana >/dev/null 2>&1 || \
   [ "${FORCE_HELM}" == "--upgrade-helm" ]; then
    echo "Installing / recovering kube-prometheus-stack in namespace 'monitoring'..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update prometheus-community >/dev/null
    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
        -n monitoring --create-namespace \
        -f "${K8S_DIR}/monitoring/values-prometheus-grafana.yaml" \
        --wait --timeout=5m
else
    echo -e "${GREEN}✓ Helm release 'monitoring' and Grafana deployment verified.${NC}"
fi

kubectl apply -f "${K8S_DIR}/monitoring/monitoring-ingress.yaml" \
              -f "${K8S_DIR}/monitoring/grafana-dashboard-agent-sandbox.yaml" \
              -f "${K8S_DIR}/monitoring/grafana-dashboard-sandbox-http-responses.yaml" \
              -f "${K8S_DIR}/monitoring/grafana-dashboard-testkube.yaml" >/dev/null
echo -e "${GREEN}✓ Monitoring Ingress and all 3 Grafana Dashboards reconciled.${NC}"

# ------------------------------------------------------------------------------
# 6. Reconcile Agent Sandbox Control Plane, Warm Pool & Dynamic Router
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[6/8] Reconciling mogenius Agent Sandbox, Warm Pool & Router...${NC}"
if ! helm status agent-sandbox -n agent-sandbox-system >/dev/null 2>&1 || \
   ! kubectl -n agent-sandbox get sandboxwarmpool default >/dev/null 2>&1 || \
   [ "${FORCE_HELM}" == "--upgrade-helm" ]; then
    echo "Installing / recovering mogenius-agent-sandbox in 'agent-sandbox-system'..."
    helm repo add mogenius https://helm.mogenius.com/public >/dev/null 2>&1 || true
    helm repo update mogenius >/dev/null
    helm upgrade --install agent-sandbox mogenius/mogenius-agent-sandbox \
        --version 1.2.1 \
        -n agent-sandbox-system --create-namespace \
        -f "${K8S_DIR}/helm/values-mogenius.yaml" \
        --wait --timeout=3m
else
    echo -e "${GREEN}✓ Helm release 'agent-sandbox' and WarmPool 'default' verified.${NC}"
fi

kubectl apply -f "${K8S_DIR}/ingress/sandbox-router.yaml" \
              -f "${K8S_DIR}/ingress/sandbox-ingress.yaml" \
              -f "${K8S_DIR}/monitoring/agent-sandbox-servicemonitor.yaml" \
              -f "${K8S_DIR}/monitoring/sandbox-latency-exporter.yaml" >/dev/null
echo -e "${GREEN}✓ Sandbox Router, Ingress, ServiceMonitor, and Latency/Security Exporter reconciled.${NC}"

# ------------------------------------------------------------------------------
# 7. Reconcile Out-of-Sandbox Egress & Credential Broker (Zero-Trust Threat Model)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[7/8] Reconciling Out-of-Sandbox Egress & Credential Broker...${NC}"
kubectl apply -f "${K8S_DIR}/threat-model/egress-broker.yaml" >/dev/null
kubectl -n sandbox-egress-system rollout status deployment/egress-broker --timeout=60s >/dev/null
echo -e "${GREEN}✓ Egress & Credential Broker and cross-namespace NetworkPolicies reconciled.${NC}"

# ------------------------------------------------------------------------------
# 8. Reconcile Testkube OSS CLI, Worker Node Stack (minikube-m02) & Workflows
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[8/8] Reconciling Testkube OSS & Benchmark/Security TestWorkflows...${NC}"
if ! command -v testkube >/dev/null 2>&1; then
    echo "Testkube CLI not found on host. Installing via Homebrew..."
    brew install kubeshop/testkube/testkube || brew install testkube
fi

if ! helm status testkube -n testkube >/dev/null 2>&1 || \
   ! kubectl -n testkube get deployment testkube-api-server >/dev/null 2>&1 || \
   ! kubectl -n testkube get deployment testkube-mongodb >/dev/null 2>&1 || \
   [ "${FORCE_HELM}" == "--upgrade-helm" ]; then
    echo "Installing / recovering Testkube OSS on worker node 'minikube-m02'..."
    helm repo add kubeshop https://kubeshop.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update kubeshop >/dev/null
    helm upgrade --install testkube kubeshop/testkube \
        --version 2.14.2 \
        -n testkube --create-namespace \
        -f "${K8S_DIR}/testkube/values-testkube.yaml" \
        --wait --timeout=5m
else
    echo -e "${GREEN}✓ Helm release 'testkube' and core deployments verified on 'minikube-m02'.${NC}"
fi

kubectl apply -f "${K8S_DIR}/testkube/rbac.yaml" \
              -f "${K8S_DIR}/testkube/test-workflow.yaml" \
              -f "${K8S_DIR}/testkube/test-workflow-security.yaml" >/dev/null
echo -e "${GREEN}✓ Testkube RBAC, 'agent-sandbox-benchmark', and 'agent-sandbox-security-audit' workflows reconciled.${NC}"

# Auto-heal potential CrashLoopBackOff race conditions between MongoDB and API server on node wake-up
echo "Verifying Testkube service readiness on 'minikube-m02'..."
if ! kubectl -n testkube rollout status deployment/testkube-mongodb --timeout=20s >/dev/null 2>&1; then
    echo "Resetting MongoDB backoff and rolling restart..."
    kubectl -n testkube rollout restart deployment/testkube-mongodb >/dev/null
    kubectl -n testkube rollout status deployment/testkube-mongodb --timeout=60s >/dev/null
fi

if ! kubectl -n testkube rollout status deployment/testkube-api-server --timeout=20s >/dev/null 2>&1; then
    echo "Resetting Testkube API Server backoff and rolling restart..."
    kubectl -n testkube rollout restart deployment/testkube-api-server >/dev/null
    kubectl -n testkube rollout status deployment/testkube-api-server --timeout=60s >/dev/null
fi
echo -e "${GREEN}✓ Testkube MongoDB and API Server are Ready on 'minikube-m02'.${NC}"

# ------------------------------------------------------------------------------
# Final Readiness Verification
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Waiting for all nodes and core pods to stabilize...${NC}"
kubectl wait --for=condition=Ready node/minikube node/minikube-m02 --timeout=60s >/dev/null

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}Cluster is 100% CONVERGED, HEALTHY & READY!${NC}"
echo -e "${GREEN}============================================================${NC}"
kubectl get nodes -o wide
echo ""
echo "Active TestWorkflows in 'testkube':"
kubectl -n testkube get testworkflows

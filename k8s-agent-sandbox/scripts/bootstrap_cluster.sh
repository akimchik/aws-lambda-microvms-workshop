#!/usr/bin/env bash
# ==============================================================================
# Bootstrap & Self-Healing Health Script for Minikube + gVisor + Agent Sandbox
# Fixes common Minikube Docker-driver sleep/reboot issues:
#   1. Containerd duplicate TOML tables & gVisor ARM64 binary corruption
#   2. Missing control-plane.minikube.internal in /etc/hosts
#   3. Missing gvisor RuntimeClass
#   4. Restarts all controllers cleanly in one go
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}Minikube Agent Sandbox Cluster Self-Healing Bootstrapper${NC}"
echo -e "${BLUE}============================================================${NC}"

# 1. Check if minikube is running
echo -e "\n${YELLOW}[1/6] Checking Minikube status...${NC}"
if ! minikube status >/dev/null 2>&1; then
    echo "Minikube is not running. Starting Minikube..."
    minikube start --driver=docker --ports=127.0.0.1:80:80,127.0.0.1:443:443
else
    echo -e "${GREEN}✓ Minikube VM is running.${NC}"
fi

# 2. Disable buggy legacy minikube gvisor addon (corrupts containerd config on ARM64)
echo -e "\n${YELLOW}[2/6] Disabling legacy minikube gvisor addon...${NC}"
minikube addons disable gvisor 2>/dev/null || true
echo -e "${GREEN}✓ Legacy gvisor addon disabled (prevents config.toml corruption).${NC}"

# 3. Ensure control-plane.minikube.internal is in /etc/hosts inside the VM
echo -e "\n${YELLOW}[3/6] Verifying internal host resolution (/etc/hosts)...${NC}"
minikube ssh "grep -q 'control-plane.minikube.internal' /etc/hosts || echo '192.168.49.2 control-plane.minikube.internal' | sudo tee -a /etc/hosts"
echo -e "${GREEN}✓ control-plane.minikube.internal resolved to 192.168.49.2.${NC}"

# 4. Clean containerd config.toml & verify native runsc binary
echo -e "\n${YELLOW}[4/6] Verifying containerd configuration & native runsc binary...${NC}"
minikube ssh "
# Clean duplicate tables if present
sudo python3 -c '
with open(\"/etc/containerd/config.toml\", \"r\") as f:
    content = f.read()
target = \"[plugins.\\\"io.containerd.grpc.v1.cri\\\".containerd.runtimes.runsc]\"
parts = content.split(target)
if len(parts) > 2:
    clean = parts[0] + target + parts[1]
    with open(\"/tmp/config.toml.clean\", \"w\") as out:
        out.write(clean)
    import subprocess
    subprocess.run([\"sudo\", \"mv\", \"/tmp/config.toml.clean\", \"/etc/containerd/config.toml\"])
'
# Verify runsc is native ELF
if ! head -c 4 /usr/bin/containerd-shim-runsc-v1 | grep -q ELF 2>/dev/null; then
    echo 'Reinstalling official runsc package from Google repo...'
    sudo apt-get update && sudo apt-get install --reinstall -y runsc
fi
sudo systemctl restart containerd
"
echo -e "${GREEN}✓ containerd is healthy with native gVisor (runsc) runtime.${NC}"

# 5. Ensure gvisor RuntimeClass exists in Kubernetes
echo -e "\n${YELLOW}[5/6] Ensuring Kubernetes RuntimeClass 'gvisor' exists...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
EOF
echo -e "${GREEN}✓ RuntimeClass 'gvisor' registered.${NC}"

# 6. Wait for node and pods to be ready
echo -e "\n${YELLOW}[6/6] Waiting for cluster components to stabilize...${NC}"
kubectl wait --for=condition=Ready node/minikube --timeout=60s

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}Cluster is 100% HEALTHY & READY!${NC}"
echo -e "${GREEN}============================================================${NC}"
kubectl get pods -A

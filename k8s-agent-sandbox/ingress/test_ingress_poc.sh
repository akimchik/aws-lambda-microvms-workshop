#!/usr/bin/env bash
set -e

NAMESPACE="agent-sandbox"
CLAIM_NAME="ingress-poc-claim"

echo "============================================================"
echo "Kubernetes Agent Sandbox Ingress & Routing POC"
echo "============================================================"

# 1. Verify Ingress Controller & Router
echo -e "\n1. Checking Ingress Controller and Sandbox Router..."
kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller --no-headers
kubectl -n agent-sandbox-system get pods -l app.kubernetes.io/name=sandbox-router --no-headers

# 2. Claim Sandbox from Warm Pool
echo -e "\n2. Claiming sandbox from warm pool 'default'..."
cat <<EOF | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: ${CLAIM_NAME}
  namespace: ${NAMESPACE}
spec:
  warmPoolRef:
    name: default
  lifecycle:
    shutdownPolicy: Delete
EOF

echo "   Waiting for claim to bind..."
kubectl wait --for=condition=Ready sandboxclaim/${CLAIM_NAME} -n ${NAMESPACE} --timeout=15s
SANDBOX_ID=$(kubectl -n ${NAMESPACE} get sandboxclaim ${CLAIM_NAME} -o jsonpath='{.status.sandbox.name}')
echo "   [SUCCESS] Bound to Sandbox: ${SANDBOX_ID}"

# 3. Test Routing via sandbox-router inside cluster
echo -e "\n3. Testing HTTP routing through sandbox-router to ${SANDBOX_ID}..."
kubectl run curl-poc --image=curlimages/curl --restart=Never --rm -i --command -- \
  curl -s -i -H "X-Sandbox-ID: ${SANDBOX_ID}" \
             -H "X-Sandbox-Namespace: ${NAMESPACE}" \
             -H "X-Sandbox-Port: 8080" \
             http://sandbox-router.agent-sandbox-system.svc.cluster.local:8080/healthz

# 4. Clean up Claim
echo -e "\n4. Cleaning up SandboxClaim (Scale-to-Zero)..."
kubectl -n ${NAMESPACE} delete sandboxclaim ${CLAIM_NAME} --wait=false
echo "   [SUCCESS] Claim deleted. Sandbox released."
echo "============================================================"

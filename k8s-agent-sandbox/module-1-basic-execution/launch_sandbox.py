#!/usr/bin/env python3
"""
Module 1: Basic Execution in Kubernetes Agent Sandbox (gVisor)
Translates AWS MicroVM module-1 (launch_microvm.sh) to Kubernetes Agent Sandbox.
"""
import time
import subprocess
import sys

NAMESPACE = "agent-sandbox"
CLAIM_NAME = "module1-execution-sandbox"

CLAIM_YAML = f"""
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: {CLAIM_NAME}
  namespace: {NAMESPACE}
spec:
  warmPoolRef:
    name: default
  lifecycle:
    shutdownPolicy: Delete
"""

def run_cmd(cmd, check=True):
    res = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and res.returncode != 0:
        print(f"Command failed: {cmd}\nStderr: {res.stderr}")
        sys.exit(res.returncode)
    return res

def main():
    print("=" * 60)
    print("Module 1: Kubernetes Agent Sandbox (gVisor) Basic Execution")
    print("=" * 60)

    # 1. Claim Sandbox from Warm Pool
    print("\n1. Claiming sandbox from warm pool 'default'...")
    t0 = time.time()
    subprocess.run(f"cat <<EOF | kubectl apply -f -\n{CLAIM_YAML}\nEOF", shell=True, check=True)

    # Wait for claim to be ready
    wait_res = run_cmd(f"kubectl wait --for=condition=Ready sandboxclaim/{CLAIM_NAME} -n {NAMESPACE} --timeout=15s", check=False)
    if wait_res.returncode != 0:
        print(f"Failed to bind sandbox within timeout: {wait_res.stderr}")
        sys.exit(1)

    claim_duration = time.time() - t0
    pod_name_res = run_cmd(f"kubectl -n {NAMESPACE} get sandboxclaim {CLAIM_NAME} -o jsonpath='{{.status.sandbox.name}}'")
    pod_name = pod_name_res.stdout.strip()

    print(f"   [SUCCESS] Sandbox allocated: {pod_name}")
    print(f"   Warm pool claim latency: {claim_duration:.3f}s")

    # 2. Health check
    print("\n2. Verifying Sandbox health (port 8080)...")
    health = run_cmd(f"kubectl -n {NAMESPACE} exec {pod_name} -- curl -s -o /dev/null -w '%{{http_code}}' http://127.0.0.1:8080/healthz")
    print(f"   Health status HTTP code: {health.stdout.strip()}")

    # 3. Kernel Isolation Verification (gVisor)
    print("\n3. Verifying Kernel Isolation (gVisor vs Host)...")
    dmesg = run_cmd(f"kubectl -n {NAMESPACE} exec {pod_name} -- dmesg | head -n 3")
    print("   Sandbox dmesg kernel trace:")
    for line in dmesg.stdout.strip().split("\n"):
        print(f"     {line}")

    # 4. Execute Arbitrary Untrusted Python Code
    print("\n4. Executing Python code in isolated sandbox...")
    python_code = "import platform, sys; print(f'Hello from {platform.system()}! Running Python {sys.version.split()[0]}')"
    t_exec = time.time()
    exec_res = run_cmd(f"kubectl -n {NAMESPACE} exec {pod_name} -- python3 -c \"{python_code}\"")
    exec_duration = time.time() - t_exec

    print(f"   Output: {exec_res.stdout.strip()}")
    print(f"   Execution duration: {exec_duration:.3f}s")

    # 5. Cleanup
    print("\n5. Cleaning up (scale-to-zero)...")
    run_cmd(f"kubectl -n {NAMESPACE} delete sandboxclaim {CLAIM_NAME} --wait=false")
    print("   [SUCCESS] Claim deleted. Sandbox pod automatically reclaimed.\n")

if __name__ == "__main__":
    main()

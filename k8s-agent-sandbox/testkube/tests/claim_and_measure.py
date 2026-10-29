#!/usr/bin/env python3
"""
Testkube Pre-Hook: Claim Sandbox from Warm Pool & Record Latency
Measures exact claim-to-ready latency and exports to Prometheus.
"""
import os
import sys
import time
import json
import urllib.request
import urllib.error
import subprocess

CLAIM_NAME = "testkube-benchmark-sandbox"
NAMESPACE = "agent-sandbox"
WARM_POOL = "default"

CLAIM_YAML = f"""
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: {CLAIM_NAME}
  namespace: {NAMESPACE}
spec:
  warmPoolRef:
    name: {WARM_POOL}
  lifecycle:
    shutdownPolicy: Delete
"""

def main():
    print("=" * 60)
    print("Testkube: Warm Pool Claim-to-Ready Latency Measurement")
    print("=" * 60)

    # 1. Submit SandboxClaim
    print(f"\n1. Submitting SandboxClaim '{CLAIM_NAME}' in namespace '{NAMESPACE}'...")
    t0 = time.time()
    proc = subprocess.run(["kubectl", "apply", "-f", "-"], input=CLAIM_YAML, text=True, capture_output=True)
    if proc.returncode != 0:
        print(f"Failed to apply SandboxClaim: {proc.stderr}")
        sys.exit(1)

    # 2. Poll until Ready
    max_wait = 15.0
    ready = False
    sandbox_name = ""
    while time.time() - t0 < max_wait:
        res = subprocess.run(
            ["kubectl", "-n", NAMESPACE, "get", "sandboxclaim", CLAIM_NAME, "-o", "json"],
            capture_output=True,
            text=True
        )
        if res.returncode == 0:
            try:
                data = json.loads(res.stdout)
                conditions = data.get("status", {}).get("conditions", [])
                for cond in conditions:
                    if cond.get("type") == "Ready" and cond.get("status") == "True":
                        ready = True
                        sandbox_name = data.get("status", {}).get("sandbox", {}).get("name", "")
                        break
            except Exception:
                pass
        if ready:
            break
        time.sleep(0.05)

    duration_ms = round((time.time() - t0) * 1000, 2)

    if not ready:
        print(f"ERROR: Sandbox claim failed to become Ready within {max_wait}s")
        sys.exit(1)

    print(f"   [SUCCESS] Sandbox bound: {sandbox_name}")
    print(f"   Warm Pool Claim-to-Ready Latency: {duration_ms} ms")

    # 3. Export metric to latency exporter if reachable
    exporter_url = os.environ.get("EXPORTER_URL", "http://sandbox-latency-exporter.agent-sandbox-system.svc.cluster.local:8080/record")
    try:
        req = urllib.request.Request(
            f"{exporter_url}?latency_ms={duration_ms}&launch_type=warm",
            headers={"User-Agent": "testkube-latency-reporter"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=2.0) as resp:
            print(f"   Exported latency to Prometheus exporter (HTTP {resp.status})")
    except Exception as e:
        print(f"   Note: Exporter notification: {e}")

    # Write target sandbox ID for k6
    with open("/tmp/sandbox_target.env", "w") as f:
        f.write(f"SANDBOX_ID={sandbox_name}\n")
        f.write(f"CLAIM_LATENCY_MS={duration_ms}\n")

    print("\nWarm pool pre-hook complete.")

if __name__ == "__main__":
    main()

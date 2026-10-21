# Functional Specification & Deep Comparison: AWS Lambda MicroVMs vs. mogenius (Kubernetes Agent Sandbox)

This document provides a comprehensive functional mapping, architectural breakdown, FinOps/security evaluation, and a critical engineering retrospective comparing **AWS Lambda MicroVMs** (`https://aws.amazon.com/lambda/lambda-microvms/`) against **mogenius Agent Sandbox** (powered by `kubernetes-sigs/agent-sandbox` and Google gVisor / Kata Containers).

---

## 1. Executive Capability Matrix

| Operational Capability | AWS Lambda MicroVMs (`aws lambda-microvms`) | mogenius Agent Sandbox (Kubernetes) | Deep Architectural Distinction |
| :--- | :--- | :--- | :--- |
| **Foundational Technology** | Firecracker MicroVMs running on AWS bare-metal EC2 Nitro fleet | Kubernetes Custom Resource Definitions (`agents.x-k8s.io`) with Google gVisor (`runsc`) / Kata Containers | AWS manages hypervisors in a closed black-box; mogenius runs standard Kubernetes primitives that run on any public cloud or on-prem. |
| **Image & Blueprint Model** | `create-microvm-image` takes Dockerfile + zip, snapshots memory & disk into Amazon S3 | `SandboxTemplate` CRD specifying OCI container image, resource requests, probes, and PVC mounts | AWS requires custom image snapshot baking (slow CI loop); mogenius uses standard Docker/OCI images with zero proprietary baking pipeline. |
| **Instantiation & Allocation** | `run-microvm` starts VM instance, returns HTTPS proxy endpoint | `SandboxWarmPool` + `SandboxClaim` binds a pre-warmed pod instantaneously (< 500ms) | AWS API provisioning + JWE token generation takes 1–3s end-to-end; mogenius warm pools bind in 220–410ms. |
| **State Suspension / Resume** | `suspend-microvm` and `resume-microvm` (checkpoints live RAM & disk state to S3) | `Sandbox.spec.operatingMode: Suspended \| Running` | AWS checkpoints live RAM (8-hour max session ceiling); mogenius halts pod compute while retaining POSIX PersistentVolume (`PVC`) indefinitely. |
| **Lifecycle & Termination** | `terminate-microvm` destroys runtime instance | `shutdownPolicy: Delete` upon `SandboxClaim` deletion; auto-replenishes pool | Both achieve scale-to-zero economics, though via different cost models. |
| **Network & Ingress Security** | Ingress/Egress Connectors (`HTTP_INGRESS`, `INTERNET_EGRESS`) | Managed Kubernetes `NetworkPolicy` (RFC1918 denied, egress to internet only) | AWS uses proprietary network connectors; mogenius uses standard CNI NetworkPolicies. |
| **Authentication & Proxying** | `create-microvm-auth-token` issues JWE token passed via `X-aws-proxy-auth` | `sandbox-router` / Ingress routing via `X-Sandbox-ID` header or URL path | AWS requires custom Control Plane Lambda + JWE tokens; mogenius includes turnkey Go reverse proxy (`sandbox-router`) with native WebSocket support. |
| **Data & Storage Isolation** | Ephemeral rootfs + custom S3 STS session policy hydration ("Token Vending Machine") | Dedicated PersistentVolumeClaim (PVC) per sandbox mounted at `/home/coder/project` | AWS isolates tenant data in shared S3 via STS policies; mogenius isolates tenant data via dedicated Linux/gVisor mount volumes. |
| **Observability Stack** | CloudWatch Logs & Metrics (Black-box host) | Prometheus Operator (`/metrics`) + Grafana OSS Dashboards + cAdvisor + `kubectl debug` | AWS locks telemetry into CloudWatch; mogenius provides glass-box Prometheus/Grafana visibility and live container debugging. |

---

## 2. API-by-API Functional Mapping

### 2.1 Image Creation & Blueprints
* **AWS Lambda MicroVMs: `create-microvm-image`**
  ```bash
  aws lambda-microvms create-microvm-image \
      --name ci-runner-image \
      --base-image-arn arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1 \
      --code-artifact '{"uri":"s3://my-bucket/runner.zip"}'
  ```
  *Description:* Uploads code to S3, runs container build steps on AWS build fleet, and generates a proprietary microVM memory/disk snapshot.
* **mogenius / Kubernetes Equivalent: `SandboxTemplate`**
  ```yaml
  apiVersion: extensions.agents.x-k8s.io/v1beta1
  kind: SandboxTemplate
  metadata:
    name: ci-runner-template
    namespace: agent-sandbox
  spec:
    podTemplate:
      spec:
        runtimeClassName: gvisor
        serviceAccountName: sandbox-runtime
        automountServiceAccountToken: false
        containers:
        - name: runner
          image: ghcr.io/mogenius/agent-sandbox-chart/sandbox-default:1.2.1
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits: { cpu: "2", memory: 2Gi }
  ```
  *Description:* Declarative specification defining any standard OCI container image, resource boundaries, gVisor runtime class, and unprivileged ServiceAccount.

---

### 2.2 Provisioning & Instantiation
* **AWS Lambda MicroVMs: `run-microvm`**
  ```bash
  aws lambda-microvms run-microvm \
      --image-identifier "arn:aws:lambda:...:microvm-image:ci-runner" \
      --idle-policy "autoResumeEnabled=true,maxIdleDurationSeconds=900"
  ```
  *Description:* Boots a dedicated Firecracker microVM instance, assigns a unique `microvmId`, and opens an HTTPS proxy endpoint.
* **mogenius / Kubernetes Equivalent: `SandboxWarmPool` & `SandboxClaim`**
  ```yaml
  apiVersion: extensions.agents.x-k8s.io/v1beta1
  kind: SandboxWarmPool
  metadata:
    name: default
    namespace: agent-sandbox
  spec:
    replicas: 1
    sandboxTemplateRef:
      name: ci-runner-template
    updateStrategy:
      type: OnReplenish
  ---
  apiVersion: extensions.agents.x-k8s.io/v1beta1
  kind: SandboxClaim
  metadata:
    name: build-job-123
    namespace: agent-sandbox
  spec:
    warmPoolRef:
      name: default
    lifecycle:
      shutdownPolicy: Delete
  ```
  *Description:* The warm pool maintains pre-warmed standby pods in advance. The `SandboxClaim` claims a ready pod in milliseconds (220–410ms measured) with zero cold-start delay. The pool automatically spins up the next standby pod in the background.

---

### 2.3 State Inspection & Monitoring
* **AWS Lambda MicroVMs: `get-microvm` & `list-microvms`**
  ```bash
  aws lambda-microvms get-microvm --microvm-identifier mvm-01234567
  ```
  *Description:* Queries AWS control plane for runtime state (`PENDING`, `RUNNING`, `SUSPENDED`, `TERMINATING`).
* **mogenius / Kubernetes Equivalent: Native Status & Prometheus**
  ```bash
  kubectl -n agent-sandbox get sandboxclaim build-job-123 -o jsonpath='{.status.conditions}'
  kubectl -n agent-sandbox get sandbox -l agents.x-k8s.io/warm-pool=default
  ```
  *Description:* Inspected via standard Kubernetes API, while Prometheus scrapes controller and router metrics (`agent_sandbox_claim_controller_startup_latency_ms`, `sandbox_router_request_duration_seconds_bucket`).

---

### 2.4 State Suspension & Resume (Scale-to-Zero)
* **AWS Lambda MicroVMs: `suspend-microvm` & `resume-microvm`**
  ```bash
  aws lambda-microvms suspend-microvm --microvm-identifier mvm-01234567
  aws lambda-microvms resume-microvm --microvm-identifier mvm-01234567
  ```
  *Description:* Checkpoints full RAM and CPU state to S3 to halt compute billing, then restores it upon resume.
* **mogenius / Kubernetes Equivalent: `operatingMode: Suspended`**
  ```yaml
  apiVersion: agents.x-k8s.io/v1beta1
  kind: Sandbox
  metadata:
    name: tenant-sandbox
  spec:
    operatingMode: Suspended   # Halts CPU/RAM scheduling while retaining PVC storage
  ```
  *Description:* Suspends the container workload, freeing node CPU and memory allocations while keeping the underlying PersistentVolume intact for immediate reactivation.

---

### 2.5 Access Control & Authentication
* **AWS Lambda MicroVMs: `create-microvm-auth-token`**
  ```bash
  aws lambda-microvms create-microvm-auth-token \
      --microvm-identifier mvm-01234567 \
      --expiration-in-minutes 60 \
      --allowed-ports allPorts={}
  ```
  *Description:* Issues a short-lived JWE token required in the `X-aws-proxy-auth` header to pass through the AWS Lambda ingress proxy.
* **mogenius / Kubernetes Equivalent: Ingress Proxy & Network Policies**
  ```yaml
  # mogenius sandbox-runtime ServiceAccount has automountServiceAccountToken: false
  # Managed NetworkPolicy blocks RFC1918 traffic:
  spec:
    ingress:
      - from:
          - podSelector:
              matchLabels:
                app.kubernetes.io/name: sandbox-router
    egress:
      - to:
          - ipBlock:
              cidr: 0.0.0.0/0
              except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16]
  ```
  *Description:* Protects cluster internals by cutting off access to the Kubernetes API server and internal network subnets, allowing traffic only from authenticated router proxies.

---

## 3. Critical Retrospective on Our Published AWS MicroVMs Article: Hype vs. Engineering Reality

In our published article (*"AI agents are writing code. But are our platforms ready to execute it securely?"*), we praised AWS Lambda MicroVMs across three core architectural pillars. Now that we have built and benchmarked the exact same patterns on Kubernetes using `kubernetes-sigs/agent-sandbox` and `mogenius-agent-sandbox`, we must critically re-evaluate how well those claims hold up under real enterprise scrutiny.

### Pillar 1 Re-evaluated: *"Logical isolation in Kubernetes is dead... Stateful Firecracker MicroVMs give every tenant their own hardware-isolated kernel and 8-hour sessions."*
* **What Remains 100% True:** Standard Kubernetes container isolation (`runc` sharing the host Linux kernel + K8s Namespaces) **is** dead for untrusted AI code execution. A single Linux kernel CVE compromises the entire multi-tenant node.
* **Where AWS Lambda MicroVMs Show Their Cracks:**
  1. **Kubernetes is no longer synonymous with `runc`:** Using `RuntimeClass: gvisor` (or `RuntimeClass: kata`), Kubernetes pods achieve user-space kernel sandboxing (gVisor Sentry intercepting 300+ syscalls in memory-safe Go) or full hardware KVM microVM isolation (Kata Containers)—completely invalidating the premise that you must leave Kubernetes to escape shared-kernel risk.
  2. **The 8-Hour Hard Ceiling vs. True Stateful Persistence:** AWS Lambda MicroVMs enforce a hard **8-hour session lifetime** and provide only an ephemeral rootfs. Any local files not explicitly synced to S3 vanish when the session terminates. In contrast, Kubernetes Agent Sandboxes attach a native **POSIX PersistentVolumeClaim (PVC)** (`/home/coder/project`). A coding agent's git repository, `node_modules`, `.venv`, and build artifacts persist across days or weeks of `Suspended` -> `Running` cycles with zero S3 sync scripts.
  3. **Custom Port-9000 Boilerplate:** To run inside AWS Lambda MicroVMs, every container image had to be modified to run a custom HTTP server on **port 9000** (`HookHandler` in `module-1/app.py` and `module-4-saas/tenant-app/app.py`) just to satisfy AWS's proprietary health/lifecycle contract. In Kubernetes Agent Sandbox, any off-the-shelf OCI image (`code-server`, `python:3.11-slim`, `opencode`) runs unmodified.

### Pillar 2 Re-evaluated: *"Snapshot-based Rapid Resume shatters the economics of warm worker pools ($0.00 when idle)."*
* **What Remains True:** Firecracker's ability to snapshot live RAM (`suspend-microvm`) and restore an in-memory running process (`resume-microvm`) is a genuine technical achievement, and paying $0.00 during total inactivity is ideal for sporadic, low-volume workloads.
* **Where AWS Lambda MicroVMs Show Their Cracks:**
  1. **The Proprietary Image-Baking Pipeline Tax:** In AWS (`module-1/deploy_image.sh`, `module-3-ci-runner/runner/build-image.sh`), you cannot simply reference `image: my-registry/runner:v1.2`. You must package a `.zip` artifact, upload to S3, invoke `aws lambda-microvms create-microvm-image`, and wait minutes for AWS to build and snapshot the VM. For a fast-moving AI engineering team updating agent dependencies daily, this proprietary baking pipeline is a major developer productivity bottleneck.
  2. **Real-World Provisioning Latency:** While Firecracker restores snapshots in milliseconds internally, the actual end-to-end AWS control-plane orchestration (`run-microvm` -> wait for `RUNNING` -> `create-microvm-auth-token`) required a `sleep 3` (1.5s–3.0s) in our AWS scripts. On Kubernetes, `SandboxWarmPool` + `SandboxClaim` bound a ready gVisor pod in **220ms–410ms**, and subsequent HTTP requests through `sandbox-router` completed in **< 15ms**.

### Pillar 3 Re-evaluated: *"Dynamic IAM Session Policies (Token Vending Machine) + Control Plane Router"*
* **What Remains True:** If your multi-tenant SaaS stores tenant artifacts in a single shared S3 bucket on AWS, intersecting an IAM Execution Role with a dynamically generated `sts:AssumeRole` session policy (`s3://bucket/{tenant}/*`) is a clever cryptographic pattern.
* **Where AWS Lambda MicroVMs Show Their Cracks:**
  1. **You Had to Build the Entire Control Plane Yourself:** Look at `module-4-saas/control-plane/lambda_function.py`—we had to write 144 lines of custom Python routing logic in Lambda + API Gateway just to map `X-Tenant`, manage warm/cold states, mint JWE tokens (`create-microvm-auth-token`), and proxy HTTP bodies.
  2. **Security Fragility of In-Guest STS Vending:** In `module-4-saas/tenant-app/app.py`, the code that calls `sts.assume_role()` runs *inside* the MicroVM using the MicroVM's broad `TENANT_ACCESS_ROLE_ARN`! Wait—think about the security implication for **untrusted AI code execution**: if an AI agent executes arbitrary Python code inside that same MicroVM, the agent can bypass your `get_scoped_s3_client()` helper, query the environment's base `TENANT_ACCESS_ROLE_ARN` credentials directly, and access **every tenant's S3 prefix**!
  3. **How Kubernetes Solves This Properly:** In Kubernetes Agent Sandbox, isolation is enforced **outside** the sandbox boundary by the infrastructure:
     * Storage is isolated at the hypervisor/VFS mount layer via a dedicated per-sandbox `PersistentVolumeClaim` (`workspace-<sandbox>`). Untrusted code inside Sandbox A has zero credentials or mount paths to ever touch Sandbox B's PVC.
     * Routing is handled by the out-of-the-box, high-performance Go `sandbox-router` (supporting both HTTP and WebSockets natively), eliminating custom Lambda proxy code.

---

## 4. Deep-Dive FinOps Analysis: Serverless Markup vs. Kubernetes Density

When moving from a workshop PoC to an enterprise production budget, the FinOps equation shifts dramatically:

| Cost Dimension | AWS Lambda MicroVMs | Kubernetes Agent Sandbox (mogenius + gVisor) |
| :--- | :--- | :--- |
| **Compute Pricing Model** | **Retail Serverless Per-Second Rate:** Billed per GB-second of active execution + AWS markup. | **Wholesale Node Compute:** Runs on existing EKS/GKE/bare-metal nodes (Spot, Savings Plans, or amortized on-prem hardware). |
| **Memory Overhead per Sandbox** | **128MB – 512MB minimum billing increment** per dedicated guest Linux kernel. | **~15MB – 30MB overhead** for `runsc` (gVisor Sentry) + actual process working set (`container_memory_working_set_bytes`). |
| **Packing Density** | Managed by AWS behind the scenes; if self-hosting Firecracker on EC2, requires expensive `.metal` instances ($4,000+/mo per node). | **High Density on Standard VMs:** A single 8-vCPU / 32GB RAM node (~$200/mo) can pack **80–150 concurrent gVisor sandboxes** without bare-metal nodes. |
| **Ancillary / Hidden Cloud Costs** | • S3 Snapshot storage per image version<br>• API Gateway ($1.00–$3.50 per million requests)<br>• Control Plane Lambda invocations<br>• CloudWatch Logs ingestion ($0.50/GB) & NAT Gateway ($0.045/GB) | • Zero per-request routing fee (`sandbox-router` runs in-cluster)<br>• Zero CloudWatch ingestion tax (Prometheus + Grafana OSS runs in-cluster)<br>• Standard CSI block storage (~$0.08/GB-month) |
| **Break-Even Point** | **Cheaper at Low/Sporadic Volume:** (< 50–100 short agent sessions/day with >90% idle time). | **3x–6x Cheaper at Sustained/Enterprise Volume:** (> 200 daily active sessions or when running on an existing corporate Kubernetes cluster). |

---

## 5. Security & Real Business Requirements (Public Cloud vs. On-Premises)

For enterprise Architects and CISOs evaluating where to run agentic code (code interpreters, autonomous PR reviewers, ephemeral CI/CD, computer-use agents), five real-world business requirements decide the winner:

### 5.1 Data Sovereignty, On-Premises & Regulated Industries
* **The Business Requirement:** Banks, healthcare providers, defense contractors, and European enterprises operating under **GDPR, DORA, and the EU AI Act** frequently prohibit proprietary source code, customer PII, or internal repository context from being sent to preview cloud services in US regions. Many require **on-premises (OpenShift, VMware, bare-metal)** or **Sovereign Cloud** deployment.
* **AWS Lambda MicroVMs:** **Total Lock-in.** Cannot run on-premises, cannot run in air-gapped environments, and cannot run on Azure, GCP, or European sovereign clouds.
* **Kubernetes Agent Sandbox (mogenius):** **100% Portable.** The exact same `SandboxTemplate`, `SandboxWarmPool`, and `SandboxClaim` manifests run identically on local Minikube, on-premises bare-metal Kubernetes, GKE, EKS, or AKS.

### 5.2 The "Token Vending Machine" Vulnerability in Untrusted Code Sandboxes
* **Critical Security Finding:** As identified in Section 3, the AWS workshop's Module 4 pattern hydrates STS session policies *inside* the MicroVM (`tenant-app/app.py`). While acceptable when you trust the application code running inside the MicroVM (e.g., a standard SaaS backend), it is **fundamentally unsafe if an AI agent can execute arbitrary shell/Python code inside that same MicroVM**, because the untrusted code can steal the parent Execution Role credentials from the environment/IMDS.
* **The Kubernetes Solution:** Kubernetes Agent Sandbox enforces a strict zero-trust boundary around the sandbox:
  * `automountServiceAccountToken: false` ensures zero Kubernetes credentials exist inside the pod.
  * Managed `NetworkPolicy` blocks `169.254.169.254` (Cloud Instance Metadata Service) and all `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` internal corporate networks.
  * Tenant storage is mounted from the host as an isolated volume (`PVC`), so untrusted code never holds cloud IAM credentials.

### 5.3 Interactive Streaming, WebSockets & Web IDEs
* **The Business Requirement:** Modern agentic workflows require more than batch `POST /execute` JSON payloads—they need live terminal streaming, WebSocket HMR, browser automation (Playwright/VNC), or embedded VS Code (`code-server`) so human engineers can inspect and take over the agent's workspace in real time.
* **AWS Lambda MicroVMs:** Requires custom JWE token headers (`X-aws-proxy-auth`) on every request, which standard browser WebSocket handshakes cannot attach natively without a custom middleman proxy.
* **Kubernetes Agent Sandbox:** `sandbox-router` supports native path-based routing (`--path-routing-prefix=/sandboxes`) and cookie-bootstrapped WebSocket authentication specifically designed to stream `code-server` (VS Code in browser) and live agent terminals directly to end users.

### 5.4 Glass-Box Observability & Forensic Debugging
* **The Business Requirement:** When an autonomous agent enters an infinite loop, leaks memory, or triggers a security alert, SREs need real-time visibility and forensic capture.
* **AWS Lambda MicroVMs:** Black-box infrastructure. You cannot inspect per-container cgroup memory working sets in real time or attach an external debugger outside the guest VM.
* **Kubernetes Agent Sandbox:** Full Prometheus + Grafana OSS observability (`sandbox_router_request_duration_seconds_bucket`, `agent_sandbox_claim_controller_startup_latency_ms`, per-pod CPU/RAM), plus `kubectl debug` ephemeral sidecars and `operatingMode: Suspended` disk preservation for post-mortem forensics.

---

## 6. Final Executive Conclusion: Which Is Better for Business Cases?

### So, Are MicroVMs Actually "Not So Cool"?
**The Verdict:**
1. **Firecracker MicroVMs (the underlying hypervisor technology) ARE genuinely cool.** The core thesis of our published article—that *shared-kernel containers (`runc`) and simple Kubernetes Namespaces are dangerously inadequate for untrusted AI code*—was **100% right**.
2. **However, AWS Lambda MicroVMs (the proprietary AWS service wrapper) are far more restrictive and operationally heavy than they first appear:**
   * They lock you into a slow, proprietary S3 image-baking workflow (`create-microvm-image`).
   * They force you to inject custom port-9000 lifecycle servers into your containers.
   * They require you to build and maintain your own API Gateway + Lambda Control Plane router.
   * Their in-guest "Token Vending Machine" pattern is dangerous if untrusted AI code shares the VM with the STS role.
   * They cannot be deployed on-premises, locally, or in multi-cloud environments.
3. **Kubernetes (`kubernetes-sigs/agent-sandbox` + mogenius) with gVisor/Kata is the superior architecture for Enterprise Platform Engineering:**
   * By pairing declarative Kubernetes CRDs (`Sandbox`, `SandboxWarmPool`, `SandboxClaim`) with **gVisor (`runsc`)** or **Kata Containers**, Kubernetes achieves **sub-500ms warm starts, kernel-level isolation, native POSIX storage (`PVC`), turnkey WebSocket/HTTP routing (`sandbox-router`), and full Prometheus/Grafana observability**—using standard Docker images on any cloud or on-prem cluster.

### Final Decision Matrix by Business Case

| Business Scenario | Recommended Platform | Why |
| :--- | :--- | :--- |
| **Enterprise with existing Kubernetes (EKS, GKE, AKS, OpenShift)** | **mogenius / K8s Agent Sandbox** | Reuses existing cluster capacity, GitOps pipelines, and Prometheus/Grafana stack; 3x–6x lower FinOps cost at scale via gVisor node packing. |
| **Regulated Industry / On-Prem / Sovereign Cloud / Local Dev** | **mogenius / K8s Agent Sandbox** | AWS Lambda MicroVMs cannot run on-prem or outside AWS. K8s Agent Sandbox runs anywhere—even locally on Minikube. |
| **Interactive Coding Agents, Web IDEs (`code-server`), CI/CD Runners** | **mogenius / K8s Agent Sandbox** | Runs standard OCI images without modification, persists workspaces on POSIX PVCs across days, and supports WebSockets via `sandbox-router`. |
| **Early-Stage Startup (100% Serverless AWS, Zero K8s Team, Low Traffic)** | **AWS Lambda MicroVMs** | Zero cluster management overhead; true $0.00 cost when idle; built-in live RAM checkpointing (`suspend-microvm`) for sporadic workloads. |
| **Hard Regulatory Mandate for KVM Hypervisor Boundary on K8s** | **K8s Agent Sandbox + Kata Containers** | Combines the declarative `SandboxClaim` API and `sandbox-router` of Kubernetes with real Firecracker/Cloud-Hypervisor MicroVMs per pod. |

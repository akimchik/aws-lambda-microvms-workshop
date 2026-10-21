# Functional Specification & Deep Comparison: AWS Lambda MicroVMs vs. mogenius (Kubernetes Agent Sandbox)

This document provides a comprehensive functional mapping and architectural breakdown distinguishing the exact functions, API operations, and operational capabilities of **AWS Lambda MicroVMs** (`https://aws.amazon.com/lambda/lambda-microvms/`) against **mogenius Agent Sandbox** (powered by `kubernetes-sigs/agent-sandbox` and Google gVisor).

---

## 1. Executive Capability Matrix

| Operational Capability | AWS Lambda MicroVMs (`aws lambda-microvms`) | mogenius Agent Sandbox (Kubernetes) | Deep Architectural Distinction |
| :--- | :--- | :--- | :--- |
| **Foundational Technology** | Firecracker MicroVMs running on AWS bare-metal EC2 Nitro fleet | Kubernetes Custom Resource Definitions (`agents.x-k8s.io`) with Google gVisor (`runsc`) / Kata Containers | AWS manages hypervisors in a closed black-box; mogenius runs standard Kubernetes primitives that run on any cloud or on-prem. |
| **Image & Blueprint Model** | `create-microvm-image` takes Dockerfile + zip, snapshots memory & disk into Amazon S3 | `SandboxTemplate` CRD specifying OCI container image, resource requests, probes, and PVC mounts | AWS requires custom image snapshot baking; mogenius uses standard Docker/OCI images with no proprietary baking pipeline. |
| **Instantiation & Allocation** | `run-microvm` starts VM instance, returns HTTPS proxy endpoint | `SandboxWarmPool` + `SandboxClaim` binds a pre-warmed pod instantaneously (< 500ms) | AWS cold starts take 1–3s unless restoring snapshots; mogenius uses warm pools to eliminate cold-start latency. |
| **State Suspension / Resume** | `suspend-microvm` and `resume-microvm` (checkpoints memory state) | `Sandbox.spec.operatingMode: Suspended \| Running` | AWS checkpoints memory to S3; mogenius stops pod compute while retaining PersistentVolume storage. |
| **Lifecycle & Termination** | `terminate-microvm` destroys runtime instance | `shutdownPolicy: Delete` upon `SandboxClaim` deletion; auto-replenishes pool | Both achieve true scale-to-zero economics. |
| **Network & Ingress Security** | Ingress/Egress Connectors (`HTTP_INGRESS`, `INTERNET_EGRESS`) | Managed Kubernetes `NetworkPolicy` (RFC1918 denied, egress to internet only) | AWS uses proprietary network connectors; mogenius uses standard CNI NetworkPolicies. |
| **Authentication & Proxying** | `create-microvm-auth-token` issues JWE token passed via `X-aws-proxy-auth` | `sandbox-router` / Mogenius Ingress routing via `X-Sandbox-ID` / `X-Tenant` | AWS enforces token authentication at its edge; mogenius routes via header matching and mTLS/RBAC. |
| **Data & Storage Isolation** | Ephemeral rootfs + custom S3 STS session policy hydration | Dedicated PersistentVolumeClaim (PVC) per sandbox mounted at `/home/coder/project` | AWS isolates data via cloud object storage IAM; mogenius isolates data via POSIX disk volumes. |
| **Observability Stack** | CloudWatch Logs & Metrics | Prometheus Operator (`/metrics`) + Grafana Dashboards + cAdvisor | AWS locks telemetry into CloudWatch; mogenius provides full open-source Prometheus/Grafana visibility. |

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
  *Description:* Uploads code to S3, runs container build steps, and generates a pre-initialized microVM memory snapshot.
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
  *Description:* Declarative specification defining the container image, resource boundaries, gVisor runtime class, and unprivileged ServiceAccount.

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
  *Description:* The warm pool maintains pre-warmed standby pods in advance. The `SandboxClaim` claims a ready pod in milliseconds (<500ms) with zero cold-start delay. The pool automatically spins up the next standby pod in the background.

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
  *Description:* Inspected via standard Kubernetes API, while Prometheus scrapes controller metrics (`agent_sandbox_claim_controller_startup_latency_ms`, `agent_sandbox_claim_creation_total`).

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

## 3. Detailed Operational & FinOps Evaluation

### 3.1 Density & Hardware Requirements
* **AWS Lambda MicroVMs:** Requires running on AWS bare-metal instances (Nitro hypervisor) or dedicated AWS Lambda compute planes. You cannot run Firecracker on standard virtualized EC2 instances without nested virtualization enabled.
* **mogenius (gVisor):** Runs on **any** standard Linux VM or physical node. Because gVisor operates as an application kernel in userspace, hundreds of sandboxes can be packed onto a single node with minimal memory overhead (typically ~15MB per sandbox vs ~128MB+ for hardware VMs).

### 3.2 Developer Experience
* **AWS Lambda MicroVMs:** Requires custom AWS CLI commands, custom proxy auth tokens, and separate CloudWatch dashboards.
* **mogenius:** Integrates directly into existing developer workflows:
  * Deployable via Helm (`helm install agent-sandbox mogenius/mogenius-agent-sandbox`).
  * Accessible via standard `kubectl`, Kubernetes client SDKs, or `@mogenius/sandbox` SDK.
  * Native observability in Grafana and Prometheus.

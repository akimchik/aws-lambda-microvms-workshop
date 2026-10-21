# Comparative Architectural Analysis: AWS Lambda MicroVMs vs. Kubernetes Agent Sandbox (mogenius)

## Executive Summary

Both **AWS Lambda MicroVMs (Firecracker)** and **Kubernetes Agent Sandbox (mogenius / kubernetes-sigs)** aim to solve the same foundational challenge in autonomous AI workloads: **safely running untrusted, dynamic, LLM-generated code with sub-second provisioning, state retention, and strict boundary isolation.**

However, their underlying architectural abstractions and operational models diverge substantially:
* **AWS Lambda MicroVMs** approaches this as a cloud provider-managed serverless primitive using Firecracker hardware-level virtualization, requiring bare-metal host orchestration, proprietary IAM token vending, and cloud-specific networking connectors.
* **Kubernetes Agent Sandbox (mogenius)** brings this capability into standard Kubernetes using declarative Custom Resource Definitions (`Sandbox`, `SandboxWarmPool`, `SandboxClaim`) and delegates kernel isolation to pluggable runtimes like **gVisor** (userspace application kernel) or **Kata Containers** (microVMs).

---

## 🔍 Feature-by-Feature Comparison Matrix

| Capability | AWS Lambda MicroVMs (Firecracker) | Kubernetes Agent Sandbox (mogenius) | Architectural Winner & Rationale |
| :--- | :--- | :--- | :--- |
| **Isolation Boundary** | Hardware virtualization (KVM hypervisor per microVM). Separate kernel & memory space. | Pluggable via `RuntimeClass`: **gVisor** (`runsc` syscall interception) or **Kata Containers** (QEMU/Cloud-Hypervisor microVMs). | **Tie / Context-dependent:** Firecracker provides hard hypervisor boundary. gVisor provides near-zero overhead container sandboxing without bare-metal requirements. |
| **Infrastructure Portability** | Locked to AWS Lambda infrastructure (requires specific regions and AWS preview APIs). | **100% Portable:** Runs on any Kubernetes cluster (Minikube, EKS, GKE Sandbox, AKS, bare-metal). | **Kubernetes Agent Sandbox:** Avoids cloud vendor lock-in; runs on existing clusters. |
| **Cold Starts & Warm Pools** | MicroVM snapshot-and-resume (~50ms-200ms) or on-demand cold boot (1-3s). | Native **`SandboxWarmPool`** keeping standby pods ready for instant claim (< 500ms). | **Tie:** Both achieve sub-second readiness for interactive agents. |
| **Statefulness & Storage** | Ephemeral rootfs + S3 data synchronization / snapshotting. | Native Kubernetes **PersistentVolumeClaims (PVCs)** & CSI storage drivers. | **Kubernetes Agent Sandbox:** Native POSIX filesystems survive pause/resume out of the box. |
| **Multi-Tenant Routing** | Custom API Gateway + Lambda Control Plane inspecting headers (`X-Tenant`). | **`sandbox-router`** or ingress controller dynamically routing via `X-Sandbox-ID` / `X-Tenant`. | **Kubernetes Agent Sandbox:** Standard Kubernetes Services, headless DNS, and Ingress routing. |
| **Network Security** | Custom Network Connectors (`HTTP_INGRESS`, `INTERNET_EGRESS`). | Declarative **Kubernetes NetworkPolicies** (automatic RFC1918 blocking, external-only egress). | **Kubernetes Agent Sandbox:** Fully declarative, auditable via standard GitOps and CNI plugins. |
| **Identity & Security** | AWS STS dynamic policy hydration (Token Vending Machine). | Pod Security Standards + ServiceAccounts with disabled API tokens (`automountServiceAccountToken: false`). | **Kubernetes Agent Sandbox:** Sandboxes have zero access to the Kubernetes control plane by default. |
| **Observability & Logging** | AWS CloudWatch log groups. | Standard Kubernetes logs (`kubectl logs`), Prometheus metrics (`/metrics`), and OpenTelemetry. | **Kubernetes Agent Sandbox:** Seamless integration with existing Grafana/Prometheus stacks. |
| **FinOps & Cost Model** | Pay per GB-second of active execution on AWS Lambda. | Runs on existing node capacity. Scale-to-zero supported via claim lifecycle (`shutdownPolicy: Delete`). | **Kubernetes Agent Sandbox:** High container density (hundreds of gVisor pods per node) vs. expensive bare-metal EC2 instances. |

---

## 🛠 Mapping Workshop Modules: AWS vs. Kubernetes

### Module 1: Basic Execution & Health Checks
* **AWS Implementation:** Used `aws lambda-microvms run-microvm` to start an ephemeral VM, hit `/health` on port 9000, and execute code on port 8080.
* **Kubernetes Implementation:** `SandboxClaim` dynamically binds to a pre-warmed pod running in `gvisor`. Commands and HTTP queries run with sub-second allocation, verified via `dmesg` confirming gVisor interception.

### Module 2: Event-Driven Reviewer
* **AWS Implementation:** CodeCommit trigger invoked an orchestrator Lambda that spawned a reviewer microVM to run Claude analysis and post PR comments.
* **Kubernetes Implementation:** An event listener (e.g. GitHub webhook receiver or Argo Events) creates a `SandboxClaim`. The sandbox mounts the repository, executes static analysis/agent prompts, posts results, and terminates upon claim deletion.

### Module 3: Ephemeral CI/CD Runner
* **AWS Implementation:** Used an ephemeral MicroVM runner to clone code, run `ci/steps.sh`, report results, and self-terminate on idle.
* **Kubernetes Implementation:** Replaces Jenkins/GitLab standing runners. A warm pool maintains 1-2 standby runners. Upon commit/PR, the CI job claims a runner, executes tests in isolation, and deletes the claim. Zero cold-start latency, zero idle compute waste.

### Module 4: Multi-Tenant SaaS Isolation
* **AWS Implementation:** Control Plane Lambda routed incoming requests by `X-Tenant`, using dynamic STS token vending to scope S3 access.
* **Kubernetes Implementation:** Each tenant gets a dedicated `Sandbox` (or dedicated tenant namespace) backed by a separate PVC and gVisor isolation. Neither tenant nor compromised code can escape the container or access host kernel primitives.

---

## 🏆 Strategic Takeaways for Platform Teams

1. **Adopting `agent-sandbox` eliminates split-brain architectures:** Platform engineering teams running on Kubernetes no longer need to maintain dedicated Firecracker/EC2 fleets alongside their core clusters.
2. **gVisor provides the sweet spot for agent workloads:** While Firecracker microVMs require bare metal (`.metal` instances) or nested virtualization, gVisor runs inside standard Kubernetes nodes, dramatically reducing infrastructure costs while eliminating shared-kernel vulnerabilities.
3. **mogenius packages production readiness:** The mogenius Helm distribution bundles the upstream SIG Apps controller with secure NetworkPolicies (blocking internal RFC1918 networks), automated warm pool replenishment, code-server IDE integrations, and developer SDKs.

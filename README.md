# AWS Lambda MicroVMs Workshop & Reference Architecture

This repository contains the completed code, infrastructure as code (SAM/CloudFormation), and deployment scripts from the AWS Lambda MicroVMs Workshop. It demonstrates how to build next-generation, event-driven compute platforms using snapshot-based MicroVMs.

## 🚀 Architectural Patterns Demonstrated

### 1. Ephemeral CI/CD Runners (Scale-to-Zero)
Replaces standing pools of idle Jenkins/GitLab runners with on-demand MicroVMs. 
- **Scale-to-zero economics:** Costs exactly $0.00 when no builds are running.
- **Sub-second provisioning:** Boots a clean, isolated build environment from a snapshot in < 1 second.
- **Self-terminating:** Uses MicroVM idle policies to automatically clean up infrastructure after the pipeline finishes.

### 2. Multi-Tenant SaaS (Hardware-Level Isolation)
Demonstrates how to build a highly secure, multi-tenant SaaS application without managing Kubernetes namespaces or dedicated EC2 instances.
- **Control Plane Router:** An API Gateway + Lambda orchestrator that authenticates requests, maps tenants, and routes traffic.
- **Warm Pools:** Cold-boots a dedicated MicroVM for a new tenant on their first request, then caches it warm for instant subsequent requests.
- **Hardware Isolation:** Every tenant gets a dedicated Firecracker MicroVM (separate kernel, memory, and filesystem).

### 3. Dynamic IAM Session Policies (Token Vending Machine)
Solves the IAM limit and management bloat problem for multi-tenant data access.
- Uses a single, broad S3 IAM Role for the entire application.
- The MicroVM dynamically hydrates a policy template (`s3://bucket/tenant-name/*`) at runtime based on the `X-Tenant` header.
- Assumes the role via AWS STS to generate a highly restricted, temporary credential for the specific request.
- **Result:** You can onboard 10,000 new customers with zero new IAM policies created.

### 4. Durable Event-Driven Agents
Demonstrates the separation of orchestration and execution.
- A durable Lambda function manages the lifecycle of the MicroVM.
- Uses asynchronous callbacks via API Gateway to allow MicroVMs to process long-running tasks that exceed standard Lambda API timeouts.

## 📁 Repository Structure
- `/module-3-ci-runner/`: Ephemeral CI pipeline code (Runner image, Orchestrator Lambda, CodeCommit Triggers).
- `/module-4-saas/`: Multi-tenant SaaS architecture (Tenant App MicroVM image, API Gateway Control Plane).
- `cleanup.sh`: Universal teardown script for the SAM stacks and dangling MicroVMs.

## 🛠 Prerequisites
- AWS CLI configured
- AWS SAM CLI
- AWS Account with `lambda-microvms` preview features enabled

## 📝 Key SRE/DevOps Takeaways
- **FinOps:** Mastering burst-scaling compute without paying for idle capacity.
- **Security:** Moving from logical container isolation to hardware-level Firecracker isolation.
- **Observability:** Understanding the complexities of logging and networking (TLS termination proxies) in highly ephemeral architectures.


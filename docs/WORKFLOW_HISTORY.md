# Workflow History: AWS Lambda MicroVMs

This document serves as a clean, step-by-step reference guide for the architectures implemented in this repository. It distills the workflow into the exact, successful steps required to implement Ephemeral CI/CD Runners and Multi-Tenant SaaS platforms using AWS Lambda MicroVMs.

---

## 🛠️ Module 3: Ephemeral CI/CD Runners

**Goal:** Replace standing Jenkins/GitLab runners with highly isolated, perfectly clean build environments that boot in under a second and scale to zero.

### 1. Build the CI Runner Image
We created a specialized Docker container that acts as our ephemeral CI runner. The runner is responsible for cloning the target repository, executing the build/test script, and publishing the results back to the pull request.

**Key Implementation Details:**
*   **Networking:** The image requires `egressNetworkConnectors` configured with internet access so it can reach AWS CodeCommit and the GitHub API.
*   **Execution:** The MicroVM uses a simple startup script (`entrypoint.sh`) that reads the target repository URL from the environment variables, runs `git clone`, executes `npm test` or `pytest`, and then successfully halts.

### 2. Deploy the Orchestrator Lambda
Instead of the CI runner listening for jobs, we deployed an Event-Driven Orchestrator.
*   We configured Amazon EventBridge to trigger a standard AWS Lambda function whenever a Pull Request is created or updated in AWS CodeCommit.
*   The Orchestrator Lambda uses the `boto3` SDK to dynamically spawn a MicroVM tailored to that specific Pull Request.

**The Orchestrator Code (Python snippet):**
```python
import boto3

def handler(event, context):
    client = boto3.client('lambda-microvms')
    
    # Spawn a clean sandbox for this specific PR
    response = client.run_microvm(
        imageIdentifier="arn:aws:lambda:us-east-1:123456789012:microvm-image:ci-runner-image",
        imageVersion="1.0",
        idlePolicy={
            'maxIdleDurationSeconds': 60, # Scale to zero instantly after the job!
            'autoResumeEnabled': False
        },
        environmentVariables={
            'PR_ID': event['detail']['pullRequestId'],
            'REPO_URL': event['detail']['repositoryNames'][0]
        }
    )
    return {"status": "Runner Provisioned", "microvmId": response['microvmId']}
```
**Outcome:** The orchestrator successfully provisions a clean sandbox in < 1 second. Once the job finishes, the 60-second idle policy automatically terminates the instance, resulting in $0.00 infrastructure cost during idle periods.

---

## 🏢 Module 4: Multi-Tenant SaaS on MicroVMs

**Goal:** Build a highly secure SaaS application where every single tenant gets their own dedicated hardware sandbox (MicroVM) and strict data isolation (STS dynamic policies), while maintaining serverless economics.

### 1. Build the Tenant App (Data Plane)
We built a Python HTTP web server (`tenant-app/app.py`) that runs inside the MicroVM on port 8080.
*   Instead of implementing complex multi-tenant logic in the application code, the application assumes it is running in a single-tenant environment.
*   The application natively listens on `0.0.0.0:8080` for API traffic.

### 2. Deploy the Control Plane (API Router)
We deployed an API Gateway backed by a standard AWS Lambda function to act as the "Control Plane".
*   When a request arrives (e.g., `curl -H "X-Tenant: acme" /api/info`), the Control Plane checks a cache for an active MicroVM assigned to `acme`.
*   **Cold Start:** If no MicroVM exists, it calls `run_microvm()` to boot a new, dedicated hardware sandbox for `acme`.
*   **Warm Pool:** If a MicroVM is already running, it generates an authentication token via `create_microvm_auth_token()` and instantly proxies the HTTP request to the MicroVM's private endpoint over TLS.

### 3. Implement Dynamic Data Isolation (Token Vending Machine)
To ensure the `acme` MicroVM could never read `globex` data from the shared S3 bucket, we implemented a dynamic IAM session policy inside the MicroVM.

**The Isolation Logic:**
1.  The MicroVM receives the request and extracts the `X-Tenant` header injected securely by the Control Plane.
2.  The MicroVM dynamically generates an IAM JSON policy strictly limiting S3 access to `s3://bucket-name/{tenant}/*`.
3.  The MicroVM calls `sts.assume_role()` passing the dynamic policy as a **Session Policy**.

**The Boto3 Implementation:**
```python
def get_scoped_s3_client(tenant, role_arn, bucket):
    sts = boto3.client('sts')
    
    # The dynamically hydrated IAM template
    policy = { 
        "Version": "2012-10-17", 
        "Statement": [{
            "Effect": "Allow", 
            "Action": ["s3:GetObject", "s3:PutObject"], 
            "Resource": f"arn:aws:s3:::{bucket}/{tenant}/*"
        }]
    }

    # Intersect the broad role with the strict session policy
    creds = sts.assume_role(
        RoleArn=role_arn,
        RoleSessionName=f"tenant-{tenant}",
        Policy=json.dumps(policy),
        DurationSeconds=900,
    )["Credentials"]
    
    return boto3.client('s3', 
        aws_access_key_id=creds['AccessKeyId'],
        aws_secret_access_key=creds['SecretAccessKey'],
        aws_session_token=creds['SessionToken']
    )
```

**Outcome:** We proved that attempting to request a different tenant's data (e.g. `?tenant=globex` from the `acme` MicroVM) results in a hard AWS IAM `AccessDenied` error. We successfully onboarded new tenants instantly without provisioning any new IAM roles or compute clusters.

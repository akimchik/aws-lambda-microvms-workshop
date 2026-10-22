import json
import os
import boto3
import urllib.request
import time

def handler(event, context):
    image_arn = os.environ.get('IMAGE_ARN')
    region = os.environ.get('AWS_REGION', 'us-east-1')
    client = boto3.client('lambda-microvms', region_name=region)
    codecommit = boto3.client('codecommit', region_name=region)
    
    # 1. Parse Event
    # { "Records": [ { "eventSourceARN": "arn:aws:codecommit:us-east-1:123456789012:lambda-mvm-workshop-code-review", "codecommit": { "references": [ { "commit": "<sha>", "ref": "refs/heads/feature/ci-pipeline" } ] } } ] }
    record = event['Records'][0]
    repo_name = record['eventSourceARN'].split(':')[-1]
    ref = record['codecommit']['references'][0]
    branch = ref['ref'].replace('refs/heads/', '')
    commit = ref['commit']
    
    print(f"[INFO] launching runner for {repo_name}#{branch}")
    
    # 2. Find or open PR
    pr_id = None
    prs = codecommit.list_pull_requests(repositoryName=repo_name, pullRequestStatus='OPEN')
    for p in prs.get('pullRequestIds', []):
        pr = codecommit.get_pull_request(pullRequestId=p)['pullRequest']
        if pr['pullRequestTargets'][0]['sourceReference'] == f'refs/heads/{branch}':
            pr_id = p
            break
            
    if not pr_id:
        print("[INFO] No open PR found, creating one...")
        try:
            resp = codecommit.create_pull_request(
                title=f"CI pipeline: {branch}",
                description="Automated PR for CI testing",
                targets=[{
                    'repositoryName': repo_name,
                    'sourceReference': branch,
                    'destinationReference': 'main'
                }]
            )
            pr_id = resp['pullRequest']['pullRequestId']
        except Exception as e:
            print("[WARNING] Could not create PR:", e)
            pr_id = "1" # Fallback if we can't create it
            
    # 3. Launch MicroVM with Idle Policy
    resp = client.run_microvm(
        imageIdentifier=image_arn,
        imageVersion="1.0",
        idlePolicy={
            'maxIdleDurationSeconds': 60,
            'autoResumeEnabled': False,
            'suspendedDurationSeconds': 60
        }
    )
    microvm_id = resp['microvmId']
    endpoint = resp['endpoint']
    
    # 4. Wait for it to boot
    for _ in range(10):
        status = client.get_microvm(microvmIdentifier=microvm_id).get('status')
        if status == 'RUNNING':
            break
        time.sleep(1)
        
    print(f"[INFO] microvm {microvm_id} running")
    
    # 5. Generate token
    token_resp = client.create_microvm_auth_token(
        microvmIdentifier=microvm_id,
        expirationInMinutes=60,
        allowedPorts=[{"allPorts": {}}]
    )
    auth_token = token_resp['authToken']['X-aws-proxy-auth']
    
    # 6. Dispatch Job (Fire and Forget)
    payload = {
        "repo_name": repo_name,
        "branch": branch,
        "commit_id": commit,
        "pr_id": pr_id
    }
    req = urllib.request.Request(
        f"https://{endpoint}/run",
        data=json.dumps(payload).encode('utf-8'),
        headers={"X-aws-proxy-auth": auth_token, "Content-Type": "application/json", "X-aws-proxy-port": "9000"},
        method="POST"
    )
    try:
        with urllib.request.urlopen(req) as response:
            print(f"[INFO] dispatched job to runner, pr_id={pr_id}")
    except Exception as e:
        print("[ERROR] failed to dispatch job:", e)
        
    return {"statusCode": 200, "body": "Dispatched"}

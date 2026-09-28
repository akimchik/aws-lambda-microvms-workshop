import json
import os
import boto3
from aws_durable_execution_sdk import durable_step, DurableContext

@durable_step
def get_pr_metadata(event):
    # Mock CodeCommit PR metadata lookup
    return {
        "repo": "lambda-mvm-workshop-code-review",
        "branch": "feature/bad-code",
        "commit": "HEAD"
    }

@durable_step
def launch_microvm(image_arn):
    client = boto3.client('lambda-microvms')
    resp = client.run_microvm(
        imageIdentifier=image_arn,
        imageVersion="1.0"
    )
    return resp['microvmId'], resp['endpoint']

@durable_step
def poll_until_running(microvm_id):
    client = boto3.client('lambda-microvms')
    resp = client.get_microvm(microvmIdentifier=microvm_id)
    return resp.get('status') == 'RUNNING'

@durable_step
def create_auth_token(microvm_id):
    client = boto3.client('lambda-microvms')
    resp = client.create_microvm_auth_token(
        microvmIdentifier=microvm_id,
        expirationInMinutes=60,
        allowedPorts={"allPorts": {}}
    )
    return resp['authToken']['X-aws-proxy-auth']

@durable_step
def dispatch_review(endpoint, auth_token, callback_id, pr_data):
    import urllib.request
    req = urllib.request.Request(
        f"https://{endpoint}/review",
        data=json.dumps({"callback_id": callback_id, "pr_data": pr_data}).encode('utf-8'),
        headers={"X-aws-proxy-auth": auth_token, "Content-Type": "application/json", "X-aws-proxy-port": "9000"},
        method="POST"
    )
    with urllib.request.urlopen(req) as response:
        return response.read().decode('utf-8')

@durable_step
def terminate_microvm(microvm_id):
    client = boto3.client('lambda-microvms')
    client.terminate_microvm(microvmIdentifier=microvm_id)

def handler(event, context: DurableContext):
    image_arn = os.environ.get('IMAGE_ARN')
    
    # 1. Parse Event
    pr_data = get_pr_metadata(event)
    
    # 2. Launch MicroVM
    microvm_id, endpoint = launch_microvm(image_arn)
    
    # 3. Wait for it to boot
    context.wait_for_condition(lambda: poll_until_running(microvm_id), poll_interval_seconds=2)
    
    # 4. Generate token
    auth_token = create_auth_token(microvm_id)
    
    # 5. Mint a callback ID and dispatch
    callback = context.create_callback(name="claude-review-complete")
    dispatch_review(endpoint, auth_token, callback.id, pr_data)
    
    # 6. Suspend and wait for review callback
    try:
        review_result = callback.result()
        print("Review completed:", review_result)
    except Exception as e:
        print("Review failed:", str(e))
    
    # 7. Terminate
    terminate_microvm(microvm_id)
    
    return {"statusCode": 200, "body": "Orchestration Complete"}

import json
import os
import boto3
import urllib.request
import time

tenant_cache = {}

def handler(event, context):
    tenant = event.get('headers', {}).get('x-tenant')
    if not tenant:
        return {"statusCode": 400, "body": "Missing X-Tenant header"}
        
    image_arn = os.environ.get('IMAGE_ARN')
    region = os.environ.get('AWS_REGION', 'us-east-1')
    client = boto3.client('lambda-microvms', region_name=region)
    
    # Check cache
    microvm_id = tenant_cache.get(tenant)
    endpoint = None
    state = None
    
    if microvm_id:
        try:
            st = client.get_microvm(microvmIdentifier=microvm_id)
            state = st.get('state')
            if state == 'RUNNING':
                endpoint = st.get('endpoint')
            elif state == 'SUSPENDED':
                client.resume_microvm(microvmIdentifier=microvm_id)
                # Wait for resume
                for _ in range(10):
                    st = client.get_microvm(microvmIdentifier=microvm_id)
                    state = st.get('state')
                    if state == 'RUNNING':
                        endpoint = st.get('endpoint')
                        if endpoint:
                            break
                    time.sleep(1)
            else:
                microvm_id = None
        except Exception:
            microvm_id = None
            
    if not microvm_id:
        print(f"launching MicroVM for tenant={tenant}")
        resp = client.run_microvm(
            imageIdentifier=image_arn,
            imageVersion="1.0",
            executionRoleArn=os.environ.get('MVM_EXECUTION_ROLE_ARN'),
            idlePolicy={
                'maxIdleDurationSeconds': 60,
                'autoResumeEnabled': False,
                'suspendedDurationSeconds': 60
            }
        )
        microvm_id = resp.get('microvmId') or resp.get('MicrovmId')
        tenant_cache[tenant] = microvm_id
        
        # Wait for boot
        for _ in range(20):
            st = client.get_microvm(microvmIdentifier=microvm_id)
            state = st.get('state')
            if state == 'RUNNING':
                endpoint = st.get('endpoint')
                if endpoint:
                    break
            time.sleep(1)
            
    if not endpoint:
        return {"statusCode": 500, "body": f"MicroVM {microvm_id} failed to boot. State: {state}"}
        
    print(f"tenant={tenant} microvm={microvm_id} RUNNING at {endpoint}")
    
    # Scope token to port 8080
    token_resp = client.create_microvm_auth_token(
        microvmIdentifier=microvm_id,
        expirationInMinutes=60,
        allowedPorts=[{"port": 8080}]
    )
    auth_token = token_resp['authToken']['X-aws-proxy-auth']
    
    # Proxy to tenant MicroVM
    path = event.get('rawPath', '/api/info')
    if event.get('rawQueryString'):
        path = f"{path}?{event['rawQueryString']}"
        
    method = event.get('requestContext', {}).get('http', {}).get('method', 'GET')
    
    headers = {
        "X-aws-proxy-auth": auth_token,
        "X-aws-proxy-port": "8080",
        "X-Tenant": tenant,
        "X-Microvm-Id": microvm_id
    }
    
    data = None
    if event.get('body'):
        import base64
        if event.get('isBase64Encoded'):
            data = base64.b64decode(event['body'])
        else:
            data = event['body'].encode('utf-8')
        headers['Content-Length'] = str(len(data))
        if 'content-type' in event.get('headers', {}):
            headers['Content-Type'] = event['headers']['content-type']

    req = urllib.request.Request(
        f"https://{endpoint}{path}",
        data=data,
        headers=headers,
        method=method
    )
    
    import ssl
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    
    # Retry loop in case the app inside the MicroVM is still binding to port 8080
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=5) as response:
                return {
                    "statusCode": response.getcode(),
                    "headers": {"Content-Type": "application/json"},
                    "body": response.read().decode('utf-8')
                }
        except urllib.error.HTTPError as e:
            return {
                "statusCode": e.code,
                "body": e.read().decode('utf-8')
            }
        except urllib.error.URLError as e:
            last_err = str(e)
            time.sleep(1)
        except Exception as e:
            last_err = str(e)
            break
            
    return {
        "statusCode": 500,
        "body": f"Failed to connect to proxy: {last_err}"
    }

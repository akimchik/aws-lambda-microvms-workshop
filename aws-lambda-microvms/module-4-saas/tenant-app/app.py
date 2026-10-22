import json
import threading
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

import boto3
import os
from urllib.parse import urlparse, parse_qs

def scoped_policy(bucket, tenant): 
    return json.dumps({ 
        "Version": "2012-10-17", 
        "Statement": [ 
            {"Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": f"arn:aws:s3:::{bucket}", "Condition": {"StringLike": {"s3:prefix": [f"{tenant}/", f"{tenant}/*"]}}}, 
            {"Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], "Resource": f"arn:aws:s3:::{bucket}/{tenant}/*"}, 
        ], 
    })

def get_scoped_s3_client(tenant):
    bucket = os.environ.get('TENANT_DATA_BUCKET')
    role_arn = os.environ.get('TENANT_ACCESS_ROLE_ARN')
    sts = boto3.client('sts', region_name='us-east-1')
    creds = sts.assume_role(
        RoleArn=role_arn,
        RoleSessionName=f"tenant-{tenant}",
        Policy=scoped_policy(bucket, tenant),
        DurationSeconds=900,
    )["Credentials"]
    
    return boto3.client(
        's3', region_name='us-east-1',
        aws_access_key_id=creds['AccessKeyId'],
        aws_secret_access_key=creds['SecretAccessKey'],
        aws_session_token=creds['SessionToken']
    )

class AppHandler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode('utf-8'))

    def do_GET(self):
        parsed = urlparse(self.path)
        tenant = self.headers.get('X-Tenant', 'unknown')
        microvm_id = self.headers.get('X-Microvm-Id', 'unknown')
        bucket = os.environ.get('TENANT_DATA_BUCKET')

        if parsed.path == '/api/info':
            resp = {
                "message": "Hello from a Lambda MicroVM",
                "tenant": tenant,
                "microvm": microvm_id,
                "python": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
            }
            self._send_json(200, resp)
            
        elif parsed.path == '/api/files' or parsed.path == '/api/files/':
            query = parse_qs(parsed.query)
            target_tenant = query.get('tenant', [tenant])[0]
            prefix = f"{target_tenant}/"
            
            try:
                s3 = get_scoped_s3_client(tenant)
                res = s3.list_objects_v2(Bucket=bucket, Prefix=prefix)
                keys = [obj['Key'] for obj in res.get('Contents', [])]
                self._send_json(200, {
                    "tenant": tenant, "target_prefix": prefix, "bucket": bucket, "keys": keys
                })
            except Exception as e:
                self._send_json(403, {
                    "tenant": tenant, "target_prefix": prefix, "error": type(e).__name__, "message": str(e)
                })
                
        elif parsed.path.startswith('/api/files/'):
            filename = parsed.path.replace('/api/files/', '')
            key = f"{tenant}/{filename}"
            try:
                s3 = get_scoped_s3_client(tenant)
                res = s3.get_object(Bucket=bucket, Key=key)
                body = res['Body'].read()
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(body)
            except Exception as e:
                self._send_json(403, {
                    "tenant": tenant, "key": key, "error": type(e).__name__, "message": str(e)
                })
                
        else:
            self.send_response(404)
            self.end_headers()

    def do_PUT(self):
        parsed = urlparse(self.path)
        tenant = self.headers.get('X-Tenant', 'unknown')
        bucket = os.environ.get('TENANT_DATA_BUCKET')

        if parsed.path.startswith('/api/files/'):
            filename = parsed.path.replace('/api/files/', '')
            key = f"{tenant}/{filename}"
            length = int(self.headers.get('Content-Length', 0))
            data = self.rfile.read(length)
            
            try:
                s3 = get_scoped_s3_client(tenant)
                s3.put_object(Bucket=bucket, Key=key, Body=data)
                self._send_json(200, {
                    "tenant": tenant, "wrote": key, "bytes": len(data)
                })
            except Exception as e:
                self._send_json(403, {
                    "tenant": tenant, "key": key, "error": type(e).__name__, "message": str(e)
                })
        else:
            self.send_response(404)
            self.end_headers()

class HookHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'ready')

def run_app():
    print("[INFO] App listening on port 8080")
    HTTPServer(('0.0.0.0', 8080), AppHandler).serve_forever()

def run_hook():
    print("[INFO] Hook listening on port 9000")
    HTTPServer(('0.0.0.0', 9000), HookHandler).serve_forever()

if __name__ == '__main__':
    threading.Thread(target=run_hook, daemon=True).start()
    run_app()
